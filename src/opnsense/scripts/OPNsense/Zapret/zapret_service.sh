#!/bin/sh

# zapret_service.sh — Service management for zapret2 on OPNsense
# Called by configd via actions_zapret.conf.
#
# Architecture — ipfw divert + sockarg loop-guard (inherited from
# v1.1.0 which ran flawlessly for 3 weeks on bare-metal PPPoE and was
# verified to work for NAT'd LAN clients):
#
#   - `ipfw divert $DIVERT_PORT tcp from any to any $port out not sockarg
#     xmit $wan_dev` for each configured port (80, 443). Only matches
#     outbound on WAN and only when the packet DOESN'T already carry the
#     sockarg tag (so reinjected packets from dvtws2 sail past).
#   - dvtws2 is started with `--sockarg=0x200`, which makes it mark every
#     reinjected packet with that tag. Combined with `not sockarg` above,
#     this is the clean loop-prevention pair.
#   - daemon(8) -r supervision auto-respawns dvtws2 within ~1s on crash.
#   - safety watchdog probes a control URL every minute; 3 consecutive
#     failures → stop the service so a bad strategy can't kill household
#     internet for long.
#
# Why NOT pf divert-to (the v1.6.x approach): empirically broken for
# NAT'd LAN-client traffic on both virtio and bare-metal+PPPoE. See
# memory/feedback_v110_ipfw_works_pf_divert_broken.md for the diagnosis.

ZAPRET_DIR="/usr/local/etc/zapret2"
CONFIG="${ZAPRET_DIR}/zapret.conf"
PIDFILE="/var/run/dvtws2.pid"
SUPERVISOR_PIDFILE="/var/run/dvtws2-supervisor.pid"
WATCHDOG_PIDFILE="/var/run/zapret-watchdog.pid"
WATCHDOG_SUPERVISOR_PIDFILE="/var/run/zapret-watchdog-supervisor.pid"
WATCHDOG_LOOP="/usr/local/opnsense/scripts/OPNsense/Zapret/watchdog_loop.sh"
DVTWS_BIN="${ZAPRET_DIR}/binaries/my/dvtws2"
HOSTLIST="${ZAPRET_DIR}/hostlist.txt"
HOSTLIST_EXCLUDE="${ZAPRET_DIR}/hostlist-exclude.txt"
AUTOHOSTLIST="${ZAPRET_DIR}/autohostlist.txt"
LUA_LIB="${ZAPRET_DIR}/lua/zapret-lib.lua"
LUA_ANTIDPI="${ZAPRET_DIR}/lua/zapret-antidpi.lua"

# ipfw rule numbers we own. Range 19000-19010 — high enough to avoid
# OPNsense's own rules, low enough to fire before the default-accept at
# 65534. We add one rule per configured port (80, 443 by default → two
# rules: 19000 and 19001).
RULE_BASE=19000
RULE_MAX=$((RULE_BASE + 10))

load_config() {
    if [ ! -f "${CONFIG}" ]; then
        echo "zapret is not running (configuration file not found — save settings first)"
        exit 1
    fi
    . "${CONFIG}"
}

resolve_interface() {
    local iface="$1"

    # Direct match first (raw device names like pppoe2, igc0)
    if ifconfig "${iface}" > /dev/null 2>&1; then
        echo "${iface}"
        return
    fi

    # Map an OPNsense logical interface (opt11, wan, lan, …) to its kernel
    # device. pluginctl -4 emits JSON like:
    #   {"opt11":[{"address":"...","device":"pppoe2", ...}]}
    local dev=""
    if [ -x /usr/local/bin/jq ]; then
        dev=$(/usr/local/sbin/pluginctl -4 "${iface}" 2>/dev/null \
            | /usr/local/bin/jq -r --arg if "${iface}" '.[$if][0].device // empty')
    fi
    if [ -n "${dev}" ]; then
        echo "${dev}"
        return
    fi

    # Last resort: hand the original string back to the caller.
    echo "${iface}"
}

remove_ipfw_rules() {
    # Delete anything in our reserved rule range. Silent if the rule
    # doesn't exist. Run on stop AND before adding on start (so a crashed
    # previous invocation doesn't leave stale rules around).
    local r=${RULE_BASE}
    while [ ${r} -le ${RULE_MAX} ]; do
        /sbin/ipfw -q delete ${r} 2>/dev/null
        r=$((r + 1))
    done
}

