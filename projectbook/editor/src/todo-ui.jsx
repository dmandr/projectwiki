import React from 'react';
import {createEditor,$getRoot,$createParagraphNode,$createTextNode,KEY_ENTER_COMMAND,KEY_ESCAPE_COMMAND,COMMAND_PRIORITY_HIGH} from 'lexical';
import {registerPlainText} from '@lexical/plain-text';
import {registerHistory,createEmptyHistoryState} from '@lexical/history';
import './todo.css';
import {todoSourceUrl} from './todo-format.mjs';
export { todoStore } from './todo-store.mjs';
export const useTodos=store=>React.useSyncExternalStore(store.subscribe,store.snapshot);
export function TodoMessages({store}) {
  const s=useTodos(store);
  return <div role="status" className="pb-todo-message">{s.message}{s.errors.map((e,i)=><p key={i}>{e.path}: {e.error}</p>)}{s.message.startsWith('Could not load') && <button type="button" onClick={()=>store.load()}>Retry</button>}</div>;
}

// Native menu over a compact pill, with new-list creation in place.
export function ListPicker({store,value,onChoose,label='TODO list'}) {
  const s=useTodos(store),[creating,setCreating]=React.useState(false),[name,setName]=React.useState('');
  const newId=React.useRef(null),input=React.useRef(null),saving=React.useRef(false);
  React.useEffect(()=>{if(creating)input.current?.focus();},[creating]);
  async function create() {
    if(saving.current)return;
    if(!name.trim()){setCreating(false);return;}
    const existing=s.lists.find(list=>list.title.toLowerCase()===name.trim().toLowerCase());
    newId.current ||= crypto.randomUUID();
    const list=existing || {kind:'list',id:newId.current,title:name.trim(),expected_version:''};
    saving.current=true;
    try{if(await onChoose(list,!existing)!==false){setCreating(false);setName('');newId.current=null;}}
    finally{saving.current=false;}
  }
  if(creating)return <input ref={input} className="pb-todo-list-name" aria-label="New list name" placeholder="New list name" maxLength={200} value={name} disabled={s.busy}
    onChange={e=>setName(e.target.value)} onBlur={create} onKeyDown={e=>{
      e.stopPropagation();
      if(e.key==='Enter'){e.preventDefault();e.stopPropagation();create();}
      if(e.key==='Escape'){e.preventDefault();e.stopPropagation();saving.current=true;setCreating(false);setName('');queueMicrotask(()=>{saving.current=false;});}
    }}/>;
  const title=s.lists.find(list=>list.id===value)?.title || (value?'Missing list':'Choose list…');
  return <span className="pb-task-list-picker"><span className="pb-task-tag" aria-hidden="true">{title}</span><select className="pb-task-list-select" aria-label={label} value={value || ''} disabled={!s.editable || s.busy} onKeyDown={e=>e.stopPropagation()} onChange={e=>{
    if(e.target.value==='new'){setCreating(true);return;}
    const list=s.lists.find(list=>list.id===e.target.value);if(list)onChoose(list,false);
  }}>
    {!value && <option value="">Choose list…</option>}
    {value && !s.lists.some(list=>list.id===value) && <option value={value}>Missing list</option>}
    {s.lists.map(list=><option key={list.id} value={list.id}>{list.title}</option>)}
    <option value="new">Create new list…</option>
  </select></span>;
}

export function TaskSource({store,task}) {
  const [open,setOpen]=React.useState(false),root=React.useRef(null);
  const sources=task.source_references || [];
  React.useEffect(()=>{
    if(!open)return;
    const outside=e=>{if(!root.current?.contains(e.target))setOpen(false);};
    const escape=e=>{if(e.key==='Escape'){e.stopPropagation();setOpen(false);}};
    document.addEventListener('pointerdown',outside);document.addEventListener('keydown',escape);
    return ()=>{document.removeEventListener('pointerdown',outside);document.removeEventListener('keydown',escape);};
  },[open]);
  return <span ref={root} className="pb-task-source-wrap">
    <a className={'pb-task-source '+(task.status==='done'?'pb-task-done':'')} href={todoSourceUrl(task,store.base,store.revision)}
      title={task.version?(sources.length>1?'Choose task source':'Go to task source'):'Save this document to open the task source'}
      aria-disabled={!task.version || undefined} aria-haspopup={sources.length>1?'dialog':undefined} aria-expanded={sources.length>1?open:undefined}
      onClick={e=>{e.stopPropagation();if(!task.version){e.preventDefault();return;}if(sources.length>1){e.preventDefault();setOpen(!open);}}}>{task.title}</a>
    {open && <span className="pb-task-sources" role="dialog" aria-label="Task sources">
      <span className="pb-task-sources-heading">Task appears in multiple documents<button type="button" aria-label="Close task sources" onClick={()=>setOpen(false)}>×</button></span>
      {sources.map(path=><a key={path} href={todoSourceUrl({...task,source_target:path},store.base,store.revision)} onClick={e=>{e.stopPropagation();setOpen(false);}}>{path}</a>)}
    </span>}
  </span>;
}

