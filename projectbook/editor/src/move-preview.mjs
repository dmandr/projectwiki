// Shared, accessible preview for tree and editor moves. No page text is inserted
// as HTML: filenames and diffs are untrusted book content.
export function confirmMove(preview, source, target) {
  return new Promise(resolve=>{
    const dialog=document.createElement('dialog');dialog.className='pb-move-preview';dialog.setAttribute('aria-label','Move preview');
    const title=document.createElement('h2');title.textContent='Move preview';dialog.append(title);
    const paths=document.createElement('p');paths.textContent=source+' → '+target;dialog.append(paths);
    const summary=document.createElement('p');summary.textContent=`${preview.moved_count} file(s) moved; ${preview.updated_count} other file(s) updated. Links and folder order are saved in the same commit.`;dialog.append(summary);
    const list=document.createElement('div');list.className='pb-move-preview-files';dialog.append(list);
    for(const change of preview.changes){
      const details=document.createElement('details'),label=document.createElement('summary');
      label.textContent=change.moved?change.previous_path+' → '+change.path:change.path;
      details.append(label);
      const pre=document.createElement('pre');pre.textContent=change.diff || (change.moved?'File content preserved.':'Metadata/order update.');
      if(change.diff_truncated)pre.textContent+='\n… Diff truncated';
      details.append(pre);list.append(details);
    }
    const buttons=document.createElement('div');buttons.className='pb-editor-actions';dialog.append(buttons);
    function finish(value){dialog.close();dialog.remove();resolve(value);}
    const cancel=document.createElement('button');cancel.type='button';cancel.className='btn';cancel.textContent='Cancel';cancel.onclick=()=>finish(false);buttons.append(cancel);
    const save=document.createElement('button');save.type='button';save.className='btn btn-primary';save.textContent='Confirm move';save.onclick=()=>finish(true);buttons.append(save);
    dialog.addEventListener('cancel',event=>{event.preventDefault();finish(false);});
    document.body.append(dialog);dialog.showModal();cancel.focus();
  });
}
