export function titleFromPath(path) {
  if (path.endsWith('/.index.md')) path=path.slice(0,-10);
  return path.split('/').pop().replace(/\.(md|markdown|mdown|mkdn)$/i, '').replace(/[-_]+/g, ' ').trim().split(/\s+/).map(word => word ? word[0].toUpperCase() + word.slice(1) : '').join(' ');
}
export function titleFromInput(value) {
  value = value.trim();
  return /^[\p{Ll}\p{N}]+(?:[-_][\p{Ll}\p{N}]+)+$/u.test(value) ? titleFromPath(value) : value;
}
export function slugFromTitle(value) {
  const russian = Object.fromEntries([..."абвгдеёжзийклмнопрстуфхцчшщъыьэюя"].map((letter, i) => [letter, ['a','b','v','g','d','e','yo','zh','z','i','y','k','l','m','n','o','p','r','s','t','u','f','kh','ts','ch','sh','shch','','y','','e','yu','ya'][i]]));
  return [...value.normalize('NFC').toLowerCase()].map(letter => russian[letter] ?? letter).join('').normalize('NFKD').replace(/\p{M}/gu, '').replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
}
if (typeof window !== 'undefined') window.projectbookNames = {titleFromPath, titleFromInput, slugFromTitle};
