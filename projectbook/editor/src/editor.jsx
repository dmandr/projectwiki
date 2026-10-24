import React, { useState, useRef } from 'react';
import { createRoot } from 'react-dom/client';
import { MDXEditor, realmPlugin, addExportVisitor$, rootEditor$, viewMode$,
  headingsPlugin, listsPlugin, quotePlugin, thematicBreakPlugin, linkPlugin, linkDialogPlugin,
  imagePlugin, tablePlugin, codeBlockPlugin, codeMirrorPlugin, frontmatterPlugin, markdownShortcutPlugin,
  diffSourcePlugin, toolbarPlugin, DiffSourceToggleWrapper, UndoRedo, BoldItalicUnderlineToggles,
  BlockTypeSelect, ListsToggle, CreateLink, InsertImage, InsertTable, InsertCodeBlock, Separator } from '@mdxeditor/editor';
import { $createRangeSelection, $setSelection, $getSelection, $isRangeSelection } from 'lexical';
import { EditorView } from '@codemirror/view';
import { draftStore } from './drafts';
import { imageDimensionsPlugin, ImageToolbar } from './image-dimensions';
import '@mdxeditor/editor/style.css';
import './style.css';

const form = document.getElementById('gollum-editor-form');
if (document.getElementById('projectbook-editor-app')) {
  const initial = document.getElementById('projectbook-initial-markdown').value;
  const path = form.dataset.path;
  const isNew = form.dataset.create === 'true';
  const base = window.baseUrl || '';
  const encodePath = value => value.split('/').map(part => encodeURIComponent(part).replace(/[!'()*]/g, c => '%' + c.charCodeAt(0).toString(16))).join('/');
  const pageUrl = base + '/' + encodePath(path);
  const parent = path.split('/').slice(0, -1).join('/');
  const closeUrl = isNew ? base + '/gollum/overview/' + encodePath(parent) + '/' : pageUrl;
  const draftKey = base + ':' + path;
  const relativeUrl = target => '../'.repeat(path.split('/').length - 1) + encodePath(target);
  const translations = { 'Rich text': 'Visual', 'Source mode': 'Markdown', 'Diff mode': 'Changes' };
  const bridge = { realm: null, mode: 'rich-text' };
  const integration = realmPlugin({ init(realm) {
    bridge.realm = realm;
    realm.sub(viewMode$, value => { bridge.mode = value; });
    realm.pub(addExportVisitor$, {
      priority: 10, testLexicalNode: node => node.getType() === 'linebreak',
      visitLexicalNode: ({ mdastParent, actions }) => actions.appendToParent(mdastParent, { type: 'break' })
    });
  } });

  function Editor() {
    const ref = useRef(null), current = useRef(initial), normalized = useRef(null);
    const pending = useRef([]), working = useRef(false), allowLeave = useRef(false);
    const queue = useRef(Promise.resolve()), draftTimer = useRef(null);
    const [status, setStatus] = useState(''), [busy, setBusy] = useState(false);
    const [confirmDiscard, setConfirmDiscard] = useState(false);
    const [files, setFiles] = useState([]), [draft, setDraft] = useState(null);
    const name = useRef(path.split('/').pop());
    const [filename, setFilename] = useState(name.current);
    React.useEffect(() => { document.title = (isNew ? 'New: ' : 'Edit: ') + filename; }, [filename]);
    const targetPath = () => isNew ? [parent, name.current.trim()].filter(Boolean).join('/') : path;
    const [summary, setSummary] = useState((isNew ? 'Created ' : 'Updated ') + path);
    const picker = useRef(null), container = useRef(null);
    const dirty = () => current.current !== initial || pending.current.length > 0 || targetPath() !== path;
    window.projectbookEditorDirty = dirty;
    const snapshot = () => ({ filename: name.current, content: current.current, files: pending.current.map(({url, ...file}) => file), etag: form.dataset.etag, saved: Date.now() });
    const stash = () => {
      clearTimeout(draftTimer.current);
      const data = snapshot();
      queue.current = queue.current.catch(() => {}).then(() => draftStore('put', draftKey, data));
      return queue.current;
    };
    const stashSoon = () => {
      clearTimeout(draftTimer.current);
      draftTimer.current = setTimeout(() => stash().catch(() => setStatus('Browser draft could not be stored. Keep this tab open or download Markdown.')), 350);
    };
    const change = (value, normalization) => {
      if (normalization) { normalized.current ??= value; return; }
      current.current = value === normalized.current ? initial : value;
      stashSoon();
    };
    React.useEffect(() => {
      draftStore('get', draftKey).then(value => {
        // Migrate text drafts from the earlier editor without deleting the old copy.
        if (!value) { try { value = JSON.parse(localStorage.getItem('projectbook:mdx:draft:' + location.pathname)); } catch (_) {} }
        if (value && (value.content !== initial || value.files?.length || (value.filename && value.filename !== name.current))) setDraft(value);
      }).catch(() => setStatus('Browser draft storage is unavailable. Keep this tab open until Save succeeds.'));
      const warn = event => { if (!allowLeave.current && dirty()) { event.preventDefault(); event.returnValue = ''; } };
      window.addEventListener('beforeunload', warn);
      return () => window.removeEventListener('beforeunload', warn);
    }, []);
    const restore = () => {
      pending.current.forEach(file => URL.revokeObjectURL(file.url));
      pending.current = (draft.files || []).map(file => ({...file, url: URL.createObjectURL(file.blob)}));
      setFiles([...pending.current]);
      if (isNew && draft.filename) { name.current = draft.filename; setFilename(draft.filename); }
      current.current = draft.content; ref.current.setMarkdown(draft.content);
      setStatus(draft.etag !== form.dataset.etag ? 'Draft restored from an older version. Review Changes against the current document before saving.' : 'Draft and attachments restored.');
      setDraft(null); stashSoon();
    };
    function stage(file) {
      if (form.dataset.uploads !== 'true') throw new Error('File uploads are disabled.');
      if (file.size > 20 * 1024 * 1024) throw new Error(`${file.name}: maximum file size is 20 MB.`);
      if (pending.current.reduce((sum, f) => sum + f.blob.size, file.size) > 50 * 1024 * 1024 || pending.current.length >= 30)
        throw new Error('Maximum 30 attachments and 50 MB per save.');
      const safeName = file.name.replace(/[\\/:\x00-\x1f\x7f%?#]/g, '-').replace(/^[._]+/, '').replace(/[. ]+$/, '').trim() || 'attachment';
      if (new TextEncoder().encode(safeName).length > 180) throw new Error('This filename is too long. Rename the file and try again.');
      const target = 'uploads/' + crypto.randomUUID() + '/' + safeName;
      const item = {path: target, name: safeName, blob: file, source: relativeUrl(target), url: URL.createObjectURL(file)};
      pending.current.push(item); setFiles([...pending.current]); stashSoon();
      return item;
    }
    function insert(markdown, event) {
      if (bridge.mode === 'diff') throw new Error('Switch to Visual or Markdown to insert attachments.');
      if (bridge.mode === 'source') {
        const element = container.current.querySelector('.cm-editor');
        const view = element && EditorView.findFromDOM(element);
        if (!view) throw new Error('Click in the Markdown editor and try again.');
        const position = event ? view.posAtCoords({x: event.clientX, y: event.clientY}) : null;
        const from = position ?? view.state.selection.main.from;
        const to = position == null ? view.state.selection.main.to : from;
        view.dispatch({changes: {from, to, insert: markdown}, selection: {anchor: from + markdown.length}}); view.focus();
      } else {
        const editor = bridge.realm.getValue(rootEditor$);
        let range = null;
        if (event) {
          if (document.caretRangeFromPoint) range = document.caretRangeFromPoint(event.clientX, event.clientY);
          else { const pos = document.caretPositionFromPoint?.(event.clientX, event.clientY); if (pos) { range = document.createRange(); range.setStart(pos.offsetNode, pos.offset); range.collapse(true); } }
        }
        if (range && editor.getRootElement()?.contains(range.startContainer)) {
          editor.update(() => { const selection = $createRangeSelection(); selection.applyDOMRange(range); $setSelection(selection); }, {discrete: true});
          insertBlocks();
        } else ref.current.focus(insertBlocks);
        function insertBlocks() {
          // Markdown's leading/trailing blank lines disappear during parsing.
          // Split real editor paragraphs so attachments never join surrounding text.
          editor.update(() => { const selection = $getSelection(); if ($isRangeSelection(selection)) selection.insertParagraph(); }, {discrete: true});
          ref.current.insertMarkdown(markdown);
          editor.update(() => { const selection = $getSelection(); if ($isRangeSelection(selection)) selection.insertParagraph(); }, {discrete: true});
        }
      }
    }
    function attach(list, event) {
      if (working.current) return;
      if (bridge.mode === 'diff') { setStatus('Switch to Visual or Markdown to add attachments.'); return; }
      const before = [...pending.current];
      try {
        const added = Array.from(list).map(stage);
        const markdown = added.map(file => {
          const label = file.name.replace(/[\\\[\]]/g, '\\$&');
          const image = /^image\/(png|jpeg|gif|webp|avif)$/i.test(file.blob.type);
          return `${image ? '!' : ''}[${label}](${file.source})`;
        }).join('\n\n');
        insert('\n\n' + markdown + '\n\n', event);
        setStatus('Attachments are kept in this browser until Save.');
      } catch (error) {
        pending.current.filter(file => !before.includes(file)).forEach(file => URL.revokeObjectURL(file.url));
        pending.current = before; setFiles([...before]); setStatus(error.message); stashSoon();
      }
    }
    const download = () => {
      const url = URL.createObjectURL(new Blob([current.current], {type: 'text/markdown;charset=utf-8'}));
      const a = document.createElement('a'); a.href = url; a.download = name.current; a.click();
      setTimeout(() => URL.revokeObjectURL(url), 1000);
    };
    async function close(discard) {
      if (working.current) return;
      try {
        clearTimeout(draftTimer.current);
        await queue.current.catch(() => {});
        if (discard) await draftStore('delete', draftKey); else if (dirty()) await stash();
        if (discard) localStorage.removeItem('projectbook:mdx:draft:' + location.pathname);
        allowLeave.current = true; location.assign(closeUrl);
      } catch (_) { setStatus('Could not store or discard the browser draft. Keep this tab open until Save succeeds.'); }
    }
    async function save(event) {
      event?.preventDefault();
      if (working.current) return;
      const savePath = targetPath();
      if (isNew && (!name.current.trim() || /[\\/]/.test(name.current) || !/\.md$/i.test(name.current.trim()))) { setStatus('Enter a Markdown filename ending in .md, without folder separators.'); return; }
      working.current = true; setBusy(true); setStatus('Preparing save…');
      const content = current.current;
      // An undone/deleted insertion must not leave an orphan in the Git book.
      const used = pending.current.filter(file => content.includes(file.source));
      const data = new FormData();
      data.append('document', JSON.stringify({path: savePath, content, create: isNew, etag: form.dataset.etag, attachments: used.map(file => ({path: file.path}))}));
      data.append('message', summary === `Created ${path}` ? `Created ${savePath}` : summary || `Updated ${savePath}`);
      used.forEach(file => data.append('files[]', file.blob, file.name));
      try {
        await stash().catch(() => {});
        const result = await new Promise((resolve, reject) => {
          const request = new XMLHttpRequest();
          request.open('POST', base + '/gollum/projectbook/save'); request.timeout = 120000;
          request.setRequestHeader('X-ProjectWiki-Request', '1');
          request.upload.onprogress = event => setStatus(event.lengthComputable ? `Uploading ${Math.round(event.loaded / event.total * 100)}%…` : 'Uploading…');
          request.upload.onload = () => setStatus('Saving document and attachments to Git…');
          request.onload = () => {
            let result; try { result = JSON.parse(request.responseText); } catch (_) {}
            if (request.status >= 200 && request.status < 300 && result?.url) resolve(result);
            else reject(new Error(result?.error || `Save failed (HTTP ${request.status}). Your draft is preserved.`));
          };
          request.onerror = request.ontimeout = () => reject(new Error('No save confirmation. Your text and attachments remain here. Check the connection and retry; if the server already saved, compare with the latest document.'));
          request.send(data);
        });
        clearTimeout(draftTimer.current); await queue.current.catch(() => {});
        await draftStore('delete', draftKey).catch(() => {});
        localStorage.removeItem('projectbook:mdx:draft:' + location.pathname);
        allowLeave.current = true; location.assign(result.url);
      } catch (error) { setStatus(error.message); }
      finally { working.current = false; setBusy(false); }
    }
    React.useEffect(() => {
      form.addEventListener('submit', save);
      return () => form.removeEventListener('submit', save);
    });
    const plugins = React.useMemo(() => [
      integration(), headingsPlugin(), listsPlugin(), quotePlugin(), thematicBreakPlugin(), linkPlugin(), linkDialogPlugin({onClickLinkCallback: source => {
        const local = pending.current.find(file => file.source === source);
        const url = local?.url || new URL(source, new URL(pageUrl, location.origin)).href;
        if (/^(https?:|blob:)/.test(url)) window.open(url, '_blank', 'noopener,noreferrer');
      }}),
      imagePlugin({disableImageResize: true, EditImageToolbar: ImageToolbar,
        imageUploadHandler: form.dataset.uploads === 'true' ? async file => {try { return stage(file).source; } catch (error) {setStatus(error.message); throw error;}} : undefined,
        imagePreviewHandler: async source => pending.current.find(file => file.source === source)?.url || new URL(source, new URL(pageUrl, location.origin)).href}),
      imageDimensionsPlugin(), tablePlugin(), frontmatterPlugin(), codeBlockPlugin({defaultCodeBlockLanguage: 'text'}),
      codeMirrorPlugin({codeBlockLanguages: {text: 'Text', js: 'JavaScript', python: 'Python', sh: 'Shell', json: 'JSON', yaml: 'YAML', '': 'Plain'}}),
      markdownShortcutPlugin(), diffSourcePlugin({viewMode: /<!--|\[\[/.test(initial) ? 'source' : 'rich-text', diffMarkdown: initial}),
      toolbarPlugin({toolbarContents: () => <DiffSourceToggleWrapper options={['rich-text', 'source', 'diff']}>
        <UndoRedo/><Separator/><BlockTypeSelect/><BoldItalicUnderlineToggles/><Separator/>
        <ListsToggle/><CreateLink/><InsertImage/><InsertTable/><InsertCodeBlock/>
      </DiffSourceToggleWrapper>})
    ], []);
    return <>
      <h1 className="header-title">{filename || 'Untitled document'}</h1>
      {isNew && <label className="pb-document-name">Document filename<input className="form-control" aria-label="Document filename" value={filename} disabled={busy}
        onChange={event => { name.current = event.target.value; setFilename(event.target.value); stashSoon(); }}/><small>Saved as /{targetPath()}. The filename is separate from the document text.</small></label>}
      {draft && <div className="pb-draft-banner">A browser draft is available. <button type="button" className="btn btn-sm" disabled={busy} onClick={restore}>Restore draft</button></div>}
      <div className="pb-editor-actions">
        <button type="submit" className="btn btn-primary" disabled={busy}>Save</button>
        <button type="button" className="btn" disabled={busy} onClick={() => close(false)}>Close and keep draft</button>
        <button type="button" className="btn" disabled={busy} onClick={() => dirty() || draft ? setConfirmDiscard(true) : close(true)}>Discard</button>
        {form.dataset.uploads === 'true' && <button type="button" className="btn" disabled={busy} onClick={() => picker.current.click()}>Attach files</button>}
        <button type="button" className="btn" onClick={download}>Download Markdown</button>
        <input ref={picker} hidden type="file" multiple onChange={event => { attach(event.target.files); event.target.value = ''; }}/>
      </div>
      {confirmDiscard && <div className="pb-draft-banner" role="alert">
        Discard this draft and its unsaved attachments?{' '}
        <button type="button" className="btn btn-sm" onClick={() => close(true)}>Discard draft</button>{' '}
        <button type="button" className="btn btn-sm" onClick={() => setConfirmDiscard(false)}>Keep editing</button>
      </div>}
      <div className="pb-editor-status" role="status" aria-live="polite">{status}</div>
      <div className="pb-content-label">Document content</div>
      <div id="projectbook-mdx" ref={container} aria-busy={busy}
        onKeyDown={event => {if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 's') save(event);}}
        onDragOverCapture={event => {if (event.dataTransfer.types.includes('Files')) {event.preventDefault(); event.stopPropagation(); event.dataTransfer.dropEffect = 'copy';}}}
        onDropCapture={event => {if (event.dataTransfer.files.length) {event.preventDefault(); event.stopPropagation(); attach(event.dataTransfer.files, event);}}}
        onPasteCapture={event => {if (event.clipboardData.files.length) {event.preventDefault(); event.stopPropagation(); attach(event.clipboardData.files);}}}>
        <MDXEditor ref={ref} markdown={initial} trim={false} readOnly={busy} contentEditableClassName="pb-prose"
          translation={(key, fallback) => translations[fallback] || fallback || key}
          onChange={change} onError={() => {setStatus('Visual mode cannot parse this content. Use Markdown; source text is preserved.'); queueMicrotask(() => bridge.realm?.pub(viewMode$, 'source'));}}
          plugins={plugins}/>
      </div>
      {files.length > 0 && <div className="pb-pending-files"><strong>Unsaved attachments</strong><ul>{files.map(file => <li key={file.path}>
        <a href={file.url} download={file.name}>{file.name}</a> · {(file.blob.size / 1024).toFixed(1)} KB
      </li>)}</ul><small>Only attachments still referenced in the document are saved. Undo or remove the link to leave one out.</small></div>}
      <label className="pb-save-summary">Commit message<input className="form-control" value={summary} disabled={busy} onChange={event => setSummary(event.target.value)}/></label>
      <p className="pb-editor-hint">Drop images, PDFs or other files into the editor. Maximum 20 MB per file, 50 MB per save. Drafts stay in this browser.</p>
    </>;
  }
  createRoot(document.getElementById('projectbook-editor-app')).render(<Editor/>);
}
