#!/bin/sh
# BLOCKING=1 or --fg: foreground test. DRY_RUN=1: no changes. DEBUG=1: progress toasts.
# METHODS, NTP_SERVERS, HTTP_HOSTS, BOOT_DELAY, MAX_ATTEMPTS, RETRY_DELAY, PER_SERVER_TIMEOUT override defaults.

[ "$1" = "--fg" ] && BLOCKING=1
BLOCKING="${BLOCKING:-0}"
DRY_RUN="${DRY_RUN:-0}"
DEBUG="${DEBUG:-0}"
METHODS="${METHODS:-ntpd ntpdate node http}"
NTP_SERVERS="${NTP_SERVERS:-0.pool.ntp.org 1.pool.ntp.org time.google.com time.cloudflare.com}"
HTTP_HOSTS="${HTTP_HOSTS:-example.com neverssl.com google.com}"
PER_SERVER_TIMEOUT="${PER_SERVER_TIMEOUT:-10}"
RETRY_DELAY="${RETRY_DELAY:-15}"
MIN_UNIX=1767225600

if [ "$BLOCKING" = "1" ]; then
    BOOT_DELAY="${BOOT_DELAY:-0}"
    MAX_ATTEMPTS="${MAX_ATTEMPTS:-1}"
else
    BOOT_DELAY="${BOOT_DELAY:-20}"
    MAX_ATTEMPTS="${MAX_ATTEMPTS:-20}"
fi

LOG=/tmp/ntp-sync.log
PLOG=/var/lib/webosbrew/ntp-sync.log
LOCK=/tmp/ntp-sync.lock

log() {
    line="$(date '+%F %T') [$$] $*"
    { echo "$line" >> "$LOG"; } 2>/dev/null
    { echo "$line" >> "$PLOG"; } 2>/dev/null
    if [ "$BLOCKING" = "1" ]; then echo "$line"; fi
}

toast_once() {
    sleep 0.5 2>/dev/null || sleep 1
    out=$(luna-send -n 1 -f luna://com.webos.notification/createToast \
        "{\"sourceId\":\"ntp-sync\",\"message\":\"$1\"}" 2>&1)
    rc=$?
    log "toast rc=$rc msg=[$1] reply=$(echo "$out" | tr -d '\n')"
    return $rc
}

toast() {
    i=0
    while [ $i -lt 5 ]; do
        toast_once "$1" && return 0
        i=$((i + 1)); sleep 3
    done
    return 1
}

dbg() {
    log "DBG $*"
    if [ "$DEBUG" = "1" ]; then ( toast_once "DBG: $*" >/dev/null 2>&1 & ); fi
}

if [ "$BLOCKING" != "1" ] && [ "$1" != "--worker" ]; then
    log "launcher invoked: argv0=$0 user=$(id -u) pwd=$(pwd) DRY_RUN=$DRY_RUN METHODS=[$METHODS]"
    dbg "launcher ran"
    self=$(readlink -f "$0" 2>/dev/null || echo "$0")
    nohup sh "$self" --worker >>"$LOG" 2>&1 &
    log "launcher forked worker pid=$! self=$self"
    exit 0
fi

if [ "$BLOCKING" != "1" ]; then
    log "worker started"
    if [ -e "$LOCK" ] && kill -0 "$(cat "$LOCK" 2>/dev/null)" 2>/dev/null; then
        log "another worker is running (pid $(cat "$LOCK")), exiting"
        exit 0
    fi
    echo $$ > "$LOCK"
    trap 'rm -f "$LOCK"' EXIT
fi

run_to() {
    t=$1; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$t" "$@"; else "$@"; fi
}

have() { command -v "$1" >/dev/null 2>&1 && echo yes || echo NO; }

NODE=$(command -v node 2>/dev/null || command -v nodejs 2>/dev/null)
log "mode: BLOCKING=$BLOCKING DRY_RUN=$DRY_RUN METHODS=[$METHODS] attempts=$MAX_ATTEMPTS"
log "tools: ntpd=$(have ntpd) ntpdate=$(have ntpdate) node=${NODE:-NO} nc=$(have nc) nslookup=$(have nslookup) timeout=$(have timeout) luna-send=$(have luna-send)"
log "clock at start: $(date)"
dbg "worker started, tools ntpd=$(have ntpd) node=${NODE:-NO}"

