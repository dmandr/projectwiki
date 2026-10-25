# Shared Git assets

Current design (2026-10-25): one hidden root directory `.asset/<upload UUID>/<filename>`.
This supersedes the per-page `.assets` ownership design. There are no owner manifests.

- New editor uploads and MCP save_document attachments are saved with the page in one commit. Browser drafts keep unsaved bytes outside Git. Existing limits remain 20 MiB/file, 50 MiB/save, 30 files.
- Markdown uses `![caption](/.asset/UUID/image.png)`; sized HTML images keep their width. GitHub documents root-relative repository links/images, so these links work in rendered repository Markdown on the same branch. Standalone local previewers may require a configured repository root. GitHub sanitization can differ for HTML styling.
- Move/rename of pages or folders leaves shared bytes in place. Copy document copies Markdown and rebases other relative links, reusing shared attachments. Deleting pages leaves shared assets intact. Replacing an image stages a fresh UUID, never silently overwrites a shared file.
- Clipboard image bytes use the normal upload path. Markdown/HTML copied from a book page reuses shared links. The paste handler normalizes same-origin HTML URLs and root/relative .asset references without rewriting code examples. External images remain external links.
- `.asset` is excluded by tree/Pages/file-name search filters. Files remain accessible by validated Git blob paths through Web and MCP; other dot-files and symlinks are not exposed. HTML/SVG are downloads with restrictive headers, not executable inline content.
- MCP: stage chunks with upload_raw_note_attachment (also usable for document bytes), then save_document with attachments `{upload_id,name,sha256,mime_type}`. Before save link `uploads/<upload_id>/<name>` relative to the page. Save rewrites this to `/.asset/...`. Dry run precedes apply; expected_version protects browser edits. read_attachment and read_pdf_text can read shared files.
- Existing visible assets/, uploads/, and Raw Notes media are unchanged. No automatic migration or garbage collection. Future cleanup needs book-wide reference analysis and explicit preview. Hidden PDFs are currently readable through MCP but excluded from the RAG crawl; standalone manuals keep their existing indexing behavior.

## Review stand

An isolated clone avoids interrupting the open editor on port 4000:

```sh
PROJECTBOOK_INSTANCE=projectbook-local-assets \
PROJECTBOOK_PORT=4001 \
PROJECTBOOK_IMAGE=projectwiki:local-assets \
PROJECTBOOK_WIKI_DIR=/Users/dmandr/code/ProjectBook/testwiki-local-assets \
docker compose -f projectbook/compose.yaml up -d --build --wait
```

Tests: projectbook/test/local_assets_test.rb, editor_save_test.rb, existing move/folder/MCP tests, and editor JS tests. Review pages: `/playground/shared-assets-review.md` and `/playground/paste-target.md`.