ensure_ipfw_default_accept() {
    # ipfw's default ruleset ends at 65535 with "deny ip from any to any"
    # UNLESS the kernel was built with IPFIREWALL_DEFAULT_TO_ACCEPT or
    # the sysctl is 1. On OPNsense neither is guaranteed, so we add an
    # explicit accept-all at 65534 (just inside the default-deny) the
    # first time we enable ipfw. Without this, loading the ipfw module
    # instantly drops every packet the box is handling.
    local default_accept=$(/sbin/sysctl -n net.inet.ip.fw.default_to_accept 2>/dev/null)
    if [ "${default_accept}" != "1" ]; then
        /sbin/ipfw -q add 65534 allow ip from any to any 2>/dev/null || true
    fi
}

configure_ipfw_reinject() {
    # Make ipfw's divert fire BEFORE pf on the outbound IPv4 path, so pf
    # builds correct state for dvtws2's reinjected/desynced packets instead
    # of dropping their return traffic. THE ORDER OF THESE STEPS MATTERS —
    # it was verified live on OPNsense 26.1 / FreeBSD 14 (bare-metal PPPoE):
    #
    #   - With pf ahead of ipfw, the blocked site's reinjected ClientHello
    #     goes out but the server's SYN-ACK is dropped by pf (no matching
    #     state) and the connection hangs — even general HTTPS breaks.
    #   - With ipfw ahead of pf, divert fires AND traffic completes: blocked
    #     domain bypasses, untouched domains keep working.
    #
    # The legacy `net.inet.ip.pfil.outbound=ipfw,pf` knob USED to set this
    # order but DOES NOT EXIST on FreeBSD 14 (the OID is gone), so it can't
    # be relied on. The working mechanism is pfil hook (re)registration order:
    #
    # 1) Enable ipfw FIRST. Enabling links ipfw's hook into the `inet` pfil
    #    head — but it appends AFTER pf (pf registered at boot). `kldload`
    #    alone is not enough: on OPNsense ipfw is usually already resident
    #    (e.g. blockcheck loads it then restores enable=0 on exit), so the
    #    `kldstat || kldload` guard short-circuits and enable stays 0 — then
    #    the divert rules are installed but ipfw evaluates NOTHING. Set it
    #    explicitly, and set it here so the hook is linked before step 2.
    /sbin/sysctl net.inet.ip.fw.one_pass=1 >/dev/null 2>&1
    /sbin/sysctl net.inet.ip.fw.enable=1   >/dev/null 2>&1

    # 2) THEN bounce pf. Disabling unlinks pf's hooks; re-enabling appends
    #    them to the BACK of the chain — i.e. AFTER ipfw, which is now
    #    already linked. Result on the outbound `inet` head:
    #        ipfw:default   (runs first → divert)
    #        pf:default-out (runs second → NAT/state on the final packets)
    #    Doing this bounce BEFORE enabling ipfw (as a previous revision did)
    #    leaves ipfw behind pf and silently breaks the bypass.
    /sbin/pfctl -d >/dev/null 2>&1
    /sbin/pfctl -e >/dev/null 2>&1
}

