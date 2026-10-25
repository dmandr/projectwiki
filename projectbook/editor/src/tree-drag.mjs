export const parentPath = path => path.split('/').slice(0, -1).join('/');
export function dropIntent(source, target, folder, fraction) {
  if (!source || source === target) return null;
  if (folder && fraction >= 1/3 && fraction <= 2/3) {
    return parentPath(source) === target ? null : {action:'move',folder:target};
  }
  if (parentPath(source) !== parentPath(target)) return null;
  return {action:'reorder',folder:parentPath(source),position:fraction < 0.5 ? 'before' : 'after'};
}
