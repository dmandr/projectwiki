import './callouts.css';
import React from 'react';
import {createRoot} from 'react-dom/client';
import {inlineStore,useInlineTodos,InlineTodoBoard,InlineTodoList,InlineTaskRow} from './inline-todo-ui';
import {readTodo,readTodoList} from './inline-todo-format.mjs';
const host=document.getElementById('projectbook-tasks-app');
const config=document.getElementById('projectbook-todos-script');
const base=window.baseUrl||'',revision=config?.dataset.revision||'',path=window.pageFullPath||'Home.md';
const store=inlineStore({base,revision});
if(config?.dataset.pageVersion)store.sourceVersions[path]=config.dataset.pageVersion;
function TaskAt({ordinal}){const state=useInlineTodos(store),task=state.tasks.filter(t=>t.path===path)[ordinal];if(task&&store.sourceVersions[path]&&task.version!==store.sourceVersions[path])return <span>Document changed. Reload this page to see its TODOs.</span>;return task?<InlineTaskRow store={store} task={task} direct/>:<span>{state.loading?'Loading TODO…':'TODO source unavailable'}</span>;}
function ErrorNotice(){const state=useInlineTodos(store);return state.error?<p role="alert">{state.error} <button onClick={()=>store.load()}>Refresh TODOs</button></p>:null;}
if(host){createRoot(host).render(<InlineTodoBoard store={store}/>);store.load();}
else{
 let ordinal=0,mounted=false;
 for(const anchor of document.querySelectorAll('#wiki-content a')){
  if(anchor.closest('pre,code'))continue;
  const href=anchor.getAttribute('href')||'';
  // Gollum may expand relative metadata URLs; use its original href when available.
  const raw=anchor.dataset.inlineTodoUrl??href;
  if(!readTodo(anchor.textContent,raw))continue;
  const element=document.createElement('span');anchor.replaceWith(element);
  createRoot(element).render(<TaskAt ordinal={ordinal++}/>);mounted=true;
 }
 for(const p of document.querySelectorAll('#wiki-content p')){
  const query=readTodoList(p.textContent);if(!query)continue;
  const element=document.createElement('div');p.replaceWith(element);createRoot(element).render(<InlineTodoList store={store} query={query}/>);mounted=true;
 }
 if(mounted){
  const errors=document.createElement('div');document.getElementById('wiki-content').append(errors);createRoot(errors).render(<ErrorNotice/>);
  store.load().then(()=>requestAnimationFrame(()=>{if(location.hash.startsWith('#todo-at-'))document.getElementById(location.hash.slice(1))?.scrollIntoView({block:'center'});}));
 }
}
