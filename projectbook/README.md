# ProjectWiki: локальный Docker-стенд

Первый этап: воспроизводимая сборка приложения из **этого checkout** и запуск с отдельной книгой. Перенесён прототип MDXEditor и добавлена быстрая навигация по каталогам и файлам. Создание каталогов, новые темы и полная интеграция редактора ещё впереди. [План](../PLAN.md), [правила работы](../AGENTS.md).

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
- Браузер: локальные черновики прототипа редактора.

Собственная база данных и Git LFS для этого стенда не нужны. Нажатие Save в Web UI создаёт локальный commit **книги**; это не commit исходников приложения. Автоматического push/pull нет. При проверке deployment агент не сохраняет тестовые правки и не делает commits.

## Сборка и ограничения прототипа

Базовые образы закреплены digest. Для текущего Gollum дополнительно собираются SassC 2.4.0 и FFI 1.17.2 в отдельной стадии; компилятор не переносится в runtime. Frontend собирается через `npm ci` по lockfile. Runtime берётся из закреплённого официального образа Gollum; затем Gollum переустанавливается из этого checkout. Сборка проверяет требования к Ruby-зависимостям и загрузку приложения. При обновлении зависимостей потребуется обновить runtime; дополнительные gems устанавливаются только с явно указанными версиями.

В upstream manifest исправлен путь `template.scss.erb` на существующий `template.scss`, иначе gem из текущего исходного дерева не собирается. В упаковку gem также включён скрытый Sprockets manifest, без которого страницы пытались пересобирать отсутствующие frontend-зависимости при запросе. Исходный Dockerfile Gollum оставлен; этот стенд использует `projectbook/Dockerfile`. MIT-лицензия Gollum сохранена.

На Linux каталогу книги нужны права записи для пользователя контейнера `www-data` (UID 1000). На этом этапе проверяется Mac / Apple Silicon с Docker Desktop; другие платформы пока не проверены. Порт доступен только с локальной машины, внешняя авторизация ещё не реализована.

Существующий MDXEditor пока использует скрытый Ace-адаптер, нормализует Markdown и загружает изображения через старый endpoint с отдельным commit. Полноценный drag and drop произвольных вложений, единое сохранение, новые темы, TODO, MCP и синхронизация не входят в этот этап. Для Gollum-специфичной разметки и HTML-комментариев не обещается сохранение точного исходника в визуальном режиме.


## Navigation

The interface is in English; document contents keep their original language. Folders are collapsed on the first visit. Click the chevron to expand/collapse without a server request; click a different folder name to open its contents in the right pane and expand it. Clicking the selected folder name toggles its children without reloading the page; clicking the selected file is a no-op. Expanded folders are remembered in this browser. Search is retained across transitions and restored synchronously before the content renders. The tree and content share one page scroll: the taller column determines page height, with no separate sidebar scrollbar. A stable page scrollbar gutter prevents horizontal shifts when folders expand or collapse. `Expand all`, `Collapse all` and `Find in tree` operate locally. Arrow keys move between visible entries and expand/collapse folders; Enter follows a link.

The tree includes documents and attachments. Both navigation and folder listings use file paths from Git tree metadata, never a full enumeration of page/file blobs. A bounded in-memory cache holds the index and sidebar HTML. Each page request checks the **local branch commit ID**; only a changed ID rebuilds the cache. Save or an externally updated branch is reflected on the next navigation/reload. There is no Git fetch/pull, network synchronization or automatic polling of the remote. Raw uncommitted filesystem changes are not part of the committed navigation index.

Regression checks (no commits or book writes):

```sh
docker run --rm --entrypoint ruby -e RUBYLIB=/src/lib \
  -v "$PWD:/src:ro" projectwiki:local /src/projectbook/test/navigation_index_test.rb
```


Images and PDF files selected in the tree or folder list open in an attachment preview with the sidebar retained. `Open original` opens the raw file separately; `Download` offers the original file. Raw asset URLs remain unchanged so embedded media still work. Other attachments show download/open actions. Directory headings use the folder name; the root is called `Files`.
