# Проверка Docker-стенда

Дата: 24 октября 2026. Среда: macOS / Apple Silicon, Docker Desktop. Проверки ниже проводились до коммита. 24 октября пользователь подтвердил результат и разрешил зафиксировать стенд и навигацию; push не запрошен.

- Собран образ `projectwiki:local` из текущего checkout. SHA256 установленного `lib/gollum/app.rb` совпадает с локальным исходником.
- Ruby runtime загружается; все 18 прямых gem-зависимостей удовлетворены. Проверяется наличие production Sprockets manifest и перечисленных в нём файлов.
- Frontend собран через `npm ci` с зафиксированными версиями. Компилятор native gems, `.git` приложения, локальные настройки и книга в runtime-образ не попали.
- HTTP 200: Home, Contents, редактор Home, JS/CSS MDXEditor, пример JPEG и PDF. В браузере проверены просмотр документа и загрузка визуального редактора с таблицей и изображением. Save не нажимался.
- Контейнер проходит healthcheck по рендерингу `/gollum/overview`.
- Выполнены stop → start и cleanup → start. Контейнер и сеть удаляются и создаются повторно, книга сохраняется.
- До/после проверок совпали HEAD, Git-конфигурация, статус и SHA256 всех 203 файлов как независимой книги стенда, так и исходной тестовой книги. Новых commits книги нет.
- Повторная подготовка книги отказалась перезаписывать существующий каталог. Некорректный порт и отсутствующая книга дают понятную ошибку до запуска Docker.
- Экземпляры на 4567 и 4568 продолжили работу, их Home отвечает HTTP 200.
- В приложении HEAD остался исходным `d00fefc8`; staging пуст, commit/push не выполнялись.

Стенд: http://127.0.0.1:4569/Home. Книга — отдельный sibling clone `testwiki-projectwiki`, исходная книга — `testwiki`. Автосинхронизации между ними нет. Команды — в [README](README.md).

Эта проверка подтверждает упаковку, запуск и сохранность данных при работе со стендом. Новые навигация/темы, прямая интеграция редактора, drag and drop документов, сохранение с новыми функциями, TODO и MCP будут проверяться на следующих этапах.


## Navigation update — 24 October 2026

- Baseline HTTP response times: Home 1.58 s, nested document 1.53 s, log document 1.54 s. `wiki.tree_list` alone took 1.48–1.63 s, while metadata enumeration took about 1.4 ms. No remote fetch/pull is involved.
- Replaced blob enumeration with a bounded, immutable navigation index keyed by local repository/ref/page directory and refreshed on commit-ID changes. Sidebar HTML is cached per index/base URL. The overview route also uses the metadata index.
- After deployment, three requests per route: median Home 49.2 ms, nested document 31.8 ms, log document 24.5 ms, directory listings 17.3–17.9 ms. These are local HTTP response times, not timings for downloading/rendering every image in a browser.
- Four regression tests / 26 assertions passed: reuse, change/rewind invalidation, immutability, HTML caching per base path, page directory prefixes, protected files, path encoding and collapsed accessible folder controls. No test creates commits.
- Browser checks passed: initially collapsed folders; chevron expansion without navigation; clicking `log` opens its right-hand page list; clicking a document opens it and preserves expansion; attachment search and restoration after clearing search. English labels verified; document contents remain unchanged.
- Search, expand and collapse operate in the browser. A changed local Git commit is reflected on the next navigation/reload, not pushed live into already-open pages.
- App and books remain uncommitted/unchanged respectively; no push was performed. Screenshot retained outside the public repository.


## Navigation interaction and attachment preview refinement

- Tree rows reduced from approximately 32 px to 24 px. Folder titles now replace the previous branch-based overview heading.
- First click on a folder name expands it and opens its contents. Repeating the selected folder click toggles children only. Server logs confirmed one GET before and after two repeated folder clicks; selecting the already-open image also produced no extra GET.
- Sidebar expansion and filter are restored before the main content renders, avoiding the initial collapsed-tree flash. A search result preserves its ancestor path when opened. Distinct pages still use normal browser navigation; this is not an SPA router.
- Browser verified the DokuWiki PNG in the right pane with navigation retained, then Back to folder and reopening the image with its search context retained. Image/PDF preview routes respond with HTML and sidebar; the original PNG URL still returns image/png.
- Focused suite: 5 tests / 30 assertions, all passed. JS syntax check and git diff whitespace checks passed. No document saves, application commits or pushes were performed.

## Shared page scroll (2026-10-24)
- Replaced the fixed, independently scrolling sidebar with a two-column grid in document flow. The taller column determines page height; narrow screens stack both sections without a sidebar height limit.
- Reserved a stable root scrollbar gutter (with an always-scroll fallback for older browsers). Removed obsolete sidebar scroll persistence.
- Rebuilt and deployed the healthy local Docker instance on port 4569. Browser checked collapsed/expanded boat, Expand all, scrolling over the long tree, and Collapse all: only the page scrolls and the column boundary remains stable. PNG preview remains in the right column. No document writes, commits or pushes.


## Shared header and creation (2026-10-24, pending review)

- Deployed the common Home/search/Recent changes/Files header, breadcrumbs and contextual actions. Replaced ambiguous New with New document / New folder above the explorer. No theme or metadata implementation in this step.
- Browser created `playground/UI demo` and `Welcome.md` using the UI. Empty-folder marker remains hidden. Cancelling the new document returned to its folder with only the marker present and no document commit. Saving created the document and its tree entry; content renders correctly. Repeating the name reports a conflict in the dialog. Search finds the saved page; attachment previews retain the common header and their Open original/Download actions.
- Creation integration tests use disposable `/tmp` repositories: folder commit, Unicode/space paths, document preflight without writes, duplicate names, missing parent, traversal/reserved names, missing request header, read-only mode, untracked files and symlinks. Save-time duplicate creation returns 409 without changing HEAD/content. Four tests / 32 assertions passed. Navigation regression suite: five tests / 30 assertions passed.
- UI smoke-test commits exist only in the disposable independent book on 4569. Original testwiki and ports 4567/4568 were not modified. Application HEAD remains `aa30d625`; no application commit or push.

