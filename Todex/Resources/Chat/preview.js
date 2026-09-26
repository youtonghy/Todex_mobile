'use strict';
// Localized by the host app (window.todexL10n); falls back to the source text.
const tr=k=>(window.todexL10n&&window.todexL10n[k])||k;
if(window.todexLang)document.documentElement.lang=window.todexLang;
document.getElementById('doc')?.setAttribute('aria-label',tr('文档预览'));
const md=window.markdownit({html:false,linkify:true,breaks:true});
md.use(window.todexMath);
// Images have no backend file proxy in preview: render them as links like the
// timeline does instead of issuing requests the CSP would block anyway.
md.renderer.rules.image=(tokens,i)=>{const t=tokens[i],src=t.attrGet('src')||'';return md.validateLink(src)?'<a href="'+md.utils.escapeHtml(src)+'">▧ '+md.utils.escapeHtml(t.content||tr('图片'))+'</a>':tr('[图片]');};
const root=document.getElementById('doc');
function bridge(value){window.webkit.messageHandlers.chat.postMessage(value);}
window.renderDocument=(text,fontSize)=>{
 root.innerHTML=md.render(text||'');
 if(fontSize>0)root.style.fontSize=fontSize+'px';
 root.querySelectorAll('pre').forEach(pre=>{
  const code=pre.querySelector('code');
  if(code&&code.textContent.length<32000){try{hljs.highlightElement(code);}catch{}}
  const copy=document.createElement('button');copy.className='copy';copy.textContent=tr('复制');copy.setAttribute('aria-label',tr('复制代码'));
  copy.onclick=()=>bridge({action:'copy',text:code?code.textContent:pre.textContent});pre.prepend(copy);
 });
};
document.addEventListener('click',e=>{const a=e.target.closest('a');if(a){e.preventDefault();bridge({action:'link',url:a.getAttribute('href')});}});
bridge({action:'ready'});
