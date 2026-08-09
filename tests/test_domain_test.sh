#!/bin/sh

set -eu

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="${REPO_ROOT}/src/opnsense/scripts/OPNsense/Zapret/test_domain.sh"
FIXTURES="${REPO_ROOT}/tests/fixtures"
TMP_ROOT=$(mktemp -d)

cleanup()
{
    rm -f "${TMP_ROOT}"/logs/* "${TMP_ROOT}"/state/* 2>/dev/null || true
    rmdir "${TMP_ROOT}/logs" "${TMP_ROOT}/state" "${TMP_ROOT}" 2>/dev/null || true
}

trap cleanup EXIT
mkdir "${TMP_ROOT}/logs" "${TMP_ROOT}/state"

encode_strategy()
{
    printf '%s' "$1" | base64 | tr -d '\n'
}

run_test()
{
    STRATEGY_TEST_SKIP_DVTWS=1 \
    STRATEGY_TEST_STATE_DIR="${TMP_ROOT}/state" \
    STRATEGY_TEST_LOG_DIR="${TMP_ROOT}/logs" \
    DRILL="${FIXTURES}/test-domain-drill.sh" \
    CURL="${FIXTURES}/test-domain-curl.sh" \
    sh "${SCRIPT}" "$@"
}

strategy="--payload=tls_client_hello --lua-desync=tcpseg:pos=0,midsld"
mkdir "${TMP_ROOT}/state/zapret-strategy-test.lock"
printf '%s\n' 99999999 > "${TMP_ROOT}/state/zapret-strategy-test.lock/pid"
output=$(run_test strategy-test.example "$(encode_strategy "${strategy}")")

printf '%s\n' "${output}" | grep -q 'Resolved IPv4 addresses (2):'
printf '%s\n' "${output}" | grep -q -- '--- IPv4 203.0.113.10 ---'
printf '%s\n' "${output}" | grep -q -- '--- IPv4 203.0.113.20 ---'
[ "$(printf '%s\n' "${output}" | grep -cE '^  [0-9][0-9] PASS ')" -eq 10 ]
[ "$(printf '%s\n' "${output}" | grep -cE '^  [0-9][0-9] FAIL ')" -eq 10 ]
printf '%s\n' "${output}" | grep -q 'Overall Result: UNSTABLE'
printf '%s\n' "${output}" | grep -q 'Successful TLS requests: 10/20 (50%)'

restricted="--payload=tls_client_hello --port=9999 --lua-desync=fake"
if restricted_output=$(run_test strategy-test.example "$(encode_strategy "${restricted}")" 2>&1); then
    echo "restricted strategy unexpectedly succeeded" >&2
    exit 1
fi
printf '%s\n' "${restricted_output}" | grep -q 'option managed by the test runner'

echo "test_domain tests passed"
