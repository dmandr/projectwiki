import './callouts.css';
import React from 'react';
import {createRoot} from 'react-dom/client';
import {todoStore,TodoBoard,TodoMessages,TaskRow,TodoList} from './todo-ui';
import {todoReference,renderedTodoReference} from './todo-format.mjs';
const host=document.getElementById('projectbook-tasks-app');
const config=document.getElementById('projectbook-todos-script');
const base=window.baseUrl || '', revision=config?.dataset.revision || '';
const anchors=Array.from(document.querySelectorAll('#wiki-content a[href]')).filter(a=>!a.closest('pre,code'));
const targets=anchors.flatMap(anchor=>{
  const ref=renderedTodoReference(anchor.getAttribute('href'),anchor.textContent,window.pageFullPath || 'Home.md',base,location.origin);
  return ref?[{anchor,ref}]:[];
});
const selfPath='/' + (window.pageFullPath || '');
const selfRef=todoReference(selfPath,'TODO list:') || todoReference(selfPath,'TODO:');
if (host || targets.length || selfRef) {
  const store=todoStore({base,revision});store.load();
  if(host)createRoot(host).render(<TodoBoard store={store}/>);
  else {
    if (selfRef) {
      const body=document.getElementById('wiki-body');
      const element=document.createElement('span');element.className='pb-todo-token';body?.prepend(element);
      createRoot(element).render(selfRef.kind==='task'?<TaskRow store={store} id={selfRef.id} direct/>:<TodoList store={store} id={selfRef.id}/>);
      for(const pre of body?.querySelectorAll('pre') || []) {
        try {
          const metadata=JSON.parse(pre.textContent);
          if(metadata.id!==selfRef.id || metadata.kind!==selfRef.kind)continue;
          pre.remove();
        } catch {}
      }
    }
    for(const {anchor,ref} of targets){
      const li=anchor.closest('li');
      if(ref.kind==='task' && li && li.querySelectorAll('a[href]').length===1) {
        { const checkbox=li.querySelector(':scope > input[type="checkbox"], :scope > p > input[type="checkbox"]'); if(checkbox){checkbox.remove();li.classList.add('pb-managed-check-item');} }
      }
      const element=document.createElement('span');element.className='pb-todo-token';
      anchor.replaceWith(element);
      createRoot(element).render(ref.kind==='task'?<TaskRow store={store} id={ref.id} direct/>:<TodoList store={store} id={ref.id} status={ref.status}/>);
    }
    const panel=document.createElement('div');document.getElementById('wiki-content')?.append(panel);
    createRoot(panel).render(<TodoMessages store={store}/>);
  }
}
