#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
parser="${repo_root}/src/opnsense/scripts/OPNsense/Zapret/blockcheck_winners.awk"
fixture="${repo_root}/tests/fixtures/blockcheck-winners.log"
expected="${repo_root}/tests/fixtures/blockcheck-winners.expected"
actual=$(mktemp "${TMPDIR:-/tmp}/blockcheck-winners.XXXXXX")
prefixed=$(mktemp "${TMPDIR:-/tmp}/blockcheck-winners-prefixed.XXXXXX")

cleanup()
{
    rm -f "${actual}" "${prefixed}"
}
trap cleanup EXIT INT TERM HUP

awk -f "${parser}" "${fixture}" > "${actual}"
diff -u "${expected}" "${actual}"

awk -v prefix='-' -f "${parser}" "${fixture}" > "${prefixed}"
awk '
    !/^- curl_test_[^ ]+ ipv[46] [^ ]+ : / { exit 1 }
' "${prefixed}"

echo 'blockcheck winner parser tests: ok'
