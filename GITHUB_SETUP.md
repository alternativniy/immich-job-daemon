# Настройка автоматической сборки Docker образа в GitHub

## Что уже настроено

В проекте уже создан GitHub Actions workflow (`.github/workflows/docker-build.yml`), который автоматически:

- ✅ Собирает Docker образ для нескольких архитектур (amd64, arm64, arm/v7)
- ✅ Публикует образ в GitHub Container Registry (ghcr.io)
- ✅ Создает теги для версий (latest, semver)
- ✅ Использует кеширование для ускорения сборки
- ✅ Поддерживает ручной запуск через workflow_dispatch

## Что нужно сделать

### 1. Включить GitHub Container Registry

GitHub Container Registry уже включен по умолчанию, но убедитесь, что в настройках репозитория:

1. Перейдите в репозиторий на GitHub
2. Откройте **Settings** → **Actions** → **General**
3. В разделе **Workflow permissions** выберите **Read and write permissions**
4. Поставьте галочку **Allow GitHub Actions to create and approve pull requests**
5. Нажмите **Save**

### 2. Замените alternativniy на ваше имя пользователя

В следующих файлах замените `alternativniy` на ваше имя пользователя GitHub:

- `Dockerfile` (в LABEL org.opencontainers.image.url и source)
- `README.md` (в примерах использования)
- `README.en.md` (в примерах использования)
- `docker-compose.yml` (в image)

Например, если ваше имя пользователя `john`, замените:
```
ghcr.io/alternativniy/immich-job-daemon:latest
```
на:
```
ghcr.io/john/immich-job-daemon:latest
```

### 3. Запуск автоматической сборки

Workflow запускается автоматически при:

- ✅ **Push в ветку main** - создаст образ с тегом `latest`
- ✅ **Создании тега** (например, `v1.0.0`) - создаст версионированные образы:
  - `v1.0.0`
  - `1.0`
  - `1`
  - `latest`
- ✅ **Pull Request** - соберет образ для проверки (но не опубликует)
- ✅ **Ручной запуск** - через вкладку Actions → Run workflow

### 4. Создание первого релиза

Для создания версионированного релиза:

```bash
# Создайте и запушьте тег
git tag v1.0.0
git push origin v1.0.0
```

Или через GitHub:
1. Перейдите в **Releases** → **Create a new release**
2. Создайте новый тег (например, `v1.0.0`)
3. Добавьте описание изменений
4. Нажмите **Publish release**

### 5. Использование образа

После успешной сборки образ будет доступен по адресу:

```
ghcr.io/alternativniy/immich-job-daemon:latest
```

Для использования:

```bash
docker pull ghcr.io/alternativniy/immich-job-daemon:latest

docker run -d \
  --name immich-job-daemon \
  -e IMMICH_URL=http://your-immich-server:2283 \
  -e API_KEY=your_api_key_here \
  -e MAX_CONCURRENT_JOBS=2 \
  ghcr.io/alternativniy/immich-job-daemon:latest
```

### 6. Настройка видимости пакета

По умолчанию пакет будет приватным. Чтобы сделать его публичным:

1. Перейдите на страницу вашего профиля
2. Откройте вкладку **Packages**
3. Найдите `immich-job-daemon`
4. Откройте **Package settings**
5. Внизу страницы в разделе **Danger Zone** нажмите **Change visibility**
6. Выберите **Public**

## Проверка статуса сборки

1. Перейдите в репозиторий
2. Откройте вкладку **Actions**
3. Найдите последний workflow run
4. Проверьте логи сборки

## Добавление бейджа в README

Вы можете добавить бейдж статуса сборки в README:

```markdown
![Docker Build](https://github.com/alternativniy/immich-job-daemon/actions/workflows/docker-build.yml/badge.svg)
```

## Мультиархитектурная поддержка

Образ автоматически собирается для следующих архитектур:
- `linux/amd64` - Intel/AMD процессоры (x86_64)
- `linux/arm64` - ARM 64-bit (Apple Silicon, Raspberry Pi 4+)
- `linux/arm/v7` - ARM 32-bit (Raspberry Pi 3, старые версии)

Docker автоматически выберет правильную версию для вашей платформы.

## Troubleshooting

### Ошибка "permission denied"
Проверьте настройки Workflow permissions в Settings → Actions → General

### Образ не публикуется
Убедитесь, что вы пушите в ветку `main` или создаете тег версии

### Ошибка аутентификации
GitHub автоматически использует `GITHUB_TOKEN`, дополнительных настроек не требуется
