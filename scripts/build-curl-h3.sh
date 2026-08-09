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

echo "==> Verifying private HTTP/3 curl"

if ! "${DEST}/bin/curl" -V | grep -q 'HTTP3'; then
    echo "ERROR: private curl failed HTTP3 verification" >&2
    "${DEST}/bin/curl" -V >&2 || true
    exit 1
fi

echo "==> HTTP/3 curl bundle ready"
"${DEST}/bin/curl" -V