## Header layout refinement (2026-10-24)

- Moved New document / New folder, document History/Edit and attachment Open original into the shared header, using built-in Octicons plus English labels/tooltips. Breadcrumbs are in its second row; removed duplicate body/sidebar action bars and common Upload/Download.
- Rename appears only while editing. Added the standard rename form on edit screens and a capture guard for unsaved body/header/footer/sidebar content. Internal unnamed MDXEditor textareas are excluded.
- Browser verified Home layout, header creation dialog/cancel, History navigation, attachment actions, Rename blocked with changed text, available after Undo, and successful no-op rename form submission. No test document content was saved in this round. Docker is healthy; JavaScript syntax and whitespace checks passed. App changes remain uncommitted and unpushed.

## Compact icons and unified History (2026-10-24)

- Header actions are icon-only with title/aria-label; New folder uses a folder-plus icon. Search and all header actions share one row. Breadcrumbs use an 18 px line and 4 px top margin, without header/sidebar horizontal separators.
- A single History action routes Home to whole-book changes and other documents to their own history. Both views have the title History and a History of selector populated from the cached navigation index.
- Browser verified Home -> whole-book History -> selecting boat/log/start.md -> viewing that document -> its History -> Entire book. Selected scope, breadcrumbs and title match each route. Docker is healthy; Ruby syntax and whitespace checks pass. No book writes, application commits or pushes in this round.

## Direct editor, attachments and image widths (2026-10-24, pending review)

- MDXEditor now has its own template and save endpoint. Markdown edit screens do not load the Ace bundle or initialize the stock editor. Non-Markdown and explicit Ace deployments retain the original editor.
- Six save API integration tests / 31 assertions passed against disposable repositories: document + binary in one commit, exact binary bytes, stale retry, invalid paths, read-only/uploads-disabled/missing-header rejection, local file preservation, create collision, unchanged-source no-op and size limit without partial writes. Existing creation suite also passed (4 tests / 32 assertions).
- Browser checked Markdown paste with headings, bold, checklist and table; Visual/Markdown switching; image + real PDF insertion via file chooser; close/reopen/restore of text and both File blobs from IndexedDB; Save and successful rendered result. Test book commit `a19fcd9` contains the document, PNG and PDF together.
- Tested FileList drop events in Visual and Markdown using a temporary same-origin fixture page. TXT/PDF links inserted at the drop position, repeated names had independent UUID paths. A native drag of script-created files in the harness only supplied text; OS/Finder-to-browser file dragging remains a manual cross-browser check. No Drop check document or its four temporary attachments reached Git. The fixture was outside the source repo and disappeared on final container replacement.
- Changed image width with 50% button, edited the HTML width to 23% in Markdown, returned to Visual, saved and reopened. DOM measurements: editor 116.27 / 505.52 px; viewer 120.56 / 524.19 px, both 23%. Width and relative source URL survived. Book commit `447e51d` records this test change. A subsequent Save without changes left HEAD unchanged.
- Temporary iframe test hit an embedded-browser automation failure around native confirm. Replaced Discard confirmation with inline React controls; final inline discard still needs user/browser verification. Close-and-keep-draft was verified.
- Final build is healthy at port 4569. Attachment links in rendered documents now target the wiki viewer, retaining navigation. Application changes remain uncommitted and unpushed; original prototype ports and original book remain untouched.
- Print is recorded as a separate backlog item, not implemented in this step.

## Editor usability fixes (2026-10-24, approved for commit)

- New documents show their filename, an editable Document filename field and the resulting path, separate from Document content. Browser drafts preserve the changed name as well as text and files. Existing documents retain the header Rename action.
- Image controls appear on selection and disappear on outside click, Apply or Escape. Arrow keys and Enter move to a paragraph before/after the selected image, creating one when needed. Attachments and image-dialog insertions keep adjacent text in separate paragraphs.
- Browser exercised a new empty document: changed its filename, attached PNG, used Up/Down to type before/after it, set 23%, dismissed controls with Apply/outside click, checked Markdown, closed/restored the draft, then saved under the changed name. Test book commit `317264d` contains exactly the new document and PNG. Viewer HTML has three separate paragraphs; image width 210.68/916 px = 23%. Reopen + unchanged Save did not change book HEAD.
- A second browser scenario inserted an image via Insert image into the middle of BeforeAfter. Visual and Markdown show Before, image and After as separate paragraphs. Undo restores BeforeAfter; Redo restores the image and paragraphs. Inline Discard confirmation returned to the folder and did not save that document.
- Save API tests: 6 tests / 31 assertions; creation tests: 4 tests / 32 assertions; all passed in the Docker container. Original user test page and prototype instances were left untouched.
- This closes the editor review fixes. Print remains the next small standalone task, followed by TODO; neither is implemented here. Application commit explicitly authorized by the user; no push.

## Full-path Rename / Move (2026-10-24, pending review)

- Added title-adjacent icon and full-path confirmation to MDXEditor; the shared Rename button opens it too. New pages can choose a different destination before Save; existing pages save edits, attachments and move in one commit. New folders are created on demand.
- Save integration: 9 tests / 64 assertions passed, including move + edits + binary in one commit, old path removal, stale-source refusal, duplicate paths, traversal, symlinks, file-as-parent, case collisions and local work preservation. Existing creation tests: 4 / 32 passed. Three Node tests cover Markdown rebasing, references, nested linked images, fragments, spaces, unchanged source and code/frontmatter preservation. Docker build with npm ci passed.
- Browser created a test document under a new destination, rejected a move onto Home.md without losing edits, then moved the document to a deeper directory with pending text changes. HTML image width 23% and Markdown links remained valid. Fixed void-element serialization, then verified move back/up and down again, reopening in Visual, HTML anchor text/destination preservation and Cancel without writing.
- Test data is confined to playground/Move check in the disposable book. Both toolbar Rename and title Rename / Move were exercised. No application commit or push for this step. Incoming links/redirects and nonstandard URL locations remain explicitly outside this change.

