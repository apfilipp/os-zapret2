#!/bin/sh

# setup.sh — Download and compile zapret2 for OPNsense/FreeBSD
# Run once after plugin installation or to update zapret2.

ZAPRET_DIR="/usr/local/etc/zapret2"
ZAPRET_REPO="https://github.com/bol-van/zapret2.git"

set -e

echo "=== zapret2 setup ==="

# Install build + runtime dependencies if missing.
# These come from FreeBSD's main pkg repo (not OPNsense's). OPNsense ships
# with that repo *disabled* by default via an override at
# /usr/local/etc/pkg/repos/FreeBSD.conf containing { enabled: no }. We enable
# it here ONLY for the duration of the dependency install, and we ALWAYS
# restore the original state on exit — success, failure, or interrupt — via a
# trap. Leaving the FreeBSD repo enabled lets a later `pkg upgrade` pull
# FreeBSD's upstream builds over OPNsense's own forks, which corrupts system
# packages and dashboard widgets (issue #2).
FREEBSD_REPO_OVERRIDE=/usr/local/etc/pkg/repos/FreeBSD.conf
ENABLED_FREEBSD_REPO=0

restore_freebsd_repo() {
    if [ "${ENABLED_FREEBSD_REPO}" = "1" ] && [ -f "${FREEBSD_REPO_OVERRIDE}.bak" ]; then
        mv "${FREEBSD_REPO_OVERRIDE}.bak" "${FREEBSD_REPO_OVERRIDE}"
        ENABLED_FREEBSD_REPO=0
        echo "Restored FreeBSD pkg repo to its original (disabled) state."
    fi
}
# Failsafe: restore the repo no matter how the script terminates.
trap restore_freebsd_repo EXIT INT TERM HUP

if [ -f "${FREEBSD_REPO_OVERRIDE}" ] && grep -q 'enabled: no' "${FREEBSD_REPO_OVERRIDE}"; then
    echo "Temporarily enabling FreeBSD pkg repo to fetch luajit/jq/git/pkgconf..."
    cp "${FREEBSD_REPO_OVERRIDE}" "${FREEBSD_REPO_OVERRIDE}.bak"
    # Enable ONLY the base FreeBSD repo. Do NOT enable FreeBSD-kmods — no kernel
    # module is needed here, and pulling kmods risks clobbering OPNsense's own.
    cat > "${FREEBSD_REPO_OVERRIDE}" <<'EOF'
FreeBSD: { enabled: yes }
EOF
    ENABLED_FREEBSD_REPO=1
fi

# Refresh package catalogues. Do NOT use `-f` (force): a forced refresh churns
# the entire catalog against every enabled repo and was implicated in breaking
# system package state (issue #2). The default refresh fetches any missing or
# stale catalog (including the just-enabled FreeBSD repo) and is a fast no-op
# otherwise.
pkg update -q

# Install a dependency, accepting any of several candidate package names. This
# tolerates naming differences across OPNsense/FreeBSD versions: some releases
# ship `git-lite`, others only the full `git` (issue #1). Succeeds if any
# candidate is already installed or can be installed; fails only if none can.
install_dep() {
    for _name in "$@"; do
        if pkg info -q "${_name}"; then
            return 0
        fi
    done
    for _name in "$@"; do
        if pkg install -y "${_name}"; then
            return 0
        fi
    done
    echo "ERROR: could not install dependency (tried: $*)" >&2
    return 1
}

install_dep pkgconf
install_dep luajit
# Accept either the slim `git-lite` or the full `git`, whichever the running
# OPNsense/FreeBSD version offers — and skip entirely if git is already present.
install_dep git-lite git
# jq is required at runtime by zapret_service.sh to parse pluginctl JSON
# when resolving the WAN interface name.
install_dep jq

# Re-disable the FreeBSD repo now that deps are installed, so it stays off for
# the rest of the script (git clone below) and for all future pkg operations.
# The EXIT trap above is the backstop; this is the normal path.
restore_freebsd_repo

# Clone or update zapret2
if [ -d "${ZAPRET_DIR}/.git" ]; then
    echo "Updating existing zapret2 installation..."
    cd "${ZAPRET_DIR}"
    git pull --ff-only
else
    echo "Cloning zapret2..."
    rm -rf "${ZAPRET_DIR}"
    git clone --depth 1 "${ZAPRET_REPO}" "${ZAPRET_DIR}"
fi

# Compile
echo "Compiling zapret2..."
cd "${ZAPRET_DIR}"
make clean 2>/dev/null || true
make

# Verify binaries
if [ -x "${ZAPRET_DIR}/binaries/my/dvtws2" ]; then
    echo "dvtws2 compiled successfully: ${ZAPRET_DIR}/binaries/my/dvtws2"
else
    echo "ERROR: dvtws2 compilation failed!" >&2
    exit 1
fi

if [ -x "${ZAPRET_DIR}/binaries/my/tpws2" ]; then
    echo "tpws2 compiled successfully: ${ZAPRET_DIR}/binaries/my/tpws2"
fi

# Ensure config directory exists
mkdir -p "${ZAPRET_DIR}"

echo "=== zapret2 setup complete ==="
