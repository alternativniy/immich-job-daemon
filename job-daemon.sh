#!/bin/sh

# Immich Job Daemon
# Limits how many heavy Immich queues (the ones shown on /admin/queues) run at
# the same time. Queues are selected by pipeline priority; pausing a queue never
# interrupts a running job, it only stops new jobs from being picked up.

IMMICH_URL="${IMMICH_URL:-http://127.0.0.1:2283}"
IMMICH_URL="${IMMICH_URL%/}"
API_KEY="${API_KEY:-}"
MAX_CONCURRENT_JOBS="${MAX_CONCURRENT_JOBS:-1}"
POLL_INTERVAL="${POLL_INTERVAL:-10}"
STRICT_LIMIT="${STRICT_LIMIT:-true}"
DRAIN_TIMEOUT="${DRAIN_TIMEOUT:-1800}"
RESUME_UNMANAGED="${RESUME_UNMANAGED:-true}"
HEALTH_FILE="${HEALTH_FILE:-/tmp/immich-job-daemon.health}"

# Heavy queues in pipeline order (upstream first)
DEFAULT_MANAGED_QUEUES="library sidecar metadataExtraction storageTemplateMigration thumbnailGeneration smartSearch faceDetection ocr facialRecognition duplicateDetection migration videoConversion"
MANAGED_QUEUES=$(echo "${MANAGED_QUEUES:-$DEFAULT_MANAGED_QUEUES}" | tr ',' ' ')

# Docker health check mode: healthy if the last successful poll is recent enough
if [ "$1" = "--healthcheck" ]; then
    [ -f "$HEALTH_FILE" ] || exit 1
    last=$(cat "$HEALTH_FILE")
    [ $(($(date +%s) - last)) -le $((POLL_INTERVAL * 3 + 30)) ]
    exit $?
fi

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

# Validate configuration
[ -n "$API_KEY" ] || fail "API_KEY environment variable is required"
echo "$MAX_CONCURRENT_JOBS" | grep -qE '^[1-9][0-9]*$' || fail "MAX_CONCURRENT_JOBS must be a positive integer"
echo "$POLL_INTERVAL" | grep -qE '^[1-9][0-9]*$' || fail "POLL_INTERVAL must be a positive integer"
case "$STRICT_LIMIT" in true | false) ;; *) fail "STRICT_LIMIT must be 'true' or 'false'" ;; esac
echo "$DRAIN_TIMEOUT" | grep -qE '^[0-9]+$' || fail "DRAIN_TIMEOUT must be a non-negative integer"
case "$RESUME_UNMANAGED" in true | false) ;; *) fail "RESUME_UNMANAGED must be 'true' or 'false'" ;; esac
[ -n "$(echo $MANAGED_QUEUES)" ] || fail "MANAGED_QUEUES must not be empty"

RESPONSE_FILE=$(mktemp) || fail "Unable to create temporary file"
HTTP_CODE=""

# Perform an API request: api METHOD PATH [JSON_BODY]
# Sets HTTP_CODE ("000" on connection failure); response body goes to RESPONSE_FILE
api() {
    HTTP_CODE=$(curl -s -o "$RESPONSE_FILE" -w '%{http_code}' \
        --connect-timeout 10 --max-time 30 \
        -X "$1" "$IMMICH_URL$2" \
        -H "Accept: application/json" \
        -H "Content-Type: application/json" \
        -H "x-api-key: $API_KEY" \
        ${3:+-d} ${3:+"$3"}) || HTTP_CODE="000"
    case "$HTTP_CODE" in 2??) return 0 ;; esac
    return 1
}

in_list() {
    case " $2 " in *" $1 "*) return 0 ;; esac
    return 1
}

# Fetch queue state into STATE, one line per queue: "name isPaused active waiting"
fetch_state() {
    api GET "$LIST_PATH" || return 1
    if [ "$API_MODE" = "queues" ]; then
        filter='.[] | [.name, .isPaused, (.statistics.active // 0), ((.statistics.waiting // 0) + (.statistics.paused // 0))]'
    else
        filter='to_entries[] | [.key, .value.queueStatus.isPaused, (.value.jobCounts.active // 0), ((.value.jobCounts.waiting // 0) + (.value.jobCounts.paused // 0))]'
    fi
    STATE=$(jq -r "$filter | @tsv" "$RESPONSE_FILE" 2>/dev/null) || return 1
    [ -n "$STATE" ]
}

# Print "isPaused active waiting" for a queue, empty if the queue does not exist
queue_info() {
    printf '%s\n' "$STATE" | awk -v name="$1" '$1 == name { print $2, $3, $4; exit }'
}

