#!/bin/sh

resolved=""
previous=""

for argument in "$@"; do
    if [ "${previous}" = "--resolve" ]; then
        resolved="${argument}"
        break
    fi
    previous="${argument}"
done

case "${resolved}" in
    *:203.0.113.10)
        printf 'http=200 remote=203.0.113.10 connect=0.010000s tls=0.020000s total=0.030000s'
        exit 0
        ;;
    *:203.0.113.20)
        printf 'curl: (28) Connection timed out http=000 remote=203.0.113.20 connect=0.010000s tls=0.000000s total=5.000000s'
        exit 28
        ;;
esac

echo "unexpected --resolve value: ${resolved}" >&2
exit 2
