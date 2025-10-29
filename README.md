# Immich Job Daemon

**Русский | [English](README.en.md)**

[![Docker Build](https://github.com/alternativniy/immich-job-daemon/actions/workflows/docker-build.yml/badge.svg)](https://github.com/alternativniy/immich-job-daemon/actions/workflows/docker-build.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Docker Pulls](https://img.shields.io/docker/pulls/alternativniy/immich-job-daemon)](https://github.com/alternativniy/immich-job-daemon/pkgs/container/immich-job-daemon)

Демон для управления очередью заданий Immich. Автоматически управляет заданиями по приоритету, позволяя запускать одновременно заданное количество заданий.

## Особенности

- 🐧 Основан на Alpine Linux (минимальный размер образа)
- 🔄 Автоматическое управление приоритетами заданий
- ⚙️ Настраиваемое количество одновременных заданий
- 🔒 Запуск от непривилегированного пользователя
- 🌐 Настройка через переменные окружения

## Приоритет заданий

Задания обрабатываются в следующем порядке приоритета:

1. metadataExtraction
2. storageTemplateMigration
3. thumbnailGeneration
4. smartSearch
5. duplicateDetection
6. faceDetection
7. facialRecognition
8. videoConversion

## Использование

### Использование готового образа из GitHub Container Registry

```bash
docker run -d \
  --name immich-job-daemon \
  -e IMMICH_URL=http://your-immich-server:2283 \
  -e API_KEY=your_api_key_here \
  -e MAX_CONCURRENT_JOBS=2 \
  --restart unless-stopped \
  ghcr.io/alternativniy/immich-job-daemon:latest
```

### Сборка образа локально

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

1. Отредактируйте `docker-compose.yml`:
   ```yaml
   services:
     immich-job-daemon:
       image: ghcr.io/alternativniy/immich-job-daemon:latest
       # Или соберите локально:
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

2. Запустите контейнер:
   ```bash
   docker-compose up -d
   ```

> **📝 Примечание:** Демон зависит от `immich-server` и должен быть в той же Docker сети для доступа к API.

## Переменные окружения

| Переменная | Описание | По умолчанию | Обязательная |
|-----------|----------|--------------|--------------|
| `IMMICH_URL` | URL сервера Immich | `http://127.0.0.1:2283` | Нет |
| `API_KEY` | API ключ Immich с разрешениями `job.read` и `job.create` | - | **Да** |
| `MAX_CONCURRENT_JOBS` | Количество одновременно выполняемых заданий | `1` | Нет |

## Получение API ключа

1. Войдите в веб-интерфейс Immich
2. Перейдите в **Account Settings** → **API Keys**
3. Создайте новый API ключ с требуемыми разрешениями:
   - ✅ `job.read` - для чтения статуса заданий
   - ✅ `job.create` - для управления заданиями (pause/resume)
4. Скопируйте и используйте его в переменной `API_KEY`

> **⚠️ Важно:** API ключ должен иметь разрешения `job.read` и `job.create`, иначе демон не сможет управлять заданиями.

## Логи

Просмотр логов контейнера:

```bash
docker logs -f immich-job-daemon
```

## Как это работает

Демон каждые 10 секунд:

1. Получает список всех заданий из Immich API
2. Находит первые N заданий из списка приоритетов (где N = `MAX_CONCURRENT_JOBS`), у которых есть активность
3. Возобновляет эти задания
4. Приостанавливает все остальные управляемые задания

Это позволяет эффективно управлять ресурсами сервера, обрабатывая задания последовательно или параллельно по приоритету.

**Примеры использования:**
- `MAX_CONCURRENT_JOBS=1` - задания выполняются строго последовательно (по умолчанию)
- `MAX_CONCURRENT_JOBS=2` - два задания могут выполняться одновременно
- `MAX_CONCURRENT_JOBS=3` - три задания могут выполняться одновременно

## Требования

- Docker или Docker Compose
- **Запущенный сервер Immich** (контейнер `immich-server`)
- Доступ к Immich API
- Действительный API ключ Immich с разрешениями `job.read` и `job.create`
- Контейнер должен находиться в той же Docker сети, что и Immich

## Лицензия

MIT
