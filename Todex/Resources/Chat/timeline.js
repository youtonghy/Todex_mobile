'use strict';
const md=window.markdownit({html:false,linkify:true,breaks:true});
md.use(window.todexMath);
// Markdown images are links: no third-party request runs when a message arrives.
md.renderer.rules.image=(tokens,i)=>{const t=tokens[i],src=t.attrGet('src')||'';return md.validateLink(src)?'<a href="'+md.utils.escapeHtml(src)+'">▧ '+md.utils.escapeHtml(t.content||'图片')+'</a>':'[图片]';};
const root=document.getElementById('timeline'),bottom=document.getElementById('bottom');
const quote=document.createElement('button');
quote.id='quote';quote.type='button';quote.textContent='添加到对话';quote.hidden=true;
quote.setAttribute('aria-label','把选中的内容添加到对话');document.body.append(quote);
function updateQuote(){
 const s=getSelection();
 if(!s||s.isCollapsed||!s.rangeCount||!root.contains(s.getRangeAt(0).commonAncestorContainer)||!s.toString().trim()){quote.hidden=true;return;}
 const r=s.getRangeAt(0).getBoundingClientRect();
 quote.dataset.text=s.toString();
 const anchorEl=s.anchorNode?.nodeType===1?s.anchorNode:s.anchorNode?.parentElement;
 quote.dataset.id=anchorEl?.closest('[data-id]')?.dataset.id||'';
 quote.style.left=Math.max(8,Math.min(innerWidth-116,r.left+r.width/2-54))+'px';
 quote.style.top=(r.bottom+8)+'px';
 quote.hidden=false;
}
document.addEventListener('selectionchange',updateQuote);
addEventListener('scroll',()=>{quote.hidden=true;},{passive:true});
quote.onclick=()=>{
 const text=quote.dataset.text||'';
 if(text.trim())bridge({action:'quote',text,id:quote.dataset.id||''});
 getSelection()?.removeAllRanges();quote.hidden=true;
};
let initial=true;const openDetails=new Set();const openTools=new Set();
const activityLabel={tool:'工具活动',reasoning:'思考过程',status:'状态',assistant_progress:'进度',usage:'用量'};
const isActivity=m=>Object.prototype.hasOwnProperty.call(activityLabel,m.category);
const runningStatus=m=>['running','streaming','awaitingApproval','in_progress'].includes(m.status);
const toolState=m=>m.status==='failed'?'failed':m.status==='awaitingApproval'?'waiting':runningStatus(m)?'running':'done';
const toolStateLabel={running:'正在调用',waiting:'等待审批',failed:'调用失败',done:'已调用'};
// Each tool call is its own card, like the desktop ChatTool: the summary names
// the call and its state; the captured input/output stays folded underneath.
function renderTool(item){
 const card=document.createElement('details');card.className='tool';card.dataset.state=toolState(item);
 const s=document.createElement('summary');
 const name=document.createElement('span');name.className='tool-name';name.textContent=item.tool||'工具调用';
 const hint=document.createElement('span');hint.className='tool-hint';hint.textContent=toolStateLabel[card.dataset.state];
 s.append(name,hint);card.append(s);
 if(item.text){const body=document.createElement('div');body.className='body';renderBody(body,item.text);card.append(body);}
 card.open=openTools.has(item.id);card.ontoggle=()=>card.open?openTools.add(item.id):openTools.delete(item.id);
 card.oncontextmenu=e=>{if(getSelection()?.toString())return;e.preventDefault();bridge({action:'message',id:item.id,text:item.text});};
 return card;
}
function bridge(value){window.webkit.messageHandlers.chat.postMessage(value);}
function nearBottom(){return document.documentElement.scrollHeight-innerHeight-scrollY<130;}
function updateBottom(){bottom.style.display=nearBottom()?'none':'block';}
addEventListener('scroll',updateBottom,{passive:true});bottom.onclick=()=>{scrollTo({top:document.documentElement.scrollHeight,behavior:matchMedia('(prefers-reduced-motion:reduce)').matches?'instant':'smooth'});};
function renderBody(body,text){
 body.innerHTML=md.render(text||'');
 body.querySelectorAll('pre code').forEach(code=>{if(code.textContent.length<32000){try{hljs.highlightElement(code);}catch{}}});
 body.querySelectorAll('pre').forEach(pre=>{const copy=document.createElement('button');copy.className='copy';copy.textContent='复制';copy.setAttribute('aria-label','复制代码');copy.onclick=()=>bridge({action:'copy',text:pre.textContent});pre.prepend(copy);});
}
function formatSize(bytes){if(!bytes)return'';if(bytes<1024)return bytes+' B';if(bytes<1048576)return Math.round(bytes/1024)+' KB';return (bytes/1048576).toFixed(1)+' MB';}
// Receipts of what an outgoing message carried; backend events do not echo
// attachments, so the client joins them by request id. Images get a local
// thumbnail data URL; files and references show name and size.
function renderAttachments(list){
 const box=document.createElement('div');box.className='attachments';
 for(const a of list){
  const item=document.createElement('span');item.className='attachment';
  if(a.preview){const img=document.createElement('img');img.src=a.preview;img.alt=a.name||'附件';item.append(img);}
  const label=document.createElement('span');label.className='attachment-name';
  label.textContent=(a.name||'附件')+(a.sizeBytes?' · '+formatSize(a.sizeBytes):'');
  item.append(label);box.append(item);
 }
 return box;
}
// Consecutive activity events collapse into one group: while the turn runs the
// summary reads 正在工作, afterwards only a single folded row remains so the
// final output is what the timeline shows.
function renderActivityGroup(items,existing){
 const key='group:'+items[0].id,signature=JSON.stringify(items);
 let article=existing.get(key);if(article?.dataset.signature===signature){existing.delete(key);return article;}
 if(!article){article=document.createElement('article');article.dataset.id=key;}
 article.dataset.signature=signature;article.className='message activity';article.replaceChildren();
 const last=items[items.length-1],running=items.some(runningStatus);
 const d=document.createElement('details');d.className='activity';
 const s=document.createElement('summary');s.textContent=running?'正在工作 · '+activityLabel[last.category]+' · '+(last.text||'').slice(0,40):'过程记录 · '+items.length+' 项';d.append(s);
 const populate=()=>{if(d.dataset.loaded)return;d.dataset.loaded='1';for(const item of items){if(item.category==='tool'){d.append(renderTool(item));continue;}const row=document.createElement('div');row.className='activity-item';const label=document.createElement('div');label.className='activity-label';label.textContent=activityLabel[item.category];const body=document.createElement('div');body.className='body';renderBody(body,item.text);row.append(label,body);row.oncontextmenu=e=>{if(getSelection()?.toString())return;e.preventDefault();bridge({action:'message',id:item.id,text:item.text});};d.append(row);}};
 d.open=openDetails.has(key);if(d.open)populate();d.ontoggle=()=>{if(d.open){openDetails.add(key);populate();}else openDetails.delete(key);};article.append(d);existing.delete(key);return article;
}
window.renderTimeline=function(messages,provider,fontSize){
 const follow=initial||nearBottom(),top=scrollY;root.style.fontSize=fontSize+'px';
 const existing=new Map([...root.querySelectorAll('.message')].map(e=>[e.dataset.id,e]));
 if(!messages.length){root.innerHTML='<div class="empty"><h2>一起把想法变成现实</h2><p>描述你的任务，或从操作台引用文件。</p></div>';return;}
 root.querySelector('.empty')?.remove();
 for(let i=0;i<messages.length;i++){const message=messages[i];
  if(isActivity(message)){
   const run=[message];while(i+1<messages.length&&isActivity(messages[i+1]))run.push(messages[++i]);
   root.append(renderActivityGroup(run,existing));continue;
  }
  let article=existing.get(message.id);existing.delete(message.id);
  const signature=JSON.stringify(message);if(article?.dataset.signature===signature){root.append(article);continue;}
  if(!article){article=document.createElement('article');article.dataset.id=message.id;}
  article.dataset.signature=signature;article.className='message '+(message.role==='user'?'user':message.category==='error'?'error':'');article.replaceChildren();
  const meta=document.createElement('div');meta.className='meta';const who=document.createElement('span');who.className='brand';who.textContent=message.role==='user'?'你':provider;meta.append(who);
  if(runningStatus(message)){const status=document.createElement('span');status.textContent='正在生成…';meta.append(status);}article.append(meta);
  const body=document.createElement('div');body.className='body';renderBody(body,message.text);article.append(body);
  if(Array.isArray(message.attachments)&&message.attachments.length)article.append(renderAttachments(message.attachments));
  article.oncontextmenu=e=>{if(getSelection()?.toString())return;e.preventDefault();bridge({action:'message',id:message.id,text:message.text});};
  root.append(article);
 }existing.forEach(e=>e.remove());
 if(follow)scrollTo(0,document.documentElement.scrollHeight);else scrollTo(0,top);initial=false;updateBottom();
};
document.addEventListener('click',e=>{const a=e.target.closest('a');if(a){e.preventDefault();bridge({action:'link',url:a.getAttribute('href')});}});
bridge({action:'ready'});