## Separate title editing and Move (2026-10-24, pending review)

- Clicking the editor title or its pencil icon opens an inline field. Rename now updates the leading Markdown H1, preserving the filename and URL; Move remains a separate full-path dialog. Save also applies an open title field. Enter applies locally; Escape cancels.
- Eight Node tests passed: five title tests (leading/setext H1, frontmatter, body preservation, literal Markdown characters and invalid input), plus three existing link-rebasing tests. Frontend and Docker builds passed.
- Browser verified click-to-edit, Enter, Escape cancellation, separate Move path and Cancel, title-only Save and Save with the title field still open. Reopening showed the saved heading; the file path and image stayed unchanged. Test saves only affected the disposable playground/Move check document. No application commit or push.

## Title/path creation and navigation (2026-10-24, pending review)

- New document now asks for Title and offers an editable full path. Lowercase hyphen/underscore input becomes a readable title; title-to-path suggestions use lowercase ASCII, hyphens, Russian transliteration and Latin accent folding. Editing the full path generates a title and updates the selected folder. Explicit existing paths are not migrated.
- Create and edit saves an initial Markdown H1 and opens the existing editor. Missing document URLs show a confirmation instead of entering the editor immediately; GET and Cancel do not create files. Missing parent folders are created with the document. Rename and Move remain independent after creation.
- Page headings, the tree, directory lists, search result names and history scope labels use the document H1, with a humanized basename fallback. A missing H1 is added on Save. Legacy frontmatter remains before the H1. Actual paths stay in breadcrumbs/tooltips. Duplicate titles do not hide separate documents.
- Checks passed: 9 Node tests; title/creation integration 5 tests / 32 assertions; save integration 9 / 64; previous creation 4 / 32; navigation cache 6 / 34. The navigation tests verify unchanged Markdown is not reread on an unrelated commit and media is not loaded for titles. Warm localhost Home response measured about 60 ms (server response only).
- Browser verified filename-like Title, manual nested path -> Title, create -> editor, missing URL -> confirmation -> creation, Rename -> unchanged URL with refreshed tree/directory labels, and Russian title -> Latin filename while retaining the selected directory. Test data is under playground/title-rules in the disposable book. Docker is healthy. Application remains uncommitted and unpushed.

## Unchanged-title confirmation (2026-10-24, approved for commit)

- Confirming the displayed title is a no-op, including formatting/setext headings, surrounding field whitespace and filename-derived fallback titles. It does not call editor replacement, create a draft, or show Title updated. Real title changes still use normal saving.
- Added No unsaved changes / Unsaved changes status. Returning to the original content clears the state; an outdated Title updated message is hidden when there are no changes.
- Ten Node tests passed. Browser verified unchanged Apply, Save without changing the document's latest Git commit, body edit -> Unsaved changes -> Undo -> No unsaved changes. Existing Ruby integration/cache checks from the preceding rounds remain applicable. Local Docker deployment is healthy.
- User explicitly approved committing the completed Title/path/Move work after this fix. No push requested.

## Unified search field (2026-10-24, pending review)

- Removed the sidebar Find in tree field. Search documents in the header now filters the tree locally by title/path while typing; Enter/the search button submits the existing full-text search.
- Query persists across navigation; a query in a search URL takes precedence over stored state. Escape/native clearing restores the tree. Expand all/Collapse all preserve the active query.
- Browser verified a single search field, live Cyrillic-title filtering without navigation, Enter -> full-text results, filename/path filtering, filtered expand/collapse, query retained on opening a document, no-results state and Escape restoring the tree. Docker build/health and whitespace checks passed. No book writes, application commit or push in this step.

## Print (2026-10-24, pending review)

- Unified search was approved and committed as `8d3ed30d`; no push. Print changes remain uncommitted.
- Added a document-only printer icon invoking `window.print()`. Print CSS removes the shared header/explorer, breadcrumbs, action forms, wiki header/sidebar/footer and modification footer, preserving rendered document content.
- Docker rebuild and health check passed. Exported Home through Chromium's print-to-PDF and visually inspected all three pages: Cyrillic text, links, a large portrait photograph and table render without application panels. Initial photo splitting was fixed with a print-only height bound and preserved aspect ratio; the final photo fits on one page. Verification artifacts are outside this public repository.
- The native Print click hit a browser-automation timeout; PDF rendering was independently verified using the browser's printing API. Physical printer output and the macOS system dialog were not verified. Browser URL/date headers are a user-controlled dialog option.
- No book data was changed in this step.

## MCP and agent memory (2026-10-24, pending review)

