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

`start.sh` проверяет книгу и ветку, собирает образ, запускает контейнер и ждёт успешного healthcheck. После запуска: **http://127.0.0.1:4000/Home**.

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
- `PROJECTBOOK_PORT`: порт на `127.0.0.1`, по умолчанию 4000.
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

### Optional experimental semantic search

A separate read-only deployment at port 4570 adds local Qdrant/FastEmbed search over Markdown and extracted PDF text. See [experiment setup, limits and rollback](rag/README.md). It is off in the normal deployment; the existing literal search and MCP editing remain unchanged.

### MCP: book access and durable agent memory

The local Streamable HTTP endpoint is `http://127.0.0.1:4000/mcp` (same container and port as the wiki). It uses the official Ruby SDK, pinned to `mcp 1.8.1`. No external model/API key or database is needed. It reads saved documents, writes agent notes, and creates/edits Markdown through the shared browser save service with optimistic version checks. It does **not** expose Move, uploads, deletion or Git push.

Connect a local Codex client:

```sh
codex mcp add projectbook --url http://127.0.0.1:4000/mcp
codex mcp list
```

Or merge this section into the client's configuration (do not replace the rest of the file):

```toml
[mcp_servers.projectbook]
url = "http://127.0.0.1:4000/mcp"
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
| `save_document` | Create/replace complete Markdown with expected blob SHA; preview by default, explicit local commit. |
| `edit_document` | Apply unique exact text replacements with expected blob SHA; preview by default. |
| `save_agent_note` | Create/update durable summary, finding or task log; one local Git commit, no push. |

Try asking: “Read the book map, find the engine documentation, compare its recent changes and summarise the relevant findings with links. Save the useful result as an agent note linked to the source versions.” Another session can ask: “Load saved findings for the engine section and check whether the sources have changed.” Search/work history is saved explicitly as a `task_log`, not by recording every query or the agent's private reasoning.

Agent notes are ordinary UTF-8 JSON files at `.projectbook/agent-memory/<uuid>.json` in the **book** repository. `content` is Markdown. The logical `scope` is a document path, directory, or empty string for book-wide context. Each record contains `kind`, `title`, `content`, `agent` (a supplied label, not an authenticated identity), timestamps, and `sources: [{path, sha}]`. Summary sources are mandatory; use blob SHAs from `read_document`/`list_tree`. Changed, moved or deleted sources mark notes `stale`; these notes remain retrievable but need verification. Scope/source paths are not automatically rewritten by Move yet.

The UUID is chosen by the caller and reused on retries. Create with `expected_version: ""`; update with the note's current `version`. Concurrent edits return a version conflict. Repeating identical content is a no-op. Memory files are excluded from the explorer/overview and Markdown document search; they are not secret or access-controlled separately from the book and remain visible in Git/history. Existing generic wiki file routes are not a confidentiality boundary. Git clone/push carries the notes along with the book.

### Version-checked document editing

1. Call `read_document` for the current path. Use its **`sha`**, not the repository `revision`, as `expected_version`. For a new file use an empty version and an explicit `.md` path.
2. Preview `edit_document` with `edits: [{old_text, new_text}]`, or `save_document` with complete `content`. `dry_run` defaults to true. Each replacement must match exactly once; replacements apply sequentially and a failed match cancels the whole operation. For partial/truncated reads prefer exact edits; never replace the whole document with an excerpt.
3. Review the returned `diff`, then repeat with `dry_run: false` and the **same expected version**. Preview does not reserve the document: saving validates it again.
4. Successful writes return the resulting blob `version`, Git `commit`, `revision` and URL. Preview's `version` is only the proposed blob hash, not a saved version. Content without an H1 gains the same title as in the browser. Saving unchanged content with a current version creates no commit.

Example after reading `hardware/engine.md`:

```json
{
  "path": "hardware/engine.md",
  "expected_version": "<sha from read_document>",
  "edits": [{"old_text": "- [ ] Check coolant", "new_text": "- [x] Check coolant"}],
  "dry_run": true,
  "message": "Record coolant check"
}
```

A newer save from the browser/agent returns an MCP tool error with status `412` (or `409` for a moved/deleted/occupied path or uncommitted disk changes), `current_version`, `current_revision`, and recovery guidance. Read again and reconcile the edits; simply substituting the new SHA would defeat the protection. Browser Save uses the same SHA check, so an older browser draft cannot overwrite an MCP save either. Unsaved browser drafts remain client-side; the server cannot read them. No automatic merge or force overwrite is offered.

After a network failure with an unknown outcome, read the current document to determine whether the save succeeded. Retrying with a stale version is rejected, even if the supplied text is identical. Changes to other documents do not invalidate this document's blob version. An existing path cannot be overwritten by passing an empty version. Read-only flags remove tools from discovery and reject direct calls too.

Deployment settings (export in ignored `projectbook/settings.local.sh`):

- `PROJECTBOOK_MCP_ENABLED=false` disables the endpoint.
- `PROJECTBOOK_MCP_MEMORY_WRITE=false` disables agent-note writes.
- `PROJECTBOOK_MCP_DOCUMENT_WRITE=false` disables document writes. Set both flags to false for read-only MCP, or use `GOLLUM_READ_ONLY=true` to disable writes in both MCP and Web UI.
- `PROJECTBOOK_MCP_TOKEN` optionally requires `Authorization: Bearer ...`; leave credentials out of Git. For Codex, configure `bearer_token_env_var` with a token-bearing environment variable available to the client. Do not put a token into a URL.
- The default test deployment binds only to Mac loopback and has no token. The SDK validates Host/Origin; arbitrary browser origins are rejected. Do not change the bind address to publish this test configuration.

MCP runs in the same process and outer write lock as the Web UI. Document and memory writes therefore share the UI's validation/write serialization. This does not lock external Git commands/other processes; no concurrent external writers are supported yet. Read tools pin a Git revision and do not checkout old commits. Pass that revision to later pages of a result to keep a consistent snapshot. Only book-root deployments (`page_file_dir` empty) are supported in this first version.

Limits: request 3 MiB; tool response 256 KiB; 100 results per page; Markdown text up to 2 MiB; reads up to 500 lines/40,000 characters; diffs up to 40,000 characters; memory content up to 20,000 characters and complete record up to 100 KB. Truncation/pagination are explicit. Source text is cached by blob SHA with a 32 MiB process-local bound. A changed blob is read again; no generated cache is committed.

Optional semantic/hybrid search is available through the per-deployment [RAG services](rag/README.md). The primary local deployment can enable it while retaining document and memory writes. PDF text and original attachment reads work without RAG. Not yet implemented: OCR, automatic summarisation, full task management, multi-document transactions, Move/attachment uploads through MCP, or Git synchronization. The vector index remains rebuildable, while authored summaries and notes live in Git. Any external transfer of book content needs separate configuration.

Tests (temporary repositories; not the user's book):

```sh
docker exec -i projectbook-fork-wiki-1 ruby - < projectbook/test/mcp_test.rb
```


### PDF text and original files through MCP

The same `/mcp` endpoint exposes:

- `read_pdf_text(path, start_page?, end_page?, page_offset?, max_chars?, revision?)`: omit the page range for the whole document, or specify an inclusive 1-based range. Returns ordered `{page, text, offset, page_characters, empty}` records, source SHA and revision. A response has at most 50 pages / 40,000 characters. When `complete=false`, call again with `start_page=next_page`, `page_offset=next_page_offset`, the returned `revision`, and the same `requested_end_page`. Continue until complete; the last response alone is not the whole document. Empty text is not evidence that the page has no meaningful image content.
- `read_attachment(path, format="resource", revision?)`: returns metadata and a standard MCP `resource_link`. Read its URI with `resources/read` to get the exact original file as a binary resource (base64 in the protocol). URI embeds the Git revision; it continues to read that version after later edits. It uses the same MCP authentication and visibility checks, not a public download URL.
- `read_attachment(path, format="bytes", offset=0, length=65536, revision?)`: fallback for clients without resource support and files over the resource limit. Decode each base64 part separately and concatenate bytes; follow `next_offset` with the same revision until null. Verify `sha` as Git's SHA-1 of `blob <byte_length>\0<bytes>`.

PDF extraction uses Poppler in the wiki image, independent of embeddings, Qdrant, model download and the semantic-search enable switch. It reads committed Git blobs; uncommitted checkout changes are excluded. Extraction limits: 100 MiB input, 3,000 pages, 50 pages per call, 1 GiB child address space, 25 CPU / 30 wall seconds per command, 16 MiB extracted-output file. Invalid/password-protected PDFs and exceeded limits produce explicit errors; use a smaller page range or retrieve the original. No OCR or guaranteed table reconstruction. PDF reads may temporarily queue writes behind the existing MCP/UI lock.

Original-file limits: 100 MiB attachment, 16 MiB per `resources/read`; byte-range responses up to 96 KiB of binary data. Paths must be visible regular attachments in the selected book history. Hidden files, symlinks, Markdown-as-attachment and paths outside the book are rejected. These are read APIs; uploads are a later step.

### Primary deployment with RAG

Copy `settings.example.sh` to ignored `settings.local.sh` and set:

```sh
export PROJECTBOOK_RAG_AVAILABLE=true
export PROJECTBOOK_RAG_ENABLED=true
export PROJECTBOOK_SETTINGS_ADMIN=true
```

`PROJECTBOOK_RAG_ENABLED` is an initial default; subsequent values are persisted by Settings. Run `./projectbook/start.sh`. Primary Web UI remains `http://127.0.0.1:4000/Home`, MCP remains `http://127.0.0.1:4000/mcp`, and write tools remain enabled. Each deployment has separate model/index/settings volumes. To keep RAG installed but disable search/indexing use Settings. To remove sidecars entirely, set `PROJECTBOOK_RAG_AVAILABLE=false` and rerun start; volumes and book remain intact. PDF reading remains available in either case.

