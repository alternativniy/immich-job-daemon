# Immich Job Daemon

**English | [Русский](README.ru.md)**

[![Docker Build](https://github.com/alternativniy/immich-job-daemon/actions/workflows/docker-build.yml/badge.svg)](https://github.com/alternativniy/immich-job-daemon/actions/workflows/docker-build.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Docker Pulls](https://img.shields.io/docker/pulls/alternativniy/immich-job-daemon)](https://github.com/alternativniy/immich-job-daemon/pkgs/container/immich-job-daemon)

A daemon that limits how many heavy Immich queues run at the same time. Immich only has per-queue concurrency settings ([discussion #3625](https://github.com/immich-app/immich/discussions/3625)); this daemon adds a global limit by pausing and resuming queues in pipeline priority order.

## Features

- 🐧 Based on Alpine Linux (minimal image size)
- 🔄 Pipeline-aware priority: new uploads get metadata and thumbnails first
- ⚙️ Configurable number of concurrent queues
- 🛡️ Never touches service queues (background tasks, search, notifications, ...)
- ♻️ Resumes its own pauses on shutdown, nothing stays paused
- 🤝 Respects pauses made by Immich itself or by you in the UI
- 🔒 Runs as non-privileged user
- 🌐 Configuration via environment variables

## Managed Queues

The daemon manages only the heavy queues shown on the `/admin/queues` page, in pipeline order (upstream first):

1. `library`
2. `sidecar`
3. `metadataExtraction`
4. `storageTemplateMigration`
5. `thumbnailGeneration`
6. `smartSearch`
7. `faceDetection`
8. `ocr`
9. `facialRecognition`
10. `duplicateDetection`
11. `migration`
12. `videoConversion`

The list and order can be changed with `MANAGED_QUEUES`. Queues missing on your Immich version are skipped.

Service queues (`backgroundTask`, `search`, `notifications`, `backupDatabase`, `workflow`, `editor`, `integrityCheck`) are never paused. If one of them is left paused (e.g. by an older daemon version), it is resumed on startup.

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
| `API_KEY` | Immich admin API key (see permissions below) | - | **Yes** |
| `MAX_CONCURRENT_JOBS` | Number of queues allowed to run at the same time | `1` | No |
| `POLL_INTERVAL` | Polling interval in seconds | `10` | No |
| `STRICT_LIMIT` | `true`: a queue starts only after running jobs of paused queues finish, so the limit is never exceeded. `false`: switch immediately, running jobs of paused queues finish in parallel | `true` | No |
| `DRAIN_TIMEOUT` | Seconds a paused queue with running jobs may occupy a slot. After that it is no longer counted, so a hung job can't block everything. `0` = no timeout | `1800` | No |
| `MANAGED_QUEUES` | Managed queues in priority order (space or comma separated) | see above | No |
| `RESUME_UNMANAGED` | Resume paused unmanaged queues on startup | `true` | No |

> **📝 Note:** `MAX_CONCURRENT_JOBS` limits the number of *queues*. Each queue still runs up to its own concurrency from **Administration → Settings → Job Settings** (e.g. thumbnails 3, metadata 5). For strictly one job at a time set the concurrency of the heavy queues to `1` there.

## Getting API Key

1. Log in to Immich web interface as an administrator
2. Go to **Account Settings** → **API Keys**
3. Create a new API key with required permissions:
   - Immich 2.4 and newer: ✅ `queue.read`, ✅ `queue.update`
   - Older versions: ✅ `job.read`, ✅ `job.create`
4. Copy and use it in the `API_KEY` variable

The daemon detects the API automatically: it uses `/api/queues` when available and falls back to the deprecated `/api/jobs`.

> **⚠️ Upgrading:** Immich 2.4+ requires a key with `queue.read` and `queue.update`. An old key with only `job.*` permissions gets HTTP 403 and the daemon exits at startup with this error — create a new key or add the permissions to the existing one.

## Logs

View container logs:

```bash
docker logs -f immich-job-daemon
```

## How It Works

Every `POLL_INTERVAL` seconds the daemon:

1. Reads the real state of all queues from the Immich API (failed requests are retried on the next poll)
2. Selects the first `MAX_CONCURRENT_JOBS` managed queues in priority order that have work (`waiting + active > 0`)
3. Pauses the other managed queues that have work
4. Keeps queues without work resumed: they use no resources, new jobs start immediately and the **Missing** / **All** buttons on `/admin/queues` stay available (Immich hides them for paused queues)
5. Resumes the selected queues (with `STRICT_LIMIT=true` only while there are free slots: running jobs of just-paused queues occupy a slot until they finish or `DRAIN_TIMEOUT` expires)

Pauses made by someone else are respected: Immich pauses `metadataExtraction` while importing reverse geocoding data, and you can pause a queue manually in the UI. The daemon only resumes queues it paused itself. Managed queues found paused at startup are treated as left over by a previous run and taken over.

A queue without work may start a new job before the next poll. The overshoot is limited to the jobs already started at that moment; after that the queue is managed as usual. This is why `videoConversion`, the queue with the longest jobs, has the lowest priority.

Pausing a queue **does not interrupt** running jobs: the current job finishes, only new jobs are not picked up. This is why a higher-priority queue can preempt a lower one at any time.

**Example** (`MAX_CONCURRENT_JOBS=1`):

- `videoConversion` processes 500 videos
- A new photo is uploaded, `metadataExtraction` gets a job
- The daemon pauses `videoConversion`; its current video finishes
- `metadataExtraction` starts, then `storageTemplateMigration`, `thumbnailGeneration`, ML jobs for the new photo
- When they are done, `videoConversion` continues

On shutdown (`docker stop`) the daemon resumes the queues it paused, so Immich keeps working without it.

## Requirements

- Docker or Docker Compose
- **Running Immich server** (`immich-server` container)
- Access to Immich API
- Valid Immich admin API key with `queue.read` and `queue.update` permissions (`job.read` and `job.create` for Immich < 2.4)
- Container must be in the same Docker network as Immich

## License

MIT
