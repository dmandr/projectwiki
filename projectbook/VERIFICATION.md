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