function TaskText({store,task,direct}) {
  const s=useTodos(store),input=React.useRef(null),editorRef=React.useRef(null),original=React.useRef(task),latest=React.useRef(task);
  latest.current=task;
  React.useLayoutEffect(()=>{
    // Give each task an independent editor root. The document editor must not
    // handle Select All, typing or undo intended for this nested text field.
    const editor=createEditor({namespace:'projectbook-task-title',onError:error=>{throw error;}});
    editorRef.current=editor;editor.setRootElement(input.current);
    const replace=title=>editor.update(()=>{$getRoot().clear().append($createParagraphNode().append($createTextNode(title)));},{tag:'task-external',discrete:true});
    replace(latest.current.title);
    const unregisterPlain=registerPlainText(editor);
    const unregisterHistory=registerHistory(editor,createEmptyHistoryState(),300);
    const unregisterUpdate=editor.registerUpdateListener(({editorState,tags})=>{
      if(tags.has('task-external'))return;
      let text;editorState.read(()=>{text=$getRoot().getTextContent();});
      const title=text.replace(/[\r\n]+/g,' ').slice(0,200);
      if(text!==title)replace(title);
      if(store.staged && title!==latest.current.title)store.change([{...latest.current,title}]);
    });
    const unregisterEnter=editor.registerCommand(KEY_ENTER_COMMAND,event=>{event?.preventDefault();input.current.blur();return true;},COMMAND_PRIORITY_HIGH);
    const unregisterEscape=editor.registerCommand(KEY_ESCAPE_COMMAND,event=>{
      event?.preventDefault();replace(original.current.title);if(store.staged)store.change([original.current]);return true;
    },COMMAND_PRIORITY_HIGH);
    return ()=>{unregisterEscape();unregisterEnter();unregisterUpdate();unregisterHistory();unregisterPlain();editor.setRootElement(null);editorRef.current=null;};
  },[store]);
  React.useLayoutEffect(()=>{
    const editor=editorRef.current;if(!editor)return;
    editor.setEditable(!s.busy);
    let text;editor.getEditorState().read(()=>{text=$getRoot().getTextContent();});
    if(text!==task.title && document.activeElement!==input.current)editor.update(()=>{
      $getRoot().clear().append($createParagraphNode().append($createTextNode(task.title)));
    },{tag:'task-external',discrete:true});
  },[task.title,s.busy]);
  React.useEffect(()=>{
    if(direct && s.focusId===task.id && editorRef.current){
      editorRef.current.focus(()=>editorRef.current.update(()=>{const text=$getRoot().getAllTextNodes()[0];if(text)text.select(0,text.getTextContentSize());},{discrete:true}));
      store.focusTask(null);
    }
  },[s.focusId,direct,task.id]);
  async function commit() {
    if(store.staged)return;
    let value;editorRef.current.getEditorState().read(()=>{value=$getRoot().getTextContent().trim();});
    if(!value || value===latest.current.title)return;
    await store.change([{...original.current,title:value}]);
  }
  return <><span ref={input} data-task-title role="textbox" aria-label="Task text" aria-multiline="false"
    contentEditable suppressContentEditableWarning tabIndex={0}
    className={'pb-task-title-editor '+(task.status==='done'?'pb-task-done':'')}
    onFocus={()=>{original.current=latest.current;}} onBlur={commit}/><span className="pb-task-print-title">{task.title}</span></>;
}

