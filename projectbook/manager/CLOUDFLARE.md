# Автоматическая настройка Cloudflare

28 октября 2026 интеграция развернута на `https://pb.dmandr.net` в образе `projectbook-manager:cloudflare-20261028` (amd64, `sha256:c114c77f80ce2b857267fb2e900c8c9849e060a62b38c79d3da684eb9dd78591`). Отдельный API-токен `Project Book Manager · cloud` установлен в закрытый Docker volume. По явному выбору владельца токен бессрочный; разрешён только исходящий IP сервера `37.27.29.125/32`. Credential cloudflared не используется как API-токен.

Account ID: `bb22093bd449760b0f4e21427889fec7`; Zone ID `dmandr.net`: `b651eb0adba4da1ade1dd5f68f98c0b8`; Tunnel ID: `fce3d7a9-4580-4e8d-abd2-d5ed039776e2`; общее MCP-приложение: `bd3b0b97-af25-4360-afc9-66e391193c6e`. Это публичные идентификаторы ресурсов, не credentials.

Реальный API проверен с сервера: токен active; чтение DNS, Access и конфигурации туннеля; занятый адрес отклонён. На временном адресе выполнены создание политики/приложения, публикация DNS/маршрута, привязка к общему MCP, изменение политики и отзыв сессий, снятие публикации. Проверено точное сохранение прежней конфигурации туннеля, списка политик MCP и Managed OAuth. Временные ресурсы удалены; тест не создавал книгу или Git-репозиторий. Вход в обновлённую админку и добавление владельца в People проверены через браузер. Полный OAuth-сеанс MCP-клиента и облачный цикл Git остаются отдельной проверкой: Git credential ещё не установлен.

Резервная копия до обновления: `/opt/projectbook-manager/backups/pre-cloudflare-20261028` (прежние `.env`, compose и реестр). Для отката к старому образу восстановить из неё `.env` и `compose.yaml`, выполнить `docker compose -f compose.yaml -f compose.cloud.yaml up -d --no-build --wait` в каталоге установки. Сохранить текущий реестр и secret volume; не перезаписывать реестр старой копией, если после обновления создавались книги или пользователи. Старый образ `projectbook-manager:20261028` сохранён.

## Минимальные разрешения

Создайте Custom API Token:

| Категория | Разрешение в UI | Ресурсы |
| --- | --- | --- |
| Account | Access: Apps and Policies — Edit | Только аккаунт установки |
| Account | Cloudflare Tunnel — Edit | Только аккаунт установки |
| Zone | DNS — Edit | Только `dmandr.net` |

Account ID, Zone ID и Tunnel ID задаются заранее, поэтому `Zone Read`, управление аккаунтом, пользователями Cloudflare, биллингом и API-токенами не нужны. Access Edit также позволяет отзывать сессии приложения. API-токен ограничьте проверенным исходящим IP сервера и подходящим сроком действия. Account-права охватывают соответствующие ресурсы всего аккаунта, DNS — всю выбранную зону: проверки сохранённых ID в Manager не сужают сами полномочия токена Cloudflare. Не используйте Global API Key.