set_clock() {
    unix=$1
    ts=$(date -u -d "@$unix" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
    if [ -n "$ts" ]; then date -u -s "$ts" >>"$LOG" 2>&1; else date -u -s "@$unix" >>"$LOG" 2>&1; fi
}

SYNC_SRC=""

apply_unix() {
    unix=$1; label=$2
    local_unix=$(date -u +%s)
    log "  $label: server unix=$unix local unix=$local_unix offset=$((unix - local_unix))s"
    if [ "$unix" -le "$MIN_UNIX" ]; then log "  timestamp before MIN_UNIX, ignoring"; return 1; fi
    if [ "$DRY_RUN" = "1" ]; then SYNC_SRC="$label (dry run)"; return 0; fi
    set_clock "$unix" || return 1
    SYNC_SRC="$label"
    return 0
}

try_ntpd() {
    command -v ntpd >/dev/null 2>&1 || { log "ntpd: not installed"; return 1; }
    if [ "$DRY_RUN" = "1" ]; then log "ntpd: skipped in dry run (it sets the clock)"; return 1; fi
    for s in $NTP_SERVERS; do
        log "ntpd -> $s"
        run_to "$PER_SERVER_TIMEOUT" ntpd -q -n -p "$s" >>"$LOG" 2>&1
        rc=$?
        log "ntpd $s rc=$rc"
        if [ $rc -eq 0 ] && [ "$(date -u +%s)" -gt "$MIN_UNIX" ]; then SYNC_SRC="ntpd $s"; return 0; fi
    done
    return 1
}

try_ntpdate() {
    command -v ntpdate >/dev/null 2>&1 || { log "ntpdate: not installed"; return 1; }
    for s in $NTP_SERVERS; do
        log "ntpdate -> $s"
        if [ "$DRY_RUN" = "1" ]; then
            run_to "$PER_SERVER_TIMEOUT" ntpdate -q "$s" >>"$LOG" 2>&1 && { SYNC_SRC="ntpdate $s (dry run)"; return 0; }
            continue
        fi
        run_to "$PER_SERVER_TIMEOUT" ntpdate -u "$s" >>"$LOG" 2>&1
        rc=$?
        log "ntpdate $s rc=$rc"
        if [ $rc -eq 0 ] && [ "$(date -u +%s)" -gt "$MIN_UNIX" ]; then SYNC_SRC="ntpdate $s"; return 0; fi
    done
    return 1
}

try_node() {
    [ -n "$NODE" ] || { log "node: not installed (try: find / -name 'node*' -type f 2>/dev/null | head)"; return 1; }
    for s in $NTP_SERVERS; do
        log "node ntp -> $s (UDP/123)"
        unix=$(run_to "$PER_SERVER_TIMEOUT" "$NODE" -e '
var dgram = require("dgram");
var host = process.argv[1];
var sock = dgram.createSocket("udp4");
var req = Buffer.alloc ? Buffer.alloc(48) : new Buffer(48);
req.fill(0); req[0] = 0x1b;
var timer = setTimeout(function () { console.log("timeout waiting for reply"); process.exit(2); }, 5000);
sock.on("error", function (e) { console.log("socket error: " + e.message); process.exit(3); });
sock.on("message", function (m) {
  clearTimeout(timer);
  console.log(m.readUInt32BE(40) - 2208988800);
  process.exit(0);
});
sock.send(req, 0, 48, 123, host, function (e) { if (e) { console.log("send error: " + e.message); process.exit(4); } });
' "$s" 2>&1)
        case "$unix" in
            ''|*[!0-9]*) log "  failed: ${unix:-no output}"; continue ;;
        esac
        apply_unix "$unix" "NTP $s" && return 0
    done
    return 1
}

try_http() {
    command -v nc >/dev/null 2>&1 || { log "http: nc not installed"; return 1; }
    for h in $HTTP_HOSTS; do
        log "http Date -> http://$h"
        ip=$(nslookup "$h" 2>/dev/null | awk '$1 ~ /^Address/ && $NF ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {a=$NF} END{print a}')
        [ -n "$ip" ] || { log "  could not resolve $h"; continue; }
        hdr=$( { printf 'HEAD / HTTP/1.0\r\nHost: %s\r\nConnection: close\r\n\r\n' "$h"; sleep 3; } \
            | run_to 8 nc "$ip" 80 2>/dev/null | tr -d '\r' | grep -i '^date:' | head -n1 )
        [ -n "$hdr" ] || { log "  no Date header from $h ($ip)"; continue; }
        log "  header: $hdr"
        ts=$(echo "$hdr" | awk '{
            split("Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec", m, " ");
            for (i=1;i<=12;i++) if (m[i]==$4) mon=i;
            printf "%04d-%02d-%02d %s", $5, mon, $3, $6 }')
        [ -n "$ts" ] || { log "  could not parse header"; continue; }
        unix=$(date -u -d "$ts" +%s 2>/dev/null)
        case "$unix" in ''|*[!0-9]*) log "  date -d failed for '$ts'"; continue ;; esac
        apply_unix "$unix" "HTTP Date $h" && return 0
    done
    return 1
}

try_methods() {
    for m in $METHODS; do
        case "$m" in
            ntpd)    try_ntpd ;;
            ntpdate) try_ntpdate ;;
            node)    try_node ;;
            http)    try_http ;;
            *)       log "unknown method: $m"; false ;;
        esac && return 0
    done
    return 1
}

push_to_system_service() {
    out=$(luna-send -n 1 luna://com.webos.service.systemservice/time/setSystemTime \
        "{\"utc\":$(date -u +%s)}" 2>&1)
    log "setSystemTime reply: $(echo "$out" | tr -d '\n')"
}

if [ "$BOOT_DELAY" -gt 0 ]; then
    dbg "waiting ${BOOT_DELAY}s for the network"
    sleep "$BOOT_DELAY"
fi

attempt=1
while [ $attempt -le "$MAX_ATTEMPTS" ]; do
    log "attempt $attempt/$MAX_ATTEMPTS"
    if [ $attempt -le 2 ]; then dbg "attempt $attempt"; fi
    SYNC_SRC=""
    if try_methods; then
        if [ "$DRY_RUN" = "1" ]; then
            log "DRY RUN OK via $SYNC_SRC (clock unchanged)"
            exit 0
        fi
        push_to_system_service
        now=$(date '+%F %T')
        log "SUCCESS via $SYNC_SRC: $now"
        toast "Time set OK via $SYNC_SRC ($now)"
        exit 0
    fi
    attempt=$((attempt + 1))
    if [ $attempt -le "$MAX_ATTEMPTS" ]; then sleep "$RETRY_DELAY"; fi
done

log "FAILED after $MAX_ATTEMPTS attempts"
if [ "$DRY_RUN" != "1" ]; then toast "Time sync FAILED after $MAX_ATTEMPTS attempts. See /tmp/ntp-sync.log"; fi
exit 1
