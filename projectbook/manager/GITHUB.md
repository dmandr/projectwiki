# GitHub: OAuth и создание репозиториев

28 октября 2026 интеграция включена на `https://pb.dmandr.net`. GitHub App **Project Book dmandr** создано и установлено на выбранные репозитории, OAuth владельца и реальное создание private-репозитория проверены. Cloudflare сохраняет текущий токен.

## Поведение

Администратор нажимает **Connect GitHub** и входит как владелец, указанный в `GITHUB_OWNER`. В **New book** можно проверить доступ к `owner/repository`. Manager сверяет числовой ID пользователя, установку приложения, Contents write и право пользователя на push. Для отсутствующего репозитория дополнительно требуется Repository creation write. Если GitHub возвращает 404, интерфейс не утверждает, что имя свободно: недоступный репозиторий выглядит так же. Создание занятого имени отклоняет GitHub.

Новые репозитории всегда private, принадлежат настроенному личному аккаунту. Организации пока не поддержаны. Создание сохраняет маркер операции; Retry проверяет ID и результат предыдущей попытки, не подменяет репозиторий с тем же именем. После создания Manager клонирует репозиторий, создаёт Home, делает первый push и проверяет удалённую ревизию. После этого запускаются книга и публикация Cloudflare.

Перед каждым Git helper права проверяются снова. При Remove сначала выполняются commit, обычный push и проверка remote SHA; при ошибке данные и контейнеры сохраняются для Retry. Сам GitHub-репозиторий никогда не удаляется. Периодическая Git-синхронизация этим изменением не добавляется.

## Минимальная GitHub App

В GitHub Settings → Developer settings → GitHub Apps создайте приложение своего аккаунта:

- Homepage: `https://pb.dmandr.net`.
- Callback: `https://pb.dmandr.net/auth/github/callback`, без wildcard.
- Expire user authorization tokens: включено.
- Request user authorization during installation: выключено; вход начинается кнопкой Manager, с проверкой state, PKCE и cookie браузера.
- Webhook и Device flow: выключены.
- Repository permissions: **Contents — Read and write**, **Repository creation — Read and write**, обязательное **Metadata — Read-only**. Administration, Actions, Workflows, Secrets и прочие разрешения не нужны.
- Where can this GitHub App be installed: **Only on this account**.

Установите приложение только на необходимые существующие репозитории. Для первичной проверки выбран `projectbook-testwiki`. Настоящий GitHub API подтвердил: новый репозиторий, созданный этим приложением, автоматически добавляется к выбранной установке. Поэтому All repositories не требуется. Если иной существующий репозиторий не входит в разрешённые, Manager остановится до clone с просьбой выбрать его в GitHub App installation и нажать Retry. Доступ к невыбранному `projectwiki` проверен и отклонён без изменений его содержимого.

Задайте публичные `GITHUB_CLIENT_ID` и `GITHUB_OWNER=dmandr` в серверном `.env`. Client secret хранится в `/run/github/client-secret` (0600), volume `projectbook-manager-github`. Manager имеет запись в этот volume для обновления пользовательских OAuth credentials. Не помещайте секрет в `.env`, Git, параметры команд, журналы или скриншоты. Примените compose и нажмите Connect GitHub в защищённой админке.

## Сроки и хранение

GitHub App user access token действует 8 часов. Manager обновляет его через refresh token, который действует 6 месяцев и заменяется при каждом обновлении. После отзыва или истечения refresh token требуется новый Connect GitHub. Долгоживущий PAT не принимается. Client secret приложения и refresh token остаются серверными секретами: короткий срок access token не устраняет потребность защищать их.

Credentials привязаны к подтверждённому Cloudflare-пользователю и записываются атомарно в отдельные файлы 0600. В registry хранятся только идентификаторы аккаунта/репозитория и состояние операции. Access token передаётся Git helper через stdin Docker и временный файл в tmpfs; helper не получает refresh token, client secret, Docker socket или credentials других книг. Credential helper выдаёт токен только точному HTTPS-репозиторию на github.com; HTTP redirects запрещены. Контейнер книги токен не получает. OAuth callback исключён из nginx access log.

## Проверки и локальный стенд

Облачный релиз: `projectbook-manager:github-20261028`, image `sha256:eec7bc7a415635bb0de481e74fdce2d2af880ea6773af1b76b29ec4d6fa77e16`. App ID `5516448`, Client ID `Iv23liCevnT3KSAUFpsF`, installation `176316500`, проверенный GitHub user ID `112403690` (`dmandr`). Это публичные идентификаторы, не credentials. Фактические разрешения установки: contents write, repository_creation write, metadata read; repository_selection selected. Приватный ключ приложения не генерировался и для этого OAuth-сценария не потребовался.

