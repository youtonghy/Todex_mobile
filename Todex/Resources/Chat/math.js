'use strict';
// Parse math before Markdown consumes TeX's backslashes. Code spans and fences
// retain their normal Markdown meaning; raw HTML and KaTeX trust stay disabled.
window.todexMath = function(md) {
 const inline = [['$$','$$',true],['\\[','\\]',true],['\\(','\\)',false],['$','$',false]];
 md.inline.ruler.before('escape','todex_math',(state,silent)=>{
  const start=state.pos;
  for(const [open,close,display] of inline){
   if(!state.src.startsWith(open,start))continue;
   const begin=start+open.length;
   if(open==='$'&&(/\s/.test(state.src[begin]||'')||state.src[begin]==='$'))continue;
   let end=state.src.indexOf(close,begin);
   while(end>=0&&state.src[end-1]==='\\')end=state.src.indexOf(close,end+close.length);
   if(end<0||end===begin||end-begin>16000)return false;
   if(open==='$'&&(/\s/.test(state.src[end-1])||/\d/.test(state.src[end+1]||'')))return false;
   if(!silent){const token=state.push('todex_math','',0);token.content=state.src.slice(begin,end);token.meta={display};}
   state.pos=end+close.length;return true;
  }return false;
 });
 md.block.ruler.before('paragraph','todex_math_block',(state,startLine,endLine,silent)=>{
  const start=state.bMarks[startLine]+state.tShift[startLine];
  const line=state.src.slice(start,state.eMarks[startLine]).trimEnd();
  const open=line.startsWith('$$')?'$$':line.startsWith('\\[')?'\\[':null;
  if(!open)return false;const close=open==='$$'?'$$':'\\]';
  let end=startLine,parts=[line.slice(open.length)],found=false;
  while(end<endLine){const last=parts[parts.length-1];if(last.endsWith(close)){parts[parts.length-1]=last.slice(0,-close.length);found=true;break;}if(++end>=endLine)break;parts.push(state.src.slice(state.bMarks[end]+state.tShift[end],state.eMarks[end]));}
  if(!found||parts.join('\n').length>16000)return false;
  if(silent)return true;
  const token=state.push('todex_math','',0);token.content=parts.join('\n');token.meta={display:true};token.block=true;token.map=[startLine,end+1];state.line=end+1;return true;
 },{alt:['paragraph','reference','blockquote','list']});
 md.renderer.rules.todex_math=(tokens,i)=>{
  try{return katex.renderToString(tokens[i].content,{displayMode:tokens[i].meta.display,throwOnError:false,trust:false,maxExpand:500,maxSize:20});}
  catch{return md.utils.escapeHtml(tokens[i].content);}
 };
};
