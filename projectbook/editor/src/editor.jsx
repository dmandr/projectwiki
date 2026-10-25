import React, { useState, useRef } from 'react';
import { createRoot } from 'react-dom/client';
import { MDXEditor, realmPlugin, addExportVisitor$, rootEditor$, viewMode$,
  headingsPlugin, listsPlugin, quotePlugin, thematicBreakPlugin, linkPlugin, linkDialogPlugin,
  imagePlugin, tablePlugin, codeBlockPlugin, codeMirrorPlugin, frontmatterPlugin, markdownShortcutPlugin,
  diffSourcePlugin, toolbarPlugin, UndoRedo, BoldItalicUnderlineToggles,
  ListsToggle, CreateLink, InsertImage, InsertTable, InsertCodeBlock, Separator } from '@mdxeditor/editor';
import { $createRangeSelection, $setSelection, $getSelection, $isRangeSelection } from 'lexical';
import { EditorView } from '@codemirror/view';
import { draftStore } from './drafts';
import { rebaseMarkdown } from './move-links.mjs';
import {confirmMove} from './move-preview.mjs';
import { documentTitle, withDocumentTitle } from './document-title.mjs';
import { titleFromPath } from './names.mjs';
import { imageDimensionsPlugin, ImageToolbar } from './image-dimensions';
import { todoStore, TodoMessages, useTodos } from './todo-ui';
import { todoPlugin } from './todo-editor';
import { TodoToolbar } from './todo-toolbar';
import { EditorToolbar } from './editor-toolbar';
import {calloutsPlugin,CalloutBlockType} from './callouts';
import {footnotesPlugin,InsertFootnote} from './footnotes';
import { todoLink, pendingTodos } from './todo-format.mjs';
import '@mdxeditor/editor/style.css';
import './style.css';

