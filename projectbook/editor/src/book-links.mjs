import {fromMarkdown} from 'mdast-util-from-markdown';
import {toMarkdown} from 'mdast-util-to-markdown';
import {gfmFootnote} from 'micromark-extension-gfm-footnote';
import {gfmFootnoteFromMarkdown,gfmFootnoteToMarkdown} from 'mdast-util-gfm-footnote';
import {frontmatter} from 'micromark-extension-frontmatter';
import {frontmatterFromMarkdown} from 'mdast-util-frontmatter';
import {decodeNamedCharacterReference} from 'decode-named-character-reference';

const encode = path => path.split('/').map(encodeURIComponent).join('/');
const decode = value => value.replace(/&(#x[\da-f]+|#\d+|[a-z][\da-z]+);/gi, (all, name) => {
  if (!name.startsWith('#')) return decodeNamedCharacterReference(name) || all;
  const code = name[1].toLowerCase()==='x' ? parseInt(name.slice(2),16) : Number(name.slice(1));
  return code>0 && code<=0x10ffff ? String.fromCodePoint(code) : all;
});
const escape = value => value.replace(/&/g,'&amp;').replace(/"/g,'&quot;').replace(/'/g,'&#39;');
export function movedPath(path, source, target) {
  return path===source ? target : path.startsWith(source+'/') ? target+path.slice(source.length) : path;
}
export function rewriteBookLinks(text, from, to, source, target, paths) {
  const known = new Set(paths);
  const resolve = path => known.has(path) ? path : [path+'.md',path+'.markdown'].find(p=>known.has(p)) || path;
  function url(value, wiki=false) {
    if (!value || /^(?:[a-z][a-z\d+.-]*:|\/\/|#|\?)/i.test(value)) return value;
    let parsed; try { parsed=new URL(value,'https://book.invalid/'+encode(from)); } catch { return value; }
    if(parsed.origin!=='https://book.invalid') return value;
    let path; try { path=decodeURIComponent(parsed.pathname).slice(1); } catch { return value; }
    let route='';
    for(const prefix of ['gollum/file/','gollum/overview/','gollum/edit/','gollum/history/']) {
      if(path.startsWith(prefix)){route=prefix;path=path.slice(prefix.length);break;}
    }
    const trailing=path.endsWith('/'); path=path.replace(/\/$/,'');
    const resolved=resolve(path), mapped=movedPath(resolved,source,target);
    if(mapped===resolved && from===to) return value;
    if(value.startsWith('/') && mapped===resolved) return value;
    // A moved wiki link is made explicit to avoid title/basename ambiguity.
    const resultPath=mapped===resolved ? path : mapped;
    let output=route+encode(resultPath)+(trailing?'/':'');
    if(value.startsWith('/')) output='/'+output;
    else {
      const dest=output.split('/'), parent=encode(to).split('/').slice(0,-1);
      while(parent.length && dest.length && parent[0]===dest[0]){parent.shift();dest.shift();}
      output='../'.repeat(parent.length)+dest.join('/') || './';
    }
    return output+parsed.search+parsed.hash;
  }
  const tree=fromMarkdown(text,{extensions:[frontmatter(['yaml','toml']),gfmFootnote()],mdastExtensions:[frontmatterFromMarkdown(['yaml','toml']),gfmFootnoteFromMarkdown()]});
  const edits=[], protectedRanges=[];
  const range=node=>[node.position.start.offset,node.position.end.offset];
  // Raw HTML code regions may span several Markdown AST nodes.
  const raw= /<!--[\s\S]*?-->|<(script|style|pre|code)\b[^>]*>[\s\S]*?<\/\1\s*>/gi;
  for(const match of text.matchAll(raw)) protectedRanges.push([match.index,match.index+match[0].length]);
  const protectedAt=(a,b)=>protectedRanges.some(([x,y])=>a<y && b>x);
  function html(value){
    return value.replace(/<!--[\s\S]*?-->|<(script|style|pre|code)\b[^>]*>[\s\S]*?<\/\1\s*>|<[a-z][\w:-]*\b(?:[^"'<>]|"[^"]*"|'[^']*')*>/gi,(tag,raw)=>raw || tag.startsWith('<!--') ? tag : tag.replace(/(\s(?:src|href)\s*=\s*)(?:"([^"]*)"|'([^']*)'|([^\s>]+))/gi,(all,lead,dq,sq,bare)=>{
      const original=dq??sq??bare, next=url(decode(original));
      return next===decode(original)?all:lead+'"'+escape(next)+'"';
    }));
  }
  function rewrite(node){
    let changed=false;
    if(['link','image','definition'].includes(node.type)){const next=url(node.url);changed=next!==node.url;node.url=next;}
    for(const child of node.children||[]) changed=rewrite(child)||changed;
    return changed;
  }
  function visit(node){
    const [a,b]=range(node);
    if(['code','inlineCode','yaml','toml'].includes(node.type)){protectedRanges.push([a,b]);return;}
    if(protectedRanges.some(([x,y])=>a>=x && b<=y) && node.type!=='root') return;
    if(['link','image','definition'].includes(node.type)){
      protectedRanges.push([a,b]);
      if(rewrite(node))edits.push({a,b,text:toMarkdown(node,{extensions:[gfmFootnoteToMarkdown()]}).trimEnd()});
    } else if(node.type==='html'){
      // Keep comments and code regions byte-for-byte, including examples.
      const next=html(node.value);if(next!==node.value)edits.push({a,b,text:next});
      protectedRanges.push([a,b]);
    } else for(const child of node.children||[])visit(child);
  }
  visit(tree);
  for(const match of text.matchAll(/\[\[([^\]\n]+)\]\]/g)){
    const a=match.index,b=a+match[0].length;
    if(protectedAt(a,b) || (a && text[a-1]==='\\'))continue;
    const pieces=match[1].split('|');if(pieces.length>2)continue;
    const index=pieces.length-1, original=pieces[index].trim(),next=url(original,true);
    if(next!==original){pieces[index]=pieces[index].replace(original,next);edits.push({a,b,text:'[['+pieces.join('|')+']]'});}
  }
  for(const edit of edits.sort((a,b)=>b.a-a.a)) text=text.slice(0,edit.a)+edit.text+text.slice(edit.b);
  return text;
}
