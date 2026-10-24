# ProjectWiki: локальный Docker-стенд

Воспроизводимая сборка приложения из **этого checkout** и запуск с отдельной книгой. Реализованы навигация, создание каталогов/документов и прямое подключение MDXEditor. Последняя интеграция редактора проходит пользовательскую проверку без commit/push; темы и метаданные остаются в плане. [План](../PLAN.md), [правила работы](../AGENTS.md).

## Быстрый запуск на Mac

Нужны Git и запущенный Docker Desktop с Docker Compose v2, поддерживающим `up --wait`. Node и Ruby на Mac не нужны: всё собирается в Docker.

Из корня `projectwiki`, если рядом уже есть `testwiki`:

```sh
./projectbook/prepare-book.sh
./projectbook/start.sh
```

`prepare-book.sh` один раз создаёт независимый sibling clone `../testwiki-projectwiki`. Он копирует закоммиченные данные, не трогает исходную книгу и отказывается перезаписывать существующий каталог. Можно вместо локальной книги указать Git URL:

```sh
./projectbook/prepare-book.sh git@github.com:OWNER/BOOK.git
```

Для приватного GitHub-репозитория доступ нужен только хосту, выполняющему clone. SSH-ключи и токены в контейнер не передаются. Скрипт сохраняет настоящий `origin`, но сам не делает commit/push и не включает синхронизацию.

`start.sh` проверяет книгу и ветку, собирает образ, запускает контейнер и ждёт успешного healthcheck. После запуска: **http://127.0.0.1:4569/Home**.

В Finder также можно запускать `Start.command`, `Stop.command`, `Status.command` и `Cleanup.command`. Первичная подготовка книги выполняется в Terminal командой выше.

## Повседневные команды

```sh
./projectbook/status.sh         # контейнер, health, адрес, HEAD и изменения книги
./projectbook/logs.sh           # последние 100 строк
./projectbook/logs.sh --follow  # следить за логами, Ctrl-C завершает просмотр
./projectbook/stop.sh           # остановить только этот экземпляр
./projectbook/start.sh          # собрать изменения и запустить снова
./projectbook/cleanup.sh        # удалить его контейнер и сеть; книгу и образ сохранить
./projectbook/cleanup.sh --image # также удалить локальный образ, без force и global prune
```

Все скрипты работают из любого текущего каталога. По умолчанию Compose-проект — `projectbook-fork`, образ — `projectwiki:local`. Существующие эксперименты на 4567/4568 не затрагиваются. Контейнер возобновляет работу при старте Docker, если ранее не был остановлен вручную.

Очистка **никогда не удаляет каталог книги**. Чтобы полностью выбросить экспериментальные данные, после остановки отдельно удалите `testwiki-projectwiki`, предварительно проверив, что его локальные изменения больше не нужны. `prepare-book.sh` затем создаст свежую копию. Docker build cache не чистится глобально.

## Настройки

Для постоянных настроек:

```sh
cp projectbook/settings.example.sh projectbook/settings.local.sh
```

Отредактируйте `settings.local.sh`; это доверенный shell-файл, он исключён из Git и Docker build context. Примеры временного переопределения:

```sh
PROJECTBOOK_PORT=4570 ./projectbook/start.sh
PROJECTBOOK_WIKI_DIR=/absolute/path/to/book ./projectbook/start.sh
GOLLUM_EDITOR=ace ./projectbook/start.sh
GOLLUM_READ_ONLY=true ./projectbook/start.sh
```

