#!/bin/sh

# blockcheck_job.sh — background job controller for blockcheck.sh

BLOCKCHECK="/usr/local/opnsense/scripts/OPNsense/Zapret/blockcheck.sh"
PIDFILE="/var/run/zapret-blockcheck.pid"
RESULT="/var/run/zapret-blockcheck.result"
META="/var/run/zapret-blockcheck.meta"
LOG_DIR="/var/log/zapret"

ACTION="$1"
DOMAIN="$2"
MODE="${3:-all}"

case "${MODE}" in
    http|tls12|tls13|http3|all)
        ;;
    *)
        MODE="all"
        ;;
esac

is_running()
{
    if [ -f "${PIDFILE}" ]; then
        pid=$(cat "${PIDFILE}" 2>/dev/null)
        if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null; then
            return 0
        fi
        rm -f "${PIDFILE}"
    fi
    return 1
}

case "${ACTION}" in
    start)
        if [ -z "${DOMAIN}" ]; then
            echo '{"status":"error","message":"no domain specified"}'
            exit 0
        fi

        if ! echo "${DOMAIN}" | grep -qE '^[a-zA-Z0-9][a-zA-Z0-9.-]+[a-zA-Z]{2,}$'; then
            echo '{"status":"error","message":"invalid domain format"}'
            exit 0
        fi

        if is_running; then
            echo '{"status":"error","message":"blockcheck is already running"}'
            exit 0
        fi

        rm -f "${RESULT}" "${META}"

        started=$(date -u +%s)

        {
            echo "${DOMAIN}"
            echo "${started}"
        } > "${META}"

        /usr/sbin/daemon \
            -p "${PIDFILE}" \
            -o "${RESULT}" \
            "${BLOCKCHECK}" "${DOMAIN}" "${MODE}"

        /usr/local/bin/jq -nc \
            --arg domain "${DOMAIN}" \
            --argjson started "${started}" \
            '{status:"ok", state:"started", domain:$domain, started_epoch:$started}'
        ;;

    status)
        if [ ! -f "${META}" ]; then
            echo '{"status":"ok","state":"idle"}'
            exit 0
        fi

        domain=$(sed -n '1p' "${META}")
        started=$(sed -n '2p' "${META}")
        now=$(date -u +%s)
        elapsed=$((now - started))

        log_domain=$(printf '%s' "${domain}" | tr -c 'a-zA-Z0-9.-' '_')
        log_file=$(ls -1t "${LOG_DIR}"/blockcheck-*-"${log_domain}".log 2>/dev/null | head -1)

        if is_running; then
            stage=""
            attempts=0
            winners=""
            tail_output=""

            if [ -n "${log_file}" ] && [ -f "${log_file}" ]; then
                stage=$(grep -E '^[*-] curl_test_' "${log_file}" 2>/dev/null | tail -1)
                attempts=$(grep -cE '^- curl_test_.* : dvtws2 ' "${log_file}" 2>/dev/null)
		winners=$(awk '
 		    /^- curl_test_/ {
        		candidate=$0
       		        next
    		}
    /^[[:space:]]*!!!!! AVAILABLE !!!!!/ && candidate != "" {
        print candidate
        candidate=""
    }
' "${log_file}" 2>/dev/null)
                tail_output=$(tail -20 "${log_file}" 2>/dev/null)
            fi

            /usr/local/bin/jq -nc \
                --arg domain "${domain}" \
                --arg stage "${stage}" \
                --arg winners "${winners}" \
                --arg log_file "${log_file}" \
                --arg tail "${tail_output}" \
                --argjson elapsed "${elapsed}" \
                --argjson attempts "${attempts}" \
                '{
                    status:"ok",
                    state:"running",
                    domain:$domain,
                    elapsed_seconds:$elapsed,
                    stage:$stage,
                    attempts:$attempts,
		    winners:(
		        $winners
			| split("\n")
			| map(
 			    select(length > 0)
			    | . as $line
			    | try capture("^- (?<test>[^ ]+) ipv(?<ip_version>[0-9]+) (?<domain>[^ ]+) : (?<daemon>[^ ]+) (?<strategy>.*)$")
 			      catch {raw:$line}
			  )
		    ),                    
                    log_file:$log_file,
                    tail:$tail
                }'
            exit 0
        fi

        if [ -s "${RESULT}" ]; then
            /usr/local/bin/jq -nc \
                --arg domain "${domain}" \
                --argjson elapsed "${elapsed}" \
                --slurpfile result "${RESULT}" \
                '{
                    status:"ok",
                    state:"finished",
                    domain:$domain,
                    elapsed_seconds:$elapsed,
                    result:($result[0] // null)
                }'
        else
            /usr/local/bin/jq -nc \
                --arg domain "${domain}" \
                --argjson elapsed "${elapsed}" \
                '{status:"error", state:"finished", domain:$domain, elapsed_seconds:$elapsed, message:"blockcheck finished without result"}'
        fi
        ;;

    *)
        echo '{"status":"error","message":"usage: blockcheck_job.sh start <domain> | status"}'
        ;;
esac

exit 0
