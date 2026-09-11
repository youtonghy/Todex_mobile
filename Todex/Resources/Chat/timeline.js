'use strict';
const md=window.markdownit({html:false,linkify:true,breaks:true});
md.use(window.todexMath);
// Markdown images are links: no third-party request runs when a message arrives.
md.renderer.rules.image=(tokens,i)=>{const t=tokens[i],src=t.attrGet('src')||'';return md.validateLink(src)?'<a href="'+md.utils.escapeHtml(src)+'">▧ '+md.utils.escapeHtml(t.content||'图片')+'</a>':'[图片]';};
const root=document.getElementById('timeline'),bottom=document.getElementById('bottom');
let initial=true;const openDetails=new Set();
const activityLabel={tool:'工具活动',reasoning:'思考过程',status:'状态',assistant_progress:'进度',usage:'用量'};
const isActivity=m=>Object.prototype.hasOwnProperty.call(activityLabel,m.category);
const runningStatus=m=>['running','streaming','awaitingApproval','in_progress'].includes(m.status);
function bridge(value){window.webkit.messageHandlers.chat.postMessage(value);}
function nearBottom(){return document.documentElement.scrollHeight-innerHeight-scrollY<130;}
function updateBottom(){bottom.style.display=nearBottom()?'none':'block';}
addEventListener('scroll',updateBottom,{passive:true});bottom.onclick=()=>{scrollTo({top:document.documentElement.scrollHeight,behavior:matchMedia('(prefers-reduced-motion:reduce)').matches?'instant':'smooth'});};
function renderBody(body,text){
 body.innerHTML=md.render(text||'');
 body.querySelectorAll('pre code').forEach(code=>{if(code.textContent.length<32000){try{hljs.highlightElement(code);}catch{}}});
 body.querySelectorAll('pre').forEach(pre=>{const copy=document.createElement('button');copy.className='copy';copy.textContent='复制';copy.setAttribute('aria-label','复制代码');copy.onclick=()=>bridge({action:'copy',text:pre.textContent});pre.prepend(copy);});
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
 const s=document.createElement('summary');
 s.textContent=running
  ?'正在工作 · '+activityLabel[last.category]+' · '+(last.text||'').slice(0,40)
  :'过程记录 · '+items.length+' 项';
 d.append(s);
 for(const item of items){
  const row=document.createElement('div');row.className='activity-item';
  const label=document.createElement('div');label.className='activity-label';label.textContent=activityLabel[item.category];
  const body=document.createElement('div');body.className='body';renderBody(body,item.text);
  row.append(label,body);
  row.oncontextmenu=e=>{if(getSelection()?.toString())return;e.preventDefault();bridge({action:'message',id:item.id,text:item.text});};
  d.append(row);
 }
 d.open=openDetails.has(key);d.ontoggle=()=>d.open?openDetails.add(key):openDetails.delete(key);
 article.append(d);existing.delete(key);return article;
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
  article.oncontextmenu=e=>{if(getSelection()?.toString())return;e.preventDefault();bridge({action:'message',id:message.id,text:message.text});};
  root.append(article);
 }existing.forEach(e=>e.remove());
 if(follow)scrollTo(0,document.documentElement.scrollHeight);else scrollTo(0,top);initial=false;updateBottom();
};
document.addEventListener('click',e=>{const a=e.target.closest('a');if(a){e.preventDefault();bridge({action:'link',url:a.getAttribute('href')});}});
bridge({action:'ready'});
