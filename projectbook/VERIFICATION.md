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
