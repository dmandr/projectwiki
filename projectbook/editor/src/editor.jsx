import React from 'react';
import { createRoot } from 'react-dom/client';
import { MDXEditor, realmPlugin, addExportVisitor$, headingsPlugin, listsPlugin, quotePlugin, thematicBreakPlugin,
  linkPlugin, linkDialogPlugin, imagePlugin, tablePlugin, codeBlockPlugin, codeMirrorPlugin,
  frontmatterPlugin, markdownShortcutPlugin, diffSourcePlugin, toolbarPlugin,
  DiffSourceToggleWrapper, UndoRedo, BoldItalicUnderlineToggles, BlockTypeSelect,
  ListsToggle, CreateLink, InsertImage, InsertTable, InsertCodeBlock, Separator } from '@mdxeditor/editor';
import '@mdxeditor/editor/style.css';
import './style.css';

const hardBreaksPlugin = realmPlugin({ init(realm) {
  realm.pub(addExportVisitor$, {
    priority: 10, testLexicalNode: node => node.getType() === 'linebreak',
    visitLexicalNode: ({ mdastParent, actions }) => actions.appendToParent(mdastParent, { type: 'break' })
  });
} });

// The stock editor remains a hidden adapter for Gollum's preview and form fields.
// No upstream files or wiki content are modified by loading this module.
window.jQuery(() => {
  const form = document.getElementById('gollum-editor-form');
  const textarea = document.getElementById('gollum-editor-body');
  const ace = window.ace_editor;
  if (!form || !ace || textarea.dataset.markupLang !== 'markdown') return;
  const fallback = new URL(location.href); fallback.searchParams.set('editor', 'ace');
  if (new URL(location.href).searchParams.get('editor') === 'ace') return;
  const initial = textarea.value;
  let normalizedInitial = null;
  let current = initial, dirty = false, saving = false, bridge = false;
  const ref = React.createRef();
  const storageKey = 'projectbook:mdx:draft:' + location.pathname;
  const notice = document.createElement('div');
  notice.className = 'pb-editor-notice';
  notice.innerHTML = '<strong>MDXEditor</strong> · Visual mode / Markdown <a>Open legacy editor</a>';
  notice.querySelector('a').href = fallback.href;
  const status = document.createElement('div'); status.setAttribute('role', 'status');
  status.className = 'pb-editor-status';
  const mount = document.createElement('div'); mount.id = 'projectbook-mdx';
  textarea.before(notice, status, mount);
  const message = text => { status.textContent = text; };
  function stash() {
    try { localStorage.setItem(storageKey, JSON.stringify({ content: current, etag: form.elements.etag?.value, saved: Date.now() })); return true; }
    catch (_) { message('Could not store the browser draft. Download Markdown before leaving.'); return false; }
  }
  function sync(value) {
    current = value; dirty = current !== initial;
    bridge = true; ace.session.setValue(value); bridge = false;
    textarea.value = value;
    if (dirty) stash();
  }
  // Preserve external edits, e.g. Gollum's existing Restore button.
  ace.session.on('change', () => { if (!bridge) { current = ace.getValue(); dirty = current !== initial; ref.current?.setMarkdown(current); if (dirty) stash(); } });
  const pagePath = [form.elements.path.value.replace(/^\/+|\/+$/g, ''), form.elements.page.value].filter(Boolean).join('/');
  const pageUrl = new URL((window.baseUrl || '') + '/' + pagePath.split('/').map(encodeURIComponent).join('/'), location.origin);
  async function upload(file) {
    const data = new FormData(); data.append('file', file);
    const response = await fetch((window.baseUrl || '') + '/gollum/upload_file', { method: 'POST', body: data });
    if (!response.ok) throw new Error('Upload failed: HTTP ' + response.status);
    return (window.baseUrl || '') + '/' + (window.uploadDest || 'uploads').split('/').map(encodeURIComponent).join('/') + '/' + encodeURIComponent(file.name);
  }
  const translations = { 'Rich text': 'Visual', 'Source mode': 'Markdown', 'Diff mode': 'Changes' };
  createRoot(mount).render(<MDXEditor ref={ref} markdown={initial} trim={false}
    contentEditableClassName="pb-prose" translation={(key, defaultValue) => translations[defaultValue] || defaultValue || key}
    onChange={(value, normalization) => {
      if (normalization) { normalizedInitial ??= value; return; }
      sync(value === normalizedInitial ? initial : value);
    }}
    onError={() => message('This content is not supported in visual mode. Open Markdown or the legacy editor; the source text is preserved.')}
    plugins={[
      hardBreaksPlugin(), headingsPlugin(), listsPlugin(), quotePlugin(), thematicBreakPlugin(), linkPlugin(), linkDialogPlugin(),
      imagePlugin({ disableImageResize: true, imageUploadHandler: upload,
        imagePreviewHandler: async source => new URL(source, pageUrl).href }),
      tablePlugin(), frontmatterPlugin(), codeBlockPlugin({ defaultCodeBlockLanguage: 'text' }),
      codeMirrorPlugin({ codeBlockLanguages: { text: 'Text', js: 'JavaScript', python: 'Python', sh: 'Shell', json: 'JSON', yaml: 'YAML', '': 'Plain' } }),
      markdownShortcutPlugin(), diffSourcePlugin({ viewMode: 'rich-text', diffMarkdown: initial }),
      toolbarPlugin({ toolbarContents: () => <DiffSourceToggleWrapper options={['rich-text', 'source', 'diff']}>
        <UndoRedo /><Separator /><BlockTypeSelect /><BoldItalicUnderlineToggles /><Separator />
        <ListsToggle /><CreateLink /><InsertImage /><InsertTable /><InsertCodeBlock />
      </DiffSourceToggleWrapper> })
    ]} />);
  document.getElementById('gollum-editor').classList.add('pb-mdx-active');
  if (/\[\[|<!--/.test(initial)) message('This document contains wiki syntax or HTML comments. Use the legacy editor to preserve them exactly; review Changes before saving.');
  let draft;
  try { draft = JSON.parse(localStorage.getItem(storageKey)); } catch (_) {}
  if (draft && draft.content !== initial) {
    const restore = document.createElement('button'); restore.type = 'button'; restore.textContent = 'Restore draft';
    restore.className = 'btn btn-sm';
    restore.onclick = () => { ref.current.setMarkdown(draft.content); sync(draft.content); restore.remove(); message('Draft restored. Review the text before saving.'); };
    notice.append(restore);
    if (draft.etag !== form.elements.etag?.value) message('A draft from another page version is available. Compare it with the current document before saving.');
  }
  const download = document.createElement('button');
  download.type = 'button'; download.className = 'btn'; download.textContent = 'Download Markdown';
  download.onclick = () => {
    const url = URL.createObjectURL(new Blob([current], { type: 'text/markdown;charset=utf-8' }));
    const link = document.createElement('a'); link.href = url;
    link.download = (form.elements.page.value || 'draft').replace(/\.md$/i, '') + '.md';
    link.click(); setTimeout(() => URL.revokeObjectURL(url), 1000);
  };
  form.querySelector('.form-actions').append(download);
  const cancel = document.getElementById('gollum-editor-cancel');
  cancel.removeAttribute('onclick');
  cancel.textContent = 'Close and keep draft';
  cancel.title = 'Return to the document and keep a draft in this browser';
  cancel.addEventListener('click', event => {
    event.preventDefault(); event.stopImmediatePropagation();
    if (!stash()) return;
    dirty = false; window.onbeforeunload = null;
    location.assign(pageUrl.href);
  }, true);
  async function save(event) {
    event.preventDefault(); event.stopImmediatePropagation();
    if (saving) return;
    // onChange is synchronous with MDXEditor's state, including source mode.
    textarea.value = current;
    if (dirty) stash();
    saving = true;
    const button = document.getElementById('gollum-editor-submit'); button.disabled = true;
    message('Saving…');
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 15000);
    try {
      const response = await fetch(form.action, { method: 'POST', body: new FormData(form), signal: controller.signal });
      if (response.status === 412) throw new Error('This page was changed by another editor. Your text and draft are preserved in this browser. Open the latest page separately and compare before saving again.');
      if (!response.ok) throw new Error('Save failed: HTTP ' + response.status);
      dirty = false; window.onbeforeunload = null;
      try { localStorage.removeItem(storageKey); localStorage.removeItem('gollum_autorecover_' + window.location); } catch (_) {}
      location.assign(response.redirected ? response.url : pageUrl.href);
    } catch (error) {
      if (error.name === 'TypeError' || error.name === 'AbortError') {
        stash();
        message('No save confirmation from ' + location.host + '. Check that the container is running and try Save again. Your text remains here; download Markdown or close with a draft. If the server already saved the request, retrying may report a version conflict — compare the documents first.');
      } else { message(error.message); }
    } finally { clearTimeout(timeout); saving = false; button.disabled = false; }
  }
  // Capture prevents stock click handlers clearing drafts before the request succeeds.
  document.getElementById('gollum-editor-submit').addEventListener('click', save, true);
  form.addEventListener('submit', save, true);
  mount.addEventListener('keydown', event => { if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 's') save(event); });
  window.addEventListener('beforeunload', event => { if (dirty) { stash(); event.preventDefault(); event.returnValue = ''; } });
});
