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
IDLE_POLICY="${IDLE_POLICY:-resume}"
RESUME_UNMANAGED="${RESUME_UNMANAGED:-true}"
HEALTH_FILE="${HEALTH_FILE:-/tmp/immich-job-daemon.health}"

# Heavy queues in pipeline order (upstream first)
DEFAULT_MANAGED_QUEUES="library sidecar metadataExtraction storageTemplateMigration thumbnailGeneration smartSearch faceDetection ocr facialRecognition duplicateDetection videoConversion migration"
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
case "$IDLE_POLICY" in resume | pause) ;; *) fail "IDLE_POLICY must be 'resume' or 'pause'" ;; esac
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

# Bring a queue to the wanted state: ensure NAME WANT_PAUSED IS_PAUSED [REASON]
# The comparison is made against the real server state, so manual changes in the
# UI, Immich's own pauses and failed requests are corrected on the next poll.
ensure() {
    [ "$2" = "$3" ] && return 0
    set_paused "$1" "$2" || return 1
    if [ "$2" = "true" ]; then
        log "⏸️  Paused $1${4:+ ($4)}"
    else
        log "▶️  Resumed $1${4:+ ($4)}"
    fi
}

# Resume all managed queues: resume_managed [REASON]
resume_managed() {
    reason="$1"
    for queue in $MANAGED_QUEUES; do
        info=$(queue_info "$queue")
        [ -n "$info" ] || continue
        set -- $info
        ensure "$queue" false "$1" "$reason"
    done
}

manage_queues() {
    if ! fetch_state; then
        log "WARNING: unable to fetch queue state (HTTP $HTTP_CODE)" >&2
        return 1
    fi

    # Select the first N queues in priority order that have pending work
    selected=""
    selected_count=0
    for queue in $MANAGED_QUEUES; do
        info=$(queue_info "$queue")
        [ -n "$info" ] || continue
        set -- $info
        if [ $(($2 + $3)) -gt 0 ] && [ "$selected_count" -lt "$MAX_CONCURRENT_JOBS" ]; then
            selected="$selected $queue"
            selected_count=$((selected_count + 1))
        fi
    done

    # Nothing to do: keep queues resumed so new jobs start immediately
    if [ "$selected_count" -eq 0 ]; then
        [ "$IDLE_POLICY" = "resume" ] && resume_managed "idle"
        return 0
    fi

    # Pause everything that is not selected. Running jobs of a paused queue keep
    # going until they finish ("draining") and occupy a slot meanwhile.
    draining=0
    for queue in $MANAGED_QUEUES; do
        in_list "$queue" "$selected" && continue
        info=$(queue_info "$queue")
        [ -n "$info" ] || continue
        set -- $info
        ensure "$queue" true "$1" "lower priority"
        [ "$2" -gt 0 ] && draining=$((draining + 1))
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
    log "🛑 Received shutdown signal, resuming managed queues..."
    if fetch_state; then
        resume_managed "shutdown"
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
echo "Idle policy: $IDLE_POLICY"
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
