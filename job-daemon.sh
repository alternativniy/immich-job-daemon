#!/bin/sh

# Configuration for the API endpoint and headers
# These values should be provided via environment variables
IMMICH_URL="${IMMICH_URL:-http://127.0.0.1:2283}"
API_KEY="${API_KEY:-}"
MAX_CONCURRENT_JOBS="${MAX_CONCURRENT_JOBS:-1}"
POLL_INTERVAL="${POLL_INTERVAL:-10}"
URL="${IMMICH_URL}/api/jobs"

# Variable to store previous job states
PREV_JOB_STATES=""

# Validate required environment variables
if [ -z "$API_KEY" ]; then
    echo "ERROR: API_KEY environment variable is required" >&2
    exit 1
fi

# Validate MAX_CONCURRENT_JOBS is a positive integer
if ! echo "$MAX_CONCURRENT_JOBS" | grep -qE '^[1-9][0-9]*$'; then
    echo "ERROR: MAX_CONCURRENT_JOBS must be a positive integer" >&2
    exit 1
fi

# Validate POLL_INTERVAL is a positive integer
if ! echo "$POLL_INTERVAL" | grep -qE '^[1-9][0-9]*$'; then
    echo "ERROR: POLL_INTERVAL must be a positive integer" >&2
    exit 1
fi

echo "Starting Immich Job Daemon..."
echo "Immich URL: $IMMICH_URL"
echo "Max concurrent jobs: $MAX_CONCURRENT_JOBS"
echo "Poll interval: ${POLL_INTERVAL}s"

# Check server availability
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

# Verify API key by fetching jobs
echo "Verifying API key..."
test_response=$(curl -s -w "%{http_code}" -o /dev/null -X GET "$URL" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
-H "x-api-key: $API_KEY")

if [ "$test_response" = "401" ] || [ "$test_response" = "403" ]; then
    echo "ERROR: API key is invalid or does not have required permissions" >&2
    echo "Please ensure the API key has 'job.read' and 'job.create' permissions" >&2
    exit 1
    elif [ "$test_response" != "200" ]; then
    echo "WARNING: Unexpected response code: $test_response" >&2
fi
echo "✓ API key verified successfully"
echo ""

# Function to fetch the current job statuses from the API
fetch_jobs() {
    curl -s -X GET "$URL" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -H "x-api-key: $API_KEY" 2>/dev/null
}

# Function to send a command to pause or resume a specific job via the API
set_job() {
    local job="$1"
    local command="$2"
    local payload='{"command":"'"$command"'","force":false}'
    
    curl -s -X PUT "$URL/$job" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -H "x-api-key: $API_KEY" \
    -d "$payload" >/dev/null 2>&1
    
    if [ $? -ne 0 ]; then
        echo "Error setting job $job to $command" >&2
    fi
}

# Main logic to manage jobs
manage_jobs() {
    # Fetch all jobs from the API
    jobs=$(fetch_jobs)
    
    if [ -z "$jobs" ] || [ "$jobs" = "{}" ]; then
        return
    fi
    
    # List of jobs to manage in priority order
    priority_job_list="sidecar metadataExtraction storageTemplateMigration thumbnailGeneration smartSearch duplicateDetection faceDetection facialRecognition videoConversion"
    
    # Get all available jobs from the API response
    all_jobs=$(echo "$jobs" | jq -r 'keys[]' 2>/dev/null)
    
    # Build complete managed job list: priority jobs first, then other jobs
    # Use grep for faster lookups instead of nested loops
    managed_job_list="$priority_job_list"
    for job in $all_jobs; do
        # Check if job is not in priority list using grep (O(n) instead of O(n²))
        if ! echo " $priority_job_list " | grep -q " $job "; then
            managed_job_list="$managed_job_list $job"
        fi
    done
    
    # Check if any jobs are currently actively running (active > 0)
    # If yes, don't interrupt them - let them finish
    has_active_jobs=0
    currently_active_jobs=""
    
    for job in $managed_job_list; do
        job_counts=$(echo "$jobs" | jq -r ".$job.jobCounts | \"\(.active // 0) \(.waiting // 0) \(.paused // 0) \(.delayed // 0)\"" 2>/dev/null)
        
        if [ -z "$job_counts" ]; then
            continue
        fi
        
        set -- $job_counts
        active=$1
        
        # If this job has active tasks, don't interrupt it
        if [ "$active" -gt 0 ]; then
            has_active_jobs=1
            currently_active_jobs="$currently_active_jobs $job"
        fi
    done
    
    # Collect jobs with activity and unpause the first N jobs based on MAX_CONCURRENT_JOBS
    jobs_to_unpause=""
    jobs_unpaused=0
    
    # If there are active jobs, keep them running and don't start new ones
    if [ "$has_active_jobs" -eq 1 ]; then
        # Keep currently active jobs running
        for job in $currently_active_jobs; do
            if [ "$jobs_unpaused" -lt "$MAX_CONCURRENT_JOBS" ]; then
                jobs_to_unpause="$jobs_to_unpause $job"
                jobs_unpaused=$((jobs_unpaused + 1))
            fi
        done
    else
        # No active jobs - select new jobs by priority
        for job in $managed_job_list; do
            # Get all counts in one jq call
            job_counts=$(echo "$jobs" | jq -r ".$job.jobCounts | \"\(.active // 0) \(.waiting // 0) \(.paused // 0) \(.delayed // 0)\"" 2>/dev/null)
            
            if [ -z "$job_counts" ]; then
                continue
            fi
            
            # Parse the space-separated values
            set -- $job_counts
            active=$1
            waiting=$2
            paused=$3
            delayed=$4
            
            # Calculate total activity in one operation
            total=$((active + waiting + paused + delayed))
            
            if [ "$total" -gt 0 ]; then
                if [ "$jobs_unpaused" -lt "$MAX_CONCURRENT_JOBS" ]; then
                    jobs_to_unpause="$jobs_to_unpause $job"
                    jobs_unpaused=$((jobs_unpaused + 1))
                fi
            fi
        done
    fi
    
    # Build new state string for comparison
    new_job_states=""
    
    # Unpause selected jobs, pause all others in managed_job_list
    for job in $managed_job_list; do
        # Use grep for faster lookup (O(n) instead of O(n²))
        if echo " $jobs_to_unpause " | grep -q " $job "; then
            new_state="resume"
        else
            new_state="pause"
        fi
        
        # Add to new state
        new_job_states="${new_job_states}${job}:${new_state},"
        
        # Only execute command and log if state changed
        if ! echo "$PREV_JOB_STATES" | grep -q "${job}:${new_state}"; then
            if [ "$new_state" = "resume" ]; then
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] ▶️  Resuming job: $job"
            else
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] ⏸️  Pausing job: $job"
            fi
            set_job "$job" "$new_state"
        fi
    done
    
    # Update previous state
    PREV_JOB_STATES="$new_job_states"
}

# Graceful shutdown handler
cleanup() {
    echo ""
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] 🛑 Received shutdown signal, exiting gracefully..."
    exit 0
}

# Trap SIGTERM and SIGINT for graceful shutdown
trap cleanup TERM INT

# Run the job manager loop
echo "🚀 Job daemon started. Press Ctrl+C to stop."
echo ""
while true; do
    manage_jobs
    sleep "$POLL_INTERVAL"
done