- Print and the agreed roadmap committed as `fca1be00`, no push. All subsequent MCP changes remain uncommitted.
- Official `mcp 1.8.1` Streamable HTTP transport is mounted at `/mcp` inside the existing UI write lock. Direct dependencies and extra Docker gems are version-pinned. Tools: map, tree, Markdown reading/search, Git history/diff, and agent-note list/read/save; book context is also an MCP resource. No document-writing or push tool is exposed.
- MCP integration tests on disposable repositories passed: 4 tests / 83 assertions (initialization, discovery, resource reading, origin/host/token rejection, snapshots/pagination, Cyrillic search/line excerpts, history/diff, no checkout, memory creation/update/replay/conflict, source staleness, scope inheritance, hidden tree entries, symlink/local-file protection and read-only discovery). Existing editor-save tests: 9 / 64; navigation tests: 6 / 34, all passed.
- Official Ruby MCP HTTP client negotiated protocol `2026-07-28` against the actual container. It read a map of 100 Markdown documents / 115 attachments, a paginated boat tree, 16 `mast` matches, Home content/history and a history diff. Separate HTTP tools/list from the Mac's published port returned 200. Legacy initialization (`2025-03-26`) is covered by the integration suite.
- Live memory check created one disposable task-log record, reconnected with a new client, read it back, and repeated the identical save without an additional commit. Test-book commit: `75ed00864b75c8a4c1a41985bdf65b91f899cdfc`; note ID: `fb5eb37b-763a-461c-8491-08e650f398b6`. No normal book document was modified. The original Trinity/prototype books were not touched.
- Client-only HTTP dependencies were installed under `/tmp/projectbook-client-gems` in the running container for verification; they are not app dependencies and disappear when the container is recreated. The app does not require an LLM service. No client configuration was modified, and the user still needs to connect their chosen agent.
- Limits remain explicit: Markdown literal search only (no RAG/OCR yet), no historical full-text search, no automatic rename following/rebinding of note scopes, a single app writer process, no synchronization with external Git writers. Memory's agent label is supplied metadata rather than verified identity.

## Real Codex conversation and memory recovery (2026-10-24)

- At the user's request, added the global Codex MCP server `projectbook` via `codex mcp add projectbook --url http://127.0.0.1:4569/mcp`; `codex mcp get` confirms it is enabled with Streamable HTTP. No existing server entries were replaced.
- Through MCP, searched and read six relevant book documents, then saved a source-linked engine summary in agent memory. Read-back confirmed identical content and `stale: false`. Only the disposable book's memory received a commit; document content was unchanged.
- Created a separate fresh Codex conversation without providing the note ID or summary contents. It successfully used native `mcp__projectbook__get_book_context`, `mcp__projectbook__list_agent_notes` and `mcp__projectbook__read_agent_note`, independently found the saved summary, reported six sources / `stale: false`, and recovered its conclusions. The verification conversation used no filesystem or HTTP fallback and made no writes.
- Application changes remain uncommitted and unpushed. Summary content stays exclusively in the book repository, not in this public application repository.


## MCP document writes — 2026-10-24

- Previous MCP reading/memory stage committed as `52fd5874` on user approval; no push. Document-write changes remain uncommitted for review.
- Combined isolated tests: `mcp_test.rb`, `editor_save_test.rb`, `navigation_index_test.rb` — 23 tests, 270 assertions, no failures. Covers preview/create/no-op, exact replacements including Unicode, ambiguous/missing matches and atomic failure, stale saves both directions through the browser HTTP route, uncommitted disk content, symlinks/reserved paths and read-only controls.
- Rebuilt with `./projectbook/start.sh`; local container healthy at port 4569. Existing client configuration uses the same `/mcp` endpoint. Tool discovery now includes `save_document` and `edit_document`; a connected client may need to refresh its tool list.
- Live HTTP smoke against disposable test-book page `playground/mcp-editing/version-check-20261024180154.md`: preview, create, browser save, rejected stale MCP replacement (412), MCP exact edit, rejected stale browser save (412), concurrent MCP edits (one success/one 412), current-version no-op without a commit, and rendered Web UI content all passed. No original documents modified; local book commits are expected for actual test saves.
- This verifies saved-content concurrency in one app process. Unsaved browser drafts remain client-side; concurrent external Git writers/multiple app processes still need the planned synchronization/locking work.

## Experimental retrieval — 2026-10-24

- Existing MCP changes committed/pushed as `59eb67d8` before starting this experiment. RAG changes remain uncommitted for review.
- Separate Compose deployment `projectbook-rag`, wiki/MCP at port 4570, book mounted read-only, no exposed Qdrant/indexer ports. Main 4569 deployment unchanged.
- Full index: 130 input files; all Markdown and text from 24/29 PDFs; 9,773 chunks in 249.450 seconds, zero cache hits. AES and fallback Poppler resolved three initial PDF failures. Five files have no extractable text. Details: [benchmark](rag/BENCHMARK.md).
- Cached regeneration: 2.094 seconds, 130 cache hits, no new embeddings. Semantic/hybrid/keyword latency measured separately; actual MCP scoped search with source versions/URLs/stale markers passed. Experimental write tools are absent.
- Eight Python tests pass: committed Git reads, source chunk/token coverage, query validation, AES/blank PDF/fallback extraction, cache reuse/deletion, failed-index publication preserving old generation, query priority over indexing batches. Generation test uses temporary Git + in-memory Qdrant with synthetic vectors; real model/server behavior is checked separately on the deployed book.
- Ruby regression suite: 24 tests, 279 assertions, no failures. Optional discovery leaves normal MCP unchanged; stale per-source flags and PDF URLs checked.
- Stop/restart rollback check preserves generated volumes/book and leaves the main 4569 wiki reachable. `clean` is documented but deliberately not executed after the successful benchmark, to keep the ready-to-review index.

## Deployment Settings — 2026-10-24

- RAG experiment committed as `2fbc27ed` on approval, without push. Subsequent Settings changes remain uncommitted for review.
- Separate optional Compose overlay for any deployment, plus the comparison sandbox's independent read-only override. `PROJECTBOOK_RAG_AVAILABLE=false` resolves to wiki only; true resolves to wiki + Qdrant + indexer. Resource limits and operator controls are in `settings.example.sh`.
- English gear-button dialog: enabled/automatic/PDF switches, interval, batch size, default search mode/count, manual update, model cache/load state, retained index statistics. Settings persist outside Git with expected-version checks. Save is disabled until a value actually changes.
- Eleven Python tests and 27 Ruby tests (292 assertions) pass. Includes no model/database inference when disabled, version conflicts, validation, no-op writes, cancellation boundaries, read-only/operator distinction and request-origin/header guards.
- Real HTTP checks: persisted changes, stale-settings 409, omitted MCP defaults applied, disabled MCP search and manual indexing rejected; original enabled settings restored. Browser check: first view shows disabled/unloaded model, enabling and Save works, unchanged Save becomes disabled again.
- TODO audit: editor has native Markdown checklist support via listsPlugin/ListsToggle; stable task IDs, separate task files/metadata and consolidated task list remain planned. Per user clarification, no TODO implementation in this step.


