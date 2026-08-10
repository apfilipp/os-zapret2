#!/bin/sh

set -eu

DEST="${1:-}"

if [ -z "${DEST}" ]; then
    echo "usage: $0 <destination>" >&2
    exit 1
fi

TMP=$(mktemp -d /tmp/zapret-curl-h3.XXXXXX)

cleanup() {
    rm -rf "${TMP}"
}

trap cleanup EXIT HUP INT TERM

REPOS="${TMP}/repos"
PKGS="${TMP}/pkgs"
ROOT="${TMP}/root"

mkdir -p "${REPOS}" "${PKGS}" "${ROOT}"

FREEBSD_HOST="pkg.FreeBSD.org"

cat > "${REPOS}/FreeBSD.conf" <<EOF
FreeBSD: {
  url: "pkg+https://${FREEBSD_HOST}/\${ABI}/latest",
  mirror_type: "srv",
  signature_type: "fingerprints",
  fingerprints: "/usr/share/keys/pkg",
  enabled: yes
}
EOF

echo "==> Preparing FreeBSD package catalogue for $(pkg config abi)"

pkg -o REPOS_DIR="${REPOS}" update -f -r FreeBSD

echo "==> Fetching curl-impersonate"

pkg -o REPOS_DIR="${REPOS}" fetch -y -r FreeBSD -o "${PKGS}" curl-impersonate

PKG_FILE=$(find "${PKGS}" -type f -name 'curl-impersonate-*.pkg' | head -1)

if [ -z "${PKG_FILE}" ]; then
    echo "ERROR: curl-impersonate package was not downloaded" >&2
    exit 1
fi

# The FreeBSD repo is queried as "latest", so the version we ship is whatever
# upstream published at build time rather than a pinned release. Record it so
# the shipped bundle can be audited against THIRD_PARTY_NOTICES and so a
# surprise major bump is visible in the build log instead of silent.
PKG_VERSION=$(basename "${PKG_FILE}" .pkg | sed 's/^curl-impersonate-//')

if [ -z "${PKG_VERSION}" ]; then
    echo "ERROR: could not determine curl-impersonate version from ${PKG_FILE}" >&2
    exit 1
fi

echo "==> Resolved curl-impersonate version: ${PKG_VERSION}"

echo "==> Extracting ${PKG_FILE}"

tar -xf "${PKG_FILE}" -C "${ROOT}"

LICENSE_DIR=$(find "${ROOT}/usr/local/share/licenses" -maxdepth 1 \
    -type d -name 'curl-impersonate-*' | head -1)

if [ -z "${LICENSE_DIR}" ]; then
    echo "ERROR: curl-impersonate license files not found in package" >&2
    exit 1
fi

SRC_BIN="${ROOT}/usr/local/bin/curl-impersonate"

if [ ! -x "${SRC_BIN}" ]; then
    echo "ERROR: curl-impersonate binary not found in package" >&2
    exit 1
fi

echo "==> Checking HTTP/3 support"

if ! "${SRC_BIN}" -V | grep -q 'HTTP3'; then
    echo "ERROR: curl-impersonate does not advertise HTTP3 support" >&2
    "${SRC_BIN}" -V >&2 || true
    exit 1
fi

rm -rf "${DEST}"
mkdir -p "${DEST}/bin" "${DEST}/licenses"

cp "${SRC_BIN}" "${DEST}/bin/curl"
chmod 755 "${DEST}/bin/curl"

cp -R "${LICENSE_DIR}/." "${DEST}/licenses/"

printf 'curl-impersonate %s\n' "${PKG_VERSION}" > "${DEST}/VERSION"

echo "==> Verifying private HTTP/3 curl"

if ! "${DEST}/bin/curl" -V | grep -q 'HTTP3'; then
    echo "ERROR: private curl failed HTTP3 verification" >&2
    "${DEST}/bin/curl" -V >&2 || true
    exit 1
fi

echo "==> HTTP/3 curl bundle ready (curl-impersonate ${PKG_VERSION})"
"${DEST}/bin/curl" -V
