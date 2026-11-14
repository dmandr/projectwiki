import {readFileSync} from 'node:fs';
import {scanInlineTodos,todoMarkdown,todoListMarkdown} from './inline-todo-format.mjs';
import {fromMarkdown} from 'mdast-util-from-markdown';
import {todoReference} from './todo-format.mjs';
import {labelText} from './inline-todo-format.mjs';
const input=JSON.parse(readFileSync(0,'utf8'));
const out=input.documents.map(doc=>{
  const scan=scanInlineTodos(doc.content);
  const byte=n=>Buffer.byteLength(doc.content.slice(0,n));
  const tasks=scan.tasks.map(t=>({...t,start:byte(t.start),end:byte(t.end)}));
  const legacy=[];
  function visit(node){
    if(node.type==='code'||node.type==='inlineCode'||node.type==='html')return;
    if(node.type==='link'){
      const ref=todoReference(node.url,labelText(node),doc.path);
      if(ref)legacy.push({...ref,start:byte(node.position.start.offset),end:byte(node.position.end.offset)});
    }
    for(const c of node.children||[])visit(c);
  }
  visit(fromMarkdown(doc.content));
  return {path:doc.path,tasks,lists:scan.lists,legacy};
});
process.stdout.write(JSON.stringify(out));