const form = document.getElementById('gollum-editor-form');
if (document.getElementById('projectbook-editor-app')) {
  const initial = document.getElementById('projectbook-initial-markdown').value;
  const path = form.dataset.path;
  const folderPage = path.endsWith('/.index.md');
  const folderPath = path.slice(0,-10);
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
    const todos = React.useMemo(() => todoStore({base, staged:true, onChange:()=>stashSoon()}), []);
    useTodos(todos);
    React.useEffect(()=>{todos.setDocument(initial,path);todos.load();},[]);
    const ref = useRef(null), current = useRef(initial), normalized = useRef(null);
    const pending = useRef([]), working = useRef(false), allowLeave = useRef(false);
    const queue = useRef(Promise.resolve()), draftTimer = useRef(null);
    const [status, setStatus] = useState(''), [busy, setBusy] = useState(false);
    React.useEffect(()=>{todos.setBusy(busy);},[busy]);
    const [confirmDiscard, setConfirmDiscard] = useState(false);
    const [deleteOpen,setDeleteOpen]=useState(false),deleteDialog=useRef(null);
    const [deletePreview,setDeletePreview]=useState(null);
    async function openDelete(){
      setStatus('');setDeletePreview(null);setDeleteOpen(true);
      if(folderPage)try{const response=await fetch(base+'/gollum/projectbook/folder-delete/preview',{method:'POST',headers:{'Content-Type':'application/json','X-ProjectWiki-Request':'1'},body:JSON.stringify({folder:folderPath})});const data=await response.json();if(!response.ok)throw Error(data.error||'Preview failed');setDeletePreview(data);}catch(error){setStatus(error.message);}
    }
    React.useEffect(()=>{if(deleteOpen)deleteDialog.current?.showModal();},[deleteOpen]);
    const [files, setFiles] = useState([]), [draft, setDraft] = useState(null);
    const destination = useRef(path);
    const name = useRef(path.split('/').pop());
    const [moveOpen, setMoveOpen] = useState(false), [movePath, setMovePath] = useState(path);
    const moveDialog = useRef(null);
    const openMove = () => { if (titleEditing && !applyTitle()) return; setMovePath(folderPage ? folderPath : targetPath()); setStatus(''); setMoveOpen(true); };
    React.useEffect(() => { window.projectbookRename = openTitle; return () => { delete window.projectbookRename; }; });
    React.useEffect(() => { if (moveOpen) moveDialog.current?.showModal(); }, [moveOpen]);
    const [filename, setFilename] = useState(name.current);
    const fallbackTitle = titleFromPath(folderPage ? path : filename);
    const [headingTitle, setHeadingTitle] = useState(() => documentTitle(initial, ''));
    const [hasTextChanges, setHasTextChanges] = useState(false);
    const [titleEditing, setTitleEditing] = useState(false), [titleValue, setTitleValue] = useState('');
    const titleInput = useRef(null);
    const displayTitle = headingTitle || fallbackTitle || 'Untitled document';
    const openTitle = () => { if (working.current) return; setTitleValue(documentTitle(current.current, fallbackTitle)); setTitleEditing(true); setStatus(''); };
    React.useEffect(() => { if (titleEditing) { titleInput.current?.focus(); titleInput.current?.select(); } }, [titleEditing]);
    React.useEffect(() => { document.title = (isNew ? 'New: ' : 'Edit: ') + displayTitle; }, [displayTitle]);
    function applyTitle() {
      try {
        const next = withDocumentTitle(current.current, titleValue, fallbackTitle);
        if (next === current.current) { setTitleEditing(false); setStatus(''); return true; }
        current.current = next; ref.current.setMarkdown(next); setHeadingTitle(documentTitle(next, ''));
        setHasTextChanges(next !== initial);
        setTitleEditing(false); stashSoon(); setStatus('Title updated. Save to keep it. The file path is unchanged.'); return true;
      } catch (error) { setStatus(error.message); titleInput.current?.focus(); return false; }
    }

    const targetPath = () => isNew ? [...destination.current.split('/').slice(0, -1), name.current.trim()].join('/') : path;
    const [summary, setSummary] = useState((isNew ? 'Created ' : 'Updated ') + path);
    const picker = useRef(null), container = useRef(null);
    const dirty = () => (titleEditing && titleValue.trim() !== displayTitle) || current.current !== initial || pending.current.length > 0 || targetPath() !== path || todos.visiblePending().length > 0;
    window.projectbookEditorDirty = dirty;
    const snapshot = () => ({ todos: todos.pending(), destination: destination.current, filename: name.current, content: current.current, files: pending.current.map(({url, ...file}) => file), etag: form.dataset.etag, saved: Date.now() });
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
      todos.setDocument(current.current,path);
      setHasTextChanges(current.current !== initial);
      setHeadingTitle(documentTitle(current.current, ''));
      stashSoon();
    };
    React.useEffect(() => {
      draftStore('get', draftKey).then(value => {
        // Migrate text drafts from the earlier editor without deleting the old copy.
        if (!value) { try { value = JSON.parse(localStorage.getItem('projectbook:mdx:draft:' + location.pathname)); } catch (_) {} }
        if (value && (value.content !== initial || value.files?.length || value.todos?.length || (value.filename && value.filename !== name.current) || (value.destination && value.destination !== path))) setDraft(value);
      }).catch(() => setStatus('Browser draft storage is unavailable. Keep this tab open until Save succeeds.'));
      const warn = event => { if (!allowLeave.current && window.projectbookEditorDirty?.()) { event.preventDefault(); event.returnValue = ''; } };
      window.addEventListener('beforeunload', warn);
      return () => window.removeEventListener('beforeunload', warn);
    }, []);
    const restore = () => {
      todos.restore(draft.todos); todos.setDocument(draft.content,path);
      pending.current.forEach(file => URL.revokeObjectURL(file.url));
      pending.current = (draft.files || []).map(file => ({...file, url: URL.createObjectURL(file.blob)}));
      setFiles([...pending.current]);
      if (isNew && draft.destination) destination.current = draft.destination;
      if (isNew && draft.filename) { name.current = draft.filename; setFilename(draft.filename); }
      current.current = draft.content; ref.current.setMarkdown(draft.content); setHeadingTitle(documentTitle(draft.content, ''));
      setHasTextChanges(draft.content !== initial);
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
    function insert(markdown, event, layout = 'block') {
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
          if (layout === 'todo') {
            // TODOs are inline references. Do not use the attachment helper's
            // two paragraph splits; only leave one line break after the row.
            editor.update(() => {
              const selection = $getSelection();
              if ($isRangeSelection(selection) && selection.anchor.getNode().getTopLevelElement()?.getType() === 'heading') selection.insertParagraph();
            }, {discrete: true});
            ref.current.insertMarkdown(markdown);
            editor.update(() => { const selection = $getSelection(); if ($isRangeSelection(selection)) selection.insertLineBreak(); }, {discrete: true});
            return;
          }
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
      if (!discard && titleEditing && !applyTitle()) return;
      try {
        clearTimeout(draftTimer.current);
        await queue.current.catch(() => {});
        if (discard) await draftStore('delete', draftKey); else if (dirty()) await stash();
        if (discard) localStorage.removeItem('projectbook:mdx:draft:' + location.pathname);
        allowLeave.current = true; location.assign(closeUrl);
      } catch (_) { setStatus('Could not store or discard the browser draft. Keep this tab open until Save succeeds.'); }
    }
    async function deleteDocument() {
      if(working.current || isNew)return;
      working.current=true;setBusy(true);setStatus('Deleting document…');
      try {
        await stash().catch(()=>{});
        const response=await fetch(base+(folderPage ? '/gollum/projectbook/folder-delete/confirm' : '/gollum/projectbook/delete'),{
          method:'POST',headers:{'Content-Type':'application/json','X-ProjectWiki-Request':'1'},
          body:JSON.stringify(folderPage ? {folder:folderPath,revision:deletePreview?.revision,confirmed_folder:folderPath} : {path,etag:form.dataset.etag})
        });
        const result=await response.json();
        if(!response.ok || !result.url)throw new Error(result.error || 'Delete failed. Your draft is kept.');
        clearTimeout(draftTimer.current);await queue.current.catch(()=>{});
        await draftStore('delete',draftKey).catch(()=>{});
        localStorage.removeItem('projectbook:mdx:draft:'+location.pathname);
        allowLeave.current=true;location.assign(result.url);
      } catch(error){setStatus(error.message || 'No deletion confirmation. Check the connection before retrying.');}
      finally{working.current=false;setBusy(false);}
    }
    async function save(event, requestedPath) {
      event?.preventDefault();
      if (working.current) return;
      if (titleEditing && !applyTitle()) return;
      const savePath = requestedPath || targetPath();
      if (isNew && (!name.current.trim() || /[\\/]/.test(name.current) || !/\.md$/i.test(name.current.trim()))) { setStatus('Enter a Markdown filename ending in .md, without folder separators.'); return; }
      working.current = true; setBusy(true); setStatus('Preparing save…');
      let content;
      try { content = documentTitle(current.current, '') ? current.current : withDocumentTitle(current.current, fallbackTitle); if(isNew)content=rebaseMarkdown(content,path,savePath); }
      catch (_) { working.current = false; setBusy(false); setStatus('Could not update relative links. Keep the current path and save your edits first.'); return; }
      // An undone/deleted insertion must not leave an orphan in the Git book.
      const used = pending.current.filter(file => current.current.includes(file.source));
      let moveRevision;
      if(!isNew && savePath!==path){
        try{
          setStatus('Checking links…');
          const response=await fetch(base+'/gollum/projectbook/move/preview',{method:'POST',headers:{'Content-Type':'application/json','X-ProjectWiki-Request':'1'},body:JSON.stringify({source:path,target:savePath,content,etag:form.dataset.etag})});
          const preview=await response.json();if(!response.ok)throw new Error(preview.error || 'Move preview failed.');
          if(!await confirmMove(preview,path,savePath)){working.current=false;setBusy(false);setStatus('Move canceled.');return;}
          moveRevision=preview.revision;
        }catch(error){working.current=false;setBusy(false);setStatus(error.message);return;}
      }
      const data = new FormData();
      data.append('document', JSON.stringify({path: savePath, source_path: path, content, move_revision:moveRevision, todos: pendingTodos(todos.pending(), current.current, path), create: isNew, etag: form.dataset.etag, attachments: used.map(file => ({path: file.path}))}));
      data.append('message', !isNew && savePath !== path && summary === `Updated ${path}` ? `Move ${path} to ${savePath}` : summary === `Created ${path}` ? `Created ${savePath}` : summary || `Updated ${savePath}`);
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
      integration(), todoPlugin({store:todos,path}), headingsPlugin(), listsPlugin(), quotePlugin(), calloutsPlugin(), footnotesPlugin(), thematicBreakPlugin(), linkPlugin(), linkDialogPlugin({onClickLinkCallback: source => {
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
      toolbarPlugin({toolbarContents: () => {
        const todoTools=<TodoToolbar store={todos} onError={setStatus} onInsert={(item,status)=>insert(todoLink(item,path,status),null,'todo')}/>;
        return <EditorToolbar sourceTools={<><span>Markdown</span>{todoTools}</>}>
          <UndoRedo/><Separator/><CalloutBlockType/><BoldItalicUnderlineToggles/><Separator/>
          <span className="pb-editor-list-tools"><ListsToggle/>{todoTools}</span><CreateLink/>{folderPage&&<button type="button" title="Insert dynamic subpages block" aria-label="Insert subpages" onClick={()=>insert('[Pages](#projectbook-pages)',null)}>☷</button>}<InsertFootnote/><InsertImage/><InsertTable/><InsertCodeBlock/>
        </EditorToolbar>;
      }})
    ], []);
    return <>
      <div className="pb-document-heading">
        {titleEditing ? <div className="pb-title-editor">
          <input ref={titleInput} className="form-control" aria-label="Document title" value={titleValue} disabled={busy}
            onChange={event => setTitleValue(event.target.value)} onKeyDown={event => {
              if (event.key === 'Enter') { event.preventDefault(); applyTitle(); }
              if (event.key === 'Escape') { event.preventDefault(); setTitleEditing(false); }
            }}/>
          <button type="button" className="btn btn-sm" title="Apply title" aria-label="Apply title" disabled={busy} onClick={applyTitle}>✓</button>
          <button type="button" className="btn btn-sm" title="Cancel title edit" aria-label="Cancel title edit" disabled={busy} onClick={() => setTitleEditing(false)}>×</button>
        </div> : <h1 className="header-title"><button type="button" className="pb-title-button" title="Edit document title" aria-label="Edit document title" disabled={busy} onClick={openTitle}>{displayTitle}</button></h1>}
        <button type="button" className="btn btn-sm" title="Rename title" aria-label="Rename title" disabled={busy} onClick={openTitle}>
          <svg aria-hidden="true" viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" strokeWidth="1.6"><path d="m15 4 5 5M4 20l5-1L21 7a2 2 0 0 0-5-5L4 14Z"/></svg>
        </button>
        <button type="button" className="btn btn-sm" title="Move" aria-label="Move" disabled={busy} onClick={openMove}>
          <svg aria-hidden="true" viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" strokeWidth="1.6"><path d="M3 7h7l2 2h9v11H3ZM3 7V4h7l2 3M8 14h9m-3-3 3 3-3 3"/></svg>
        </button>
        {!isNew && <button type="button" className="btn btn-sm" title="Delete document" aria-label="Delete document" disabled={busy} onClick={openDelete}>
          <svg aria-hidden="true" viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" strokeWidth="1.6"><path d="M3 6h18M9 6V3h6v3M5 6l1 15h12l1-15M10 10v7m4-7v7"/></svg>
        </button>}
      </div>
      {deleteOpen && <dialog ref={deleteDialog} className="pb-move-dialog" aria-labelledby="pb-delete-title" onCancel={event=>{if(busy)event.preventDefault();else setDeleteOpen(false);}}>
        <h2 id="pb-delete-title">{folderPage ? 'Delete entire folder?' : 'Delete document?'}</h2>
        <p><strong>{displayTitle} — /{folderPage ? folderPath : path}</strong></p>
        {folderPage ? <p>Delete this folder and ALL subfolders, pages and attachments inside it. {deletePreview ? `${deletePreview.files} files (${deletePreview.documents} Markdown documents) will be removed.` : 'Loading deletion preview…'} Git history is kept. This confirmation cannot be disabled.</p> : <p>The page will be removed from the book. Its saved versions remain in Git history. Attachments and separate TODO files are kept.</p>}
        {(dirty() || draft) && <p>Unsaved edits in this editor will be discarded.</p>}
        <div role="status" className="pb-editor-status">{status}</div>
        <div className="pb-editor-actions">
          <button autoFocus type="button" className="btn" disabled={busy} onClick={()=>setDeleteOpen(false)}>Cancel</button>
          <button type="button" className="btn btn-danger" disabled={busy || (folderPage && !deletePreview)} onClick={deleteDocument}>{folderPage ? 'Delete entire folder' : 'Delete document'}</button>
        </div>
      </dialog>}
      <p className="pb-document-location">/{targetPath()}</p>
      {titleEditing && <p className="pb-title-hint">The title is the first # heading in Markdown. The filename and URL stay unchanged. Enter to apply, Escape to cancel.</p>}
      {moveOpen && <dialog ref={moveDialog} className="pb-move-dialog" aria-labelledby="pb-move-title"
        onCancel={event => { if (busy) event.preventDefault(); else setMoveOpen(false); }}>
        <h2 id="pb-move-title">{folderPage ? 'Move folder' : 'Move document'}</h2>
        <p>Current path: <strong>/{targetPath()}</strong></p>
        <label>{folderPage ? 'New folder path' : 'New document path'}<input autoFocus className="form-control" aria-label="New document path" value={movePath} disabled={busy}
          onKeyDown={event => { if (event.key === 'Enter') event.preventDefault(); }} onChange={event => setMovePath(event.target.value)}/></label>
        <p>New path: <strong>/{movePath.trim().replace(/^\//, '')}</strong></p>
        <p>{folderPage ? 'Use a folder path from the book root. The entire subtree moves together, preserving its order.' : 'Use a full path from the book root, including the Markdown extension. Missing folders will be created.'}</p>
        <p>{isNew ? 'This chooses where the document will be saved. Nothing is created until Save.' : 'The document and any unsaved edits will be saved together at the new path. The old file will be removed.'}</p>
        <p>Links inside this document and incoming links elsewhere in the book will be updated. Review affected files before confirming.</p>
        <div role="status" className="pb-editor-status">{status}</div>
        <div className="pb-editor-actions">
          <button type="button" className="btn" disabled={busy} onClick={() => setMoveOpen(false)}>Cancel</button>
          <button type="button" className="btn btn-primary" disabled={busy || !movePath.trim() || movePath.trim().replace(/^\//, '').replace(/\/$/, '') === (folderPage ? folderPath : targetPath())}
            onClick={() => {
              const next = movePath.trim().replace(/^\//, '').replace(/\/$/,'') + (folderPage ? '/.index.md' : '');
              if (isNew) { destination.current = next; name.current = next.split('/').pop(); setFilename(name.current); setMoveOpen(false); stashSoon(); }
              else save(null, next);
            }}>{isNew ? 'Use this path' : 'Preview move'}</button>
        </div>
      </dialog>}
      {draft && <div className="pb-draft-banner">A browser draft is available. <button type="button" className="btn btn-sm" disabled={busy} onClick={restore}>Restore draft</button></div>}
      <div className="pb-editor-actions">
        <button type="submit" className="btn btn-primary" disabled={busy}>Save</button>
        <button type="button" className="btn" disabled={busy} onClick={() => close(false)}>Close and keep draft</button>
        <button type="button" className="btn" disabled={busy} onClick={() => dirty() || draft ? setConfirmDiscard(true) : close(true)}>Discard</button>
        <span id="projectbook-editor-modes"/>
        {form.dataset.uploads === 'true' && <button type="button" className="btn" disabled={busy} onClick={() => picker.current.click()}>Attach files</button>}
        <button type="button" className="btn" onClick={download}>Download Markdown</button>
        <input ref={picker} hidden type="file" multiple onChange={event => { attach(event.target.files); event.target.value = ''; }}/>
      </div>
      {confirmDiscard && <div className="pb-draft-banner" role="alert">
        Discard this draft and its unsaved attachments?{' '}
        <button type="button" className="btn btn-sm" onClick={() => close(true)}>Discard draft</button>{' '}
        <button type="button" className="btn btn-sm" onClick={() => setConfirmDiscard(false)}>Keep editing</button>
      </div>}
      <div className="pb-editor-status" role="status" aria-live="polite">{status.startsWith('Title updated.') && !dirty() ? '' : status}</div>
      <div className="pb-change-state" role="status">{hasTextChanges || dirty() ? 'Unsaved changes' : 'No unsaved changes'}</div>
      <TodoMessages store={todos}/>
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
