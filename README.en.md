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

1. metadataExtraction
2. storageTemplateMigration
3. thumbnailGeneration
4. smartSearch
5. duplicateDetection
6. faceDetection
7. facialRecognition
8. videoConversion

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
         - IMMICH_URL=http://immich-server:2283
         - API_KEY=your_api_key_here
         - MAX_CONCURRENT_JOBS=2
   ```

2. Start the container:
   ```bash
   docker-compose up -d
   ```

## Environment Variables

| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `IMMICH_URL` | Immich server URL | `http://127.0.0.1:2283` | No |
| `API_KEY` | Immich API key | - | **Yes** |
| `MAX_CONCURRENT_JOBS` | Number of jobs running concurrently | `1` | No |

## Getting API Key

1. Log in to Immich web interface
2. Go to **Account Settings** → **API Keys**
3. Create a new API key
4. Copy and use it in the `API_KEY` variable

## Logs

View container logs:

```bash
docker logs -f immich-job-daemon
```

## How It Works

The daemon runs every 10 seconds:

1. Fetches all jobs from Immich API
2. Finds the first N jobs from the priority list (where N = `MAX_CONCURRENT_JOBS`) that have activity
3. Resumes these jobs
4. Pauses all other managed jobs

This allows efficient server resource management by processing jobs sequentially or in parallel according to priority.

**Usage Examples:**
- `MAX_CONCURRENT_JOBS=1` - jobs run strictly sequentially (default)
- `MAX_CONCURRENT_JOBS=2` - two jobs can run simultaneously
- `MAX_CONCURRENT_JOBS=3` - three jobs can run simultaneously

## Requirements

- Docker or Docker Compose
- Access to Immich API
- Valid Immich API key

## License

MIT