# Pause or resume a queue: set_paused NAME true|false
set_paused() {
    if [ "$API_MODE" = "queues" ]; then
        api PUT "/api/queues/$1" "{\"isPaused\":$2}" && return 0
    else
        if [ "$2" = "true" ]; then cmd="pause"; else cmd="resume"; fi
        api PUT "/api/jobs/$1" "{\"command\":\"$cmd\",\"force\":false}" && return 0
    fi
    log "ERROR: unable to set $1 isPaused=$2 (HTTP $HTTP_CODE): $(head -c 200 "$RESPONSE_FILE")" >&2
    return 1
}

# Queues paused by this daemon. Pauses made by someone else (Immich itself, e.g.
# metadataExtraction during geodata import, or a user in the UI) are respected.
OWNED_PAUSES=""
# Draining queues and the time they started draining: "name=epoch ..."
DRAIN_SINCE=""
DRAIN_EXPIRED=""

list_add() {
    eval "in_list \"\$2\" \"\$$1\" || $1=\"\$$1 \$2\""
}

list_del() {
    eval "_list=\$$1"
    _result=""
    for _item in $_list; do
        [ "$_item" = "$2" ] || [ "${_item%%=*}" = "$2" ] || _result="$_result $_item"
    done
    eval "$1=\$_result"
}

is_external_pause() {
    [ "$1" = "true" ] && ! in_list "$2" "$OWNED_PAUSES"
}

# Bring a queue to the wanted state: ensure NAME WANT_PAUSED IS_PAUSED [REASON]
# The comparison is made against the real server state, so failed requests are
# retried on the next poll.
ensure() {
    [ "$2" = "$3" ] && return 0
    set_paused "$1" "$2" || return 1
    if [ "$2" = "true" ]; then
        list_add OWNED_PAUSES "$1"
        log "⏸️  Paused $1${4:+ ($4)}"
    else
        list_del OWNED_PAUSES "$1"
        log "▶️  Resumed $1${4:+ ($4)}"
    fi
}

# Whether a paused queue with running jobs still occupies a slot: is_draining NAME ACTIVE
# A queue stops counting after DRAIN_TIMEOUT seconds so a hung job can't block everything.
is_draining() {
    if [ "$2" -eq 0 ]; then
        list_del DRAIN_SINCE "$1"
        list_del DRAIN_EXPIRED "$1"
        return 1
    fi
    since=""
    for _item in $DRAIN_SINCE; do
        [ "${_item%%=*}" = "$1" ] && since="${_item#*=}"
    done
    if [ -z "$since" ]; then
        since="$NOW"
        DRAIN_SINCE="$DRAIN_SINCE $1=$NOW"
    fi
    [ "$DRAIN_TIMEOUT" -gt 0 ] && [ $((NOW - since)) -ge "$DRAIN_TIMEOUT" ] || return 0
    if ! in_list "$1" "$DRAIN_EXPIRED"; then
        DRAIN_EXPIRED="$DRAIN_EXPIRED $1"
        log "WARNING: $1 has been finishing its jobs for over ${DRAIN_TIMEOUT}s, no longer counting it towards the limit" >&2
    fi
    return 1
}

manage_queues() {
    if ! fetch_state; then
        log "WARNING: unable to fetch queue state (HTTP $HTTP_CODE)" >&2
        return 1
    fi
    NOW=$(date +%s)

    # A queue resumed by someone else is no longer our pause
    for queue in $OWNED_PAUSES; do
        set -- $(queue_info "$queue")
        [ "$1" = "true" ] || list_del OWNED_PAUSES "$queue"
    done

    # Select the first N queues in priority order that have pending work
    selected=""
    selected_count=0
    for queue in $MANAGED_QUEUES; do
        info=$(queue_info "$queue")
        [ -n "$info" ] || continue
        set -- $info
        is_external_pause "$1" "$queue" && continue
        if [ $(($2 + $3)) -gt 0 ] && [ "$selected_count" -lt "$MAX_CONCURRENT_JOBS" ]; then
            selected="$selected $queue"
            selected_count=$((selected_count + 1))
        fi
    done

    # Pause other queues that have work. Empty queues stay resumed: they use no
    # resources and Immich UI only offers "Missing"/"All" for non-paused queues.
    # Running jobs of a paused queue keep going until they finish ("draining")
    # and occupy a slot meanwhile.
    draining=0
    for queue in $MANAGED_QUEUES; do
        info=$(queue_info "$queue")
        [ -n "$info" ] || continue
        set -- $info
        if in_list "$queue" "$selected"; then
            list_del DRAIN_SINCE "$queue"
            continue
        fi
        if ! is_external_pause "$1" "$queue"; then
            if [ $(($2 + $3)) -gt 0 ]; then
                ensure "$queue" true "$1" "lower priority"
            else
                ensure "$queue" false "$1" "no pending work"
            fi
        fi
        is_draining "$queue" "$2" && draining=$((draining + 1))
    done

    # Selected queues that already run jobs keep their slot
    running=0
    for queue in $selected; do
        set -- $(queue_info "$queue")
        if [ "$2" -gt 0 ]; then
            ensure "$queue" false "$1" "running"
            running=$((running + 1))
        fi
    done

    # Start the remaining selected queues while there are free slots
    for queue in $selected; do
        set -- $(queue_info "$queue")
        [ "$2" -gt 0 ] && continue
        if [ "$STRICT_LIMIT" = "false" ] || [ $((running + draining)) -lt "$MAX_CONCURRENT_JOBS" ]; then
            ensure "$queue" false "$1" "pending: $3"
            running=$((running + 1))
        else
            ensure "$queue" true "$1" "waiting for a free slot"
        fi
    done
}