## Primary RAG and MCP PDF reading — 2026-10-25 (pending review)

- Settings were approved and committed as `42ba1e68`, without push. This stage remains uncommitted/unpushed.
- Primary deployment at 4569 now uses its own Qdrant/index/settings volumes and retains Web UI/MCP document and agent-memory writes. Existing downloaded model files were copied into its independent model volume to avoid downloading again. Ignored `settings.local.sh` enables RAG, its initial search default and local Settings administration; reproducible setup/rollback is in README. The read-only 4570 experiment remains separate and running.
- PDF extraction uses Poppler in the wiki image and committed Git blobs; no RAG dependency. Original attachments use MCP resource links/resources/read or exact base64 byte ranges. Both text continuations and binary reads pin source revisions. Resource/template access uses the same MCP authentication; no public file endpoint was added.
- Automated regression: 31 tests / 334 assertions, no failures. Covers real generated PDFs (blank pages, ranges, dense-page text continuation, 51-page batching), exact binary reconstruction, immutable historical reads, malformed PDF/URI/ranges, hidden/symlink/path rejection, token enforcement, and existing settings/MCP/save/navigation behavior.
- Live MCP: all read/write/search tools discovered together; complete two-page PDF read; reconstructed its full text over 11 small responses without omissions; original 34,984-byte PDF returned via resources/read and byte ranges with identical Git blob SHA. Selected pages of 206-page and 24-page manuals read successfully. PDF text and original-file access also passed with semantic search disabled; settings restored afterward.
- First page of every test-book PDF: 29 successful reads, zero extraction failures, five empty first pages, 1.71 seconds total on this Mac. Empty text can be a scan/blank/design page; no OCR is implemented. This checks first-page readability, not every page in each PDF.
- Test-book HEAD remained `a0e90d2caaa4dca007e60e13e973d0715fc43795`, clean. No document/memory writes were made for these checks. Raw Notes requirements were recorded in PLAN; TODO/Raw Notes implementation is deferred.
- Primary index ready: 125 indexed files, 9,774 fragments, 272.557 seconds for the completed build, matching current book HEAD (`stale=false`). Live hybrid search found a PDF; page text and original-file metadata matched the retrieved source SHA/revision. Russian semantic query returned results. A version-checked document edit dry-run remained unchanged and made no commit. Settings UI shows ready/up to date; main editing controls remain present.

## Local port convention — 2026-10-25

- Default primary port changed to 4000 in Compose, launch configuration, examples, README and AGENTS.md. The ignored local settings and existing Codex `projectbook` MCP URL were updated accordingly. Existing parallel experiment 4570 is unchanged.
- Recreated only the primary wiki container with the new port/public URL, retaining book and RAG volumes. Verified Web UI HTTP 200, all 15 MCP tools (including PDF and writes), and RAG state ready. No commit or push.


## Dedicated Settings page — 2026-10-25

- Approved primary semantic search/PDF MCP and port convention committed as `c167dd84`, without push. User explicitly authorized implementing, testing and committing this Settings stage too, without push.
- Header gear is now a normal link to `/gollum/settings`; modal markup/script is removed from document pages. Dedicated view/template shares the book layout and offers a Semantic Search tab, status card, return link and indexing explanation. Existing JSON settings endpoints/permissions/version checks remain unchanged.
- Rebuilt and deployed at port 4000; API regression tests: 3 tests / 13 assertions passed. Live page and JSON endpoint return 200, default interval remains 60, index ready. Browser: gear opens the page, interval 60→61 saves and survives reload, restored 60 saves; returning a draft to its saved value disables Save and clears the dirty indicator. Leaving with a changed draft remained on Settings; after reverting, Back to book navigated normally. Direct page reload and navigation back from Home work. Added beforeunload guard and discard confirmation for Reload.
- Settings edits do not modify book documents or Git commits. Git pull is explicitly recorded as not implemented. Full task IDs/metadata/list remain planned; only standard Markdown checklists exist in the editor.

### Settings navigation and timing labels follow-up
- Removed the redundant Back to book button; the explorer and ProjectBook link provide navigation.
- Replaced Last build with Last indexing duration (minutes/seconds), and added Last indexed using the report completion time in the browser locale. Revision checks that skip rebuilding retain the previous report.
- Rebuilt on port 4000 and checked the browser: no Back to book link; index ready, duration 4 min 33 s and completion timestamp visible. Changes remain uncommitted pending review.

### Settings connection recovery
- Investigated a reported Load failed: current backend requests return HTTP 200; the exact interrupted request was not captured. A transient fetch failure previously left a stale error after successful polling.
- Connection status is now separate from save/conflict messages, clears on successful retry, and initial loading recovers automatically. Poll recovery preserves unsaved form values.
- `node --test projectbook/test/settings_ui_test.mjs`: 2 tests passed, covering initial failure/recovery and interrupted polling with an unsaved draft and a save-error message.