- `PROJECTBOOK_WIKI_DIR`: абсолютный путь к отдельному обычному clone (не git worktree с внешним `.git`). По умолчанию `../testwiki-projectwiki` относительно корня приложения.
- `PROJECTBOOK_PORT`: порт на `127.0.0.1`, по умолчанию 4569.
- `PROJECTBOOK_INSTANCE`: отдельное имя Compose-проекта для второго экземпляра.
- `PROJECTBOOK_IMAGE`: локальный тег образа.
- `GOLLUM_REF`: ветка книги, по умолчанию `main`; checkout должен находиться на ней и иметь хотя бы один commit.
- `GOLLUM_EDITOR`: `mdx` или `ace`; `GOLLUM_TREE=false` отключает прототип дерева.
- `GOLLUM_READ_ONLY=true`: отключает редактирование и загрузки через Gollum.

При переопределении имени экземпляра используйте его же для status/stop/cleanup, либо сохраните в локальных настройках. При изменении имени сначала остановите старый экземпляр. Для параллельных экземпляров задайте разные имена, порты и **разные clone книги**. Разные рабочие копии не синхронизируются автоматически.

## Что хранится где

- Публичный репозиторий: исходники приложения, расширения, npm lockfile, Dockerfile и скрипты.
- Docker-образ: Gollum из текущих исходников, зафиксированные Ruby-зависимости и собранный frontend. `.dockerignore` разрешает только перечисленные исходники, поэтому книги, локальные настройки и ключи не попадают в build context.
- Каталог книги на Mac: Markdown, медиа и `.git`, подключённые в `/wiki`. Остановка, пересборка и удаление контейнера не меняют их.
- Браузер: Markdown и несохранённые вложения в IndexedDB. Черновики не синхронизируются между браузерами и могут быть потеряны при очистке данных сайта.

Собственная база данных и Git LFS для этого стенда не нужны. Нажатие Save в Web UI создаёт локальный commit **книги**; это не commit исходников приложения. Автоматического push/pull нет. Проверки UI могут создавать локальные коммиты одноразовой тестовой книги; исходники приложения коммитятся только после подтверждения пользователя.

## Сборка и текущие ограничения

Базовые образы закреплены digest. Для текущего Gollum дополнительно собираются SassC 2.4.0 и FFI 1.17.2 в отдельной стадии; компилятор не переносится в runtime. Frontend собирается через `npm ci` по lockfile. Runtime берётся из закреплённого официального образа Gollum; затем Gollum переустанавливается из этого checkout. Сборка проверяет требования к Ruby-зависимостям и загрузку приложения. При обновлении зависимостей потребуется обновить runtime; дополнительные gems устанавливаются только с явно указанными версиями.

В upstream manifest исправлен путь `template.scss.erb` на существующий `template.scss`, иначе gem из текущего исходного дерева не собирается. В упаковку gem также включён скрытый Sprockets manifest, без которого страницы пытались пересобирать отсутствующие frontend-зависимости при запросе. Исходный Dockerfile Gollum оставлен; этот стенд использует `projectbook/Dockerfile`. MIT-лицензия Gollum сохранена.

На Linux каталогу книги нужны права записи для пользователя контейнера `www-data` (UID 1000). На этом этапе проверяется Mac / Apple Silicon с Docker Desktop; другие платформы пока не проверены. Порт доступен только с локальной машины, внешняя авторизация ещё не реализована.

MDXEditor и новое сохранение описаны ниже. Темы, TODO, MCP и Git-синхронизация остаются отдельными этапами. Для Gollum-специфичной разметки и HTML-комментариев используйте Markdown; точный исходник при визуальном редактировании не гарантируется.


## Navigation

The interface is in English; document contents keep their original language. Folders are collapsed on the first visit. Click the chevron to expand/collapse without a server request; click a different folder name to open its contents in the right pane and expand it. Clicking the selected folder name toggles its children without reloading the page; clicking the selected file is a no-op. Expanded folders are remembered in this browser. Search is retained across transitions and restored synchronously before the content renders. The tree and content share one page scroll: the taller column determines page height, with no separate sidebar scrollbar. A stable page scrollbar gutter prevents horizontal shifts when folders expand or collapse. One `Search documents` field filters the tree locally by title/path while typing; Enter or the search button opens full-text document results. The query survives navigation; Escape or clearing the field restores the tree. Explicit search URL queries take priority over the remembered query. `Expand all` and `Collapse all` operate locally without clearing the search. Arrow keys move between visible entries and expand/collapse folders; Enter follows a link.