start_service() {
    load_config

    if [ "${ZAPRET_ENABLED}" != "1" ]; then
        echo "zapret is not running (disabled in settings)"
        exit 0
    fi

    # Already running?
    if [ -f "${SUPERVISOR_PIDFILE}" ] && kill -0 "$(cat ${SUPERVISOR_PIDFILE})" 2>/dev/null; then
        echo "zapret is already running as pid $(cat ${PIDFILE} 2>/dev/null || echo unknown)"
        exit 0
    fi

    if [ ! -x "${DVTWS_BIN}" ]; then
        echo "dvtws2 binary not found at ${DVTWS_BIN} — run setup.sh first" >&2
        exit 1
    fi

    # Load required kernel modules. ipdivert is the divert socket
    # backend; ipfw is the firewall that owns our divert rules.
    kldstat -q -m ipdivert || kldload ipdivert
    kldstat -q -m ipfw     || kldload ipfw
    ensure_ipfw_default_accept
    configure_ipfw_reinject

    local wan_dev=$(resolve_interface "${WAN_IF}")
    if [ -z "${wan_dev}" ]; then
        echo "could not resolve WAN interface '${WAN_IF}' to a kernel device" >&2
        exit 1
    fi

    # Build dvtws2 args
    local args="--port=${DIVERT_PORT}"
    [ -f "${LUA_LIB}" ]      && args="${args} --lua-init=@${LUA_LIB}"
    [ -f "${LUA_ANTIDPI}" ]  && args="${args} --lua-init=@${LUA_ANTIDPI}"
    [ -n "${HTTP_ARGS}" ]    && args="${args} ${HTTP_ARGS}"
    [ -n "${HTTPS_ARGS}" ]   && args="${args} ${HTTPS_ARGS}"

    if [ "${HOSTLIST_MODE}" = "list" ] && [ -f "${HOSTLIST}" ] && [ -s "${HOSTLIST}" ]; then
        args="${args} --hostlist=${HOSTLIST}"
    elif [ "${HOSTLIST_MODE}" = "auto" ]; then
        touch "${AUTOHOSTLIST}" 2>/dev/null
        args="${args} --hostlist-auto=${AUTOHOSTLIST}"
    fi

    if [ -f "${HOSTLIST_EXCLUDE}" ] && [ -s "${HOSTLIST_EXCLUDE}" ]; then
        args="${args} --hostlist-exclude=${HOSTLIST_EXCLUDE}"
    fi

    [ -n "${EXTRA_ARGS}" ] && args="${args} ${EXTRA_ARGS}"

    # Run dvtws2 under daemon(8) -r so a crash auto-restarts within 1s.
    # No --daemon / --pidfile to dvtws2 — daemon(8) manages those.
    #
    # `--user=nobody` drops privs to UID 65534 AFTER dvtws2 has bound its
    # raw/divert sockets. This is what enables our `not uid 65534` ipfw
    # filter (see remove/install rules below) to skip dvtws2's reinjected
    # packets — without it, the reinjects re-enter our own divert rule
    # and produce the catastrophic million-packet loop observed on virtio.
    /usr/sbin/daemon \
        -P "${SUPERVISOR_PIDFILE}" \
        -p "${PIDFILE}" \
        -r -R 1 \
        -t zapret2 \
        -f \
        ${DVTWS_BIN} ${args} --sockarg=0x200 --user=nobody

    sleep 1
    if [ ! -f "${SUPERVISOR_PIDFILE}" ] || ! kill -0 "$(cat ${SUPERVISOR_PIDFILE})" 2>/dev/null; then
        echo "dvtws2 supervisor failed to start" >&2
        exit 1
    fi
    if [ ! -f "${PIDFILE}" ] || ! kill -0 "$(cat ${PIDFILE})" 2>/dev/null; then
        sleep 2
        if [ ! -f "${PIDFILE}" ] || ! kill -0 "$(cat ${PIDFILE})" 2>/dev/null; then
            kill "$(cat ${SUPERVISOR_PIDFILE})" 2>/dev/null
            rm -f "${SUPERVISOR_PIDFILE}"
            echo "dvtws2 child failed to start — check strategy arguments" >&2
            exit 1
        fi
    fi

    # Install ipfw divert rules — one per port. Exact form from upstream
    # zapret's pfSense script (init.d/pfsense/zapret.sh:22):
    #
    #   divert 989 tcp from any to any 80,443 out not diverted not sockarg
    #
    # Loop-guard: `not diverted not sockarg` — BOTH conditions combined.
    # - `not diverted` checks the M_IPFW_DIVERT mbuf flag (IPv4).
    # - `not sockarg` checks SO_USER_COOKIE (IPv4 only; FreeBSD kernel
    #   ignores sockarg on IPv6, which is why upstream uses a second
    #   divert socket for IPv6 and falls back to `diverted`-only.)
    #
    # Either of these flags alone was insufficient in our virtio tests
    # (million-packet loops). Combined with the `pfctl -d ; pfctl -e`
    # bounce in configure_ipfw_reinject above, traffic flows correctly.
    #
    # `xmit $wan_dev` scopes to outbound on the WAN device so we only
    # intercept traffic actually leaving the firewall.
    remove_ipfw_rules
    local rulenum=${RULE_BASE}
    local IFS_SAVED="${IFS}"
    IFS=","
    for port in ${PORTS}; do
        /sbin/ipfw -qf add ${rulenum} divert ${DIVERT_PORT} tcp from any to any ${port} out not diverted not sockarg xmit ${wan_dev}
        rulenum=$((rulenum + 1))
    done
    IFS="${IFS_SAVED}"

    # Start the safety watchdog under daemon(8) too. It probes a control URL
    # every minute and stops the service if 3 consecutive checks fail —
    # so a misconfigured strategy that breaks general HTTPS auto-recovers
    # within ~3 minutes instead of leaving the household offline.
    if [ -x "${WATCHDOG_LOOP}" ]; then
        /usr/sbin/daemon \
            -P "${WATCHDOG_SUPERVISOR_PIDFILE}" \
            -p "${WATCHDOG_PIDFILE}" \
            -r -R 5 \
            -t zapret-watchdog \
            -f \
            "${WATCHDOG_LOOP}"
    fi

    echo "zapret is running as pid $(cat ${PIDFILE}) (supervisor pid $(cat ${SUPERVISOR_PIDFILE}))"
}