На сервере повторно прошли 46 тестов. Реальная проверка: OAuth с PKCE; access token 28800 секунд; успешная замена access/refresh пары; существующий `projectbook-testwiki` с push; создание private `dmandr/projectbook-oauth-smoke-20261028` (ID `1437594897`), автоматическое добавление в выбранную установку, clone/первый push, запуск книги и доступ через Cloudflare. Документ отредактирован через браузер. Remove отправил его в GitHub, проверил SHA `d7a8c043409e41f99baddedd063271f0b1324f19`, снял контейнер и публикацию. Тестовый private-репозиторий и Docker volumes сохранены; Access-приложение/политика остаются защитой старого адреса по обычной логике удаления. Анонимный admin получает 302, общий MCP — 401 OAuth challenge. Полный клиентский OAuth-сеанс общего MCP — отдельная незавершённая проверка.

Конфигурация отката: `/opt/projectbook-manager/backups/pre-github-20261028/{.env,compose.yaml,compose.cloud.yaml,nginx.conf}`. Содержит настройки установки; не публиковать. Для отката восстановить эти файлы в `/opt/projectbook-manager` и выполнить `docker compose -f compose.yaml -f compose.cloud.yaml up -d --no-build --force-recreate --wait`. OAuth credentials остаются в отдельном volume. Старый релиз Cloudflare сохранён. Не используйте создание второго `Manager('/data')` для диагностики работающей установки: конструктор помечает незавершённые операции как прерванные. Для чтения используйте API либо `Registry` без мутаций.

46 модульных тестов: OAuth state/cookie/PKCE, другой аккаунт, refresh rotation, права пользователя и установки, создание private, потерянный ответ и Retry, отсутствие секретов в Docker Config и registry. Интеграционный тест использует настоящие Docker/Git/HTTPS clone и push, но GitHub OAuth/API и Cloudflare API заменены локальными fixtures. Проверены первый push, запрет чужого owner, отказ push с изменённым файлом, сохранение данных и успешное удаление после Retry.

Из корня приложения (требуется уже собранный `projectwiki:local`):

```sh
docker build -t projectbook-manager:github-preview projectbook/manager
docker run --rm --network none -v "$PWD/projectbook/manager/tests:/tests:ro" --entrypoint python projectbook-manager:github-preview -m unittest discover -s /tests
docker compose -f projectbook/manager/tests/compose.github-preview.yaml up -d --wait remote
mkdir -p /tmp/pb-github-integration-image
docker cp projectbook-github-remote:/certs/ca.crt /tmp/pb-github-integration-image/ca.crt
cat > /tmp/pb-github-integration-image/Dockerfile <<'DOCKERFILE'
FROM projectbook-manager:github-preview
COPY ca.crt /usr/local/share/ca-certificates/github-fixture.crt
RUN update-ca-certificates
DOCKERFILE
docker build -t projectbook-manager:github-integration /tmp/pb-github-integration-image
docker compose -f projectbook/manager/tests/compose.github-preview.yaml up -d --wait manager
docker exec projectbook-manager-github-preview python /tests/github_integration.py
```

Preview: `http://127.0.0.1:8074`. GitHub identity `owner` и домены карточек — симуляция, внешние репозитории/DNS не создаются. Книга открывается через показанный локальный Origin-порт. Fixture доверяет только тестовым токенам; его CA добавлен исключительно в образ `github-integration`. Никогда не разворачивайте этот образ или fixture entrypoints на сервере. Для production собирайте обычный Dockerfile без тестового CA. Стенд использует отдельную Docker-сеть; внешние подключения сетью не заблокированы. Завершение: `docker compose -f projectbook/manager/tests/compose.github-preview.yaml down`; книги предварительно Remove через UI, volumes остаются.

## Источники

- [GitHub App user access tokens и OAuth](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/generating-a-user-access-token-for-a-github-app).
- [Сроки и обновление токенов](https://docs.github.com/en/apps/creating-github-apps/authenticating-with-a-github-app/refreshing-user-access-tokens).
- [Создание репозитория через REST API](https://docs.github.com/en/rest/repos/repos?apiVersion=2026-03-10#create-a-repository-for-the-authenticated-user).
