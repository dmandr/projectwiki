import {realmPlugin,createRootEditorSubscription$} from '@mdxeditor/editor';
import {$getSelection,$isRangeSelection,KEY_ENTER_COMMAND,INSERT_LINE_BREAK_COMMAND,INSERT_PARAGRAPH_COMMAND,COMMAND_PRIORITY_CRITICAL} from 'lexical';
import {enterModeKey,enterAction} from './enter-mode.mjs';
export const enterModePlugin=realmPlugin({init(realm){
  realm.pub(createRootEditorSubscription$,editor=>editor.registerCommand(KEY_ENTER_COMMAND,event=>{
    if(!event || editor.isComposing())return false;
    let selection=$getSelection();if(!$isRangeSelection(selection))return false;
    if(selection.isCollapsed()){
      let task=selection.anchor.getNode();while(task && task.getType()!=='projectbook-inline-todo')task=task.getParent();
      if(task){task.selectNext();selection=$getSelection();}
    }
    const node=selection.anchor.getNode();
    if([node,...node.getParents()].some(n=>['code','codeblock'].includes(n.getType())))return false;
    if(event.target?.closest?.('.cm-editor,[aria-label="Task text"]'))return false;
    let mode='paragraph';try{mode=localStorage.getItem(enterModeKey)||mode;}catch{}
    const action=enterAction(mode,event);if(!action)return false;
    // Keep normal paragraph handling (list exit, callouts) in the default mode.
    if(action==='paragraph' && !event.metaKey && !event.ctrlKey)return false;
    event.preventDefault();
    return editor.dispatchCommand(action==='break'?INSERT_LINE_BREAK_COMMAND:INSERT_PARAGRAPH_COMMAND,false);
  },COMMAND_PRIORITY_CRITICAL));
}});
