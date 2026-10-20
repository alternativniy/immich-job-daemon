# Immich Job Daemon

**[English](README.md) | Русский**

[![Docker Build](https://github.com/alternativniy/immich-job-daemon/actions/workflows/docker-build.yml/badge.svg)](https://github.com/alternativniy/immich-job-daemon/actions/workflows/docker-build.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Docker Pulls](https://img.shields.io/docker/pulls/alternativniy/immich-job-daemon)](https://github.com/alternativniy/immich-job-daemon/pkgs/container/immich-job-daemon)

Демон, ограничивающий число одновременно работающих тяжёлых очередей Immich. В Immich есть только настройка параллельности для каждой очереди отдельно ([discussion #3625](https://github.com/immich-app/immich/discussions/3625)); демон добавляет глобальный лимит, ставя очереди на паузу и возобновляя их в порядке приоритета пайплайна.

## Особенности

- 🐧 Основан на Alpine Linux (минимальный размер образа)
- 🔄 Приоритет по пайплайну: новые загрузки первыми получают метаданные и превью
- ⚙️ Настраиваемое количество одновременных очередей
- 🛡️ Не трогает служебные очереди (фоновые задачи, поиск, уведомления, ...)
- ♻️ При остановке снимает свои паузы, ничего не остаётся на паузе
- 🤝 Не трогает паузы, поставленные самим Immich или вами в UI
- 🔒 Запуск от непривилегированного пользователя
- 🌐 Настройка через переменные окружения

## Управляемые очереди

Демон управляет только тяжёлыми очередями со страницы `/admin/queues`, в порядке пайплайна (сначала верхние этапы):

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

Список и порядок меняются через `MANAGED_QUEUES`. Очереди, которых нет в вашей версии Immich, пропускаются.

Служебные очереди (`backgroundTask`, `search`, `notifications`, `backupDatabase`, `workflow`, `editor`, `integrityCheck`) никогда не ставятся на паузу. Если какая-то из них осталась на паузе (например, от старой версии демона), она возобновляется при старте.

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
| `API_KEY` | API ключ администратора Immich (разрешения ниже) | - | **Да** |
| `MAX_CONCURRENT_JOBS` | Количество одновременно работающих очередей | `1` | Нет |
| `POLL_INTERVAL` | Интервал опроса в секундах | `10` | Нет |
| `STRICT_LIMIT` | `true`: очередь запускается только после завершения текущих задач поставленных на паузу очередей, лимит никогда не превышается. `false`: переключение сразу, текущие задачи приостановленных очередей доделываются параллельно | `true` | Нет |
| `DRAIN_TIMEOUT` | Сколько секунд очередь на паузе с выполняющимися задачами может занимать слот. После этого она не учитывается, чтобы зависшая задача не блокировала всё. `0` = без ограничения | `1800` | Нет |
| `MANAGED_QUEUES` | Управляемые очереди в порядке приоритета (через пробел или запятую) | см. выше | Нет |
| `RESUME_UNMANAGED` | Возобновлять при старте неуправляемые очереди, стоящие на паузе | `true` | Нет |

> **📝 Примечание:** `MAX_CONCURRENT_JOBS` ограничивает число *очередей*. Каждая очередь по-прежнему выполняет до своего лимита параллельности из **Administration → Settings → Job Settings** (например, превью 3, метаданные 5). Для строго одной задачи за раз выставьте там параллельность тяжёлых очередей в `1`.

## Получение API ключа

1. Войдите в веб-интерфейс Immich под администратором
2. Перейдите в **Account Settings** → **API Keys**
3. Создайте новый API ключ с требуемыми разрешениями:
   - Immich 2.4 и новее: ✅ `queue.read`, ✅ `queue.update`
   - Старые версии: ✅ `job.read`, ✅ `job.create`
4. Скопируйте и используйте его в переменной `API_KEY`

Демон определяет API автоматически: использует `/api/queues`, если он доступен, иначе устаревший `/api/jobs`.

> **⚠️ При обновлении:** Immich 2.4+ требует ключ с правами `queue.read` и `queue.update`. Старый ключ только с правами `job.*` получит HTTP 403, и демон завершится с этой ошибкой при старте — создайте новый ключ или добавьте права существующему.

## Логи

Просмотр логов контейнера:

```bash
docker logs -f immich-job-daemon
```

## Как это работает

Каждые `POLL_INTERVAL` секунд демон:

1. Читает реальное состояние всех очередей из Immich API (неудачные запросы повторяются на следующем опросе)
2. Выбирает первые `MAX_CONCURRENT_JOBS` управляемых очередей по приоритету, в которых есть работа (`waiting + active > 0`)
3. Ставит на паузу остальные управляемые очереди, в которых есть работа
4. Очереди без работы оставляет без паузы: они не тратят ресурсы, новые задачи стартуют сразу, а кнопки **Missing** / **All** на `/admin/queues` остаются доступны (для очередей на паузе Immich их скрывает)
5. Возобновляет выбранные (при `STRICT_LIMIT=true` только при наличии свободных слотов: текущие задачи только что приостановленных очередей занимают слот до своего завершения или до истечения `DRAIN_TIMEOUT`)

Чужие паузы не трогаются: Immich ставит `metadataExtraction` на паузу на время импорта данных обратного геокодирования, а вы можете приостановить очередь вручную в UI. Демон снимает только свои паузы. Управляемые очереди, стоящие на паузе при старте, считаются оставшимися от прошлого запуска и берутся под управление.

Очередь без работы может начать новую задачу до следующего опроса. Перерасход ограничен уже начатыми к этому моменту задачами, дальше очередь управляется как обычно. Поэтому у `videoConversion`, очереди с самыми долгими задачами, самый низкий приоритет.

Пауза очереди **не прерывает** выполняющиеся задачи: текущая задача доделывается, новые просто не берутся. Поэтому очередь с более высоким приоритетом может вытеснить низкоприоритетную в любой момент.

**Пример** (`MAX_CONCURRENT_JOBS=1`):

- `videoConversion` обрабатывает 500 видео
- Загружено новое фото, в `metadataExtraction` появилась задача
- Демон ставит `videoConversion` на паузу, текущее видео дообрабатывается
- Запускается `metadataExtraction`, затем `storageTemplateMigration`, `thumbnailGeneration`, ML-задачи для нового фото
- После их завершения `videoConversion` продолжает работу

При остановке (`docker stop`) демон снимает поставленные им паузы, и Immich продолжает работать без него.

## Требования

- Docker или Docker Compose
- **Запущенный сервер Immich** (контейнер `immich-server`)
- Доступ к Immich API
- Действительный API ключ администратора Immich с разрешениями `queue.read` и `queue.update` (`job.read` и `job.create` для Immich < 2.4)
- Контейнер должен находиться в той же Docker сети, что и Immich

## Лицензия

MIT
