#!/bin/sh

# blockcheck_job.sh — background job controller for blockcheck.sh

BLOCKCHECK="/usr/local/opnsense/scripts/OPNsense/Zapret/blockcheck.sh"
PIDFILE="/var/run/zapret-blockcheck.pid"
RESULT="/var/run/zapret-blockcheck.result"
META="/var/run/zapret-blockcheck.meta"
STOPFILE="/var/run/zapret-blockcheck.stop"
START_LOCK="/var/run/zapret-blockcheck.start.lock"
LOG_DIR="/var/log/zapret"

umask 077

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
        case "${pid}" in
            ''|*[!0-9]*)
                ;;
            *)
                if kill -0 "${pid}" 2>/dev/null; then
                    pid_command=$(ps -o command= -p "${pid}" 2>/dev/null)
                    case "${pid_command}" in
                        *"${BLOCKCHECK}"*)
                            return 0
                            ;;
                    esac

                    # daemon(8) writes its child PID just before exec(2).  A
                    # startup poll must not unlink that fresh pidfile while
                    # the child command still briefly appears as daemon.
                    if [ "${1:-}" = "preserve-live-pidfile" ]; then
                        return 1
                    fi
                fi
                ;;
        esac
        rm -f "${PIDFILE}"
    fi
    return 1
}

release_start_lock()
{
    lock_owner=$(cat "${START_LOCK}/pid" 2>/dev/null)
    if [ "${lock_owner}" = "$$" ]; then
        rm -f "${START_LOCK}/pid" "${META}.$$"
        rmdir "${START_LOCK}" 2>/dev/null
    fi
}

