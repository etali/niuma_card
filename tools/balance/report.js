// Copyright (C) 2026 etali (https://github.com/etali)
// SPDX-License-Identifier: AGPL-3.0-only
// See LICENSE in the project root.

'use strict';
const $=id=>document.getElementById(id);
const esc=x=>String(x??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
let Q=[];
const finite=x=>typeof x==='number'&&Number.isFinite(x);
const number=x=>finite(x)?x.toFixed(1):'未观测';
const signed=x=>finite(x)?(x>0?'+':'')+x.toFixed(1):'未观测';
const clone=x=>JSON.parse(JSON.stringify(x));
const equal=(a,b)=>canonical(a)===canonical(b);
function canonical(x){if(Array.isArray(x))return '['+x.map(canonical).join(',')+']';if(x&&typeof x==='object')return '{'+Object.keys(x).sort().map(k=>JSON.stringify(k)+':'+canonical(x[k])).join(',')+'}';return JSON.stringify(x)}
let data,configs=[],runs=[],draft,sourceId='default',savedId='default',dirty=false,aiValues={},loadingProfile=false,polling=false,submitting=false,savingNotes=false,launching=false,runRevision=0;
const expandedRunDistributions=new Set();
const stopRequests=new Set(),stopErrors=new Map();
const isActiveRun=r=>['queued','running','stopping'].includes(r.status);
const hasRunResult=r=>r?.status==='complete'&&!!r.result?.metrics;
const status={queued:'等待开始',running:'运行中',stopping:'正在停止',complete:'已完成',cancelled:'已停止',interrupted:'上次中断',error:'运行错误'};
const kindLabel={product:'生产卡',attack:'攻击卡',buff:'增益卡',legend:'传说卡',unit:'资源卡'};
const buffs={user_fill:'用户配方补满',output_x2:'产出加倍',attack_x2:'攻击加倍',protect_user:'保护用户',protect_cash:'保护现金'};
function message(text,error=false){$('message').textContent=text;$('message').classList.toggle('error',error)}
async function api(path,body){const response=await fetch(path,{method:body?'POST':'GET',headers:body?{'Content-Type':'application/json','X-Balance-Token':data.token}:{},body:body?JSON.stringify(body):undefined});const result=await response.json();if(!response.ok)throw Error(result.error||'请求失败');return result}
function safe(fn){return async e=>{try{await fn(e)}catch(error){if(error?.name!=='AbortError')message(error.message,true)}}}
function config(id){return configs.find(x=>x.id===id)}
function metricCompatibilityHint(m,q){return q==='Q7'&&m&&m.definition!=='upgrade-production-v1'?'Q7口径已更新，请重新评估。':''}
function compatibleMetric(m,q){return metricCompatibilityHint(m,q)?null:m}
function metric(run,q){return run?.status==='complete'?compatibleMetric(run.result?.metrics?.[q],q):null}
function observedMetric(run,q){const m=metric(run,q);return m&&finite(m.value)?m:null}
function metricText(m){return m&&finite(m.value)?number(m.value)+m.unit:'未观测'}
function countText(m,q){if(!m)return '';if(q==='Q10')return `已归类 ${m.classified_games} 局 · 已出现 ${m.observed_categories} 种 · 配置上限 ${m.category_count} 种 · 未归类胜局 ${m.unclassified_wins} 局`;return `${m.numerator} / ${m.denominator}`}
function winDistribution(m){
 if(!m)return '<p class="muted">未观测：该记录没有获胜方式统计。</p>';
 const rows=Array.isArray(m.distribution)?m.distribution:[];
 return `<p class="muted">${esc(countText(m,'Q10'))}</p>${finite(m.value)?'':'<p class="muted">未观测：没有已归类胜局。</p>'}<table class="win-distribution-table"><thead><tr><th>获胜方式</th><th>局数</th><th>占已归类胜局</th></tr></thead><tbody>${rows.map(x=>`<tr data-win-method="${esc(x.id)}"><td>${esc(x.label)}</td><td>${finite(x.count)?x.count:'未记录'}</td><td>${finite(x.percentage)?number(x.percentage)+'%':'未观测'}</td></tr>`).join('')}</tbody></table>`;
}
function runMetricText(m,q,runId){const hint=metricCompatibilityHint(m,q);return metricText(compatibleMetric(m,q))+(hint?`<small>${hint}</small>`:'')+(q==='Q10'&&m?`<details class="run-win-distribution" data-run-id="${esc(runId)}"${expandedRunDistributions.has(runId)?' open':''}><summary>查看获胜分布</summary>${winDistribution(m)}</details>`:'')}
function metricDelta(a,b,q){const x=metric(a,q)?.value,y=metric(b,q)?.value;return finite(x)&&finite(y)?y-x:null}
function metricUnit(q,a,b){return data.definitions.find(x=>x[0]===q)?.[3]||metric(a,q)?.unit||metric(b,q)?.unit||(q==='Q2'?'回合':'%')}
function comparable(a,b){return !!(hasRunResult(a)&&hasRunResult(b)&&a.engine_fingerprint===b.engine_fingerprint&&a.result.meta.metric_version===b.result.meta.metric_version&&equal({...a.options,ai_parameters:a.result.meta.ai_parameters},{...b.options,ai_parameters:b.result.meta.ai_parameters}))}
function labelQ(q){return data.definitions.find(x=>x[0]===q)[1]}
function option(value,text){return `<option value="${esc(value)}">${esc(text)}</option>`}
function setOptions(id,html,fallback){const prior=$(id).value;$(id).innerHTML=html;$(id).value=Array.from($(id).options).some(x=>x.value===prior)?prior:fallback}
function renderSelectors(){const html=configs.map(c=>option(c.id,c.name)).join('');setOptions('source',html,sourceId);setOptions('compare-a',html,'default');setOptions('compare-b',html,savedId);renderRunOptions('a');renderRunOptions('b')}
function selectSource(id){sourceId=id;savedId=id;draft=clone(config(id).cards);dirty=false;$('source').value=id;$('name').value=config(id).name;$('play-result').hidden=true;renderEditor();renderNotes();renderDirty()}
function draftChanges(){const base=config(sourceId);const changed=data.fields.filter(f=>draft[f.card][f.field]!==base.cards[f.card][f.field]).length;return {changed,nameChanged:$('name').value.trim()!==base.name}}
function nameBlockReason(){
 const name=$('name').value.trim(),{changed,nameChanged}=draftChanges();
 if(!name)return '请填写新版本名称。';
 if(name.length>100)return '配置名称不能超过100字。';
 if(nameChanged&&configs.some(c=>c.id!==sourceId&&c.name===name))return `名称“${name}”已被其他已保存配置使用，请换一个未使用的新名称。`;
 if(changed&&!nameChanged)return `已修改 ${changed} 个卡牌参数；请填写新版本名称，避免同名不同配置。`;
 return '';
}
function draftBlockReason(){const reason=nameBlockReason(),{changed,nameChanged}=draftChanges();if(reason)return reason;if(nameChanged&&!changed)return '新名称已填写；再修改至少一个卡牌参数后即可保存新配置。';return ''}
function assertRunnableDraft(){const reason=draftBlockReason();if(reason)throw Error(reason+' 当前操作未执行。')}
function syncDraftFields(){
 let invalid='';
 for(const input of document.querySelectorAll('.editor input[data-card]')){
  const spec=data.fields.find(f=>f.card===input.dataset.card&&f.field===input.dataset.field),min=spec.min??1;
  if(spec.optional&&input.value===''&&!input.validity?.badInput)delete draft[spec.card][spec.field];
  else{
   if(!input.checkValidity()||!Number.isInteger(input.valueAsNumber)||input.valueAsNumber<min||input.valueAsNumber>(spec.max??2147483647)){invalid=invalid||`${input.getAttribute('aria-label')}必须是${min===0?'非负整数':'正整数'}（不超过${spec.max??2147483647}）。`;continue}
   draft[spec.card][spec.field]=input.valueAsNumber;
  }
  input.classList.toggle('changed',draft[spec.card][spec.field]!==config(sourceId).cards[spec.card][spec.field]);
 }
 return invalid;
}
function simulationBlockReason(){
 for(const input of document.querySelectorAll('.sim-grid input[type=number]')){
  if(input.checkValidity()&&Number.isFinite(input.valueAsNumber))continue;
  const label=({'pairs':'种子对数','max-rounds':'每局回合上限','seed':'起始种子'})[input.id]||data.ai.schema.find(s=>s.key===input.dataset.ai)?.label||'AI 参数';
  return `${label}必须为 ${input.getAttribute('min')}–${input.getAttribute('max')} 范围内的有效数值，步长为 ${input.getAttribute('step')}。`;
 }
 return '';
}
function renderDirty(){
 const invalid=syncDraftFields(),{changed,nameChanged}=draftChanges();
 dirty=changed>0||nameChanged||!!invalid;
 const nameReason=nameBlockReason(),cardReason=invalid||draftBlockReason(),reason=cardReason||simulationBlockReason();
 $('name').setAttribute('aria-invalid',String(!!nameReason));
 $('name-error').textContent=nameReason;
 $('name-error').hidden=!nameReason;
 $('dirty').classList.toggle('error',!!reason);
 if(reason)$('dirty').textContent=reason;
 else if(!dirty)$('dirty').textContent=`名称和参数都未修改；复用“${config(sourceId).name}”，不会新增配置。`;
 else $('dirty').textContent=`已同时修改 ${changed} 个参数和版本名称；保存时会按“${$('name').value.trim()}”创建新版本。`;
 const editingBusy=submitting?'正在保存并启动模拟，请稍候。':savingNotes?'正在保存配置与备注，请稍候。':launching?'正在保存并以当前配置启动游戏，请稍候。':'';
 const busy=editingBusy||(loadingProfile?'正在读取 AI 参数，请稍候。':'');
 const blocked=reason||busy;
 $('run').disabled=!!blocked;
 $('run').title=blocked;
 $('run-reason').textContent=reason?'无法运行：'+reason:busy||(!dirty?'可以运行：复用当前配置，只新增模拟记录。':`可以运行：将保存新配置“${$('name').value.trim()}”并启动模拟。`);
 $('run-reason').classList.toggle('error',!!reason);
 const playBlocked=cardReason||editingBusy;
 $('play').disabled=!!playBlocked;$('play').title=playBlocked;
 $('play-reason').textContent=cardReason?'暂时无法试玩：'+cardReason:editingBusy||(dirty?'将先保存新配置和备注，再打开游戏试玩。':'用所选配置打开游戏试玩，已有配置和评估记录会保留。');
 $('play-reason').classList.toggle('error',!!cardReason);
 renderNotesState(cardReason);
}
function fieldInput(card,field){const f=data.fields.find(x=>x.card===card&&x.field===field);if(!f)return '<span class="muted">—</span>';const v=draft[card][field],changed=v!==config(sourceId).cards[card][field];return `<input type="number" min="${f.min??1}" max="${f.max??2147483647}" step="1" value="${v??''}" ${f.optional?'placeholder="自动"':'required'} data-card="${esc(card)}" data-field="${field}" aria-label="${esc(f.name+' '+f.label)}" class="${changed?'changed':''}">`}
function renderEditor(){
 $('game-fields').innerHTML=data.fields.filter(f=>f.card==='_game').map(f=>`<label>${esc(f.label)}${fieldInput(f.card,f.field)}</label>`).join('');renderCards();
}
function renderCards(){const search=$('card-search').value.trim(),kind=$('kind').value;const cards=Object.entries(draft).filter(([id,c])=>!id.startsWith('_')&&c.kind!=='unit');const total=cards.reduce((s,[,c])=>s+(c.price>=0?c.weight:0),0);
 $('card-rows').innerHTML=cards.filter(([id,c])=>(!search||c.name.includes(search)||id.includes(search))&&(!kind||c.kind===kind)).map(([id,c])=>{
 const res=k=>draft[k]?.name||k;const effect=c.buff_type?buffs[c.buff_type]:c.upgrade_from?`升级来源：${res(c.upgrade_from)==='dup_t2'?'同名二级卡':res(c.upgrade_from)} × ${c.upgrade_dup_n}`:kindLabel[c.kind];
 return `<tr><td><div class="card-identity"><img class="card-thumb" src="assets/art/icon/icon_${encodeURIComponent(id)}.png" alt=""><span><strong>${esc(c.name)}</strong><small>${esc(effect)}</small></span></div></td><td>${fieldInput(id,'price')}</td><td>${fieldInput(id,'pawn')}</td><td>${fieldInput(id,'weight')}</td><td>${fieldInput(id,'recipe_n')}<small>${esc(c.recipe_res?res(c.recipe_res):'')}</small></td><td>${fieldInput(id,'output_n')}<small>${esc(c.output_res?res(c.output_res):'')}</small></td><td>${fieldInput(id,'attack_n')}<small>${esc(c.attack_res?res(c.attack_res):'')}</small></td><td data-probability-card="${esc(id)}">${marketProbability(c,total)}</td></tr>`}).join('');
}
function marketProbability(card,total){const p=total?100*card.weight/total:0;return card.price>=0?`${p.toFixed(1)}%<meter class="probability" min="0" max="100" value="${p}" aria-label="${esc(card.name)}市场单格概率"></meter>`:'不进市场'}
function updateMarketProbabilities(){
 const total=Object.entries(draft).reduce((sum,[id,c])=>sum+(!id.startsWith('_')&&c.kind!=='unit'&&c.price>=0?c.weight:0),0);
 for(const cell of document.querySelectorAll('[data-probability-card]'))cell.innerHTML=marketProbability(draft[cell.dataset.probabilityCard],total);
}
function changeField(e){if(!e.target.dataset.card)return;renderDirty();if(e.target.dataset.field==='weight')updateMarketProbabilities()}
function formValid(includeSimulation=true){const invalid=syncDraftFields()||(includeSimulation?simulationBlockReason():'');const selector=includeSimulation?'.editor input[type=number],.sim-grid input[type=number]':'.editor input[type=number]';for(const n of document.querySelectorAll(selector))if(!n.reportValidity())throw Error('请修正标出的数值');if(invalid)throw Error(invalid);for(const f of data.fields){const v=draft[f.card][f.field];if(f.optional&&v===undefined)continue;if(!Number.isInteger(v)||v<(f.min??1)||v>(f.max??2147483647))throw Error(f.name+' '+f.label+'数值无效')}}
async function saveDraft(){
 formValid(false);renderDirty();assertRunnableDraft();
 if(!dirty)return savedId;
 const snapshot={source_id:sourceId,name:$('name').value.trim(),cards:clone(draft)};
 const c=await api('api/config',snapshot);
 c.notes=c.notes||{text:''};
 if(!config(c.id))configs.push(c);
 // 保存期间切换或继续编辑时，保留当前编辑器；备注仍存到本次保存的配置。
 if(sourceId===snapshot.source_id&&$('name').value.trim()===snapshot.name&&equal(draft,snapshot.cards)){
  savedId=c.id;sourceId=c.id;dirty=false;
  renderSelectors();$('source').value=c.id;$('name').value=c.name;renderEditor();
 }else renderSelectors();
 renderDirty();
 message(c.reused?'名称和参数均未变化，复用已有配置：'+c.name:'已保存新配置：'+c.name);
 return c.id;
}
function notesChanged(){return $('notes').value!==(config(savedId).notes?.text||'')}
function renderNotes(){$('notes').value=config(savedId).notes?.text||''}
function renderNotesState(cardReason){
 const c=config(savedId),name=$('name').value.trim()||'未命名配置';
 $('notes-name').textContent=dirty?`备注将随新配置“${name}”保存；起点“${c.name}”的备注保留。`:'备注所属配置：'+c.name;
 const reason=$('notes').value.length>10000?'备注最多10000字。':dirty?cardReason:'';
 $('save-notes').textContent=dirty?'保存配置与备注':'保存备注';
 $('save-notes').disabled=savingNotes||submitting||launching||!!reason||(!dirty&&!notesChanged());
 $('save-config').disabled=$('save-notes').disabled;
 const saveReason=(savingNotes||submitting||launching)?'正在保存配置与备注…':reason||(!dirty&&!notesChanged()?'配置和备注均未修改，无需重复保存。':'仅保存配置和备注，不启动模拟或游戏。');
 $('save-config').title=saveReason;
 $('save-reason').textContent=saveReason;
 $('save-reason').classList.toggle('error',!!reason);
 $('notes-status').textContent=(savingNotes||submitting||launching)?'正在保存配置与备注…':reason|| (dirty?'保存配置与备注即可，无需运行评估。':notesChanged()?'备注尚未保存。':'备注未修改，无需保存；切换配置会显示对应备注。');
 $('notes-status').classList.toggle('error',!!reason);
}
async function saveConfigNotes(cid,text){
 if(text===(config(cid).notes?.text||''))return;
 const notes=await api('api/notes',{id:cid,text});
 // 请求期间可能切换配置；响应只更新发出请求时的配置。
 config(cid).notes=notes;
 renderDirty();renderComparison();
}
async function saveCurrentConfig(){
 if(savingNotes||submitting||launching)return;
 const text=$('notes').value;savingNotes=true;renderDirty();
 try{const cid=await saveDraft();await saveConfigNotes(cid,text);message(`已保存配置“${config(cid).name}”及试玩备注，未启动模拟或游戏。`)}
 finally{savingNotes=false;renderDirty()}
}
function options(){return {pairs:Number($('pairs').value),max_rounds:Number($('max-rounds').value),seed_start:Number($('seed').value),model:data.ai.model,strength:Number($('strength').value),ai_parameters:clone(aiValues)}}
function renderBudget(){const o=options();$('budget').textContent=`${o.pairs*2} 局 · 每局最多 ${o.max_rounds} 回合 · 种子 ${o.seed_start}–${o.seed_start+o.pairs-1} · 每项模拟独立运行，可并行提交`;}
function renderAI(){ $('ai-fields').innerHTML=data.ai.schema.map(s=>`<label>${esc(s.label)}<input type="number" data-ai="${esc(s.key)}" min="${s.min}" max="${s.max}" step="${s.step}" value="${aiValues[s.key]}"><small>${esc(s.hint)}</small></label>`).join('')}
async function loadProfile(strength){loadingProfile=true;renderDirty();try{const p=await api('api/profile',{strength});data.token=p.token||data.token;aiValues=p.parameters;renderAI();renderBudget()}finally{loadingProfile=false;renderDirty()}}
function elapsedSeconds(r){const end=r.finished||Date.now()/1000;return Math.max(0,end-r.created)}
function formatElapsed(seconds){const s=Math.floor(seconds);const h=Math.floor(s/3600),m=Math.floor(s%3600/60),rest=s%60;return h?`${h}小时${String(m).padStart(2,'0')}分${String(rest).padStart(2,'0')}秒`:m?`${m}分${String(rest).padStart(2,'0')}秒`:`${rest}秒`}
function runProgress(r){const p=r.progress||{completed:0,total:r.options.pairs*2,round:0};return {p,text:`${p.completed}/${p.total}局${r.status==='running'&&p.round?' · 第'+p.round+'回合':''}`}}
function stopControl(r){
 const stopping=stopRequests.has(r.id)||r.status==='stopping';
 const button=isActiveRun(r)?`<button class="stop-run" data-stop-run="${esc(r.id)}" ${stopping?'disabled':''} aria-label="${esc('停止模拟：'+r.name+'（'+r.id+'）')}">${stopping?'正在停止…':'停止模拟'}</button>`:'';
 return button+(stopErrors.has(r.id)?`<small class="error run-stop-error" role="status">${esc(stopErrors.get(r.id))}</small>`:'');
}
function renderRuns(){
 // Native toggle events are deferred; capture the visible state before replacing rows.
 for(const details of $('run-rows').querySelectorAll('.run-win-distribution')){
  if(details.open)expandedRunDistributions.add(details.dataset.runId);else expandedRunDistributions.delete(details.dataset.runId);
 }
 let xs=runs.slice();const q=$('sort').value,dir=$('direction').value==='asc'?1:-1;xs.sort((a,b)=>{const x=q==='created'?a.created:metric(a,q)?.value,y=q==='created'?b.created:metric(b,q)?.value;if(!finite(x)||!finite(y))return finite(x)?-1:finite(y)?1:0;return (x-y)*dir});
 $('run-rows').innerHTML=xs.map(r=>{const pg=runProgress(r),m=r.status==='complete'?r.result?.metrics:pg.p.metrics;return `<tr data-run-id="${esc(r.id)}"><td><strong>${esc(r.name)}</strong><small>${new Date(r.created*1000).toLocaleString('zh-CN')}</small><small>${r.options.pairs*2}局 / AI ${r.options.strength} / ${r.options.max_rounds}回合</small></td><td><span class="badge">${stopRequests.has(r.id)?'正在停止':status[r.status]||esc(r.status)}</span><small>耗时 ${formatElapsed(elapsedSeconds(r))}</small><progress max="${pg.p.total||1}" value="${pg.p.completed||0}"></progress><small>${pg.text}</small>${stopControl(r)}</td>${Q.map(q=>`<td>${runMetricText(m?.[q],q,r.id)}</td>`).join('')}<td><div class="actions-small"><button data-run="${r.id}" data-side="a">放入 A</button><button data-run="${r.id}" data-side="b">放入 B</button></div></td></tr>`}).join('')||`<tr><td colspan="${Q.length+3}">还没有模拟记录。修改或保留当前卡表，点击“保存并运行当前配置”。</td></tr>`;
 for(const details of $('run-rows').querySelectorAll('.run-win-distribution'))details.ontoggle=()=>{
  if(!details.isConnected)return;
  const wasOpen=expandedRunDistributions.has(details.dataset.runId);
  if(details.open)expandedRunDistributions.add(details.dataset.runId);else expandedRunDistributions.delete(details.dataset.runId);
  if(details.open&&!wasOpen)details.scrollIntoView({block:'nearest',inline:'nearest'});
 };
}
function configHash(c){return c?.hash||canonical(c?.cards||{})}
function runMatchesConfig(r,c){return Boolean(c&&(r.config_id===c.id||canonical(r.cards||{})===canonical(c.cards||{})))}
function renderRunOptions(side){const selected=config($('compare-'+side).value);const relevant=runs.filter(r=>runMatchesConfig(r,selected)&&hasRunResult(r)).sort((a,b)=>Number(b.config_id===selected?.id)-Number(a.config_id===selected?.id)||b.created-a.created);const prior=$('run-'+side).value;const finiteCount=r=>Q.filter(q=>observedMetric(r,q)).length;const totalDenominator=r=>Q.reduce((sum,q)=>sum+(metric(r,q)?.denominator||0),0);const preferred=relevant.slice().sort((a,b)=>finiteCount(b)-finiteCount(a)||totalDenominator(b)-totalDenominator(a)||Number(b.config_id===selected?.id)-Number(a.config_id===selected?.id)||b.created-a.created)[0];const html=option('',relevant.length?'未选择模拟结果':'没有可用模拟，请先运行该配置')+relevant.map(r=>option(r.id,`${new Date(r.created*1000).toLocaleString('zh-CN')} · ${r.options.pairs*2}局 · AI ${r.options.strength}${r.config_id===selected?.id?'':' · 同卡表记录'} · ${finiteCount(r)}/${Q.length}项有值`)).join('');$('run-'+side).innerHTML=html;$('run-'+side).value=relevant.some(r=>r.id===prior)?prior:(preferred?.id||'')}
function selectedRun(side){return runs.find(r=>r.id===$('run-'+side).value)}
function differences(a,b){return data.fields.filter(f=>a[f.card][f.field]!==b[f.card][f.field]).map(f=>({...f,a:a[f.card][f.field]??null,b:b[f.card][f.field]??null}))}
function chart(a,b){
 const rows=Q.filter(q=>metricUnit(q,a,b)==='%'),blue='#2454b8',orange='#b75a19',height=rows.length*38+62;
 let svg=`<svg viewBox="0 0 560 ${height}" role="img" aria-label="百分比指标对比，蓝色A，橙色B。横轴0到100%"><text x="160" y="18" font-size="12" fill="${blue}">A</text><text x="200" y="18" font-size="12" fill="${orange}">B</text>`;
 for(const t of [0,25,50,75,100])svg+=`<line x1="${160+t*3.6}" x2="${160+t*3.6}" y1="26" y2="${height-25}" stroke="#d6dfe6"/><text x="${160+t*3.6}" y="${height-8}" text-anchor="middle" font-size="11">${t}%</text>`;
 rows.forEach((q,i)=>{const y=40+i*38;svg+=`<text x="0" y="${y+10}" font-size="13">${q} ${esc(labelQ(q))}</text>`;[a,b].forEach((r,j)=>{const v=metric(r,q)?.value;if(finite(v)){const w=Math.max(v===0?2:0,Math.max(0,Math.min(100,v))*3.6);svg+=`<rect x="160" y="${y+j*12}" width="${w}" height="9" fill="${j?orange:blue}"/>`}else svg+=`<text x="163" y="${y+8+j*12}" font-size="9" fill="#596b7b">未观测</text>`})});svg+='</svg>';
 const quantities=Q.filter(q=>metricUnit(q,a,b)!=='%').map(q=>{
  const unit=metricUnit(q,a,b),values=[metric(a,q)?.value,metric(b,q)?.value],observed=values.filter(finite),limits=q==='Q10'?[metric(a,q)?.category_count,metric(b,q)?.category_count].filter(finite):[],max=Math.max(...observed,...limits,1);
  let plot=`<svg viewBox="0 0 560 120" role="img" aria-label="${esc(labelQ(q))}对比，独立${esc(q==='Q10'?'方式数量':unit)}轴">`;
  values.forEach((v,i)=>{
   plot+=`<text x="0" y="${30+i*40}" font-size="14">${i?'B':'A'}</text>`;
   if(finite(v))plot+=`<rect x="30" y="${16+i*40}" width="${Math.max(v===0?2:0,v/max*380)}" height="22" fill="${i?orange:blue}"/><text x="548" y="${32+i*40}" text-anchor="end" font-size="13">${number(v)}</text>`;
   else plot+=`<text x="35" y="${32+i*40}" font-size="13" fill="#596b7b">未观测</text>`;
  });
  if(observed.length)plot+=`<text x="30" y="108" font-size="12">0</text><text x="410" y="108" text-anchor="end" font-size="12">${number(max)} ${esc(unit)}</text>`;
  return `<figure data-metric-chart="${esc(q)}"><figcaption>${esc(q)} ${esc(labelQ(q))} · 独立${esc(q==='Q10'?'方式数量':unit)}轴</figcaption>${plot}</svg></figure>`;
 }).join('');
 return `<div class="chart-grid">${rows.length?`<figure data-metric-chart="percentage"><figcaption>百分比指标 · A / B</figcaption>${svg}</figure>`:''}${quantities}</div><p class="muted">蓝色 A，橙色 B；各数量指标使用独立坐标轴，条长是观测值，不表示越长越好。观测样本见上表；Q10按配置分类上限绘图。</p>`;
}
function renderComparison(){const ca=config($('compare-a').value),cb=config($('compare-b').value);if(!ca||!cb)return;const a=selectedRun('a'),b=selectedRun('b');const comparableNow=comparable(a,b);const missing=[];if(!a)missing.push('A 没有可用模拟');if(!b)missing.push('B 没有可用模拟');$('compare-notice').textContent=missing.length?missing.join('；')+'。请先运行该配置，或在“使用哪次模拟”中选择已有结果。':comparableNow?'测量条件一致。B − A 是直接算术差，不是统计显著改善；玩家感受另看。':'测量条件不同（种子、局数、回合上限、AI或引擎版本）。仍显示已有指标的算术差，但不能归因于卡牌改动。';
 for(const [side,c] of [['a',ca],['b',cb]])$('note-'+side).textContent=`试玩备注：${c.notes?.text||'暂无备注'}`;
 $('metric-diff').innerHTML=Q.map(q=>{const x=metric(a,q),y=metric(b,q),d=metricDelta(a,b,q),unit=metricUnit(q,a,b);return `<tr><td><strong>${q} ${esc(labelQ(q))}</strong></td><td>${metricText(x)}<small>${esc(countText(x,q)||metricCompatibilityHint(a?.result?.metrics?.[q],q))}</small></td><td>${metricText(y)}<small>${esc(countText(y,q)||metricCompatibilityHint(b?.result?.metrics?.[q],q))}</small></td><td class="delta">${finite(d)?signed(d)+' '+esc(unit==='%'?'个百分点':unit):'未观测'}</td></tr>`}).join('');
 $('win-distributions').hidden=!Q.includes('Q10');$('win-distributions').innerHTML=Q.includes('Q10')?`<h3>获胜方式分布</h3><p class="muted">每个已归类胜局按导致胜利的最终事件计入一种方式；未结束局和未归类胜局不进入占比。Q10为这些占比的熵取指数：1表示单一方式，方式越多、分布越均匀，数值越高。它衡量终局机制，不能代替打法或乐趣评价。</p><div class="win-distribution-grid">${[['a',a],['b',b]].map(([side,r])=>`<div class="side-${side}" data-win-distribution="${side}"><h4>${side.toUpperCase()} 的获胜方式</h4>${winDistribution(metric(r,'Q10'))}</div>`).join('')}</div>`:'';
 $('metric-chart').innerHTML=chart(a,b);const ds=differences(ca.cards,cb.cards);$('diff-summary').textContent=`共 ${ds.length} 个参数不同，涉及 ${new Set(ds.filter(d=>d.card!=='_game').map(d=>d.card)).size} 张卡。只显示变动项。`;$('card-diff').innerHTML=ds.map(d=>`<tr><td>${esc(d.name)}</td><td>${esc(d.label)}</td><td>${d.a??'自动'}</td><td class="changed">${d.b??'自动'}</td><td class="delta">${finite(d.a)&&finite(d.b)?signed(d.b-d.a):'—'}</td></tr>`).join('')||'<tr><td colspan="5">两份卡牌参数相同。</td></tr>';
}
async function saveJsonAs(name,obj){
 const text=JSON.stringify(obj,null,2)+'\n';
 if(typeof window.showSaveFilePicker==='function'){
  const handle=await window.showSaveFilePicker({suggestedName:name,types:[{description:'JSON 卡表',accept:{'application/json':['.json']}}]});
  const writable=await handle.createWritable();await writable.write(text);await writable.close();message('已保存到你选择的位置：'+handle.name);return;
 }
 const path=prompt('当前浏览器不支持系统保存窗口。请输入要保存到的完整路径：',name);
 if(!path)return;
 const result=await api('api/export',{path,obj});message('已保存到：'+result.path);
}
function download(name,obj){const url=URL.createObjectURL(new Blob([JSON.stringify(obj,null,2)+'\n'],{type:'application/json'}));const a=document.createElement('a');a.href=url;a.download=name;a.click();setTimeout(()=>URL.revokeObjectURL(url),1000)}
async function stopRun(id){
 const current=runs.find(r=>r.id===id);
 if(!current||!isActiveRun(current)||current.status==='stopping'||stopRequests.has(id))return;
 stopRequests.add(id);stopErrors.delete(id);renderRuns();
 try{
  const result=await api('api/stop',{run_id:id});
  runRevision++;
  const latest=runs.find(r=>r.id===id);
  if(latest&&isActiveRun(latest)&&result.status)latest.status=result.status;
  message(result.stopping?`已请求停止“${current.name}”的本次模拟；其他模拟继续运行。`:`本次模拟已${status[result.status]?.replace(/^已/,'')||'结束'}；其他模拟不受影响。`);
 }catch(error){stopErrors.set(id,'停止失败：'+error.message);throw error}
 finally{stopRequests.delete(id);renderRuns();await refresh()}
}
async function refresh(){
 if(polling)return;
 polling=true;const revision=runRevision;let retry=false;
 try{
  const r=await api('api/runs');
  // A snapshot requested before a successful submit/stop must not undo that response.
  if(revision!==runRevision){retry=true;return}
  const before=new Map(runs.map(x=>[x.id,hasRunResult(x)]));
  const completedNow=r.runs.filter(x=>hasRunResult(x)&&!before.get(x.id));
  const changed=completedNow.length>0||runs.map(x=>x.id+x.status).join()!==r.runs.map(x=>x.id+x.status).join();
  runs=r.runs;
  for(const run of runs)if(!isActiveRun(run))stopErrors.delete(run.id);
  renderRuns();renderDirty();
  if(changed){
   renderRunOptions('a');renderRunOptions('b');
   for(const side of ['a','b']){
    const newest=completedNow.filter(run=>runMatchesConfig(run,config($('compare-'+side).value))).sort((a,b)=>b.created-a.created)[0];
    if(newest)$('run-'+side).value=newest.id;
   }
   renderComparison();
  }
 }catch(e){message('本地服务连接失败：'+e.message+'；重新双击启动入口可恢复查看已保存数据。',true)}
 finally{polling=false;if(retry)refresh()}
}
async function init(){data=await api('api/bootstrap');Q=data.definitions.map(([q])=>q);configs=data.configs;runs=data.runs;aiValues=clone(data.ai.parameters);
 $('definitions-title').textContent=`先看懂这 ${Q.length} 个数`;$('metrics-range').textContent=`${Q[0]}–${Q[Q.length-1]}`;
 $('definitions').innerHTML=data.definitions.map(([q,name,text])=>`<article><strong>${q} ${esc(name)}</strong><p>${esc(text)}</p></article>`).join('');
 $('sort').innerHTML=option('created','最新优先')+data.definitions.map(([q,n])=>option(q,q+' '+n)).join('');$('run-head').innerHTML='<tr><th>配置 / 模拟条件</th><th>状态</th>'+Q.map(q=>`<th><button data-sort="${q}">${q} ${esc(labelQ(q))} ↕</button></th>`).join('')+'<th>比较</th></tr>';
 renderSelectors();selectSource('default');renderAI();renderBudget();renderRuns();renderComparison();message('本地模拟器已连接。先修改参数，也可导入任意合法的完整卡表。');
 $('source').onchange=safe(()=>{if((dirty||notesChanged())&&!confirm('当前未保存的配置或备注将被替换，继续吗？')){$('source').value=sourceId;return}selectSource($('source').value)});
 $('card-search').oninput=renderCards;$('kind').onchange=renderCards;$('card-rows').oninput=changeField;$('card-rows').onchange=changeField;$('game-fields').oninput=changeField;$('game-fields').onchange=changeField;
 $('name').oninput=renderDirty;$('name').onchange=renderDirty;
 $('import').onchange=safe(async e=>{const f=e.target.files[0];if(!f)return;if(f.size>2000000)throw Error('卡表文件不能超过2MB');const raw=JSON.parse(await f.text());const importedName=(typeof raw._name==='string'&&raw._name.trim())||f.name.replace(/\.json$/i,'');const cards=clone(raw);delete cards._name;const c=await api('api/config',{source_id:sourceId,name:importedName,imported_name:importedName,source_file:f.name,cards});c.notes=c.notes||{text:''};if(!config(c.id))configs.push(c);renderSelectors();selectSource(c.id);message(`已导入“${c.name}”，并显示在起点配置中；旧指标不会混入新评估。`);e.target.value=''});
 $('export').onclick=safe(async()=>{formValid(false);await saveJsonAs('cards.json',draft)});
 for(const id of ['pairs','max-rounds','seed']){$(id).oninput=()=>{renderBudget();renderDirty()};$(id).onchange=$(id).oninput}
 $('ai-fields').oninput=e=>{if(e.target.dataset.ai&&e.target.checkValidity()&&Number.isFinite(e.target.valueAsNumber))aiValues[e.target.dataset.ai]=e.target.valueAsNumber;renderDirty()};$('ai-fields').onchange=$('ai-fields').oninput;
 $('strength').onchange=safe(async()=>{await loadProfile(Number($('strength').value))});
 $('run').onclick=safe(async()=>{if(loadingProfile||submitting||savingNotes||launching)return;formValid();renderDirty();assertRunnableDraft();const notesText=$('notes').value,runOptions=options();submitting=true;renderDirty();try{const cid=await saveDraft();await saveConfigNotes(cid,notesText);const r=await api('api/run',{config_id:cid,options:runOptions});runRevision++;if(!runs.some(x=>x.id===r.id))runs.unshift(r);renderRuns();message(`已按“${r.name}”保存并启动真实Godot模拟，可继续提交其他模拟。`)}finally{submitting=false;renderDirty()}});
 $('play').onclick=safe(async()=>{
  if(launching||submitting||savingNotes)return;
  formValid(false);renderDirty();assertRunnableDraft();
  const notesText=$('notes').value;
  launching=true;renderDirty();$('play-result').hidden=false;$('play-result').classList.toggle('error',false);$('play-result').textContent='正在保存当前配置并打开游戏…';
  try{
   const cid=await saveDraft();await saveConfigNotes(cid,notesText);
   const result=await api('api/play',{config_id:cid});
   const text=`已用配置“${result.name}”启动游戏。试玩后可回到这里记录备注。`;
   $('play-result').textContent=text;message(text);
  }catch(error){$('play-result').textContent='启动失败：'+error.message;$('play-result').classList.toggle('error',true);throw error}
  finally{launching=false;renderDirty()}
 });
 $('notes').oninput=renderDirty;$('notes').onchange=renderDirty;
 $('save-config').onclick=safe(saveCurrentConfig);
 $('save-notes').onclick=safe(saveCurrentConfig);
 $('sort').onchange=renderRuns;$('direction').onchange=renderRuns;$('run-head').onclick=e=>{const q=e.target.dataset.sort;if(!q)return;$('direction').value=$('sort').value===q&&$('direction').value==='desc'?'asc':'desc';$('sort').value=q;renderRuns()};
 $('run-rows').onclick=safe(async e=>{const button=e.target.closest('button');if(!button||button.disabled)return;if(button.dataset.stopRun)return stopRun(button.dataset.stopRun);const rid=button.dataset.run,side=button.dataset.side;if(!rid||!['a','b'].includes(side))return;const r=runs.find(x=>x.id===rid);$('compare-'+side).value=r.config_id;renderRunOptions(side);$('run-'+side).value=hasRunResult(r)?rid:'';renderComparison();$('comparison').scrollIntoView({behavior:'smooth'})});
 for(const side of ['a','b']){$('compare-'+side).onchange=()=>{renderRunOptions(side);renderComparison()};$('run-'+side).onchange=renderComparison}
 $('swap').onclick=()=>{const a=$('compare-a').value,b=$('compare-b').value,ra=$('run-a').value,rb=$('run-b').value;$('compare-a').value=b;$('compare-b').value=a;renderRunOptions('a');renderRunOptions('b');$('run-a').value=rb;$('run-b').value=ra;renderComparison()};
 $('export-diff').onclick=()=>{const a=config($('compare-a').value),b=config($('compare-b').value),ra=selectedRun('a'),rb=selectedRun('b');download('手动调参差异.json',{schema:'manual-balance-comparison-v1',a,b,run_a:ra||null,run_b:rb||null,comparable:comparable(ra,rb),metric_difference:Object.fromEntries(Q.map(q=>[q,metricDelta(ra,rb,q)])),card_difference:differences(a.cards,b.cards)})};
 window.addEventListener('beforeunload',e=>{if(dirty||notesChanged()){e.preventDefault();e.returnValue=''}});setInterval(()=>{if(runs.some(isActiveRun))renderRuns();refresh()},1000);
}
init().catch(e=>message('无法连接本地工具：'+e.message+'。请双击项目根目录「启动手动调参.command」，不要直接打开此HTML。',true));