## TODO lists and document integration — 2026-10-25
- User simplified the model to one list/tag per task. Implemented portable Markdown task/list files with UUIDs, metadata forms, due dates/notes, versioned batch writes, document-save integration, common board, embedded list links and four MCP tools. Application changes are not committed or pushed.
- Ruby suite: 45 tests / 436 assertions passed. Covers atomic task/list/document writes, stale task rejection before any document changes, dry run/no-op, missing lists, duplicate names, invalid date/ID/status, local work protection, pinned historical reads, HTTP permissions and updated MCP discovery/write permissions.
- Editor suite: 16 tests passed. Covers relative links/moves, foreign URLs, code examples, unreferenced new files, staged metadata no-op, undo/redo reference filtering, and resolving historical links from the original document path.
- Docker rebuilt and healthy on port 4000. Browser: created Spring list and oil task; editor showed a list and repeated reference; Visual → Markdown → Visual kept UUID links; toggles synchronized repeated references; inserted a new task and Autumn/open list and saved all four changed files in test-book commit dcbd570. Confirmed the task API had not persisted editor drafts before Save.
- Actual MCP: list_todo_lists/list_tasks/read_todo worked; save_todos dry-run and apply moved the belt task to Autumn; stale retry returned 412. The browser then showed that task in the embedded Autumn/open view. Completing it removed it from the filtered view and updated its separate reference; reopened it for the demo.
- Verified metadata toggle back to original clears Unsaved changes, new task Undo removes its pending file and Redo restores the same staged data; Close and keep draft → reopen → Restore draft → Save preserved task metadata.
- Fixed viewer failure caused by href-less heading anchors. Historical demo at fc48c6bde809f2398c71c78983750d95ee1981be shows only the old open oil task with disabled controls. The direct Spring list document renders its tasks and collapses machine metadata.
- Demo: /playground/todo-demo.md; board: /gollum/tasks. Test book has generated local commits; no push. No deletion/archive or backlink index yet. Text Undo and metadata editing remain distinct; the complete draft can be discarded.

## 2026-10-25 — inline TODO editing, no dialogs (uncommitted)

- New TODO inserts an open task in Default and focuses/selects its title. Case-insensitive Default reuse and no staged network writes covered by store tests.
- Removed task dialogs, due-date/notes fields, technical Metadata disclosures and the Pending TODO details panel. Existing stored notes/dates survive edits.
- Task text is editable inline, wraps on narrow screens, and supports Cmd+A without Lexical intercepting it. List/tag dropdown selects existing lists or creates a named list inline; no separate popup or Update step.
- Browser-tested Default insertion, inline text, new list creation, Visual/Markdown round-trip and atomic Save. Git inspection confirmed one commit containing document, new task and list; unused provisional Default was not persisted.
- Tested a Markdown `- [ ] [TODO: ...](...)` wrapper: one visible checkbox, Space changes canonical task status; changing the same task through an embedded list synchronizes the wrapper. Save and reopening preserve title/status/list and UUID.
- Test-book page `playground/inline-todo-demo.md` demonstrates the task and its embedded list. Long text wraps; title updates propagate to both occurrences. Discard was tested on this agent-created page only.
- Editor JS tests: 18/18 pass. Browser error log empty. Docker rebuilt and healthy on port 4000. No application commit/push.

## 2026-10-25 — TODO source navigation (uncommitted)

- Task titles in embedded lists are navigation links; inline definitions still edit text and list membership. Completion checkbox is independent.
- Actual Markdown references in the requested Git snapshot determine source documents. Code examples/external URLs are excluded. One source links directly; multiple sources open a document-path chooser; missing references fall back to the task file. Newly created tasks record their creation document.
- Browser verified chooser for the task shared by `playground/inline-todo-demo.md` and `playground/todo-demo.md`, navigation to the selected document and UUID anchor, and automatic scrolling. Explicit highlight state handles asynchronously mounted anchors in WebKit.
- Tests: 47 Ruby tests / 446 assertions, 19 editor JS tests, all passing. Covers source discovery, ambiguity, historical snapshots, creation origin, source document moves, unsafe paths and encoded/history URLs.
- Warm catalog requests on the current test book measured 25–48 ms locally. No book files are rewritten by source discovery. Application remains uncommitted; no push.

## 2026-10-25 — Delete in editor, clean page footer (uncommitted)

- Removed the normal-page last-modified and Delete links. Historical revision notice remains.
- Saved documents expose a trash icon beside Rename/Move. Confirmation shows the exact path, defaults focus to Cancel, and notes unsaved edits when present. New unsaved documents use Discard instead.
- Delete uses the shared write lock, editing permission, same-origin/custom-header checks, blob version and working-copy checks; it creates a Git deletion commit. The editor clears its draft only after success, and returns to the parent folder.
- Browser: created disposable `playground/delete-button-check.md`, verified no footer links, opened/cancelled confirmation, then confirmed deletion and verified the page disappeared from the parent listing. No other document was deleted. Screenshot: `.runtime/delete-document.png`.
- Full Ruby suite passed 50 tests; focused deletion tests passed again after correcting the root-folder return URL. Coverage includes retained history, stale version, uncommitted disk edits, read-only mode, cross-origin requests and repeated deletion. Docker healthy at port 4000. No application commit/push.

## 2026-10-25 — compact TODO insertion (uncommitted)

- Root cause: TODO links added leading/trailing blank lines and reused attachment insertion, which additionally split paragraphs before/after each reference.
- TODO insertion now bypasses attachment paragraph splitting. Markdown inserts the reference alone; Visual adds one hard line break after it. Heading-to-body insertion preserves the heading boundary.
- Browser: inserted First/Second/Third consecutively with no manual line breaks, switched Visual → Markdown → Visual, saved and inspected the Git file. Tasks occupy consecutive source lines 3–5, with no blank lines between them. In Markdown, insertion between `Before ` and ` After` added no whitespace.
- Cleaned only the named test document `Test Pages/to-do-items-2.md` through version-checked MCP preview/apply. Preserved all four task references/IDs, including the fourth task already present on disk. Other documents were not normalized. Verified source lines 3–6 and no unsaved changes after reopening. Screenshot `.runtime/todo-spacing.png`.
- Build and 19 JS tests passed; Docker deployed on port 4000. Application remains without commit/push.