acquire_start_lock()
{
    if ! mkdir "${START_LOCK}" 2>/dev/null; then
        # A second caller can observe the directory just before the first one
        # writes its owner PID. Give that tiny window time to close before
        # deciding whether the lock is stale.
        [ -f "${START_LOCK}/pid" ] || sleep 1
        lock_owner=$(cat "${START_LOCK}/pid" 2>/dev/null)

        case "${lock_owner}" in
            ''|*[!0-9]*)
                ;;
            *)
                if kill -0 "${lock_owner}" 2>/dev/null; then
                    lock_command=$(ps -o command= -p "${lock_owner}" 2>/dev/null)
                    case "${lock_command}" in
                        *blockcheck_job.sh*)
                            return 1
                            ;;
                    esac
                fi
                ;;
        esac

        rm -f "${START_LOCK}/pid"
        rmdir "${START_LOCK}" 2>/dev/null || return 1
        mkdir "${START_LOCK}" 2>/dev/null || return 1
    fi

    if ! printf '%s\n' "$$" > "${START_LOCK}/pid"; then
        rmdir "${START_LOCK}" 2>/dev/null
        return 1
    fi

    return 0
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

        if ! acquire_start_lock; then
            echo '{"status":"error","message":"blockcheck start is already in progress"}'
            exit 0
        fi
        trap release_start_lock EXIT
        trap 'exit 1' INT TERM HUP

        if is_running; then
            echo '{"status":"error","message":"blockcheck is already running"}'
            exit 0
        fi

        rm -f "${PIDFILE}" "${RESULT}" "${META}" "${STOPFILE}"
        started=$(date -u +%s)

        if ! {
            echo "${DOMAIN}"
            echo "${started}"
        } > "${META}.$$"; then
            rm -f "${META}.$$"
            echo '{"status":"error","message":"could not create blockcheck metadata"}'
            exit 0
        fi

        if ! mv -f "${META}.$$" "${META}"; then
            rm -f "${META}.$$"
            echo '{"status":"error","message":"could not publish blockcheck metadata"}'
            exit 0
        fi

        if ! /usr/sbin/daemon \
            -p "${PIDFILE}" \
            -o "${RESULT}" \
            "${BLOCKCHECK}" "${DOMAIN}" "${MODE}"; then
            rm -f "${PIDFILE}" "${META}"
            echo '{"status":"error","message":"could not launch blockcheck"}'
            exit 0
        fi

        launch_wait=0
        while [ "${launch_wait}" -lt 20 ] && ! is_running preserve-live-pidfile; do
            sleep 0.1
            launch_wait=$((launch_wait + 1))
        done

        if ! is_running preserve-live-pidfile; then
            rm -f "${PIDFILE}" "${META}"
            echo '{"status":"error","message":"blockcheck process exited during startup"}'
            exit 0
        fi

        /usr/local/bin/jq -nc \
            --arg domain "${DOMAIN}" \
            --argjson started "${started}" \
            '{status:"ok", state:"started", domain:$domain, started_epoch:$started}'
        ;;

    stop)
        if [ ! -f "${META}" ]; then
            echo '{"status":"ok","state":"idle"}'
            exit 0
        fi

        domain=$(sed -n '1p' "${META}")
        started=$(sed -n '2p' "${META}")

        if ! is_running; then
            /usr/local/bin/jq -nc \
                --arg domain "${domain}" \
                '{status:"ok", state:"stopped", domain:$domain}'
            exit 0
        fi

        pid=$(cat "${PIDFILE}" 2>/dev/null)
        pgid=$(ps -o pgid= -p "${pid}" 2>/dev/null | tr -d '[:space:]')

        case "${pgid}" in
            ''|*[!0-9]*)
                echo '{"status":"error","message":"could not determine blockcheck process group"}'
                exit 0
                ;;
        esac

        date -u +%s > "${STOPFILE}"

        if ! /bin/kill -TERM "-${pgid}" 2>/dev/null; then
            echo '{"status":"error","message":"could not stop blockcheck process group"}'
            exit 0
        fi

        /usr/local/bin/jq -nc \
            --arg domain "${domain}" \
            '{status:"ok", state:"stopping", domain:$domain}'
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
		
		# Immediately after a new run starts, the new log may not exist yet.
		# Do not accidentally expose results from the previous run.
		if [ -n "${log_file}" ] && [ -f "${log_file}" ]; then
			log_mtime=$(/usr/bin/stat -f '%m' "${log_file}" 2>/dev/null || echo 0)
		
			if [ "${log_mtime}" -lt "${started}" ]; then
				log_file=""
			fi
		fi
		
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

	if [ -f "${STOPFILE}" ]; then
            /usr/local/bin/jq -nc \
                --arg domain "${domain}" \
            	--arg log_file "${log_file}" \
            	--argjson elapsed "${elapsed}" \
            	'{
                    status:"ok",
                    state:"stopped",
                    domain:$domain,
                    elapsed_seconds:$elapsed,
                    log_file:$log_file
            	}'
            exit 0
    	fi

        if [ -s "${RESULT}" ]; then
            result_json=$(awk '/^[[:space:]]*\{/ {line=$0} END {print line}' "${RESULT}")

            if [ -n "${result_json}" ] && \
               printf '%s\n' "${result_json}" | /usr/local/bin/jq -e . >/dev/null 2>&1; then
                /usr/local/bin/jq -nc \
                    --arg domain "${domain}" \
                    --argjson elapsed "${elapsed}" \
                    --argjson result "${result_json}" \
                    '{
                        status:"ok",
                        state:"finished",
                        domain:$domain,
                        elapsed_seconds:$elapsed,
                        result:$result
                    }'
            else
                /usr/local/bin/jq -nc \
                    --arg domain "${domain}" \
                    --argjson elapsed "${elapsed}" \
                    '{status:"error", state:"finished", domain:$domain, elapsed_seconds:$elapsed, message:"blockcheck finished without valid result"}'
            fi
        else
            /usr/local/bin/jq -nc \
                --arg domain "${domain}" \
                --argjson elapsed "${elapsed}" \
                '{status:"error", state:"finished", domain:$domain, elapsed_seconds:$elapsed, message:"blockcheck finished without result"}'
        fi
	;;

    *)
	echo '{"status":"error","message":"usage: blockcheck_job.sh start <domain> [mode] | status | stop"}'
        ;;
esac

exit 0
