// Keep Markdown layout outside task labels, including a break whose newline
// lies just beyond the selected range.
export function sourceTodoSelection(text, following='') {
  const parts=text.split(/(\r\n|[\n\r\u2028\u2029])/);
  const titles=[];
  const rows=[];
  for(let i=0;i<parts.length;i+=2){
    const line=parts[i], newline=parts[i+1] || '';
    const leading=line.match(/^[ \t]*/)[0];
    let body=line.slice(leading.length), suffix='';
    const hasBreak=!!newline || (i===parts.length-1 && /^(?:\r\n|[\n\r])/.test(following));
    const slashes=body.match(/\\+$/)?.[0].length || 0;
    if(hasBreak && slashes%2===1){body=body.slice(0,-1);suffix='\\';}
    const trailing=body.match(/[ \t]*$/)[0];
    body=body.slice(0,body.length-trailing.length);
    suffix=trailing+suffix;
    const title=body.replace(/^(?:[-+*]|\d+[.)])\s+(?:\[[ xX]\]\s+)?/, '').trim();
    const index=title ? titles.push(title)-1 : -1;
    rows.push({original:line,newline,leading,suffix,index});
  }
  return {titles,render:links=>rows.map(row=>row.index<0 ? row.original+row.newline : row.leading+links[row.index]+row.suffix+row.newline).join('')};
}

export function todoTitles(text, markdown=false) {
  if(markdown)return sourceTodoSelection(text).titles;
  return text.split(/\r\n|[\n\r\u2028\u2029]/).map(line=>{
    let title=line.trim();
    if(markdown)title=title.replace(/^(?:[-+*]|\d+[.)])\s+(?:\[[ xX]\]\s+)?/, '');
    return title.trim();
  }).filter(Boolean);
}