## 2026-10-25 — omit repeated list names (uncommitted)

- Embedded TODO lists omit the per-task list/tag and its selector. The list name remains in the heading. Direct task occurrences and the general board retain their selectors.
- Verified `Test Pages/to-do-list.md` in view and visual editor: seven tasks, one heading, no repeated list controls. Checkbox and source links remain. Restored completed-link strikethrough specificity, which the link style previously overrode.
- Docker build successful on port 4000; no book changes, application commit or push. Screenshot `.runtime/todo-list-compact.png`.


## 2026-10-25 — searchable TODO picker and editor toolbar (uncommitted)

- Replaced the existing-task select with a modal containing multi-select list chips, All/Clear, Unicode case-insensitive word search, task/source context and incremental rendering in batches of 50. List insertion also uses a searchable dialog.
- Moved all three TODO actions into the MDXEditor toolbar as labelled icons, available in Visual and Markdown and disabled in Changes.
- Editor tests: 21/21 pass, including query/group intersection and a 600-task fixture. Production build and Docker deployment on port 4000 succeed.
- Browser checks: search plus Spring/Autumn toggles returns the expected three tasks; clearing all lists gives zero; Escape closes without dirtying the page. Visual insertion preserves the caret between explicit text markers; Markdown inserts only the existing UUID link before the following text. List search inserts the selected list with status=open; Changes disables all three controls; New TODO focuses the new task title.
- Checks ran in the agent's own playground/todo-spacing-check.md editor tab. The draft was discarded afterwards; no book write or app commit/push in this step.


## 2026-10-25 — document TODO viewing and flowing list pills (uncommitted)

- Normal document viewing renders task text/list as static spans. Only completion remains editable; embedded list titles still navigate to source. Source navigation scrolls without yellow target highlighting.
- In the visual editor, task text uses an independent plain-text Lexical root and the native list menu overlays an arrow-free pill. Both share inline flow, including long wrapping titles. Keyboard Undo is scoped to task text.
- Browser verification on the disposable playground/todo-spacing-check.md: Select All replaced only the task title, a long Russian title wrapped with its pill after the final word, choosing Spring and Save persisted both title and list. Viewed checkbox persisted completion. An embedded Spring list navigated back to the source with no highlight. Reopening preserved text/list/status; keyboard Undo restored task text without changing the page heading or other tasks; New TODO selected its placeholder for immediate replacement. Unsaved verification drafts discarded.
- The requested Test Pages/todo-items.md was inspected read-only: two static titles and Spring pills, with only checkboxes interactive. Application not committed or pushed. Editor suite 21/21 passed; final production build and Docker deployment on port 4000 succeeded.


## 2026-10-25 — editor toolbar grouping (uncommitted)

- Moved TODO icons after the three list controls, keeping them together on wrapped toolbars. Moved Visual/Changes/Markdown to the Save/Close action bar using a React portal that retains the MDXEditor mode context.
- Production build and Docker deployment succeeded. Browser checked all three modes, arrow-key switching back to Visual, TODO availability in Markdown and correct icon ordering in Visual. Switching modes left No unsaved changes. No book writes, application commit or push.


## 2026-10-25 - hidden TODO storage (application uncommitted)

- Task/list storage uses `.projectbook/tasks` and `.projectbook/task-lists`. New references use system paths; parsers and historical MCP reads accept legacy paths. The task board no longer exposes a List document link. Ordinary document writes still reject dot paths; only validated task IDs can create system task files.
- Explicit startup migration moved 12 tasks and 4 lists, updating links in six documents in test-book commit `19af67b`. All 16 metadata blobs remained byte-identical and IDs were preserved. Startup repeats are no-ops.
- Tests: editor 22/22; Ruby TODO/migration 11 tests, 86 assertions; MCP 9 tests, 182 assertions. Coverage includes clean-working-tree refusal, one-commit migration, historical reads, preserved code/external URLs, hidden navigation/search and post-migration writes.
- Browser verified embedded list rendering and absence of Tasks/TaskLists/system directory in tree and root file overview. Created Hidden storage verification in the playground document; Save created its file under .projectbook/tasks, then its checkbox updated successfully. Live MCP read_todo returned that hidden path and done status.
- The initial image omitted the migration module from the gem manifest; corrected packaging and rebuilt. The final port-4000 deployment is healthy. No application commit/push; only test-book migration and UI verification commits.
- PLAN records manual ordering and drag/drop moves as the next priority after TODO acceptance.
# Tree editing — 25 October 2026

- Previous TODO/editor changes committed as `44d2467d`, without push. Tree changes remain uncommitted for review.
- Docker deployment on port 4000. Isolated disposable fixture: `00-tree-review` with Alpha, Beta, Charlie and archive.
- Real browser drag and drop: moved Charlie before Alpha; tree changed without reload; folder overview retained alphabetical order. Reload preserved the tree order.
- Moving Charlie into archive displayed confirmation. Cancel kept the file in place; OK moved it and expanded the destination. Disabling confirmation in Settings → Navigation allowed moving it back without a dialog. Re-enabled confirmation afterwards.
- Server tests cover single-commit moves/order updates, stale revisions, local edits, case/path collisions, hidden paths, CSRF, byte-exact PDF moves, empty source folders, no-op reorder, manual folder ordering, appending new documents, and hidden `.order` rendering. Settings tests cover persistence without RAG and stale settings versions.
- Final checks: 47 Ruby tests / 428 assertions, 23 editor JavaScript tests, 2 settings UI tests; all passed. Existing TODO, MCP, editor-save, delete and navigation tests rerun. JavaScript editor tests include drag target classification; existing settings recovery tests remain green.
- Scope: documents and attachments move between folders; folders themselves can be reordered but cannot yet be moved. Markdown links inside moved documents are rebased; incoming links from other documents retain their original destinations. Tree editing is disabled inside the editor and while tree search is active.