stop_service() {
    # Remove ipfw divert rules FIRST so traffic flows normally during
    # the tear-down window. If we killed dvtws2 first, the rules would
    # still divert to a dead socket and packets would drop until we got
    # around to removing them.
    remove_ipfw_rules

    # Kill the watchdog FIRST (before its supervisor can respawn it).
    # Also clean any orphans from previous installs that lost their
    # supervisor's pidfile during pkg upgrade.
    if [ -f "${WATCHDOG_SUPERVISOR_PIDFILE}" ]; then
        kill "$(cat ${WATCHDOG_SUPERVISOR_PIDFILE})" 2>/dev/null
        rm -f "${WATCHDOG_SUPERVISOR_PIDFILE}"
    fi
    if [ -f "${WATCHDOG_PIDFILE}" ]; then
        kill "$(cat ${WATCHDOG_PIDFILE})" 2>/dev/null
        rm -f "${WATCHDOG_PIDFILE}"
    fi
    pkill -f watchdog_loop.sh 2>/dev/null
    pkill -f "daemon: zapret-watchdog" 2>/dev/null
    rm -f /var/run/zapret-watchdog.state

    # Kill the dvtws2 supervisor so daemon -r doesn't respawn dvtws2
    if [ -f "${SUPERVISOR_PIDFILE}" ]; then
        kill "$(cat ${SUPERVISOR_PIDFILE})" 2>/dev/null
        rm -f "${SUPERVISOR_PIDFILE}"
    fi

    # Then dvtws2 itself, in case it survives or wasn't supervised
    if [ -f "${PIDFILE}" ]; then
        kill "$(cat ${PIDFILE})" 2>/dev/null
        rm -f "${PIDFILE}"
    fi
    killall dvtws2 2>/dev/null

    echo "zapret is not running (stopped)"
}

status_service() {
    # Output must match the convention ApiMutableServiceControllerBase
    # parses: substring "is running" → running; "not running" → stopped.
    if [ -f "${PIDFILE}" ] && kill -0 "$(cat ${PIDFILE})" 2>/dev/null; then
        echo "zapret is running as pid $(cat ${PIDFILE})"
    else
        echo "zapret is not running"
    fi
}

reconfigure_service() {
    /usr/local/sbin/configctl template reload OPNsense/Zapret

    load_config

    if [ "${ZAPRET_ENABLED}" = "1" ]; then
        stop_service > /dev/null 2>&1
        sleep 1
        start_service
    else
        stop_service
    fi
}

case "$1" in
    start)       start_service ;;
    stop)        stop_service ;;
    restart)     stop_service > /dev/null 2>&1; sleep 1; start_service ;;
    status)      status_service ;;
    reconfigure) reconfigure_service ;;
    *)
        echo "usage: zapret_service.sh {start|stop|restart|status|reconfigure}" >&2
        exit 1
        ;;
esac