Официальные схемы: [Access policies](https://developers.cloudflare.com/api/resources/zero_trust/subresources/access/subresources/policies/methods/create/), [Tunnel/DNS](https://developers.cloudflare.com/tunnel/get-started/), [отзыв сессий](https://developers.cloudflare.com/api/resources/zero_trust/subresources/access/subresources/applications/methods/revoke_tokens/).

В серверном `.env` задайте публичные идентификаторы (секрет сюда не помещать):

```dotenv
CF_ACCOUNT_ID=ACCOUNT_ID
CF_ZONE_ID=ZONE_ID_FOR_DMANDR_NET
CF_TUNNEL_ID=EXISTING_REMOTELY_MANAGED_TUNNEL_ID
CF_MCP_APP_ID=SHARED_MCP_ACCESS_APP_ID
CF_BASE_DOMAIN=dmandr.net
```

`ADMIN_PUBLIC_URL`, `MCP_PUBLIC_URL`, `ACCESS_ISSUER`, admin/MCP audiences остаются обязательными. Общий MCP должен использовать reusable policies. Его исходная политика владельца и OAuth-настройки сохраняются, политики новых книг добавляются отдельно. Админка не получает политик пользователей книг.

Токен хранится в файле `api-token` Docker volume `projectbook-manager-cloudflare`, mode 0600. Manager получает volume read-only в `/run/cloudflare`. Git helpers и контейнеры книг этот volume не получают. Для безопасного ввода на Docker-хосте используйте интерактивный ввод без shell history (замените образ на проверенную версию):

```sh
docker run --rm -it --network none \
  -v projectbook-manager-cloudflare:/run/cloudflare \
  --entrypoint python projectbook-manager:cloudflare-preview -c \
  'import getpass,os; from pathlib import Path; p=Path("/run/cloudflare/api-token"); token=getpass.getpass("Cloudflare API token: ").strip(); assert token; fd=os.open(str(p)+".tmp",os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600); f=os.fdopen(fd,"w"); f.write(token); f.close(); os.replace(str(p)+".tmp",p)'
```

После установки токена и настроек перезапустите Manager. При неполной конфигурации кнопка создания книги недоступна. Ошибки API показываются без содержимого ответов, credentials и токенов. На тестовом Mac используйте отдельные тестовые настройки, не облачный credential.

## Адреса и восстановление после ошибок

Проверка адреса выполняется кнопкой **Check availability**, повторно при создании и перед публикацией. Проверяются записи DNS (включая wildcard), все страницы списка Access applications, маршруты настроенного туннеля и локальные установки. Любая соответствующая чужая запись блокирует создание. Домены админки/MCP зарезервированы. Глобальные catch-all правила туннеля сохраняются; wildcard-hostname, совпадающий с новым адресом, считается конфликтом.

Порядок: создать reusable email policy → отдельное Access-приложение → клонировать/запустить книгу → привязать её policy к общему MCP → добавить маршрут с проверкой Access JWT в cloudflared → создать proxied CNAME. Записи содержат уникальный маркер установки; ID и этапы сохраняются после каждого шага. После потерянного ответа повторная попытка находит свои ресурсы вместо создания дублей. При отказе API состояние остаётся ошибкой с Retry. Созданная часть защиты сохраняется.

При удалении после успешного Git push снимаются принадлежащие книге DNS и маршрут, политика отвязывается от общего MCP; лишь затем освобождается порт. Access-приложение и policy сохраняются как защита старого адреса. Имя остаётся зарезервированным до ручной проверки и очистки в Cloudflare. Это не удаляет Git remote или volumes.

Обновление туннеля в Cloudflare заменяет конфигурацию целиком. Manager сериализует свои операции, перечитывает версию перед PUT, сохраняет посторонние маршруты и проверяет результат; API не предоставляет используемого здесь атомарного compare-and-swap. Не редактируйте тот же туннель или список политик общего MCP одновременно другим контроллером. Проверяются ресурсы выбранной зоны и настроенного туннеля; локальные конфигурации других туннелей не инспектируются. Ручные изменения политики/приложения книги требуют сверки в Cloudflare, а не молчаливой перезаписи.

## Люди и доступ к книгам

**People** — общий справочник имени/email, до 50 записей. Добавление записи не выдаёт доступ и не создаёт Cloudflare-аккаунт. Это локальный предел справочника, а не счётчик свободных мест тарифа: другие приложения могут использовать места того же аккаунта.

В создании книги и в **People** на её карточке выбираются люди из справочника. Требуется хотя бы один человек. Сохранение обновляет reusable policy и отзывает браузерные сессии этой книги. MCP проверяет список на каждом запросе, включая после ожидания блокировки; при ошибке обновления книга недоступна через MCP до успешного Retry. Общий MCP может допускать пользователя по политике другой книги, но не выдаёт ему чужие инструменты, ресурсы и содержимое. При включённой интеграции старые установки без отдельного списка пользователей закрыты в общем MCP до миграции. Ручной ACL дополнительно сужает доступ, если настроен.

Чтобы удалить человека из справочника, сначала снимите его доступ во всех активных книгах. Форма изменения доступа проверяет исходный список и отклоняет устаревшую правку. Импорт старой Trinity в Manager не входит в этот этап.

## Проверки

35 модульных тестов и полный сценарий `tests/cloudflare_integration.py` с двумя настоящими Docker-книгами и имитацией Cloudflare API: занятый адрес, каталог людей, выбор доступа, фактический отказ MCP для чужой книги, отзыв/возврат доступа, Git-save и снятие маршрута перед удалением. В `tests/cloudflare_preview.py` API Cloudflare целиком имитируется; этот сервер нельзя запускать в production. Успех этих тестов не заменяет проверку настоящего Cloudflare API с ограниченным токеном.

Локальный preview на `http://127.0.0.1:8072` использует отдельный state volume `projectbook-manager-cloudflare-preview-state`, контейнер `projectbook-manager-cloudflare-preview`, образ `projectbook-manager:cloudflare-preview`. Облачные DNS-записи и политики не создаются. Имитация API находится в памяти; preview восстанавливает успешно созданные ресурсы из своего реестра при перезапуске. Для проверки прерванных операций используйте модульный fixture. Тестовый Git fixture общий с прежним локальным стендом, но каждая книга имеет собственный clone/volumes.

Из корня репозитория, при уже запущенном `git-fixture` из README:

```sh
docker compose -f projectbook/manager/tests/compose.preview.yaml up -d --build --wait
docker exec projectbook-manager-cloudflare-preview python /tests/cloudflare_integration.py
```

Интеграционный сценарий ожидает созданную через preview книгу `Cloudflare demo · Alpha` из `https://git-fixture/alpha.git`, с выбранными `owner@example.com` и ещё одним тестовым пользователем. Создаваемая им Beta одноразовая; для повторного полного прогона используйте свежий preview state, потому что старый адрес остаётся зарезервированным Access-защитой. Для остановки preview используйте тот же compose с `stop`; не удаляйте volumes автоматически.