Toolbar tooltips: all top-bar icons now show English action descriptions on hover or keyboard focus. History describes book-wide changes on Home and document history elsewhere. Verified the rendered Home toolbar, keyboard focus, Escape dismissal, and screenshot on port 4000. No commit/push.
# Callouts and footnotes — 25 October 2026

- Fixture `playground/callouts-review.md`: all five callout types, bold text, a two-item list, relative links and footnotes.
- Browser: convert an ordinary paragraph to Warning, switch Visual/Markdown, return to Paragraph without losing formatting, insert a footnote through the dialog, and exit a final empty callout paragraph with Enter. Saved through the normal editor and inspected the rendered page: both list items remain distinct and footnotes render with backlinks.
- Parser tests exercise all five alert markers and round trips; server tests verify structured lists, formatting, code examples, unknown quote types and footnotes. Move regression verifies footnote prose is not misinterpreted as a link definition.
- Blocks use supported MDXEditor/Lexical extension points; no editor fork. Code-block UI remains unchanged. No application commit or push.

## 2026-10-25 — accepted features, first-position drop and shared plan

- User authorized committing tree editing, toolbar tooltips, callouts and footnotes; no push. Earlier uncommitted status entries above describe their review stages.
- Widened folder reorder edges to thirds, accepted the whole row including the disclosure area, and added a stable 18px drop strip above the root list. Feedback names the intended target. The strip does not shift rows when dragging starts.
- Browser verification on port 4000: moved the first folder above plan.md, dragged plan.md back through the new top strip, observed Order saved, and reloaded. Plan remained first; the folder stayed in the root. No JavaScript errors.
- Replaced the stale roadmap with checked completed work and prioritized remaining work. Saved the same bytes to the user-created plan.md through MCP preview/save with expected_version; verified byte equality with application PLAN.md. AGENTS.md now requires keeping both copies reconciled and synchronized.
- Final rebuilt Docker services healthy. Editor tests: 27 passed. Ruby regression suite: 50 tests, 465 assertions, no failures/errors. Screenshot: projectbook/.runtime/shared-plan.png (local ignored evidence).

## 2026-10-25 — incoming links, folder moves and preserved order (uncommitted)

- Shared server move plan for tree and editor. A pinned book revision protects all scanned documents; stale previews and dirty working copies are rejected. File moves, incoming/outgoing link edits, TODO origin paths and parent order updates share one commit. No push.
- Markdown AST handles links/images/reference definitions and footnotes; HTML href/src and standard Gollum wiki links are rewritten. Code, frontmatter, comments and external URLs stay unchanged. Folder moves preserve internal .order bytes and binary attachments. Same-folder rename preserves position; document/legacy attachment deletion removes its order entry.
- Disposable browser fixture: playground/move-links-review/index.md. Dragged source into destination; expanded preview diff showing Markdown/HTML/wiki updates with untouched code example. Cancel produced no commit; Confirm created one commit. Followed the new link and used editor Move to rename the document; incoming links and .order updated together.
- Regression coverage: folder descendants/collisions/hidden targets/symlinks, stale revision/local draft refusal, unsaved document plus attachments, task identity/origin, nested orders, exact binary bytes, HTTP origin protection and deletion order cleanup. Final tests: 32 JavaScript tests; 60 Ruby tests / 526 assertions, all passing. Docker services healthy on port 4000.
- Native plan tasks updated through versioned MCP; their UUIDs retained. Completed move tasks are below open work; PLAN.md mirrors requirements/status. Additional confirmation preferences remain a separate discussion. No automatic order reset.
- Local screenshot evidence: projectbook/.runtime/move-preview.png. Application changes await user review, without commit/push.

## Raw Notes — 2026-10-25

- 65 Ruby tests / 561 assertions pass; 32 JS tests pass. Includes atomic note+media,
  duplicate retry, chunk retry/mismatch, SHA validation, size/type guards, status
  conflicts, local work protection, SSRF rejection, read-only/CSRF and MCP file metadata.
- Local Web UI created text+compressed photo+WAV in one commit; native player
  reads the one-second fixture correctly. Real MCP created a second photo/audio
  note; identical retry returned the existing note. No microphone capture of the
  user's environment was performed by the agent.
- Real iPhone microphone/camera and ChatGPT file handoff remain user acceptance
  tests on HTTPS. Automatic transcription/video are not in this version.
- Book backlog pushed; host auto-push reports success after new local commits.

## Folder pages — 2026-10-25 integration verification

- Final reserved name is `.index.md`. Built a dedicated local instance from committed application sources; the existing primary instance was not replaced.
- Disposable browser book: New folder transliterated a Russian title into its path and opened the editor with H1 plus Pages marker. The empty folder rendered only its title. New document selected the current folder; its saved page appeared automatically in the dynamic Pages block.
- Removed the Pages link in the visual editor and saved: the overview displayed only its heading while the child remained in the tree. Delete displayed the folder title/path and two-file subtree count. Cancel preserved both files; explicit confirmation removed both in one commit.
- Found and fixed the root-folder deletion return URL: `/gollum/overview/` incorrectly entered the missing-document route. Root deletion now returns `/gollum/overview`, nested deletion returns the parent's directory overview. Added HTTP regressions for both targets.
- Final server suite: 88 tests, 758 assertions, zero failures/errors. Editor JavaScript: 32 passing tests. RAG: 8 passing tests inside the dependency container (host Python lacks FastEmbed). RAG includes hidden overview pages without including other system files.
- Separate migrated-book checks: all 18 pages render, local Markdown links resolve, seven original attachments retain their SHA-256, and all 13 task IDs/statuses/source references are preserved. MCP search, PDF page extraction and original attachment retrieval pass. No purchase tasks were added.
- Private migration content, source snapshots and screenshots stay outside this public application repository.
