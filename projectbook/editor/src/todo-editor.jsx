import React from 'react';
import { DecoratorNode, $applyNodeReplacement, $createParagraphNode, $getNodeByKey, $getSelection, $isNodeSelection,
  KEY_ARROW_UP_COMMAND, KEY_ARROW_DOWN_COMMAND, KEY_ARROW_LEFT_COMMAND, KEY_ARROW_RIGHT_COMMAND, KEY_ENTER_COMMAND, COMMAND_PRIORITY_HIGH } from 'lexical';
import { useLexicalComposerContext } from '@lexical/react/LexicalComposerContext';
import { realmPlugin, addLexicalNode$, addImportVisitor$, addExportVisitor$ } from '@mdxeditor/editor';
import { todoReference } from './todo-format.mjs';
import { TaskRow, TodoList, useTodos } from './todo-ui';
let store;
export class TodoNode extends DecoratorNode {
  static getType(){return 'projectbook-todo';}
  static clone(node){return new TodoNode(node.__ref,node.__key);}
  static importJSON(value){return $applyNodeReplacement(new TodoNode(value.ref));}
  constructor(ref,key){super(key);this.__ref={...ref};}
  exportJSON(){return {...super.exportJSON(),type:'projectbook-todo',version:1,ref:this.__ref};}
  createDOM(){const el=document.createElement('span');el.className='pb-todo-token';return el;}
  updateDOM(){return false;}
  isInline(){return true;}
  setLabel(label){this.getWritable().__ref={...this.__ref,label};}
  getTextContent(){return this.__ref.label;}
  exportDOM(){const a=document.createElement('a');a.href=this.__ref.url;a.textContent=this.__ref.label;return {element:a};}
  decorate(){return <TodoElement nodeKey={this.__key} reference={this.__ref}/>;}
}
function TodoElement({nodeKey,reference}) {
  const [editor]=useLexicalComposerContext();
  const [wrapped,setWrapped]=React.useState(false);
  const state=useTodos(store),task=state.tasks.find(item=>item.id===reference.id);
  React.useEffect(()=>{
    if(reference.kind!=='task' || !task || !store.pending().some(item=>item.kind==='task' && item.id===task.id))return;
    const label='TODO: '+task.title;
    editor.update(()=>{const node=$getNodeByKey(nodeKey);if(node && node.__ref.label!==label)node.setLabel(label);});
  },[task?.title,editor,nodeKey]);
  React.useEffect(()=>{
    if(reference.kind!=='task' || !task)return;
    const parentItem=()=>{
      const parent=$getNodeByKey(nodeKey)?.getParent();
      return parent?.getType()==='listitem' && parent.getChildrenSize()===1 && parent.getParent()?.getListType()==='check' ? parent : null;
    };
    let previous;
    editor.getEditorState().read(()=>{previous=parentItem()?.getChecked();setWrapped(previous!==undefined);});
    const unregister=editor.registerUpdateListener(({editorState,tags})=>{
      let checked;editorState.read(()=>{checked=parentItem()?.getChecked();});
      setWrapped(checked!==undefined);
      if(!tags.has('projectbook-todo-sync') && previous!==undefined && checked!==undefined && checked!==previous) {
        const current=store.snapshot().tasks.find(item=>item.id===reference.id);
        if(current && (checked?'done':'open')!==current.status)store.change([{...current,status:checked?'done':'open'}]);
      }
      previous=checked;
    });
    editor.update(()=>{const parent=parentItem();if(parent && parent.getChecked()!==(task.status==='done'))parent.setChecked(task.status==='done');},{tag:'projectbook-todo-sync'});
    return unregister;
  },[task?.status,task?.id,editor,nodeKey]);
  React.useEffect(()=>{
    const remove=[ [KEY_ARROW_UP_COMMAND,true],[KEY_ARROW_LEFT_COMMAND,true],[KEY_ARROW_DOWN_COMMAND,false],[KEY_ARROW_RIGHT_COMMAND,false],[KEY_ENTER_COMMAND,false] ].map(([cmd,before])=>editor.registerCommand(cmd,event=>{
      const selection=$getSelection();
      if (!$isNodeSelection(selection) || !selection.has(nodeKey)) return false;
      const node=$getNodeByKey(nodeKey),block=node?.getTopLevelElement();if(!block)return false;
      const paragraph=$createParagraphNode();if(before)block.insertBefore(paragraph);else block.insertAfter(paragraph);paragraph.selectStart();event?.preventDefault();return true;
    },COMMAND_PRIORITY_HIGH));
    return ()=>remove.forEach(fn=>fn());
  },[editor,nodeKey]);
  return <span contentEditable={false}>{reference.kind==='task'?<TaskRow store={store} id={reference.id} direct editDetails wrapped={wrapped}/>:<TodoList store={store} id={reference.id} status={reference.status}/>}</span>;
}
export const todoPlugin=realmPlugin({init(realm,options){
  store=options.store;
  realm.pub(addLexicalNode$,TodoNode);
  realm.pub(addImportVisitor$,{
    priority:50,
    testNode:node=>node.type==='link' && !!todoReference(node.url,(node.children||[]).map(c=>c.value||'').join(''),options.path),
    visitNode({mdastNode,lexicalParent}){
      const ref=todoReference(mdastNode.url,mdastNode.children.map(c=>c.value||'').join(''),options.path);
      lexicalParent.append($applyNodeReplacement(new TodoNode(ref)));
    }
  });
  realm.pub(addExportVisitor$,{
    priority:50,testLexicalNode:node=>node instanceof TodoNode,
    visitLexicalNode({lexicalNode,mdastParent,actions}){
      const ref=lexicalNode.__ref;
      actions.appendToParent(mdastParent,{type:'link',url:ref.url,title:null,children:[{type:'text',value:ref.label}]});
    }
  });
}});
