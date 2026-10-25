import React from 'react';
import {createPortal} from 'react-dom';
import {useCellValue} from '@mdxeditor/gurx';
import {viewMode$} from '@mdxeditor/editor';
import {useTodos} from './todo-ui';
import {filterTodoTasks,matchesTodoQuery} from './todo-search.mjs';

function Icon({kind}) {
  return <svg aria-hidden="true" viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round">
    {kind==='new'?<><rect x="3" y="5" width="11" height="14" rx="2"/><path d="m6 11 2 2 3-4M18 8v8m-4-4h8"/></>:kind==='task'?<><rect x="3" y="3" width="11" height="14" rx="2"/><path d="m6 9 2 2 3-4M13 16l3-3a3 3 0 0 1 4 4l-3 3a3 3 0 0 1-4-4m2 2 3-3"/></>:<><rect x="3" y="3" width="18" height="18" rx="2"/><path d="m6 8 1 1 2-2m-3 6 1 1 2-2m-3 6 1 1 2-2M12 8h6m-6 5h6m-6 5h6"/></>}
  </svg>;
}

function TodoPicker({kind,store,onClose,onInsert}) {
  const s=useTodos(store),dialog=React.useRef(null),search=React.useRef(null);
  const [query,setQuery]=React.useState(''),[selected,setSelected]=React.useState(()=>s.lists.map(list=>list.id));
  const [limit,setLimit]=React.useState(50),[status,setStatus]=React.useState(''),[name,setName]=React.useState(''),[error,setError]=React.useState('');
  React.useEffect(()=>{dialog.current.showModal();search.current.focus();},[]);
  React.useEffect(()=>setLimit(50),[query,selected]);
  const isTask=kind==='task';
  const matches=isTask?filterTodoTasks(s.tasks,query,selected):s.lists.filter(list=>matchesTodoQuery(list.title,query));
  const counts=new Map();for(const task of s.tasks)if(matchesTodoQuery(task.title,query))counts.set(task.list_id,(counts.get(task.list_id)||0)+1);
  const close=()=>{dialog.current.close();onClose();};
  function choose(item) {
    if(s.busy)return;
    dialog.current.close();
    onInsert(item,isTask?'':status);onClose();
  }
  async function createList() {
    if(!name.trim() || s.busy)return;
    const existing=s.lists.find(list=>list.title.toLocaleLowerCase()===name.trim().toLocaleLowerCase());
    const item=existing || {kind:'list',id:crypto.randomUUID(),title:name.trim(),expected_version:''};
    if(existing || await store.change([item]))choose(item);else setError('Could not create list. Try again.');
  }
  return createPortal(<dialog ref={dialog} className="pb-todo-picker" aria-labelledby="pb-todo-picker-title"
    onCancel={event=>{event.preventDefault();close();}} onKeyDown={event=>event.stopPropagation()}>
    <header><h2 id="pb-todo-picker-title">{isTask?'Insert existing TODO':'Insert TODO list'}</h2><button type="button" aria-label="Close TODO picker" onClick={close}>×</button></header>
    {isTask && <section className="pb-todo-picker-groups" aria-label="Filter by TODO list">
      <div className="pb-todo-picker-group-actions"><span>Lists</span><button type="button" onClick={()=>setSelected(s.lists.map(list=>list.id))}>All lists</button><button type="button" onClick={()=>setSelected([])}>Clear</button></div>
      <div className="pb-todo-picker-chips">{s.lists.map(list=><button key={list.id} type="button" aria-label={'Filter list '+list.title} aria-pressed={selected.includes(list.id)} onClick={()=>setSelected(ids=>ids.includes(list.id)?ids.filter(id=>id!==list.id):[...ids,list.id])}>{list.title}<span>{counts.get(list.id)||0}</span></button>)}</div>
    </section>}
    <input ref={search} type="search" className="pb-todo-picker-search" aria-label={isTask?'Search tasks':'Search TODO lists'} placeholder={isTask?'Search tasks…':'Search lists…'} value={query} onChange={event=>setQuery(event.target.value)} onKeyDown={event=>{
      if(event.key==='Enter'){event.preventDefault();if(matches.length)choose(matches[0]);}
      if(event.key==='ArrowDown'){event.preventDefault();dialog.current.querySelector('[data-todo-choice]')?.focus();}
    }}/>
    {!isTask && <label className="pb-todo-picker-status">Show tasks <select aria-label="Show tasks" value={status} onChange={event=>setStatus(event.target.value)}><option value="">All tasks</option><option value="open">Open tasks</option><option value="done">Done tasks</option></select></label>}
    <div className="pb-todo-picker-count" role="status">{matches.length} {isTask?'tasks':'lists'}</div>
    <div className="pb-todo-picker-results">
      {matches.slice(0,limit).map(item=><button type="button" data-todo-choice key={item.id} className="pb-todo-picker-result" disabled={s.busy} onClick={()=>choose(item)}>
        {isTask && <span aria-label={item.status==='done'?'Done':'Open'} className="pb-todo-picker-check">{item.status==='done'?'☑':'☐'}</span>}
        <span className="pb-todo-picker-result-text"><span className={item.status==='done'?'pb-task-done':''}>{item.title}</span>{isTask && <small>{item.source_references?.[0] || item.source_path || item.path}{item.source_references?.length>1?' · '+item.source_references.length+' documents':''}</small>}</span>
        {isTask && <span className="pb-task-tag">{s.lists.find(list=>list.id===item.list_id)?.title || 'Missing list'}</span>}
      </button>)}
      {!matches.length && <p>{isTask && !selected.length?'Select at least one list.':'No matches. Try another search or list.'}</p>}
      {matches.length>limit && <button type="button" className="pb-todo-picker-more" onClick={()=>setLimit(value=>value+50)}>Show more ({matches.length-limit} remaining)</button>}
    </div>
    {!isTask && <div className="pb-todo-picker-create"><input aria-label="New list name" placeholder="New list name" value={name} maxLength={200} onChange={event=>setName(event.target.value)} onKeyDown={event=>{if(event.key==='Enter'){event.preventDefault();createList();}}}/><button type="button" disabled={!name.trim() || s.busy} onClick={createList}>Create and insert</button></div>}
    {error && <p role="alert">{error}</p>}
  </dialog>,document.body);
}

export function TodoToolbar({store,onInsert,onError}) {
  const s=useTodos(store),mode=useCellValue(viewMode$),[picker,setPicker]=React.useState(null);
  const disabled=s.loading || s.busy || !s.editable || mode==='diff';
  const insert=(item,status)=>{try{onInsert(item,status);}catch(error){onError(error.message);}};
  return <><span className="pb-todo-editor-tools" role="group" aria-label="TODO tools">
    <button type="button" title="New TODO" aria-label="New TODO" disabled={disabled} onMouseDown={event=>event.preventDefault()} onClick={async()=>{try{const item=await store.newTask();if(item)insert(item,'');}catch(error){onError(error.message);}}}><Icon kind="new"/></button>
    <button type="button" title="Insert existing TODO" aria-label="Insert existing TODO" disabled={disabled} onMouseDown={event=>event.preventDefault()} onClick={()=>setPicker('task')}><Icon kind="task"/></button>
    <button type="button" title="Insert TODO list" aria-label="Insert TODO list" disabled={disabled} onMouseDown={event=>event.preventDefault()} onClick={()=>setPicker('list')}><Icon kind="list"/></button>
  </span>{picker && <TodoPicker kind={picker} store={store} onClose={()=>setPicker(null)} onInsert={insert}/>}</>;
}
