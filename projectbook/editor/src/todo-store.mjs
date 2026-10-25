import { pendingTodos } from './todo-format.mjs';

export function todoStore({base='', staged=false, revision='', onChange=()=>{}, fetcher=fetch}={}) {
  let state={tasks:[],lists:[],errors:[],loading:true,editable:false,busy:false,message:'',focusId:null};
  let pending=[], saved={tasks:[],lists:[]}, document=null; const listeners=new Set();
  const update = next => {state={...state,...next};listeners.forEach(fn=>fn());};
  const request = async changes => {
    const response=await fetcher(base+'/gollum/projectbook/tasks'+(revision?'?revision='+encodeURIComponent(revision):''),changes ? {
      method:'POST',headers:{'Content-Type':'application/json','X-ProjectWiki-Request':'1'},body:JSON.stringify({changes})
    } : {cache:'no-store'});
    const result=await response.json(); if (!response.ok) throw new Error(result.error || 'TODO request failed.'); return result;
  };
  const visiblePending=()=>document ? pendingTodos(pending,document.markdown,document.path) : pending;
  const signature=item=>JSON.stringify(['kind','id','title','notes','list_id','status','due','source_path'].map(key=>item[key] || ''));
  const render=()=>applyPending({...state,tasks:[...saved.tasks],lists:[...saved.lists]});
  const applyPending = data => {
    for (const item of visiblePending()) {
      const key=item.kind === 'task'?'tasks':'lists';
      data[key]=[...data[key].filter(old=>old.id !== item.id),item];
    }
    return data;
  };
  const store={
    subscribe: fn=>{listeners.add(fn);return ()=>listeners.delete(fn);}, snapshot:()=>state,
    async load() {
      try {const data=await request();saved={tasks:data.tasks,lists:data.lists};update({...data,...applyPending({...data}),loading:false,message:''});}
      catch(error) {update({loading:false,message:'Could not load TODOs. '+error.message});}
    },
    pending:()=>pending, visiblePending,
    setDocument(markdown,path) {document={markdown,path};update(render());},
    setBusy:busy=>update({busy}),
    restore(items) {pending=items || [];update(render());},
    async change(items) {
      if (!state.editable || state.busy) return false;
      const changes=items.map(item=>({...item,expected_version:item.expected_version ?? item.version ?? ''}));
      if (staged) {
        for (const item of changes) {
          pending=pending.filter(old=>old.id !== item.id || old.kind !== item.kind);
          const original=[...saved.tasks,...saved.lists].find(old=>old.kind===item.kind && old.id===item.id);
          if (!original || signature(original)!==signature(item) || item.expected_version!==original.version) pending.push(item);
        }
        update({...render(),message:visiblePending().length?'TODO changes will be saved with this document.':''});onChange(); return true;
      }
      update({busy:true,message:''});
      try {await request(changes);await store.load();return true;}
      catch(error) {update({message:error.message+' Your input is kept. Reload TODOs to compare before retrying.'});return false;}
      finally {update({busy:false});}
    },
    focusTask: id=>update({focusId:id}),
    async newTask() {
      if (!state.editable || state.busy) return null;
      const list=[...state.lists,...pending.filter(item=>item.kind==='list')].find(item=>item.title.toLowerCase()==='default') ||
        {kind:'list',id:crypto.randomUUID(),title:'Default',expected_version:''};
      const task={kind:'task',id:crypto.randomUUID(),title:'TODO',list_id:list.id,status:'open',expected_version:''};
      const changes=list.version || pending.some(item=>item.id===list.id) ? [task] : [list,task];
      if (!await store.change(changes)) return null;
      update({focusId:task.id});return task;
    },
    base, staged, revision
  };return store;
}
