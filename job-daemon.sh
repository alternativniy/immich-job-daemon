#!/bin/sh

# Configuration for the API endpoint and headers
# These values should be provided via environment variables
IMMICH_URL="${IMMICH_URL:-http://127.0.0.1:2283}"
API_KEY="${API_KEY:-}"
MAX_CONCURRENT_JOBS="${MAX_CONCURRENT_JOBS:-1}"
URL="${IMMICH_URL}/api/jobs"

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

echo "Starting Immich Job Daemon..."
echo "Immich URL: $IMMICH_URL"
echo "Max concurrent jobs: $MAX_CONCURRENT_JOBS"

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
    managed_job_list="metadataExtraction storageTemplateMigration thumbnailGeneration smartSearch duplicateDetection faceDetection facialRecognition videoConversion"
    
    # Collect jobs with activity and unpause the first N jobs based on MAX_CONCURRENT_JOBS
    jobs_to_unpause=""
    jobs_unpaused=0
    
    for job in $managed_job_list; do
        active=$(echo "$jobs" | jq -r ".$job.jobCounts.active // 0")
        waiting=$(echo "$jobs" | jq -r ".$job.jobCounts.waiting // 0")
        paused=$(echo "$jobs" | jq -r ".$job.jobCounts.paused // 0")
        delayed=$(echo "$jobs" | jq -r ".$job.jobCounts.delayed // 0")
        
        if [ "$active" -gt 0 ] || [ "$waiting" -gt 0 ] || [ "$paused" -gt 0 ] || [ "$delayed" -gt 0 ]; then
            if [ "$jobs_unpaused" -lt "$MAX_CONCURRENT_JOBS" ]; then
                jobs_to_unpause="$jobs_to_unpause $job"
                jobs_unpaused=$((jobs_unpaused + 1))
            fi
        fi
    done
    
    # Unpause selected jobs, pause all others in managed_job_list
    for job in $managed_job_list; do
        should_unpause=0
        for unpause_job in $jobs_to_unpause; do
            if [ "$job" = "$unpause_job" ]; then
                should_unpause=1
                break
            fi
        done
        
        if [ "$should_unpause" -eq 1 ]; then
            # echo "Unpausing job: $job"
            set_job "$job" "resume"
        else
            # echo "Pausing job: $job"
            set_job "$job" "pause"
        fi
    done
}

# Run the job manager loop every 10 seconds
while true; do
    manage_jobs
    sleep 10
done