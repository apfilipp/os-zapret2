#!/bin/sh

cat <<'EOF'
;; ->>HEADER<<- opcode: QUERY, rcode: NOERROR, id: 1
;; ANSWER SECTION:
strategy-test.example. 60 IN A 203.0.113.10
strategy-test.example. 60 IN A 203.0.113.20
strategy-test.example. 60 IN A 203.0.113.10
;; AUTHORITY SECTION:
EOF
