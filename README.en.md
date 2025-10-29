# Immich Job Daemon

**[Русский](README.md) | English**

[![Docker Build](https://github.com/alternativniy/immich-job-daemon/actions/workflows/docker-build.yml/badge.svg)](https://github.com/alternativniy/immich-job-daemon/actions/workflows/docker-build.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Docker Pulls](https://img.shields.io/docker/pulls/alternativniy/immich-job-daemon)](https://github.com/alternativniy/immich-job-daemon/pkgs/container/immich-job-daemon)

A daemon for managing Immich job queue. Automatically manages jobs by priority, allowing you to run a specified number of jobs simultaneously.

## Features

- 🐧 Based on Alpine Linux (minimal image size)
- 🔄 Automatic job priority management
- ⚙️ Configurable number of concurrent jobs
- 🔒 Runs as non-privileged user
- 🌐 Configuration via environment variables

## Job Priority

Jobs are processed in the following priority order:

1. sidecar
2. metadataExtraction
3. storageTemplateMigration
4. thumbnailGeneration
5. smartSearch
6. duplicateDetection
7. faceDetection
8. facialRecognition
9. videoConversion
10. other jobs

## Usage

### Using Pre-built Image from GitHub Container Registry

```bash
docker run -d \
  --name immich-job-daemon \
  -e IMMICH_URL=http://your-immich-server:2283 \
  -e API_KEY=your_api_key_here \
  -e MAX_CONCURRENT_JOBS=2 \
  --restart unless-stopped \
  ghcr.io/alternativniy/immich-job-daemon:latest
```

### Build Image Locally

#### Docker Run

```bash
docker build -t immich-job-daemon .

docker run -d \
  --name immich-job-daemon \
  -e IMMICH_URL=http://your-immich-server:2283 \
  -e API_KEY=your_api_key_here \
  -e MAX_CONCURRENT_JOBS=2 \
  --restart unless-stopped \
  immich-job-daemon
```

### Docker Compose

1. Edit `docker-compose.yml`:

   ```yaml
   services:
     immich-job-daemon:
       image: ghcr.io/alternativniy/immich-job-daemon:latest
       # Or build locally:
       # build: .
       container_name: immich-job-daemon
       restart: unless-stopped
       environment:
         - IMMICH_URL=http://127.0.0.1:2283
         - API_KEY=your_api_key_here
         - MAX_CONCURRENT_JOBS=2
       depends_on:
         - immich-server
       networks:
         - immich_network
   ```

2. Start the container:
   ```bash
   docker-compose up -d
   ```

> **📝 Note:** The daemon depends on `immich-server` and must be in the same Docker network to access the API.

## Environment Variables

| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `IMMICH_URL` | Immich server URL | `http://127.0.0.1:2283` | No |
| `API_KEY` | Immich API key with `job.read` and `job.create` permissions | - | **Yes** |
| `MAX_CONCURRENT_JOBS` | Number of jobs running concurrently | `1` | No |
| `POLL_INTERVAL` | Polling interval in seconds | `10` | No |

## Getting API Key

1. Log in to Immich web interface
2. Go to **Account Settings** → **API Keys**
3. Create a new API key with required permissions:
   - ✅ `job.read` - to read job status
   - ✅ `job.create` - to manage jobs (pause/resume)
4. Copy and use it in the `API_KEY` variable

> **⚠️ Important:** API key must have `job.read` and `job.create` permissions, otherwise the daemon won't be able to manage jobs.

## Logs

View container logs:

```bash
docker logs -f immich-job-daemon
```

## How It Works

The daemon runs every N seconds (configurable via `POLL_INTERVAL`):

1. Fetches all jobs from Immich API
2. **Checks for actively running jobs** (active > 0)
3. **If there are active jobs** - continues their execution until completion (does not interrupt)
4. **If all jobs are paused** - finds the first N jobs from the priority list (where N = `MAX_CONCURRENT_JOBS`) that have tasks in queue
5. Resumes selected jobs
6. Pauses all other managed jobs

This allows efficient server resource management by processing jobs sequentially or in parallel according to priority, **without interrupting already running jobs**.

### 🔄 Priority Logic

**Important:** The daemon does not interrupt running jobs! This is critical for jobs that generate data for other jobs.

**Example:**
- Job `thumbnailGeneration` is running (priority 4)
- Data appears for `metadataExtraction` (priority 2, higher)
- The daemon **WILL NOT interrupt** `thumbnailGeneration`, lets it finish
- After all active jobs complete, it will start `metadataExtraction` by priority

**Usage Examples:**

- `MAX_CONCURRENT_JOBS=1` - jobs run strictly sequentially (default)
- `MAX_CONCURRENT_JOBS=2` - two jobs can run simultaneously
- `MAX_CONCURRENT_JOBS=3` - three jobs can run simultaneously

## Requirements

- Docker or Docker Compose
- **Running Immich server** (`immich-server` container)
- Access to Immich API
- Valid Immich API key with `job.read` and `job.create` permissions
- Container must be in the same Docker network as Immich

## License

MIT