Existing MCP clients must refresh tool discovery/reconnect to see `search_knowledge`, `get_search_index_status`, `read_pdf_text`, and `read_attachment`. No URL change is needed for a client already using port 4000. Agent guidance distinguishes semantic/hybrid retrieval from literal Markdown search and directs the agent to verify PDF search excerpts against source pages.


### Settings page

Use the header gear icon or open `http://127.0.0.1:4000/gollum/settings`. Settings now has its own page; Semantic Search is the first tab. The status card reports model/index state. Save is available only when values differ from the saved configuration; unsaved changes are indicated and guarded when leaving. Reload asks before discarding changed values. Settings remain per deployment, outside the book, with server-side version checks.

“Update automatically after saved changes” checks the local Git revision at the configured interval. It notices browser/MCP commits and externally pulled commits; it does not perform Git pull. Unchanged files reuse cached embeddings, while each changed snapshot currently builds a complete replacement Qdrant collection. “How index updates work” explains this distinction. Git pull integration and direct commit/pull event triggers remain planned.

### TODO tasks and embedded lists

Open `/gollum/tasks` using the checklist icon. A task belongs to exactly **one list**, whose name is its tag. Edit task text directly in its row, toggle the checkbox, or click its list/tag to choose another list or create one inline. New tasks start open in **Default** (an existing case-insensitive name is reused). The board supports list/status/text filters and renaming lists without changing their IDs. There are no task dialogs, due-date/notes fields, or technical metadata disclosures; explanatory notes belong in ordinary document content.