The tree includes documents and attachments. Both navigation and folder listings use file paths from Git tree metadata, never a full enumeration of page/file blobs. A bounded in-memory cache holds the index and sidebar HTML. Each page request checks the **local branch commit ID**; only a changed ID rebuilds the cache. Save or an externally updated branch is reflected on the next navigation/reload. There is no Git fetch/pull, network synchronization or automatic polling of the remote. Raw uncommitted filesystem changes are not part of the committed navigation index.

Regression checks (no commits or book writes):

```sh
docker run --rm --entrypoint ruby -e RUBYLIB=/src/lib \
  -v "$PWD:/src:ro" projectwiki:local /src/projectbook/test/navigation_index_test.rb
```


Images and PDF files selected in the tree or folder list open in an attachment preview with the sidebar retained. `Open original` in the header opens the raw file separately for viewing/downloading. Raw asset URLs remain unchanged so embedded media still work. Other attachments use the same Open original action. Directory headings use the folder name; the root is called `Files`.


## Shared header and creation

The header is shared by document, folder, attachment, editor, search and history screens: Home (ProjectBook), content search and one row of icon-only actions with accessible names and tooltips. New document / New folder, History, Edit and All files share the search row. A compact breadcrumb strip sits below it without horizontal separators. The explorer and document body no longer duplicate these controls. Rename is available while editing. In MDXEditor, clicking the title or Rename edits the leading Markdown heading without changing the file path. The separate Move icon opens full-path confirmation; pending edits are saved together with the move. The legacy Ace editor still requires saving edits before its stock rename. Upload/Download are removed from the common toolbar; attachments offer Open original. The single History button opens book-wide changes from Home and global screens, or the selected document’s history elsewhere. Both history screens are titled History and offer a History of selector for Entire book or any Markdown/document page. Theme selection and richer directory metadata are separate upcoming work.

Both creation dialogs show a selectable existing destination folder and the resulting path. A selected document/attachment defaults to its parent; a directory defaults to itself. New document asks for Title and offers an editable path. Create and edit creates the Markdown H1 in one book commit and opens MDXEditor; later content changes use Save. A folder is committed through Gollum with a hidden `.gitkeep` marker and immediately appears in the index/tree.

The creation endpoint requires the same-origin UI JSON request header, respects read-only mode, rejects reserved/traversal paths and symlinks, and reports collisions without overwriting files. POST operations in this app process are serialized, including stock saves/uploads. This is not synchronization with external Git writers or other instances. Save-time duplicate document creation now returns HTTP 409 so the editor retains its text.

Focused checks (temporary repositories inside a disposable container, not the mounted book):

```sh
docker run --rm --entrypoint ruby -e RUBYLIB=/src/lib \
  -v "$PWD:/src:ro" projectwiki:local /src/projectbook/test/creation_test.rb
```

## Редактор и вложения