export function TaskRow({store,id,direct=false,wrapped=false,navigate=false,showList=true,editDetails=false}) {
  const s=useTodos(store),task=s.tasks.find(t=>t.id===id);
  React.useEffect(()=>{
    if(!direct || !task)return;
    const reveal=()=>{if(window.location.hash==='#todo-'+id)document.getElementById('todo-'+id)?.scrollIntoView({block:'center'});};
    reveal();window.addEventListener('hashchange',reveal);return ()=>window.removeEventListener('hashchange',reveal);
  },[direct,id,!!task]);
  if(!task)return <span className="pb-todo-missing">{s.loading?'Loading task…':'Task missing or invalid'}</span>;
  const list=s.lists.find(l=>l.id===task.list_id),canEdit=editDetails && s.editable;
  return <span className="pb-task-row" data-task-id={id} id={direct?'todo-'+id:undefined}>
    {!wrapped && <input type="checkbox" aria-label={'Complete '+task.title} checked={task.status==='done'} disabled={!s.editable || s.busy}
      onChange={()=>store.change([{...task,status:task.status==='done'?'open':'done'}])}/>}
    <span className="pb-task-body">
      {navigate ? <TaskSource store={store} task={task}/> : canEdit ? <TaskText store={store} task={task} direct={direct}/> : <span className={'pb-task-text '+(task.status==='done'?'pb-task-done':'')}>{task.title}</span>}
      {showList && <>{' '}{canEdit ? <ListPicker store={store} value={task.list_id} label={'List for '+task.title} onChoose={(next,isNew)=>store.change([...(isNew?[next]:[]),{...task,list_id:next.id}])}/> : <span className="pb-task-tag">{list?.title || 'Missing list'}</span>}</>}
    </span>
  </span>;
}

export function TodoList({store,id,status=''}) {
  const s=useTodos(store),list=s.lists.find(l=>l.id===id),tasks=s.tasks.filter(t=>t.list_id===id && (!status || t.status===status));
  return <span className="pb-todo-list"><span className="pb-todo-list-heading">{list?.title || (s.loading?'Loading list…':'List missing or invalid')}{status && ' · '+status}</span>
    {tasks.map(task=><TaskRow key={task.id} store={store} id={task.id} navigate showList={false}/>)}{!tasks.length && <span className="pb-todo-empty">No tasks in this view.</span>}
  </span>;
}

export function TodoBoard({store}) {
  const s=useTodos(store),[list,setList]=React.useState(''),[status,setStatus]=React.useState(''),[query,setQuery]=React.useState(''),[creating,setCreating]=React.useState(false);
  const [listTitle,setListTitle]=React.useState('');
  const current=s.lists.find(l=>l.id===list),tasks=s.tasks.filter(t=>(!list || t.list_id===list) && (!status || t.status===status) && t.title.toLowerCase().includes(query.toLowerCase()));
  React.useEffect(()=>setListTitle(current?.title || ''),[current?.title]);
  const rename=()=>{if(current && listTitle.trim() && listTitle.trim()!==current.title)store.change([{...current,title:listTitle.trim()}]);};
  return <div className="pb-todo-board">
    <div className="pb-todo-actions"><button type="button" disabled={!s.editable || s.busy} onClick={async()=>{setList('');setStatus('');setQuery('');await store.newTask();}}>New task</button><button type="button" disabled={!s.editable || s.busy} onClick={()=>setCreating(!creating)}>New list</button><button type="button" disabled={s.busy} onClick={()=>store.load()}>Refresh</button></div>
    {creating && <ListPicker store={store} value="" label="Create or choose list" onChoose={async(item,isNew)=>{if(isNew && !await store.change([item]))return false;setList(item.id);setCreating(false);return true;}}/>}
    <div className="pb-todo-filters"><label>List / tag<select aria-label="Filter TODO list" value={list} onChange={e=>setList(e.target.value)}><option value="">All lists</option>{s.lists.map(l=><option key={l.id} value={l.id}>{l.title}</option>)}</select></label><label>Status<select value={status} onChange={e=>setStatus(e.target.value)}><option value="">All</option><option value="open">Open</option><option value="done">Done</option></select></label><label>Find task<input value={query} onChange={e=>setQuery(e.target.value)}/></label></div>
    {current && <p className="pb-todo-list-title"><input aria-label="List name" value={listTitle} disabled={!s.editable || s.busy} onChange={e=>setListTitle(e.target.value)} onBlur={rename} onKeyDown={e=>{if(e.key==='Enter'){e.preventDefault();e.currentTarget.blur();}}}/></p>}
    <TodoMessages store={store}/>{s.loading?<p>Loading TODOs…</p>:!tasks.length?<p>No matching tasks.</p>:tasks.map(task=><TaskRow key={task.id} store={store} id={task.id} direct editDetails/>)}
  </div>;
}
