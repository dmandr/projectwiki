import React from 'react';
import {createPortal} from 'react-dom';
import {cleanTags,matchesTodo,completedNow} from './inline-todo-format.mjs';
import './todo.css';
export function inlineStore({base='',revision='',readOnly=false}={}){
  let state={tasks:[],tags:[],loading:true,editable:false,error:'',busy:false};const listeners=new Set();
  const update=data=>{state={...state,...data};listeners.forEach(f=>f());};
  const store={snapshot:()=>state,subscribe:fn=>{listeners.add(fn);return ()=>listeners.delete(fn);},base,revision,sourceVersions:{},
    async load(){try{const r=await fetch(base+'/gollum/projectbook/inline-todos'+(revision?'?revision='+encodeURIComponent(revision):''),{cache:'no-store'});const data=await r.json();if(!r.ok)throw Error(data.error||'Could not load TODOs');update({...data,editable:!readOnly&&data.editable,loading:false,error:''});}catch(e){update({loading:false,error:e.message});}},
    async change(task,changes){
      update({busy:true,error:''});
      try{const r=await fetch(base+'/gollum/projectbook/inline-todos',{method:'POST',headers:{'Content-Type':'application/json','X-ProjectWiki-Request':'1'},body:JSON.stringify({changes:[{path:task.path,start:task.start,expected_version:task.version,title:task.title,done:task.done,tags:task.tags,...changes}]})});const result=await r.json();if(!r.ok)throw Error(result.error||'Could not save TODO');Object.assign(store.sourceVersions,result.versions||{});await store.load();window.dispatchEvent(new Event('projectbook:changed'));return true;}
      catch(e){update({error:e.message});return false;}finally{update({busy:false});}
    }};return store;
}
export const useInlineTodos=store=>React.useSyncExternalStore(store.subscribe,store.snapshot);
export function TagsDialog({tasks,available=[],onApply,onClose}){
  const dialog=React.useRef(null),[extra,setExtra]=React.useState(''),[changes,setChanges]=React.useState({});
  React.useEffect(()=>{dialog.current.showModal();},[]);
  const tags=cleanTags([...available,...tasks.flatMap(t=>t.tags)]);
  const state=tag=>Object.hasOwn(changes,tag)?changes[tag]:tasks.every(t=>t.tags.includes(tag))?true:tasks.some(t=>t.tags.includes(tag))?'mixed':false;
  return createPortal(<dialog ref={dialog} className="pb-todo-picker" onCancel={e=>{e.preventDefault();onClose();}} onKeyDown={e=>e.stopPropagation()}>
    <header><h2>Tags · {tasks.length} tasks selected</h2><button type="button" aria-label="Close tags" onClick={onClose}>×</button></header>
    <p>Only changed tags are applied. Other tags stay unchanged.</p>
    <div className="pb-todo-picker-chips">{tags.map(tag=><label key={tag}><input type="checkbox" aria-label={'Tag '+tag} checked={state(tag)===true} ref={el=>{if(el)el.indeterminate=state(tag)==='mixed';}} onChange={()=>setChanges({...changes,[tag]:state(tag)!==true})}/>{tag}</label>)}</div>
    <label>Add tags<input aria-label="Add tags" placeholder="spring, engine" value={extra} onChange={e=>setExtra(e.target.value)}/></label>
    <button type="button" onClick={()=>{onApply({add:cleanTags([...Object.keys(changes).filter(t=>changes[t]),...extra.split(',')]),remove:Object.keys(changes).filter(t=>!changes[t])});onClose();}}>Apply tags</button>
  </dialog>,document.body);
}
export function InlineTaskRow({store,task,direct=false}){
  const s=useInlineTodos(store),[editing,setEditing]=React.useState(false),[title,setTitle]=React.useState(task.title);
  const source=store.base+'/'+task.path.split('/').map(encodeURIComponent).join('/')+(store.revision?'/'+store.revision:'')+'#todo-at-'+task.start;
  return <span className="pb-inline-row" id={direct?'todo-at-'+task.start:undefined}>
    <input type="checkbox" aria-label={'Complete '+task.title} checked={!!task.done} disabled={!s.editable||s.busy} onChange={()=>store.change(task,{done:task.done?'':completedNow()})}/>{' '}
    {editing ? <><input aria-label="Task text" value={title} onChange={e=>setTitle(e.target.value)} maxLength={2000}/><button type="button" onClick={async()=>{if(await store.change(task,{title}))setEditing(false);}}>Save</button><button type="button" onClick={()=>setEditing(false)}>Cancel</button></> : direct ? <span className={task.done?'pb-task-done':''}>{task.title}</span> : <><a href={source} title={'Open source: '+task.path} className={task.done?'pb-task-done':''}>{task.title}</a>{s.editable&&<button className="pb-inline-edit" type="button" title="Edit task text" aria-label={'Edit '+task.title} onClick={()=>{setTitle(task.title);setEditing(true);}}>✎</button>}</>}
  </span>;
}
export function InlineTodoList({store,query={}}){
  const s=useInlineTodos(store),tasks=s.tasks.filter(t=>matchesTodo(t,query));
  return <span className="pb-todo-list"><span className="pb-todo-list-heading">{query.tags?.join(' · ')||'TODO'}</span>{tasks.map(t=><InlineTaskRow key={t.path+':'+t.start} store={store} task={t}/>)}{!tasks.length&&<span className="pb-todo-empty">{s.loading?'Loading…':'No matching tasks.'}</span>}{s.error&&<span role="alert">{s.error}</span>}</span>;
}
export function InlineTodoBoard({store}){
  const s=useInlineTodos(store),[tag,setTag]=React.useState(''),[status,setStatus]=React.useState(''),[query,setQuery]=React.useState('');
  const tasks=s.tasks.filter(t=>matchesTodo(t,{tags:tag?[tag]:[],status})&&t.title.toLocaleLowerCase().includes(query.toLocaleLowerCase()));
  return <div className="pb-todo-board"><p>Tasks are defined in their source documents. Click a task to open its source.</p><div className="pb-todo-filters"><label>Tag<select value={tag} onChange={e=>setTag(e.target.value)}><option value="">All tags</option>{s.tags.map(t=><option key={t}>{t}</option>)}</select></label><label>Status<select value={status} onChange={e=>setStatus(e.target.value)}><option value="">All tasks</option><option value="open">Open</option><option value="done">Done</option></select></label><label>Search<input value={query} onChange={e=>setQuery(e.target.value)}/></label><button onClick={()=>store.load()}>Refresh</button></div>{s.error&&<p role="alert">{s.error}</p>}{tasks.map(t=><div key={t.path+':'+t.start}><InlineTaskRow store={store} task={t}/><small>{t.path} · line {t.line}</small></div>)}</div>;
}