- Markdown редактируется напрямую в MDXEditor: Visual / Markdown / Changes, без загрузки Ace и его старой формы. Для других форматов или `GOLLUM_EDITOR=ace` остаётся штатный редактор.
- Клик по заголовку или Rename открывает поле для первого `# Заголовка` в Markdown. Имя файла и URL не меняются. Enter/галочка применяют изменение в редакторе, Escape/крестик отменяют; Save записывает его вместе с документом. Без H1 показывается имя файла без расширения. Отдельная кнопка Move меняет полный путь, включая имя файла; для новой страницы путь выбирается до Save. Применённый заголовок, путь и вложения сохраняются в браузерном черновике.
- Перетащите файлы в текст либо используйте Attach files. PNG/JPEG/GIF/WebP/AVIF вставляются изображениями; PDF и другие файлы — ссылками. Работают несколько файлов и вставка файлов из буфера обмена.
- До Save вложения находятся только в браузере. Save отправляет документ и используемые вложения одним запросом и создаёт один Git-коммит. Пути `uploads/<UUID>/<filename>` исключают перезапись одноимённых файлов; ссылки в Markdown относительные. Удалённые из текста новые вложения не публикуются.
- Ограничения: 20 MiB на файл, 50 MiB и 30 файлов за сохранение, Markdown до 2 MiB. Есть прогресс загрузки, сообщение ошибки и возможность повторить Save. При конфликте версии правки остаются в браузере; автоматического merge пока нет.
- Close and keep draft сохраняет текст и файлы в IndexedDB; Restore draft восстанавливает их. Discard удаляет только локальный черновик и возвращает к документу/каталогу. Download Markdown — аварийная выгрузка текста; отдельные несохранённые файлы доступны в списке вложений.
- Размер картинки хранится прямо в Markdown: `<img src="../../uploads/.../photo.png" alt="Photo" width="23%" />`. При выборе картинки появляется панель Original / 25% / 50% / 75% / 100%, поле для произвольного процента (включая дробный) или числа пикселей, Apply. Панель скрывается при клике вне картинки, Escape или Apply. Стрелки вверх/влево переводят курсор перед выбранной картинкой, вниз/вправо и Enter — после неё; при необходимости создаётся абзац. При изменении ширины высота автоматически сохраняет пропорции. Внешние Markdown-просмотрщики с поддержкой HTML смогут отрисовать этот формат; запрещающие HTML просмотрщики могут его скрыть.
- Вставляемые изображения отделяются от соседнего текста абзацами, в том числе через Insert image. Визуальное редактирование приводит смешанные абзацы с изображениями к блочному виду.
- Markdown без размеров остаётся обычным `![alt](path)`. Для HTML `<img>` используется собственный импорт/экспорт MDXEditor, чтобы проценты не превращались в пиксели, а относительные адреса сохранялись. Форк MDXEditor не нужен.
- Документы с HTML-комментариями/старой wiki-разметкой открываются в Markdown. Неподдерживаемый визуальным парсером синтаксис требует работы в исходнике. Визуальные правки могут нормализовать списки/таблицы; проверяйте Changes. Открытие само не меняет файлы. Save без изменений не создаёт коммит, кроме добавления отсутствующего H1 по правилу Title.
- Записи сериализуются внутри одного процесса приложения. Внешние Git-записи и синхронизация нескольких экземпляров остаются отдельным этапом.

Проверки API на одноразовых репозиториях внутри работающего контейнера:

```sh
docker exec -i projectbook-fork-wiki-1 ruby - < projectbook/test/editor_save_test.rb
```

### Заголовок и Move

- Нажмите Move и укажите полный путь от корня книги, например `Archive/2026/Notes.md`; новые каталоги создаются при сохранении. Имя должно сохранять Markdown-расширение.
- Для новой страницы Use this path выбирает путь, а запись происходит по Save. Для существующей Save and move подтверждает старый/новый путь и сохраняет несохранённый текст, используемые вложения и перенос одним Git-коммитом. Cancel ничего не записывает.
- Проверяются исходная версия, занятые пути, локальные несохранённые файлы, символические ссылки и коллизии регистра. При ошибке текст остаётся в редакторе.
- Внутри переносимого документа пересчитываются относительные Markdown-ссылки, изображения, reference definitions и HTML `src`/`href`. Код и frontmatter не меняются. HTML-картинки сохраняют совместимый с MDX вид `<img ... />`.
- Входящие ссылки из других страниц и wiki-синтаксис `[[...]]` не переписываются; редиректы не создаются. Произвольные URL в CSS, `srcset` и метаданных тоже требуют отдельной проверки. История содержимого остаётся в Git; автоматическое обнаружение переименования в History зависит от сходства содержимого до и после правок.
- Проверка преобразования ссылок: `npm --prefix projectbook/editor test`.