cleanup() {
    echo ""
    log "🛑 Received shutdown signal, resuming queues paused by the daemon..."
    if fetch_state; then
        for queue in $OWNED_PAUSES; do
            set -- $(queue_info "$queue")
            ensure "$queue" false "$1" "shutdown"
        done
    else
        log "WARNING: unable to fetch queue state, managed queues may stay paused" >&2
    fi
    rm -f "$RESPONSE_FILE" "$HEALTH_FILE"
    exit 0
}

echo "Starting Immich Job Daemon..."
echo "Immich URL: $IMMICH_URL"
echo "Max concurrent queues: $MAX_CONCURRENT_JOBS"
echo "Poll interval: ${POLL_INTERVAL}s"
echo "Strict limit: $STRICT_LIMIT"
echo "Drain timeout: ${DRAIN_TIMEOUT}s"
echo "Managed queues (by priority): $(echo $MANAGED_QUEUES)"

echo "Checking Immich server availability..."
if ! curl -s -f -o /dev/null --connect-timeout 10 "$IMMICH_URL/api/server/ping"; then
    echo "ERROR: Cannot connect to Immich server at $IMMICH_URL" >&2
    echo "Please check that:" >&2
    echo "  - IMMICH_URL is correct" >&2
    echo "  - Immich server is running" >&2
    echo "  - Network connection is available" >&2
    exit 1
fi
echo "✓ Successfully connected to Immich server"

# Detect the API: /api/queues (Immich >= 2.4) or legacy /api/jobs
echo "Verifying API key..."
if api GET /api/queues; then
    API_MODE="queues"
    LIST_PATH="/api/queues"
elif [ "$HTTP_CODE" = "401" ] || [ "$HTTP_CODE" = "403" ]; then
    fail "API key is invalid or lacks permissions. Required: 'queue.read' and 'queue.update' (Immich >= 2.4)"
elif api GET /api/jobs; then
    API_MODE="legacy"
    LIST_PATH="/api/jobs"
elif [ "$HTTP_CODE" = "401" ] || [ "$HTTP_CODE" = "403" ]; then
    fail "API key is invalid or lacks permissions. Required: 'job.read' and 'job.create' (Immich < 2.4)"
else
    fail "Unexpected response from Immich API (HTTP $HTTP_CODE)"
fi
echo "✓ API key verified successfully (API: $LIST_PATH)"

trap cleanup TERM INT

fetch_state || fail "Unable to read queue state"

for queue in $MANAGED_QUEUES; do
    [ -n "$(queue_info "$queue")" ] || echo "WARNING: queue '$queue' not found on this Immich version, skipping" >&2
done

# Paused managed queues on startup are treated as left over by a previous run
for queue in $MANAGED_QUEUES; do
    set -- $(queue_info "$queue")
    [ "$1" = "true" ] && list_add OWNED_PAUSES "$queue"
done

# Queues that are not managed must never stay paused (e.g. left over by older versions)
if [ "$RESUME_UNMANAGED" = "true" ]; then
    printf '%s\n' "$STATE" | while read -r name paused active waiting; do
        in_list "$name" "$MANAGED_QUEUES" && continue
        ensure "$name" false "$paused" "unmanaged queue"
    done
fi

echo ""
echo "🚀 Job daemon started. Press Ctrl+C to stop."
echo ""
while true; do
    manage_queues && date +%s >"$HEALTH_FILE"
    # Run sleep in background so signals are handled immediately
    sleep "$POLL_INTERVAL" &
    wait $!
done
