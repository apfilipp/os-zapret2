# Extract strategies that blockcheck2 has explicitly confirmed.
#
# Pass -v prefix="-" when the caller needs the historical live-status
# format. Without a prefix the output matches blockcheck2 SUMMARY lines.

function emit(value)
{
    if (value != "" && !seen[value]++) {
        if (prefix != "") {
            print prefix " " value
        } else {
            print value
        }
    }
}

/^\* curl_test_/ {
    test_name=$0
    sub(/^\* /, "", test_name)
    candidate=""
    next
}

/^- checking without DPI bypass/ {
    if (test_name != "") {
        candidate=test_name " : working without bypass"
    }
    next
}

/^- curl_test_.* : dvtws2([[:space:]]|$)/ {
    candidate=$0
    sub(/^- /, "", candidate)
    next
}

/^UNAVAILABLE([[:space:]]|$)/ {
    candidate=""
    next
}

/^!!!!! curl_test_.*: working strategy found for ipv[46] / {
    confirmed=$0
    sub(/^!!!!! /, "", confirmed)
    sub(/: working strategy found for /, " ", confirmed)
    sub(/ !!!!!$/, "", confirmed)
    emit(confirmed)
    candidate=""
    next
}

/^[[:space:]]*!!!!! AVAILABLE !!!!!/ {
    emit(candidate)
    candidate=""
    next
}