### Title и путь при создании

- `engine-check` / `engine_check` в поле Title превращаются в `Engine Check`; обычный введённый текст сохраняет свой регистр. Из Title предлагается имя с маленькими латинскими буквами и дефисами: `Проверка двигателя` → `proverka-dvigatelya.md`. Явно введённый путь сохраняется; менять существующие пути массово не требуется.
- Изменение Document path генерирует Title из последнего компонента пути. Изменение Title обновляет имя в выбранном каталоге. Путь виден до подтверждения; одинаковые имена не перезаписываются. При создании отсутствующие каталоги добавляются автоматически.
- Открытие отсутствующего адреса показывает Document not found с полным путём и предлагаемым Title. Только Create and edit создаёт файл; GET и Cancel не записывают данные.
- Новые документы начинаются с `# Title`. Первый H1 определяет название в редакторе, просмотре, дереве, списке каталога, поиске и выборе истории. Без H1 название генерируется из имени файла; при следующем сохранении H1 добавляется. Существующий YAML/TOML frontmatter сохраняется перед H1, чтобы не ломать метаданные старых документов. Открытие само не меняет файлы.
- После создания Title и путь независимы: Rename меняет H1, Move меняет путь. Breadcrumb и подсказки показывают настоящий путь; одинаковые Title допустимы. Индекс названий обновляется по Git SHA; неизменённые файлы повторно не разбираются.
- Проверки: `npm --prefix projectbook/editor test` и `docker exec -i projectbook-fork-wiki-1 ruby - < projectbook/test/titles_test.rb`.

Confirming an unchanged Title leaves the Markdown bytes untouched, including inline formatting. The editor shows `No unsaved changes` or `Unsaved changes`; Undo back to the original content clears the indicator. Save remains available, including for legacy pages that need their missing H1 added.

### Print

Open a saved document and use the printer icon in the shared header. It calls the browser's native print dialog; choose a printer or Save as PDF. In macOS Safari, PDF options are in the system print dialog. The action is available in document view, not in the editor or directory listing.

Print styles remove navigation, search, breadcrumbs, action buttons and wiki header/sidebar/footer blocks. The rendered document title, text, tables and images remain. Large images are bounded to the printable area; table headers repeat across pages. Browser-generated URL/date headers and footers are controlled by the print dialog, independently of the page.

### MCP: book access and durable agent memory

The local Streamable HTTP endpoint is `http://127.0.0.1:4569/mcp` (same container and port as the wiki). It uses the official Ruby SDK, pinned to `mcp 1.8.1`. No external model/API key or database is needed. This stage reads saved documents and can write agent notes; it does **not** expose document editing, uploads or Git push.

Connect a local Codex client:

```sh
codex mcp add projectbook --url http://127.0.0.1:4569/mcp
codex mcp list
```

Or merge this section into the client's configuration (do not replace the rest of the file):

```toml
[mcp_servers.projectbook]
url = "http://127.0.0.1:4569/mcp"
```