The editor toolbar has three icon-only actions with tooltips: **New TODO**, **Insert existing TODO**, and **Insert TODO list**, available in Visual and Markdown (hidden in Changes). **Insert existing TODO** opens a searchable popup: toggle one or several list chips at the top, then search task titles within those lists. Search ignores case and matches all entered words; Clear selects no lists and All lists restores them. Results show completion, list and source document; click a result or press Enter in search to insert its reference at the editor cursor. Results render in batches of 50 with Show more. Escape or the close icon cancels without changing the document. **Insert TODO list** has a searchable popup with an all/open/done filter and optional new-list creation. New TODO inserts an open task immediately and focuses its text; the list/tag is a small dropdown beside it. On an editing page these changes are drafts: **Save** commits the page, task/list files and attachments together after checking every changed file's version. Closing keeps the task metadata in the same browser draft. The normal unsaved indicator includes task changes. Text Undo/Redo handles references; task fields/checkboxes also have staged state, and Discard removes the whole draft. In a viewed document, only the completion checkbox is editable and saves immediately to Git; task text and list pills are static. Text/list changes in a document require Edit and are staged until Save. The dedicated board retains its editing controls. The optional `status=open` or `status=done` filter affects the embedded list only.

Markdown uses normal links, with relative paths from the document:

```markdown
[TODO: Check oil](../.projectbook/tasks/22222222-2222-4222-8222-222222222222.md)
[TODO list: Spring](../.projectbook/task-lists/11111111-1111-4111-8111-111111111111.md?status=open)
```

The task/list file is authoritative. Link text is a portable fallback; visual inline title editing updates that label and stages the task file together. Manually changing only the Markdown label does not rename the canonical task. Copy a reference to mention the same task elsewhere; **New TODO** creates a new ID. Removing a reference does not delete an existing task. A new task whose insertion is undone is not saved as an orphan. Unresolved references and malformed metadata are reported instead of silently creating files on read. Historical documents use the historical task/list snapshot, read-only.

Task files begin with the title, followed by a fenced `projectbook-todo` JSON object and optional free Markdown notes:

````markdown
# Check oil

```projectbook-todo
{
  "kind": "task",
  "id": "22222222-2222-4222-8222-222222222222",
  "list_id": "11111111-1111-4111-8111-111111111111",
  "status": "open",
  "due": "",
  "schema": 1
}
```

Check the manual before starting.
````

Lists use `.projectbook/task-lists/<uuid>.md`, `kind: "list"`, `id`, and `schema: 1`, plus an H1 name and notes. List names are unique ignoring case; IDs and paths remain fixed. Use inline controls or preserve this schema when editing files directly. Existing due/notes values are preserved for compatibility, although their input fields are no longer shown. No database or HTML comments are required. Ordinary Markdown checklist items remain independent. A checklist item containing only a structured TODO link uses one visible checkbox synchronized with that task, avoiding duplicate checkboxes.

MCP exposes `list_todo_lists`, `list_tasks`, `read_todo`, and `save_todos`. Reads accept pinned revisions; lists paginate. `save_todos` accepts up to 100 complete task/list objects with `expected_version` (empty for new), defaults to `dry_run: true`, and applies with `dry_run: false` in a single commit. It shares document-write permissions and the Web UI write lock. A stale task rejects the whole transaction. Creating a document plus tasks atomically is currently a Web editor operation; MCP task batches and document writes are separate operations. No deletion/archive is implemented yet. The TODO catalog derives source references from Markdown links at the requested Git revision.

Tests: `npm --prefix projectbook/editor test`; Ruby TODO/API/version tests are in `projectbook/test/tasks_test.rb` and run in the normal Docker test environment. The test book includes `playground/todo-demo.md` with Spring/Autumn examples; none of that book is packaged in the application repository.

#### Jump from a list to task context

In an embedded TODO list, the task title is a navigation link; the checkbox still changes completion. One source opens the containing document at `#todo-<UUID>` and scrolls the task into view without highlighting it. Several source documents open a small chooser with their paths. Click outside or press Escape to close it. Direct task occurrences are editable inline only in the page editor; normal viewing exposes only the completion checkbox. Unsaved new tasks must be saved before navigating; normal editor draft protection still applies.

New tasks created with a document record `source_path`. The catalog also discovers all actual TODO links (excluding code examples and external links), so existing tasks and moved documents work. Embedded list links are not definitions. With no remaining document reference, navigation falls back to the permanent task file. Historical links use the same historical snapshot. Source discovery does not modify book files.

### Delete a document

The trash icon beside Rename/Move is available only in the editor of a saved document. It opens a confirmation showing the exact path and warns when this editor has unsaved changes. Confirming removes the document in a local Git commit, clears this editor's browser draft, and returns to its parent folder. Saved history, attachments and separate TODO files remain. The version and working-copy checks reject stale or uncommitted external changes. Normal page viewing has neither the Delete link nor the “When was this page last modified?” footer; use History for revisions.

TODO insertion uses its own spacing behavior: Markdown mode inserts only the reference at the cursor, with no added whitespace. Visual mode inserts the reference plus one hard line break (serialized as a trailing backslash and newline), without the attachment helper's surrounding empty paragraphs. The rule applies to new/existing tasks and embedded lists. User-authored whitespace elsewhere is not normalized.

