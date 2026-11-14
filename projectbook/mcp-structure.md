# MCP: перенос и порядок дерева

Добавлены `get_tree_order`, `move_document`, `reorder_tree`. Они используют те же
`ProjectbookMove` и `ProjectbookTree`, что Web UI, и общий HTTP WriteLock.
MCP не выполняет Git push. Скрытые системные файлы и Raw Notes не переносятся
этими инструментами. Создать новый раздел с описанием уже можно через
`save_document(path: "section/.index.md", expected_version: "", ...)`.

## Применение

1. Прочитать `get_tree_order` (пустой `path` — корень), `list_tree` и исходную
   страницу через `read_document`. Сохранить ревизию книги и SHA документа.
2. Вызвать `move_document` с `source`, `target`, `expected_revision`, при
   переносе страницы также `expected_version`. `dry_run` по умолчанию true:
   ответ показывает переносы, обновлённые ссылки и diff без записи.
3. После проверки вызвать с теми же параметрами и `dry_run: false`.
   Смена каталога и переименование — одна операция; папка переносится целиком.
   Перенос обновляет относительные/входящие ссылки, `source_path` задач и `.order`.
4. Для порядка соседей вызвать `reorder_tree(source, before, expected_revision)`.
   `source` — полный путь; `before` — имя соседа без пути. Omit/null означает конец.
   Сначала preview, затем apply с той же ревизией.
5. При конфликте перечитать книгу и согласовать новый результат. Не подменять
   ревизию автоматически. Несохранённые файлы, коллизии, symlink и перенос
   каталога внутрь самого себя отклоняются. Повтор применения со старой ревизией
   не создаёт второй перенос.

Инструменты изменения скрыты при `PROJECTBOOK_MCP_DOCUMENT_WRITE=false` или
read-only книге. Чтение порядка остаётся доступным и поддерживает историческую
ревизию. Перенос нескольких независимых веток одной командой и удаление дерева
не добавлялись.

## Проверка и локальный стенд

Полная сборка: стандартный `projectbook/Dockerfile`. Для быстрой проверки без
смены существующих экземпляров доступен `Dockerfile.mcp-structure-review` на
основе локального образа `projectwiki:access-review` с JWT-зависимостью. Это
локальный образ для проверки, не переносимый production-рецепт.

```sh
docker build -t projectwiki:mcp-structure-review -f projectbook/Dockerfile.mcp-structure-review .
docker run --rm --entrypoint ruby projectwiki:mcp-structure-review \
  -I/opt/projectbook-source/lib /opt/projectbook-source/projectbook/test/mcp_structure_test.rb
docker run --rm --entrypoint ruby projectwiki:mcp-structure-review \
  -I/opt/projectbook-source/lib /opt/projectbook-source/projectbook/test/move_test.rb
```

Отдельный review-экземпляр: Web UI `http://127.0.0.1:4012/Home`,
MCP `http://127.0.0.1:4012/mcp`. Его книга одноразовая, содержит только тестовые
документы. Она не добавляется в конфигурацию MCP клиента и не заменяет облачное
подключение. После серверного обновления клиенту потребуется обновить discovery
инструментов. Commit/push приложения выполняются после просмотра пользователем.

## Проверено 4 ноября 2026

Локально и в облачном образе: 36 тестов, 545 проверок без ошибок.
HTTP MCP на одноразовой книге проверен отдельно: discovery, preview/apply
переноса и порядка. Облако обновлено образом `projectwiki:mcp-structure-20261104`
поверх текущего Access-образа; изменены только три Ruby-файла механизма MCP/дерева.
Cloudflare OAuth и конфигурация RAG сохранены. Проверены healthy, initialize,
discovery (29 инструментов с RAG), get_tree_order и move_document в dry-run,
отказ 401 без авторизации, get_book_context через установленный OAuth-плагин.
Новые команды опубликованы сервером; текущему клиенту нужно обновить discovery.

Серверные файлы сборки и проверки: `/opt/projectbook/releases/mcp-structure-20261104/`.
Предыдущий образ: `projectwiki:bcb9c9d3cb73-access-20261027`.
Резервная конфигурация: `/opt/projectbook/backups/pre-mcp-structure-20261104/`.
Она содержит секреты и остаётся только на сервере. Для отката достаточно вернуть
значение `PROJECTBOOK_IMAGE` на предыдущий образ в `/opt/projectbook/.env`,
выполнить `docker compose up -d --no-deps wiki` из `/opt/projectbook`, затем
`docker exec projectbook-cloud-proxy-1 nginx -s reload`. Данные книги не откатываются.
