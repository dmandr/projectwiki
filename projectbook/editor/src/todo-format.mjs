import { fromMarkdown } from 'mdast-util-from-markdown';
const uuid = '[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}';
export function todoReference(url, label, path = 'Home.md') {
  try {
    const resolved = new URL(url, 'https://book.invalid/' + path.split('/').map(encodeURIComponent).join('/'));
    if (resolved.origin !== 'https://book.invalid') return null;
    const match = decodeURIComponent(resolved.pathname).match(new RegExp('^/(Tasks|TaskLists|\\.projectbook/tasks|\\.projectbook/task-lists)/(' + uuid + ')(?:\\.md)?$'));
    if (!match) return null;
    const kind = ['Tasks','.projectbook/tasks'].includes(match[1]) ? 'task' : 'list';
    if (!(kind === 'task' ? /^TODO:/ : /^TODO list:/).test(label)) return null;
    const status = resolved.searchParams.get('status') || '';
    if (!['','open','done'].includes(status)) return null;
    return {kind, id:match[2], status, url, label};
  } catch { return null; }
}
export function todoReferences(markdown, path) {
  const refs=[];
  const visit = node => {
    if (node.type === 'link') {
      const label=(node.children || []).map(child=>child.value || '').join('');
      const ref=todoReference(node.url,label,path); if (ref) refs.push(ref);
    }
    for (const child of node.children || []) visit(child);
  };
  visit(fromMarkdown(markdown)); return refs;
}
export function todoLink(item, path, status = '') {
  const label=(item.kind === 'list' ? 'TODO list: ' : 'TODO: ') + item.title;
  const target=(item.kind === 'list' ? '.projectbook/task-lists/' : '.projectbook/tasks/') + item.id + '.md';
  const url='../'.repeat(path.split('/').length-1) + target + (status ? '?status='+status : '');
  return `[${label.replace(/[\\[\]]/g,'\\$&')}](${url})`;
}
export function pendingTodos(pending, markdown, path) {
  const refs=todoReferences(markdown,path);
  const tasks=pending.filter(item=>item.kind === 'task' && (item.expected_version || refs.some(ref=>ref.kind === 'task' && ref.id === item.id)));
  const lists=pending.filter(item=>item.kind === 'list' && (item.expected_version || refs.some(ref=>ref.kind === 'list' && ref.id === item.id) || tasks.some(task=>task.list_id === item.id)));
  return [...lists,...tasks];
}

// Resolve against the document path, not the current history URL ending in /SHA.
export function renderedTodoReference(href,label,path,base='',origin='https://book.invalid') {
  try {
    const url=new URL(href,new URL(base+'/'+path,origin));
    if(url.origin!==origin || !url.pathname.startsWith(base+'/'))return null;
    return todoReference(url.pathname.slice(base.length)+url.search,label);
  } catch { return null; }
}

export function todoSourceUrl(task,base='',revision='') {
  const path=task.source_target || task.source_path || task.path || '.projectbook/tasks/'+task.id+'.md';
  return base+'/'+path.split('/').map(encodeURIComponent).join('/')+(revision?'/'+revision:'')+'#todo-'+task.id;
}