Embedded TODO lists show the list name once in the heading; their task rows omit the redundant list/tag and its selector, in both viewing and visual editing. Individual task occurrences and the general TODO board retain their list selector.

Task text in the visual editor uses an independent plain-text Lexical root so Select All, typing and keyboard Undo stay inside that task. The list selector is a native menu over a compact pill without visible arrows. Text and pill share inline flow, so the pill follows the last line of a long task instead of occupying a separate right-hand column.

The Visual / Changes / Markdown selector lives in the page action bar beside Save/Close. In Visual mode, TODO icons sit immediately after Bulleted list / Numbered list / Checklist and before link/media tools; the list tools stay grouped when the toolbar wraps. Markdown keeps its TODO insertion tools.


### Hidden TODO storage migration

Tasks live in `.projectbook/tasks/<uuid>.md`; lists in `.projectbook/task-lists/<uuid>.md`. They remain Git-tracked but are omitted from the document tree, file overview, ordinary document search and newly built RAG indexes. Use TODO UI/MCP to access them. This is UI organization, not a confidentiality boundary.

For an existing book, run `PROJECTBOOK_MIGRATE_TODOS=true ./projectbook/start.sh`. The opt-in migration runs before the server accepts requests, requires a clean checkout on the configured branch, validates metadata and destinations, and commits file moves plus Markdown link updates together. Repeating it is a no-op. Later launches may omit the flag. Keep one writer for the book during this maintenance step. Legacy links and historical revisions remain readable; old browser drafts with changed document versions must be reconciled through the existing conflict checks. Code examples and external links are left intact. Nonstandard HTML/wiki references are not rewritten; structured legacy TODO links are still recognized. Existing RAG generations refresh through the configured index update mechanism.

To undo the migration, revert its book commit with the server stopped, then restore the corresponding application version. Do not reset or rewrite shared history.
# Tree editing

Drag an item to the upper/lower edge of a sibling row to reorder it. Drag a
document, attachment or whole folder to the middle of a folder row to move it;
drop on **Explorer** to move it to the book root. Clear search before dragging.
Tree mutations are disabled while the document editor is open.
The strip above the first root row becomes visible during dragging: drop a root
item there to place it first. Folder row edges reorder, while the middle third
moves into the folder; feedback names the destination before dropping.

**Settings → Navigation → Confirm moving documents between folders** controls
the move confirmation (enabled by default). This deployment setting works without
RAG and persists in the `app-settings` Docker volume, outside the book. Changing
it requires `PROJECTBOOK_SETTINGS_ADMIN=true`. Stop/start and image updates keep
the volume; removing that volume resets navigation settings.

Manual order is a JSON array of immediate child names in `<folder>/.order`,
created only after a real reorder. It is tracked in Git, hidden from navigation,
and cannot be created using the new-document/folder UI. Order affects only the
explorer, not the folder overview. Without `.order`, folders come first, then
files, sorted by name. Unknown externally added children appear after ordered
ones; UI/MCP creation appends children to an existing order in the same commit.

Tree writes use the shared write lock and require the displayed Git revision and
a clean book working tree. Each operation creates one local commit (no push).
Tree and editor moves use the same server-side plan. The preview lists moved files,
incoming-link changes and order/metadata updates, with expandable Markdown diffs.
The book revision must still match at Save; otherwise refresh the preview. When
tree move confirmation is disabled, the same validation runs without a dialog.
Moves update local Markdown links/images/reference definitions, HTML href/src,
and standard Gollum `[[label|path]]` links, preserving query strings and anchors.
Code, comments, frontmatter and external URLs stay untouched. Extensionless page
links resolve against tracked paths. Reverse/global wiki-link modes and custom
macro syntax are not handled. The Markdown corpus is limited to 64 MiB per scan;
each document retains the existing 2 MiB limit. Failures abort the move.
The parser is bundled from the pinned editor dependencies and runs in Node inside
the image. For a non-Docker runtime build the editor and set
`PROJECTBOOK_LINK_REWRITER` to the absolute `dist/book-links.cjs` path.
Internal `.order` files travel with a folder byte-for-byte. Parent orders remove
the old entry and append to the destination when it has a manual order. Renaming
within the same folder preserves the item's position. Deleting a document removes
its order entry in the deletion commit. No move resets manual ordering.
TODO source paths are updated; task IDs stay unchanged. Agent-memory source SHAs
remain historical evidence and can become stale after a move.
Moving attachments preserves their bytes. Empty source folders are retained with
`.gitkeep`. Canceling a confirmation and dropping in the same position write nothing.
# Callouts and footnotes

