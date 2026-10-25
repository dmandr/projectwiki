import {rebaseMarkdown} from './move-links.mjs';
import {dropIntent, parentPath} from './tree-drag.mjs';

const tree = document.getElementById('projectbook-tree');
if (tree?.dataset.editable === 'true' && !document.getElementById('gollum-editor-form')) {
  const base = window.baseUrl || '';
  const root = document.getElementById('projectbook-root-drop');
  const notice = document.getElementById('projectbook-tree-notice');
  const start = document.createElement('div');
  start.className = 'projectbook-tree-start';
  start.textContent = 'Drop here to place first';
  start.setAttribute('aria-hidden', 'true');
  tree.prepend(start);
  let source, intent, targetRow, busy = false;
  let revision = tree.dataset.revision;
  const rowFor = link => link.closest('li');
  const rowPath = row => row.dataset.folder ?? row.querySelector(':scope > a[data-document]')?.dataset.document;
  const rowLink = row => row.querySelector(':scope > a[data-document], :scope > .projectbook-tree-row > a');
  function clear() {
    document.querySelectorAll('.pb-drop-before,.pb-drop-after,.pb-drop-inside').forEach(el => el.classList.remove('pb-drop-before','pb-drop-after','pb-drop-inside'));
    intent = targetRow = null;
  }
  async function api(path, payload) {
    const response = await fetch(base + path, payload ? {method:'POST',headers:{'Content-Type':'application/json','X-ProjectWiki-Request':'1'},body:JSON.stringify(payload)} : {cache:'no-store'});
    const data = await response.json(); if (!response.ok) throw new Error(data.error || 'Tree operation failed'); return data;
  }
  tree.querySelectorAll('a[data-document],a[data-folder-link]').forEach(link => {
    link.draggable = true;
    link.addEventListener('dragstart', event => {
      if (busy || document.getElementById('projectbook-search').value.trim()) { event.preventDefault(); return; }
      source = rowFor(link);
      tree.classList.add('pb-dragging');
      event.dataTransfer.effectAllowed = 'move'; event.dataTransfer.setData('text/plain', rowPath(source));
      notice.textContent = 'Drop between rows to reorder; on a folder to move. Drop on Explorer to move to the root.';
    });
    link.addEventListener('dragend', () => { clear(); tree.classList.remove('pb-dragging'); source = null; if (!busy) notice.textContent = ''; });
  });
  function over(event) {
    clear(); if (!source || busy) return;
    if (event.currentTarget === root) {
      if (!parentPath(rowPath(source))) return;
      intent = {action:'move',folder:''}; targetRow = root;
    } else if (event.target.closest('.projectbook-tree-start')) {
      targetRow = tree.querySelector(':scope > ul > li');
      if (!targetRow || parentPath(rowPath(source)) || source === targetRow) return;
      intent = {action:'reorder',folder:'',position:'before'};
    } else {
      targetRow = event.target.closest('li');
      if (!targetRow || !tree.contains(targetRow)) return;
      const row = targetRow.querySelector(':scope > .projectbook-tree-row') || rowLink(targetRow);
      if (!row) return;
      const rect = row.getBoundingClientRect();
      intent = dropIntent(rowPath(source),rowPath(targetRow),targetRow.hasAttribute('data-folder'),(event.clientY-rect.top)/rect.height);
    }
    if (!intent || (intent.action === 'move' && source.hasAttribute('data-folder'))) { clear(); return; }
    event.preventDefault(); event.dataTransfer.dropEffect = 'move';
    const marker = targetRow === root ? root : rowLink(targetRow);
    marker.classList.add(intent.action === 'move' ? 'pb-drop-inside' : 'pb-drop-' + intent.position);
    notice.textContent = intent.action === 'move' ? 'Move into ' + (intent.folder || 'the book root') : 'Place ' + intent.position + ' ' + rowLink(targetRow).textContent.trim();
  }
  async function drop(event) {
    if (!intent || !source || busy) return;
    event.preventDefault();
    const item = source, target = targetRow, operation = {...intent,source:rowPath(source),revision};
    clear(); busy = true;
    try {
      if (operation.action === 'move') {
        const settings = await api('/gollum/projectbook/settings/navigation');
        const destination = [operation.folder, operation.source.split('/').at(-1)].filter(Boolean).join('/');
        if (settings.confirm_move && !window.confirm('Move ' + operation.source + '\nto ' + destination + '?\n\nLinks inside this document will be adjusted. Links to it from other documents are not changed.')) { notice.textContent = 'Move canceled.'; return; }
        const doc = await api('/gollum/projectbook/tree/document?path=' + encodeURIComponent(operation.source));
        if (doc.revision !== revision) throw new Error('The book changed. Reload the tree and try again.');
        operation.content = doc.content === null ? null : rebaseMarkdown(doc.content,operation.source,destination); operation.etag = doc.etag;
      } else {
        const siblings = [...item.parentElement.children].filter(row => row !== item);
        const index = siblings.indexOf(target) + (operation.position === 'after' ? 1 : 0);
        operation.before = siblings[index] ? rowPath(siblings[index]).split('/').at(-1) : null;
      }
      notice.textContent = 'Saving…';
      const result = await api('/gollum/projectbook/tree',operation); revision = result.revision; tree.dataset.revision = revision;
      if (operation.action === 'reorder') {
        if (operation.position === 'before') target.before(item); else target.after(item);
        notice.textContent = result.unchanged ? 'Order unchanged.' : 'Order saved.';
      } else {
        // Reload only after a mutation; ordinary navigation keeps its existing behavior.
        const key = 'projectwiki:tree:v2:' + base;
        try { const state = JSON.parse(localStorage.getItem(key) || '{}'); const parts = operation.folder.split('/').filter(Boolean); parts.forEach((_,i) => state[parts.slice(0,i+1).join('/')] = true); localStorage.setItem(key,JSON.stringify(state)); } catch (_) {}
        const current = item.querySelector('[aria-current="page"]');
        if (current) location.assign(base + (/\.(md|markdown)$/i.test(result.path) ? '/' : '/gollum/file/') + result.path.split('/').map(encodeURIComponent).join('/'));
        else location.reload();
      }
    } catch (error) { notice.textContent = error instanceof TypeError ? 'No server confirmation. Reload to check whether the change was saved.' : error.message; }
    finally { busy = false; source = null; }
  }
  [tree,root].forEach(element => { element.addEventListener('dragover',over); element.addEventListener('drop',drop); });
}
