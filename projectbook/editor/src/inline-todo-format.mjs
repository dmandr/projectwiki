import {fromMarkdown} from 'mdast-util-from-markdown';
export function cleanTags(tags=[]) {
  return [...new Set(tags.map(t=>String(t).trim()).filter(Boolean))].sort((a,b)=>a.localeCompare(b));
}
export function readTodo(label,url='') {
  const match=/^todo:\s*([^\r\n]+)$/i.exec(label);
  if(!match || !match[1].trim())return null;
  let done='',tags=[];
  if(url){
    const metadata=/^(?:done=([^,]*))?(?:,?tags=(.*))?$/.exec(url);
    if(!metadata || (!url.startsWith('done=')&&!url.startsWith('tags=')))return null;
    try{done=decodeURIComponent(metadata[1]||'');tags=cleanTags((metadata[2]||'').split(',').map(decodeURIComponent));}catch{return null;}
    if(done && !/^\d{4}-\d\d-\d\dT\d\d:\d\d(?::\d\d(?:\.\d{1,3})?)?(?:Z|[+-]\d\d:\d\d)?$/.test(done))return null;
  }
  return {title:match[1].trim(),done,tags};
}
export const labelText=node=>(node.children||[]).map(c=>c.type==='text'||c.type==='inlineCode'?c.value:labelText(c)).join('');
const enc=s=>encodeURIComponent(s).replace(/[!'()*]/g,c=>'%'+c.charCodeAt(0).toString(16));
export function todoURL(task){return [task.done?'done='+task.done:'',task.tags?.length?'tags='+cleanTags(task.tags).map(enc).join(','):''].filter(Boolean).join(',');}
export const todoMarkdown=task=>`[TODO: ${task.title.replace(/[\\[\]*_`<>]/g,'\\$&')}](${todoURL(task)})`;
export const completedNow=()=>new Date().toISOString().replace(/:\d\d\.\d{3}Z$/,'Z');
export function readTodoList(text){
  const match=/^:::todos\r?\n([\s\S]*?)\r?\n:::\s*$/.exec(text);if(!match)return null;
  const result={tags:[],match:'any',status:''};
  for(const line of match[1].split(/\r?\n/)){
    if(!line.trim())continue;
    const field=/^(tags|match|status):\s*(.*?)\s*$/.exec(line);if(!field)return null;
    if(field[1]==='tags')result.tags=cleanTags(field[2].split(','));else result[field[1]]=field[2];
  }
  return ['any','all'].includes(result.match)&&['','open','done'].includes(result.status)?result:null;
}
export const todoListMarkdown=query=>`:::todos\ntags: ${cleanTags(query.tags||[]).join(', ')}\nmatch: ${query.match||'any'}\nstatus: ${query.status||''}\n:::`;
export function scanInlineTodos(markdown){
  const tasks=[],lists=[];
  function visit(node){
    if(node.type==='code'||node.type==='inlineCode'||node.type==='html')return;
    if(node.type==='link'){
      const task=readTodo(labelText(node),node.url);
      if(task){tasks.push({...task,start:node.position.start.offset,end:node.position.end.offset,line:node.position.start.line,raw:markdown.slice(node.position.start.offset,node.position.end.offset)});return;}
    }
    if(node.type==='paragraph'){
      const raw=markdown.slice(node.position.start.offset,node.position.end.offset),query=readTodoList(raw);
      if(query){lists.push({...query,start:node.position.start.offset,end:node.position.end.offset});return;}
    }
    for(const child of node.children||[])visit(child);
  }
  visit(fromMarkdown(markdown));return {tasks,lists};
}
export function editTodoTags(markdown,tasks,{add=[],remove=[]}){
  let result=markdown;
  for(const task of [...tasks].sort((a,b)=>b.start-a.start)){
    result=result.slice(0,task.start)+todoMarkdown({...task,tags:cleanTags([...task.tags.filter(t=>!remove.includes(t)),...add])})+result.slice(task.end);
  }
  return result;
}
export function matchesTodo(task,query={}){
  const tags=query.tags||[];
  return (!query.status || (task.done?'done':'open')===query.status) && (!tags.length || (query.match==='all'?tags.every(t=>task.tags.includes(t)):tags.some(t=>task.tags.includes(t))));
}