In Visual mode, place the cursor in a paragraph or select several blocks, then
choose Note, Tip, Important, Warning or Caution in **Block type**. Note is grey;
Tip green; Important blue; Warning amber; Caution red. Changing the type preserves
the contents. Choosing Paragraph removes the callout wrapper. Enter in its last
empty paragraph exits to an ordinary paragraph. Code blocks keep their existing
separate toolbar button.

Storage uses GitHub-style alerts, for example `> [!WARNING]` followed by quoted
Markdown. Bold text, lists and links remain Markdown; each list item stays a
separate item. Unsupported Markdown viewers fall back to ordinary quotes.
The server renders the same callouts for reading and printing.

**Insert footnote** opens a text dialog and inserts a `[^id]` reference plus a
definition. Definitions are editable at the end of the document in Visual mode;
the normal reader numbers the references and provides links back to the text.
Definition blocks remain after a reference is removed, so deleting a reference
does not silently discard the note. Markdown mode exposes the standard syntax.

### Raw Notes (first version)

Use the **＋** toolbar action or `/gollum/raw-notes/new`. Capture optional title,
text, photos and voice; save into `raw-notes/YYYY-MM-DD-UUID/note.md` with media
and hidden `.note.json`. One local Git commit contains the complete note.
Unsorted/Processed is metadata, not a directory move. The ordinary editor can
edit the saved Markdown. Inbox: `/gollum/raw-notes`.

A raw note is a one-way conversation. Send creates the first note; subsequent
messages append to the same Markdown file in chronological order. Reopening the
note shows its saved content and the composer underneath. Each message is one
commit, with version checks and a stable request UUID for retries. New content
returns a processed note to Unsorted. Drafts are stored separately for each note.
Attachments retain selection order, with add controls below the media.
Separate Take photo, Photo library, Record voice and Audio file controls avoid a
mixed image/audio picker. iOS still owns its native picker choices. The inbox is
a newest-first feed with text excerpts, up to four image previews and audio players.

Photos default to JPEG, maximum long edge 2048 px, quality .85; choose original
quality before attaching for diagrams/labels. Unsupported image decoding keeps
the original with a notice. Original HEIC rendering depends on the browser.
Audio uses MediaRecorder MIME negotiation. Microphone requires HTTPS or localhost;
recording must finish while the page is open. IndexedDB keeps the text and finished
media on the device. Recording in progress is not guaranteed to survive closing
Safari. Video, transcription, and background/offline send queues are deferred.

Limits: 20 attachments, 20 MiB per file, 50 MiB per note, 100000 text characters.
Uploads use retryable 256 KiB chunks; staging is outside Git in the app-settings
volume, expires after 24h (lazy cleanup), capped at 250 MiB per book. SHA256 checks
all files. Reusing the same note UUID and payload returns the existing note.
Metadata edits use expected_version, document edits use the document blob SHA.

MCP: `upload_raw_note_attachment`, `create_raw_note`, `list_raw_notes`,
`read_raw_note`, `append_raw_note`, `set_raw_note_status`. `create_raw_note.files` and `append_raw_note.files` advertise
`openai/fileParams` for ChatGPT file objects; public HTTPS downloads are bounded
and private addresses/redirects rejected. Other clients can upload byte chunks.
No implicit access to chat attachments: the client must supply file objects or
bytes. No real ChatGPT file-picker integration or real iPhone test is claimed by
local protocol tests. The user confirmed the initial mobile capture works on iPhone.
See [the transcription proposal](TRANSCRIPTION.md) for the next optional service.

### Container-only cloud deployment and automatic book push

