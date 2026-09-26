'use strict';
// Localized by the host app (window.todexL10n); falls back to the source text.
const tr=k=>(window.todexL10n&&window.todexL10n[k])||k;
if(window.todexLang)document.documentElement.lang=window.todexLang;
document.getElementById('timeline')?.setAttribute('aria-label',tr('对话记录'));
{const b=document.getElementById('bottom');if(b){b.setAttribute('aria-label',tr('回到最新消息'));b.textContent=tr('↓ 最新消息');}}
const md=window.markdownit({html:false,linkify:true,breaks:true});
md.use(window.todexMath);
// Markdown images are links: no third-party request runs when a message arrives.
md.renderer.rules.image=(tokens,i)=>{const t=tokens[i],src=t.attrGet('src')||'';return md.validateLink(src)?'<a href="'+md.utils.escapeHtml(src)+'">▧ '+md.utils.escapeHtml(t.content||tr('图片'))+'</a>':tr('[图片]');};
const root=document.getElementById('timeline'),bottom=document.getElementById('bottom');
const quote=document.createElement('button');
quote.id='quote';quote.type='button';quote.textContent=tr('添加到对话');quote.hidden=true;
quote.setAttribute('aria-label',tr('把选中的内容添加到对话'));document.body.append(quote);
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
let initial=true;const openDetails=new Set();const openTools=new Set();const pendingLoads=new Set();
const activityLabel={tool:tr('工具活动'),reasoning:tr('思考过程'),status:tr('状态'),assistant_progress:tr('进度'),usage:tr('用量')};
// Desktop parity: progress narration reads like a message, so it stays a
// visible line that splits tool runs. Summary-replay stubs have no text yet
// and fold until the group hydrates them.
const isProgressLine=m=>m.category==='assistant_progress'&&!m.stub&&!!(m.text||'').trim();
const isActivity=m=>Object.prototype.hasOwnProperty.call(activityLabel,m.category)&&!isProgressLine(m);
const runningStatus=m=>['running','streaming','awaitingApproval','in_progress'].includes(m.status);
const toolState=m=>m.status==='failed'?'failed':m.status==='awaitingApproval'?'waiting':runningStatus(m)?'running':'done';
const toolStateLabel={running:tr('正在调用'),waiting:tr('等待审批'),failed:tr('调用失败'),done:tr('已调用')};
// Each tool call is its own card, like the desktop ChatTool: the summary names
// the call and its state; the captured input/output stays folded underneath.
function renderTool(item){
 const info=item.tool||{};
 const card=document.createElement('details');card.className='tool';card.dataset.state=info.failed?'failed':toolState(item);
 const s=document.createElement('summary');
 const name=document.createElement('span');name.className='tool-name';name.textContent=info.name||tr('工具调用');s.append(name);
 // The key argument (command, path, query) identifies the call without expanding.
 if(info.summary){const sum=document.createElement('span');sum.className='tool-summary';sum.textContent=info.summary;s.append(sum);}
 const hint=document.createElement('span');hint.className='tool-hint';hint.textContent=toolStateLabel[card.dataset.state];
 s.append(hint);card.append(s);
 const sections=[[tr('参数'),info.args],[tr('输出'),info.output],[tr('错误'),info.error]].filter(([,text])=>text);
 if(sections.length){
  for(const [label,text] of sections){
   const section=document.createElement('div');section.className='tool-section'+(label===tr('错误')?' tool-error':'');
   const title=document.createElement('div');title.className='activity-label';title.textContent=label;
   const pre=document.createElement('pre');const code=document.createElement('code');code.textContent=text;pre.append(code);
   section.append(title,pre);card.append(section);
  }
 }else if(item.text){const body=document.createElement('div');body.className='body';renderBody(body,item.text);card.append(body);}
 card.open=openTools.has(item.id);card.ontoggle=()=>card.open?openTools.add(item.id):openTools.delete(item.id);
 card.oncontextmenu=e=>{if(getSelection()?.toString())return;e.preventDefault();bridge({action:'message',id:item.id,text:info.output||info.error||info.args||item.text});};
 return card;
}
function bridge(value){window.webkit.messageHandlers.chat.postMessage(value);}
// Earlier-history paging: the sentinel row sits above the loaded window. The
// native side owns `more`/`loading`; `failed` is local until the next render.
let history={more:false,loading:false,failed:false};
function requestEarlier(){if(!history.more||history.loading||history.failed)return;history.loading=true;renderHistory();bridge({action:'loadEarlier'});}
function renderHistory(){
 let row=document.getElementById('history');
 if(!history.more){row?.remove();return;}
 if(!row){row=document.createElement('button');row.id='history';row.type='button';row.onclick=()=>{history.failed=false;requestEarlier();};}
 row.disabled=history.loading;
 row.textContent=history.failed?tr('加载更早的记录失败，点按重试'):history.loading?tr('正在加载更早的记录…'):tr('加载更早的消息');
 if(root.firstElementChild!==row)root.prepend(row);
}
window.historyLoadFailed=function(){history.failed=true;history.loading=false;renderHistory();};
addEventListener('scroll',()=>{if(scrollY<240)requestEarlier();},{passive:true});
function nearBottom(){return document.documentElement.scrollHeight-innerHeight-scrollY<130;}
function updateBottom(){bottom.style.display=nearBottom()?'none':'block';}
addEventListener('scroll',updateBottom,{passive:true});bottom.onclick=()=>{scrollTo({top:document.documentElement.scrollHeight,behavior:matchMedia('(prefers-reduced-motion:reduce)').matches?'instant':'smooth'});};
function renderBody(body,text){
 body.innerHTML=md.render(text||'');
 body.querySelectorAll('pre code').forEach(code=>{if(code.textContent.length<32000){try{hljs.highlightElement(code);}catch{}}});
 body.querySelectorAll('pre').forEach(pre=>{const copy=document.createElement('button');copy.className='copy';copy.textContent=tr('复制');copy.setAttribute('aria-label',tr('复制代码'));copy.onclick=()=>bridge({action:'copy',text:pre.textContent});pre.prepend(copy);});
}
function formatSize(bytes){if(!bytes)return'';if(bytes<1024)return bytes+' B';if(bytes<1048576)return Math.round(bytes/1024)+' KB';return (bytes/1048576).toFixed(1)+' MB';}
// Receipts of what an outgoing message carried; backend events do not echo
// attachments, so the client joins them by request id. Images get a local
// thumbnail data URL; files and references show name and size.
function renderAttachments(list,messageId){
 const box=document.createElement('div');box.className='attachments';
 for(const a of list){
  const item=document.createElement('span');item.className='attachment';
  // Receipts open a read-only preview of what was sent (desktop parity).
  item.setAttribute('role','button');item.tabIndex=0;
  item.onclick=e=>{e.stopPropagation();bridge({action:'attachment',messageId,attachmentId:a.id||''});};
  if(a.preview){const img=document.createElement('img');img.src=a.preview;img.alt=a.name||tr('附件');item.append(img);}
  const label=document.createElement('span');label.className='attachment-name';
  label.textContent=(a.name||tr('附件'))+(a.sizeBytes?' · '+formatSize(a.sizeBytes):'');
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
 const s=document.createElement('summary');s.textContent=running?tr('正在工作 · ')+activityLabel[last.category]:tr('工作过程');d.append(s);
 const populate=()=>{if(d.dataset.loaded)return;d.dataset.loaded='1';
  const stubs=items.filter(i=>i.stub);
  if(stubs.length){
   const row=document.createElement('div');row.className='activity-loading';row.textContent=tr('正在加载过程记录…');d.append(row);
   if(!pendingLoads.has(key)){
    const seqs=stubs.map(i=>i.sequence).filter(n=>typeof n==='number'&&n>0);
    if(seqs.length){pendingLoads.add(key);d.dataset.from=String(Math.min(...seqs));d.dataset.to=String(Math.max(...seqs));bridge({action:'loadActivity',key,from:d.dataset.from,to:d.dataset.to});}
   }
   return;
  }
  for(const item of items){if(item.category==='tool'){d.append(renderTool(item));continue;}const row=document.createElement('div');row.className='activity-item';const label=document.createElement('div');label.className='activity-label';label.textContent=activityLabel[item.category];const body=document.createElement('div');body.className='body';renderBody(body,item.text);row.append(label,body);row.oncontextmenu=e=>{if(getSelection()?.toString())return;e.preventDefault();bridge({action:'message',id:item.id,text:item.text});};d.append(row);}};
 d.open=openDetails.has(key);if(d.open)populate();d.ontoggle=()=>{if(d.open){openDetails.add(key);populate();}else openDetails.delete(key);};article.append(d);existing.delete(key);return article;
}
window.renderTimeline=function(messages,provider,fontSize,historyState){
 if(historyState)history={more:!!historyState.more,loading:!!historyState.loading,failed:history.failed&&!!historyState.more};
 const follow=initial||nearBottom(),top=scrollY;
 // Anchor to the topmost rendered row: prepended history and bottom appends
 // both keep the row under the viewport stable instead of restoring a raw offset.
 const anchor=root.querySelector('.message'),anchorTop=anchor?anchor.offsetTop:0,anchorId=anchor?.dataset.id;
 root.style.fontSize=fontSize+'px';
 const existing=new Map([...root.querySelectorAll('.message')].map(e=>[e.dataset.id,e]));
 if(!messages.length){root.innerHTML='<div class="empty"><h2>'+tr('一起把想法变成现实')+'</h2><p>'+tr('描述你的任务，或从操作台引用文件。')+'</p></div>';renderHistory();return;}
 root.querySelector('.empty')?.remove();
 for(let i=0;i<messages.length;i++){const message=messages[i];
  if(isActivity(message)){
   const run=[message];while(i+1<messages.length&&isActivity(messages[i+1]))run.push(messages[++i]);
   root.append(renderActivityGroup(run,existing));continue;
  }
  let article=existing.get(message.id);existing.delete(message.id);
  const signature=JSON.stringify(message);if(article?.dataset.signature===signature){root.append(article);continue;}
  if(!article){article=document.createElement('article');article.dataset.id=message.id;}
  article.dataset.signature=signature;article.className='message '+(message.role==='user'?'user':message.category==='error'?'error':isProgressLine(message)?'progress':'');article.replaceChildren();
  if(!isProgressLine(message)){const meta=document.createElement('div');meta.className='meta';const who=document.createElement('span');who.className='brand';who.textContent=message.role==='user'?tr('你'):provider;meta.append(who);
  if(runningStatus(message)){const status=document.createElement('span');status.textContent=tr('正在生成…');meta.append(status);}article.append(meta);}
  const body=document.createElement('div');body.className='body';renderBody(body,message.text);article.append(body);
  if(Array.isArray(message.attachments)&&message.attachments.length)article.append(renderAttachments(message.attachments,message.id));
  article.oncontextmenu=e=>{if(getSelection()?.toString())return;e.preventDefault();bridge({action:'message',id:message.id,text:message.text});};
  root.append(article);
 }existing.forEach(e=>e.remove());
 renderHistory();
 if(follow)scrollTo(0,document.documentElement.scrollHeight);
 else if(anchorId){const now=root.querySelector('[data-id="'+CSS.escape(anchorId)+'"]');scrollTo(0,now?top+now.offsetTop-anchorTop:top);}
 else scrollTo(0,top);
 initial=false;updateBottom();
 // A window shorter than the viewport still pages back until it fills.
 if(history.more&&!history.loading&&!history.failed&&document.documentElement.scrollHeight<=innerHeight+80)requestEarlier();
};
window.activityLoadFailed=function(key){
 pendingLoads.delete(key);
 const d=root.querySelector('[data-id="'+CSS.escape(key)+'"] details.activity');if(!d)return;
 d.querySelectorAll('.activity-loading,.activity-load-failed').forEach(e=>e.remove());
 const row=document.createElement('div');row.className='activity-load-failed';row.textContent=tr('加载过程记录失败，点按重试');
 row.onclick=()=>{row.className='activity-loading';row.textContent=tr('正在加载过程记录…');row.onclick=null;pendingLoads.add(key);bridge({action:'loadActivity',key,from:d.dataset.from||'0',to:d.dataset.to||'0'});};
 d.append(row);
};
document.addEventListener('click',e=>{const a=e.target.closest('a');if(a){e.preventDefault();bridge({action:'link',url:a.getAttribute('href')});}});
bridge({action:'ready'});