Reconnect/restart the client's MCP connection after configuration. These instructions follow [OpenAI's MCP connection example](https://developers.openai.com/learn/docs-mcp). We do not change your client settings automatically. An agent on another computer or a cloud executor cannot reach this Mac via its own `127.0.0.1`; remote HTTPS/auth deployment remains a separate step.

Tools:

| Tool | Purpose |
| --- | --- |
| `get_book_context` | Compact map, entry points, counts and recent agent notes. Also available as `projectbook://book/context`. |
| `list_tree` | Documents, folders and attachments, with depth/pagination and a pinned revision. |
| `read_document` | Saved Markdown, line range, headings, blob SHA, URL and scoped agent notes; optional historical revision. |
| `search_documents` | Case-insensitive literal terms over Markdown title/path/body, with excerpts and line numbers. |
| `get_history` | Book/file/directory commits; exact paths, no automatic rename following. |
| `get_diff` | Diff of one Markdown path at two reachable full commit SHAs. |
| `list_agent_notes` | Find notes by scope or text, including inherited parent context and descendant notes. |
| `read_agent_note` | Full note, version, sources and stale status. |
| `save_agent_note` | Create/update durable summary, finding or task log; one local Git commit, no push. |

Try asking: “Read the book map, find the engine documentation, compare its recent changes and summarise the relevant findings with links. Save the useful result as an agent note linked to the source versions.” Another session can ask: “Load saved findings for the engine section and check whether the sources have changed.” Search/work history is saved explicitly as a `task_log`, not by recording every query or the agent's private reasoning.

Agent notes are ordinary UTF-8 JSON files at `.projectbook/agent-memory/<uuid>.json` in the **book** repository. `content` is Markdown. The logical `scope` is a document path, directory, or empty string for book-wide context. Each record contains `kind`, `title`, `content`, `agent` (a supplied label, not an authenticated identity), timestamps, and `sources: [{path, sha}]`. Summary sources are mandatory; use blob SHAs from `read_document`/`list_tree`. Changed, moved or deleted sources mark notes `stale`; these notes remain retrievable but need verification. Scope/source paths are not automatically rewritten by Move yet.

The UUID is chosen by the caller and reused on retries. Create with `expected_version: ""`; update with the note's current `version`. Concurrent edits return a version conflict. Repeating identical content is a no-op. Memory files are excluded from the explorer/overview and Markdown document search; they are not secret or access-controlled separately from the book and remain visible in Git/history. Existing generic wiki file routes are not a confidentiality boundary. Git clone/push carries the notes along with the book.

Deployment settings (export in ignored `projectbook/settings.local.sh`):

- `PROJECTBOOK_MCP_ENABLED=false` disables the endpoint.
- `PROJECTBOOK_MCP_MEMORY_WRITE=false` exposes only read tools; `GOLLUM_READ_ONLY=true` also removes memory writes.
- `PROJECTBOOK_MCP_TOKEN` optionally requires `Authorization: Bearer ...`; leave credentials out of Git. For Codex, configure `bearer_token_env_var` with a token-bearing environment variable available to the client. Do not put a token into a URL.
- The default test deployment binds only to Mac loopback and has no token. The SDK validates Host/Origin; arbitrary browser origins are rejected. Do not change the bind address to publish this test configuration.

MCP runs in the same process and outer write lock as the Web UI. Memory writes therefore share the UI's serialization. This does not lock external Git commands/other processes; no concurrent external writers are supported yet. Read tools pin a Git revision and do not checkout old commits. Pass that revision to later pages of a result to keep a consistent snapshot. Only book-root deployments (`page_file_dir` empty) are supported in this first version.

Limits: request 128 KiB; tool response 256 KiB; 100 results per page; Markdown text up to 2 MiB; reads up to 500 lines/40,000 characters; diffs up to 40,000 characters; memory content up to 20,000 characters and complete record up to 100 KB. Truncation/pagination are explicit. Source text is cached by blob SHA with a 32 MiB process-local bound. A changed blob is read again; no generated cache is committed.

Not yet implemented: semantic/vector search, PDF text extraction/OCR, automatic summarisation, full task management, document writes through MCP, or Git synchronization. A later RAG layer can combine lexical search and embeddings (e.g. [Qdrant hybrid queries](https://qdrant.tech/documentation/search/hybrid-queries/)); the vector index remains rebuildable, while authored summaries and notes live in Git. Model choice and any external transfer of book content need to be configured separately.

Tests (temporary repositories; not the user's book):

```sh
docker exec -i projectbook-fork-wiki-1 ruby - < projectbook/test/mcp_test.rb
```