`deploy/build-image.sh linux/amd64` builds a tagged, reviewed committed checkout;
use `linux/arm64` for Mac ARM. The upstream pinned base supports both platforms.
`deploy/send-image.sh SSH_HOST IMAGE` streams the **image**, not source files,
into remote Docker. No registry login is required. Optionally tag/push that image
to your own registry. Images exclude the book, settings and credentials.

`deploy/install-cloud.sh SSH_HOST IMAGE BOOK_SSH_URL` installs Compose/proxy and
an independent book clone under `/opt/projectbook`. It requires Git SSH access
already configured on the host. Proxy listens only on `127.0.0.1:8092`; point a
Cloudflare Tunnel hostname there and protect Web UI with Cloudflare Access.
Configure `PROJECTBOOK_PUBLIC_URL=https://YOUR_HOST` in the remote `.env` and
recreate wiki after assigning the hostname. MCP additionally requires the generated
`PROJECTBOOK_MCP_TOKEN` (remote `.env`, mode0600). A ChatGPT client also needs a
compatible Access policy; this deployment does not implement OAuth.

`deploy/install-mac-push.sh` installs a user LaunchAgent that checks book HEAD
every two seconds and pushes committed changes, retrying failures. On cloud the
installer enables `projectbook-book-push.service`. No worktree modifications,
pull, merge or force push occur. Status: local `.runtime/book-push.json`, remote
`/opt/projectbook/book-push.json`. Divergent writers stop pushing until reconciled;
full automatic pull/conflict handling remains in the plan. Never assume both
copies are current without checking their Git revisions.

Stop: `docker compose stop` in `/opt/projectbook`; stop push with
`systemctl stop projectbook-book-push`. Roll back by setting an earlier image tag
in `.env` and running `docker compose up -d`; book and settings persist. Remove
containers with `docker compose down` (without `-v`). On Mac disable auto-push:
`launchctl bootout gui/$(id -u)/net.projectbook.book-push` and remove its LaunchAgent
plist. Deleting containers does not delete the book.

### Folder pages

A folder can have editable Markdown content in `.index.md`. Its H1 supplies the tree label; the file is not shown as a separate node. New folders start with a dynamic `[Pages](#projectbook-pages)` block that can be removed without deleting children. Moving the overview moves its whole folder. Deleting it requires an unavoidable confirmation for the entire subtree. See [folder-page behavior](FOLDER_PAGES.md) and [verification](VERIFICATION.md).

ChatGPT authentication is a separate integration step: the existing `/mcp`
endpoint uses a static Bearer token behind Cloudflare Access. An Access browser
login does not authenticate ChatGPT server-to-server requests. Authenticated
ChatGPT plugins require a compatible OAuth flow; do not remove Access or expose
write tools anonymously to work around this. See https://developers.openai.com/plugins/build/auth.

### Shared attachments

Images and files uploaded in the editor are stored in Git under the hidden root
folder `.asset/<UUID>/<filename>`. Uploads stay in the browser draft until Save;
the page and its new attachments are committed together.

Markdown links use paths relative to the repository root:

```markdown
![Oil filter](/.asset/12345678-1234-1234-1234-123456789012/filter.jpg)
[Inspection report](/.asset/12345678-1234-1234-1234-123456789012/report.pdf)
```

These links work in ProjectBook and GitHub's rendered repository Markdown,
including README files. Some standalone Markdown viewers need their root folder
configured. The `.asset` directory is hidden from the book's navigation and search,
but its files remain accessible through page links and MCP.

Copying text or a page reuses the same attachment links without duplicating files.
Moving or renaming a page does not move shared attachments. A new upload gets a
new UUID, so replacing an image does not overwrite images used by other pages.
Deleting a page leaves shared attachments intact. Existing `assets/`, `uploads/`
and Raw Notes media are unchanged; migration and unused-file cleanup are separate
operations. See [Shared Git assets](SHARED-ASSETS.md) for implementation details.

### Raw Notes chat controls

Saved messages appear as chronological chat bubbles. The bottom composer has a
`+` menu for Camera, Photos and Files (photos, audio, PDF, TXT and DOCX; no video).
Record shows a red recording indicator, elapsed time and live microphone level;
Stop adds the clip to the draft for listening before Send. A recording requires
HTTPS or localhost and microphone permission. Send is disabled during recording
and while permission is pending. The original audio remains in Git; this does
not perform transcription.
