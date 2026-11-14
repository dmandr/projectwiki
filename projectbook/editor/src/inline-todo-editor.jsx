import React from 'react';
import {ElementNode,DecoratorNode,$applyNodeReplacement,$createTextNode,$getNodeByKey,$getSelection,$isRangeSelection,$getNearestNodeFromDOMNode,KEY_ENTER_COMMAND,COMMAND_PRIORITY_HIGH} from 'lexical';
import {useLexicalComposerContext} from '@lexical/react/LexicalComposerContext';
import {realmPlugin,addLexicalNode$,addImportVisitor$,addExportVisitor$,addToMarkdownExtension$,createRootEditorSubscription$} from '@mdxeditor/editor';
import {readTodo,labelText,todoURL,readTodoList,todoListMarkdown,completedNow,cleanTags} from './inline-todo-format.mjs';
import {inlineStore,InlineTodoList} from './inline-todo-ui';
export class InlineTodoNode extends ElementNode {
  static getType(){return 'projectbook-inline-todo';}
  static clone(n){return new InlineTodoNode(n.__metadata,n.__key);}
  static importJSON(value){return new InlineTodoNode(value.metadata).updateFromJSON(value);}
  constructor(metadata={},key){super(key);this.__metadata={done:metadata.done||'',tags:cleanTags(metadata.tags||[])};}
  exportJSON(){return {...super.exportJSON(),type:InlineTodoNode.getType(),version:1,metadata:this.getMetadata()};}
  getMetadata(){return this.getLatest().__metadata;}
  setMetadata(data){this.getWritable().__metadata={done:data.done||'',tags:cleanTags(data.tags||[])};}
  isInline(){return true;}
  canBeEmpty(){return false;}
  canInsertTextBefore(){return true;}
  canInsertTextAfter(){return true;}
  createDOM(){
    const el=document.createElement('span');el.className='pb-inline-todo';
    const checkbox=document.createElement('input');checkbox.type='checkbox';checkbox.className='pb-inline-todo-toggle';checkbox.contentEditable='false';checkbox.setAttribute('aria-label','Complete TODO');checkbox.dataset.todoKey=this.__key;el.append(checkbox);
    const text=document.createElement('span');text.className='pb-inline-todo-text';el.append(text);this.syncDOM(el);return el;
  }
  getDOMSlot(el){return super.getDOMSlot(el).withElement(el.querySelector('.pb-inline-todo-text'));}
  syncDOM(el){el.dataset.done=String(!!this.getMetadata().done);el.querySelector('input').checked=!!this.getMetadata().done;}
  updateDOM(previous,el){this.syncDOM(el);return false;}
  exportDOM(){const a=document.createElement('a');a.href=todoURL(this.getMetadata());a.dataset.projectbookTodo='true';a.append(document.createTextNode('TODO: '));return {element:a};}
  static importDOM(){return {a:el=>el.dataset.projectbookTodo==='true'?{priority:4,conversion:()=>{const metadata=readTodo(el.textContent,el.getAttribute('href'));return metadata?{node:$createInlineTodo(metadata),forChild:()=>null}:null;}}:null};}
}
export function $createInlineTodo(task){return $applyNodeReplacement(new InlineTodoNode(task)).append($createTextNode(task.title||'TODO'));}
export function selectedTodoNodes(selection){
  if(!$isRangeSelection(selection))return [];
  const result=new Map();
  for(let node of selection.getNodes()){
    while(node){if(node instanceof InlineTodoNode){result.set(node.getKey(),node);break;}node=node.getParent();}
  }
  return [...result.values()];
}
export class InlineTodoListNode extends DecoratorNode {
  static getType(){return 'projectbook-inline-todo-list';}
  static clone(n){return new InlineTodoListNode(n.__query,n.__key);}
  static importJSON(value){return new InlineTodoListNode(value.query);}
  constructor(query={},key){super(key);this.__query={tags:query.tags||[],match:query.match||'any',status:query.status||''};}
  exportJSON(){return {...super.exportJSON(),type:InlineTodoListNode.getType(),version:1,query:this.__query};}
  createDOM(){return document.createElement('div');}updateDOM(){return false;}isInline(){return false;}
  decorate(){return <ListEditor nodeKey={this.__key} query={this.__query}/>;}
}
function ListEditor({nodeKey,query}){
  const [editor]=useLexicalComposerContext(),[open,setOpen]=React.useState(false);
  const store=React.useMemo(()=>inlineStore({base:window.baseUrl||'',readOnly:true}),[]);React.useEffect(()=>{store.load();},[]);
  function change(key,value){editor.update(()=>{const node=$getNodeByKey(nodeKey);if(node)node.getWritable().__query={...query,[key]:value};});}
  return <div contentEditable={false} className="pb-inline-list-editor"><button type="button" onClick={()=>setOpen(!open)}>TODO list filters</button>{open&&<div><label>Tags<input aria-label="TODO list tags" defaultValue={query.tags.join(', ')} onBlur={e=>change('tags',cleanTags(e.target.value.split(',')))}/></label><label>Match<select value={query.match} onChange={e=>change('match',e.target.value)}><option value="any">Any tag</option><option value="all">All tags</option></select></label><label>Status<select value={query.status} onChange={e=>change('status',e.target.value)}><option value="">All</option><option value="open">Open</option><option value="done">Done</option></select></label></div>}<InlineTodoList store={store} query={query}/><small>Preview of saved tasks. Save the document to include new tasks.</small></div>;
}
export const inlineTodoPlugin=realmPlugin({init(realm){
  realm.pub(addLexicalNode$,[InlineTodoNode,InlineTodoListNode]);
  realm.pub(addImportVisitor$,[{
    priority:70,testNode:n=>n.type==='link'&&!!readTodo(labelText(n),n.url),
    visitNode({mdastNode,lexicalParent}){lexicalParent.append($createInlineTodo(readTodo(labelText(mdastNode),mdastNode.url)));}
  },{
    priority:70,testNode:n=>n.type==='paragraph'&&!!readTodoList(labelText(n)),
    visitNode({mdastNode,lexicalParent}){lexicalParent.append($applyNodeReplacement(new InlineTodoListNode(readTodoList(labelText(mdastNode)))));}
  }]);
  realm.pub(addExportVisitor$,[{
    priority:70,testLexicalNode:n=>n instanceof InlineTodoNode,
    visitLexicalNode({lexicalNode,mdastParent,actions}){actions.appendToParent(mdastParent,{type:'link',url:todoURL(lexicalNode.getMetadata()),children:[{type:'text',value:'TODO: '+lexicalNode.getTextContent()}]});}
  },{
    priority:70,testLexicalNode:n=>n instanceof InlineTodoListNode,
    visitLexicalNode({lexicalNode,mdastParent,actions}){actions.appendToParent(mdastParent,{type:'projectbookTodoList',query:lexicalNode.__query});}
  }]);
  realm.pub(addToMarkdownExtension$,{handlers:{projectbookTodoList:node=>todoListMarkdown(node.query)}});
  realm.pub(createRootEditorSubscription$,editor=>{
    const click=e=>{const key=e.target?.dataset?.todoKey;if(!key)return;e.preventDefault();editor.update(()=>{const node=$getNodeByKey(key);if(node instanceof InlineTodoNode)node.setMetadata({...node.getMetadata(),done:node.getMetadata().done?'':completedNow()});});};
    const unregister=editor.registerRootListener((root,old)=>{old?.removeEventListener('click',click);root?.addEventListener('click',click);});
    return unregister;
  });
}});
