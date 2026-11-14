export const enterModeKey='projectbook:editor:enter-mode';
export function enterAction(mode,{metaKey=false,ctrlKey=false,shiftKey=false,altKey=false,isComposing=false}={}) {
  if(isComposing || altKey)return null;
  if(shiftKey)return 'break';
  const modified=metaKey || ctrlKey;
  return (mode==='line-break')!==modified ? 'break' : 'paragraph';
}
