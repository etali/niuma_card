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
let data,configs=[],runs=[],draft,sourceId='default',savedId='default',dirty=false,aiValues={},polling=false,submitting=false,savingNotes=false,launching=false,runRevision=0;
const profiles=Object.fromEntries(['q','a','b'].map(side=>[side,{revision:0,strength:null,loading:false,error:''}]));
const duelValues={a:{},b:{}};
const profileFields=side=>side==='q'?'ai-fields':'duel-'+side+'-fields';
const profileSlider=side=>side==='q'?'strength':'duel-'+side+'-strength';
const profileValues=side=>side==='q'?aiValues:duelValues[side];
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
function acquisitionDistribution(m){
 const p=m?.acquisitions;
 if(!p||!p.observed_games)return '<p class="muted">未观测：该记录没有获得卡牌统计，请重新评估。</p>';
 const rows=Array.isArray(p.distribution)?p.distribution.slice().sort((a,b)=>b.count-a.count):[];
 return `<p class="muted">已观测 ${esc(p.observed_games)} 局 · 未采集 ${esc(p.missing_games)} 局 · 共获得 ${esc(p.total)} 张（不含现金牌和用户牌）</p>${p.total?'':'<p class="muted">已观测，但尚未获得非资源卡。</p>'}<table class="win-distribution-table"><thead><tr><th>卡牌</th><th>获得张数</th><th>占获得卡牌总数</th></tr></thead><tbody>${rows.map(x=>`<tr data-acquisition-card="${esc(x.id)}"><td>${esc(x.label)}</td><td>${finite(x.count)?x.count:'未记录'}</td><td>${finite(x.percentage)?number(x.percentage)+'%':'未观测'}</td></tr>`).join('')}</tbody></table>`;
}
function runMetricText(m,q,runId){
 const hint=metricCompatibilityHint(m,q),key=q==='Q6'?runId+':Q6':runId;
 const detail=q==='Q6'?['acquisition','获得卡牌',acquisitionDistribution]:q==='Q10'?['win','获胜',winDistribution]:null;
 return metricText(compatibleMetric(m,q))+(hint?`<small>${hint}</small>`:'')+(detail&&m?`<details class="run-distribution run-${detail[0]}-distribution" data-run-id="${esc(key)}"${expandedRunDistributions.has(key)?' open':''}><summary>查看${detail[1]}分布</summary>${detail[2](m)}</details>`:'');
}
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
 for(const id of ['pairs','max-rounds','seed']){
  const input=$(id);
  if(input.checkValidity()&&Number.isSafeInteger(input.valueAsNumber)&&input.valueAsNumber>=1)continue;
  const label=({'pairs':'种子对数','max-rounds':'每局回合上限','seed':'起始种子'})[id];
  return `${label}必须为可精确表示的正整数。`;
 }
 const aiReason=profileBlockReason('q');if(aiReason)return aiReason;
 const o=options();
 if(o.pairs>Math.floor(Number.MAX_SAFE_INTEGER/2))return '总局数超过精确整数范围。';
 if(o.pairs-1>Number.MAX_SAFE_INTEGER-o.seed_start)return '最后一个种子超过精确整数范围。';
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
 const busy=editingBusy;
 const blocked=reason||busy;
 for(const side of ['q','a','b']){
  $(profileSlider(side)).disabled=!!editingBusy;
  for(const input of $(profileFields(side)).querySelectorAll('input[data-ai]'))input.disabled=!!editingBusy||profiles[side].loading;
  if(side!=='q')$('duel-'+side+'-profile-status').textContent=profiles[side].loading?'正在映射全部 AI 参数…':profiles[side].error;
 }
 $('run').disabled=!!blocked;
 $('run').title=blocked;
 $('run-reason').textContent=reason?'无法运行：'+reason:busy||(!dirty?'可以运行：复用当前配置，只新增模拟记录。':`可以运行：将保存新配置“${$('name').value.trim()}”并启动模拟。`);
 $('run-reason').classList.toggle('error',!!reason);
 const playBlocked=cardReason||editingBusy;
 $('play').disabled=!!playBlocked;$('play').title=playBlocked;
 $('play-reason').textContent=cardReason?'暂时无法试玩：'+cardReason:editingBusy||(dirty?'将先保存新配置和备注，再打开游戏试玩。':'用所选配置打开游戏试玩，已有配置和评估记录会保留。');
 $('play-reason').classList.toggle('error',!!cardReason);
 renderNotesState(cardReason);
 renderDuelForm(cardReason,editingBusy);
}
function numericRange(min,max,step,kind){return `范围 ${min}–${max}（含边界）；${kind==='int'?'整数':'可填小数'}，步长 ${step}`}
function fieldInput(card,field){
 const f=data.fields.find(x=>x.card===card&&x.field===field);if(!f)return '<span class="muted">—</span>';
 const v=draft[card][field],changed=v!==config(sourceId).cards[card][field],hintId=`range-${card}-${field}`;
 const extra=(f.optional?'；留空自动计算':'')+(field==='pawn'?'；0 表示不可出售':'')+(card==='_game'&&field==='start_cash'&&finite(draft._game.win_cash)?`；须低于胜利线 ${draft._game.win_cash}`:'');
 return `<input type="number" min="${f.min??1}" max="${f.max??2147483647}" step="1" value="${v??''}" ${f.optional?'placeholder="自动"':'required'} data-card="${esc(card)}" data-field="${field}" aria-label="${esc(f.name+' '+f.label)}" aria-describedby="${esc(hintId)}" class="${changed?'changed':''}"><small class="input-range" id="${esc(hintId)}">${esc(numericRange(f.min??1,f.max??2147483647,1,'int')+extra)}</small>`;
}
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
function formValid(includeSimulation=true){const invalid=syncDraftFields()||(includeSimulation?simulationBlockReason():'');const selector=includeSimulation?'.editor input[type=number],#runner .sim-grid input[type=number]':'.editor input[type=number]';for(const n of document.querySelectorAll(selector))if(!n.reportValidity())throw Error('请修正标出的数值');if(invalid)throw Error(invalid);for(const f of data.fields){const v=draft[f.card][f.field];if(f.optional&&v===undefined)continue;if(!Number.isInteger(v)||v<(f.min??1)||v>(f.max??2147483647))throw Error(f.name+' '+f.label+'数值无效')}}
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
function renderBudget(){const o=options();$('budget').textContent=`${o.pairs*2} 局 · 每局最多 ${o.max_rounds} 回合 · 种子 ${o.seed_start}–${o.seed_start+(o.pairs-1)} · 每项模拟独立运行，可并行提交`;}
function renderStrength(side){const id=profileSlider(side);$(id+'-value').textContent=Number($(id).value).toFixed(2)}
function renderAI(side='q'){
 let group='';const values=profileValues(side),container=profileFields(side);
 const groups=[...new Set(data.ai.schema.map(s=>s.group||''))].sort((a,b)=>Number(b.startsWith('设计能力'))-Number(a.startsWith('设计能力')));
 const specs=groups.flatMap(g=>data.ai.schema.filter(s=>(s.group||'')===g));
 $(container).innerHTML=specs.map(s=>{const title=s.group&&s.group!==group?`<h4 class="ai-group">${esc(s.group)}</h4>`:'';group=s.group;const hintId=`range-${side==='q'?'ai':container}-${s.key}`;
  return title+`<label>${esc(s.label)}<input type="number" required data-ai="${esc(s.key)}" min="${s.min}" max="${s.max}" step="${s.step}" value="${values[s.key]??''}" aria-describedby="${esc(hintId)}"><small class="input-range" id="${esc(hintId)}">${esc(numericRange(s.min,s.max,s.step,s.kind))}</small><small>${esc(s.hint)}</small></label>`}).join('');renderStrength(side);
}
function profileBlockReason(side){
 const slider=$(profileSlider(side)),label=side==='q'?'AI':'AI '+side.toUpperCase();
 if(slider.value===''||!slider.checkValidity()||!finite(slider.valueAsNumber)||slider.valueAsNumber<0||slider.valueAsNumber>1)return label+' 强度必须在 0–1 之间，步长 0.01。';
 if(profiles[side].loading)return label+' 参数正在映射，请稍候。';
 if(profiles[side].error)return profiles[side].error;
 for(const input of $(profileFields(side)).querySelectorAll('input[data-ai]')){
  const spec=data.ai.schema.find(s=>s.key===input.dataset.ai);
  if(input.value!==''&&input.checkValidity()&&Number.isFinite(input.valueAsNumber)&&(spec.kind!=='int'||Number.isSafeInteger(input.valueAsNumber)))continue;
  return `${label} ${spec.label}必须符合：${numericRange(spec.min,spec.max,spec.step,spec.kind)}。`;
 }
 return '';
}
function applyProfileParameters(side,parameters){
 const values=clone(parameters);if(side==='q')aiValues=values;else duelValues[side]=values;
 for(const input of $(profileFields(side)).querySelectorAll('input[data-ai]'))input.value=String(values[input.dataset.ai]??'');
}
async function loadProfile(strength,side='q'){
 const state=profiles[side];if(state.strength===strength)return;
 const revision=++state.revision;state.strength=strength;state.loading=false;state.error='';renderStrength(side);
 if(!$(profileSlider(side)).checkValidity()||!finite(strength)||strength<0||strength>1){renderDirty();return}
 // Godot supplies every legal slider step; dragging only applies its snapshots.
 const parameters=data.ai.strength_profiles?.[strength.toFixed(2)];
 if(parameters){applyProfileParameters(side,parameters);renderDirty();return}
 state.loading=true;renderDirty();
 try{
  const p=await api('api/profile',{strength});if(revision!==state.revision)return;
  data.token=p.token||data.token;applyProfileParameters(side,p.parameters);
 }catch(error){if(revision===state.revision){state.error=(side==='q'?'AI':'AI '+side.toUpperCase())+' 参数读取失败：'+error.message+'；请重新调整强度重试。';message(state.error,true)}}
 finally{if(revision===state.revision){state.loading=false;renderDirty()}}
}
function bindAIProfile(side){
 const container=$(profileFields(side)),slider=$(profileSlider(side));
 container.oninput=e=>{if(profiles[side].loading)return;if(e.target.dataset.ai&&e.target.checkValidity()&&Number.isFinite(e.target.valueAsNumber))profileValues(side)[e.target.dataset.ai]=e.target.valueAsNumber;renderDirty()};container.onchange=container.oninput;
 slider.oninput=()=>loadProfile(Number(slider.value),side);slider.onchange=slider.oninput;
}
function elapsedSeconds(r){const end=r.finished||Date.now()/1000;return Math.max(0,end-r.created)}
function formatElapsed(seconds){const s=Math.floor(seconds);const h=Math.floor(s/3600),m=Math.floor(s%3600/60),rest=s%60;return h?`${h}小时${String(m).padStart(2,'0')}分${String(rest).padStart(2,'0')}秒`:m?`${m}分${String(rest).padStart(2,'0')}秒`:`${rest}秒`}
const strengthLabel=r=>r.strength_scale==='overall-v1'?'整体强度 '+r.options.strength:'历史强度 '+r.options.strength+'（参数快照）';
function runProgress(r){const p=r.progress||{completed:0,total:r.options.pairs*2,round:0};return {p,text:`${p.completed}/${p.total}局${r.status==='running'&&p.round?' · 第'+p.round+'回合':''}`}}
function stopControl(r){
 const stopping=stopRequests.has(r.id)||r.status==='stopping';
 const button=isActiveRun(r)?`<button class="stop-run" data-stop-run="${esc(r.id)}" ${stopping?'disabled':''} aria-label="${esc('停止模拟：'+r.name+'（'+r.id+'）')}">${stopping?'正在停止…':'停止模拟'}</button>`:'';
 return button+(stopErrors.has(r.id)?`<small class="error run-stop-error" role="status">${esc(stopErrors.get(r.id))}</small>`:'');
}
function renderRuns(){
 renderDuels();
 // Native toggle events are deferred; capture the visible state before replacing rows.
 for(const details of $('run-rows').querySelectorAll('.run-distribution')){
  if(details.open)expandedRunDistributions.add(details.dataset.runId);else expandedRunDistributions.delete(details.dataset.runId);
 }
 let xs=runs.filter(r=>r.kind!=='ai-duel');const q=$('sort').value,dir=$('direction').value==='asc'?1:-1;xs.sort((a,b)=>{const x=q==='created'?a.created:metric(a,q)?.value,y=q==='created'?b.created:metric(b,q)?.value;if(!finite(x)||!finite(y))return finite(x)?-1:finite(y)?1:0;return (x-y)*dir});
 $('run-rows').innerHTML=xs.map(r=>{const pg=runProgress(r),m=r.status==='complete'?r.result?.metrics:pg.p.metrics;return `<tr data-run-id="${esc(r.id)}"><td><strong>${esc(r.name)}</strong><small>${new Date(r.created*1000).toLocaleString('zh-CN')}</small><small>${r.options.pairs*2}局 / AI ${esc(strengthLabel(r))} / ${r.options.max_rounds}回合</small></td><td><span class="badge">${stopRequests.has(r.id)?'正在停止':status[r.status]||esc(r.status)}</span><small>耗时 ${formatElapsed(elapsedSeconds(r))}</small><progress max="${pg.p.total||1}" value="${pg.p.completed||0}"></progress><small>${pg.text}</small>${stopControl(r)}</td>${Q.map(q=>`<td>${runMetricText(m?.[q],q,r.id)}</td>`).join('')}<td><div class="actions-small"><button data-run="${r.id}" data-side="a">放入 A</button><button data-run="${r.id}" data-side="b">放入 B</button></div></td></tr>`}).join('')||`<tr><td colspan="${Q.length+3}">还没有模拟记录。修改或保留当前卡表，点击“保存并运行当前配置”。</td></tr>`;
 for(const details of $('run-rows').querySelectorAll('.run-distribution'))details.ontoggle=()=>{
  if(!details.isConnected)return;
  const wasOpen=expandedRunDistributions.has(details.dataset.runId);
  if(details.open)expandedRunDistributions.add(details.dataset.runId);else expandedRunDistributions.delete(details.dataset.runId);
  if(details.open&&!wasOpen)details.scrollIntoView({block:'nearest',inline:'nearest'});
 };
}
function configHash(c){return c?.hash||canonical(c?.cards||{})}
function runMatchesConfig(r,c){return Boolean(c&&(r.config_id===c.id||canonical(r.cards||{})===canonical(c.cards||{})))}
function renderRunOptions(side){const selected=config($('compare-'+side).value);const relevant=runs.filter(r=>runMatchesConfig(r,selected)&&hasRunResult(r)).sort((a,b)=>Number(b.config_id===selected?.id)-Number(a.config_id===selected?.id)||b.created-a.created);const prior=$('run-'+side).value;const finiteCount=r=>Q.filter(q=>observedMetric(r,q)).length;const totalDenominator=r=>Q.reduce((sum,q)=>sum+(metric(r,q)?.denominator||0),0);const preferred=relevant.slice().sort((a,b)=>finiteCount(b)-finiteCount(a)||totalDenominator(b)-totalDenominator(a)||Number(b.config_id===selected?.id)-Number(a.config_id===selected?.id)||b.created-a.created)[0];const html=option('',relevant.length?'未选择模拟结果':'没有可用模拟，请先运行该配置')+relevant.map(r=>option(r.id,`${new Date(r.created*1000).toLocaleString('zh-CN')} · ${r.options.pairs*2}局 · AI ${strengthLabel(r)}${r.config_id===selected?.id?'':' · 同卡表记录'} · ${finiteCount(r)}/${Q.length}项有值`)).join('');$('run-'+side).innerHTML=html;$('run-'+side).value=relevant.some(r=>r.id===prior)?prior:(preferred?.id||'')}
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
function renderAIComparison(a,b){
 const left=a?.result?.meta?.ai_parameters??a?.options?.ai_parameters??{},right=b?.result?.meta?.ai_parameters??b?.options?.ai_parameters??{};
 const keys=[...new Set([...Object.keys(left),...Object.keys(right)])].filter(k=>!equal(left[k],right[k]));
 $('ai-diff').innerHTML=keys.map(k=>{const spec=data.ai.schema.find(s=>s.key===k);return `<tr><td>${esc(spec?.group||'版本/历史参数')}</td><td>${esc(spec?.label||k)}</td><td>${esc(left[k]??'未记录')}</td><td>${esc(right[k]??'未记录')}</td></tr>`}).join('')||'<tr><td colspan="4">已记录的 AI 参数无差异。</td></tr>';
}
function renderComparison(){const ca=config($('compare-a').value),cb=config($('compare-b').value);if(!ca||!cb)return;const a=selectedRun('a'),b=selectedRun('b');const comparableNow=comparable(a,b);const missing=[];if(!a)missing.push('A 没有可用模拟');if(!b)missing.push('B 没有可用模拟');$('compare-notice').textContent=missing.length?missing.join('；')+'。请先运行该配置，或在“使用哪次模拟”中选择已有结果。':comparableNow?'测量条件一致。B − A 是直接算术差，不是统计显著改善；玩家感受另看。':'测量条件不同（种子、局数、回合上限、AI或引擎版本）。仍显示已有指标的算术差，但不能归因于卡牌改动。';
 renderAIComparison(a,b);
 for(const [side,c] of [['a',ca],['b',cb]])$('note-'+side).textContent=`试玩备注：${c.notes?.text||'暂无备注'}`;
 $('metric-diff').innerHTML=Q.map(q=>{const x=metric(a,q),y=metric(b,q),d=metricDelta(a,b,q),unit=metricUnit(q,a,b);return `<tr><td><strong>${q} ${esc(labelQ(q))}</strong></td><td>${metricText(x)}<small>${esc(countText(x,q)||metricCompatibilityHint(a?.result?.metrics?.[q],q))}</small></td><td>${metricText(y)}<small>${esc(countText(y,q)||metricCompatibilityHint(b?.result?.metrics?.[q],q))}</small></td><td class="delta">${finite(d)?signed(d)+' '+esc(unit==='%'?'个百分点':unit):'未观测'}</td></tr>`}).join('');
 $('win-distributions').hidden=!Q.includes('Q10');$('win-distributions').innerHTML=Q.includes('Q10')?`<h3>获胜方式分布</h3><p class="muted">每个已归类胜局按导致胜利的最终事件计入一种方式；未结束局和未归类胜局不进入占比。Q10为这些占比的熵取指数：1表示单一方式，方式越多、分布越均匀，数值越高。它衡量终局机制，不能代替打法或乐趣评价。</p><div class="win-distribution-grid">${[['a',a],['b',b]].map(([side,r])=>`<div class="side-${side}" data-win-distribution="${side}"><h4>${side.toUpperCase()} 的获胜方式</h4>${winDistribution(metric(r,'Q10'))}</div>`).join('')}</div>`:'';
 $('acquisition-distributions').hidden=!Q.includes('Q6');$('acquisition-distributions').innerHTML=Q.includes('Q6')?`<h3>获得卡牌分布</h3><p class="muted">统计双方实际获得的非资源卡张数，包括购买和升级产物；同名牌多次获得累计，不计现金牌和用户牌。占比以获得总张数为分母，与 Q6 的卡种覆盖率不同。</p><div class="win-distribution-grid">${[['a',a],['b',b]].map(([side,r])=>`<div class="side-${side}" data-acquisition-distribution="${side}"><h4>${side.toUpperCase()} 的获得卡牌分布</h4>${acquisitionDistribution(metric(r,'Q6'))}</div>`).join('')}</div>`:'';
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
function duelOptions(){return {pairs:Number($('duel-pairs').value),max_rounds:Number($('duel-rounds').value),seed_start:Number($('duel-seed').value),
 a:{strength:Number($('duel-a-strength').value),ai_parameters:clone(duelValues.a)},b:{strength:Number($('duel-b-strength').value),ai_parameters:clone(duelValues.b)}}}
function duelBlockReason(){
 for(const [id,label] of [['pairs','种子对数'],['rounds','每局回合上限'],['seed','起始种子']]){
  const input=$('duel-'+id);if(!input.checkValidity()||!Number.isSafeInteger(input.valueAsNumber)||input.valueAsNumber<1)return label+'必须为范围内的正整数。';
 }
 for(const side of ['a','b']){const reason=profileBlockReason(side);if(reason)return reason}
 const o=duelOptions();if(o.pairs>Math.floor(Number.MAX_SAFE_INTEGER/2))return '总局数超过精确整数范围。';
 if(o.pairs-1>Number.MAX_SAFE_INTEGER-o.seed_start)return '最后一个种子超过精确整数范围。';return '';
}
function renderDuelForm(cardReason,busy){const reason=cardReason||duelBlockReason()||busy;$('duel-run').disabled=!!reason;$('duel-reason').textContent=reason?'无法开始：'+reason:'将保存当前卡表与备注，按双方配置启动对战。';$('duel-reason').classList.toggle('error',!!reason)}
const duelRate=v=>finite(v)?(100*v).toFixed(1)+'%':'未观测';
const duelLabel=(s,scale)=>scale==='overall-v1'?'整体强度 '+s.strength+' · 实际参数快照':'历史参数快照（原强度 '+s.strength+'）';
function duelThinking(stats){
 return ['A','B'].map(side=>{const x=stats?.[side],n=x?.decisions;
  if(!finite(n))return `<small>${side} 思考诊断：未记录</small>`;
  if(n<=0)return `<small>${side} 思考诊断：尚无决策</small>`;
  const rate=key=>finite(x[key])?duelRate(x[key]/n):'未记录';
  return `<small>${side} 平均思考 ${number(x.elapsed_ms/n/1000)} 秒 · 平均有效前推 ${number(x.future_depth/n)} 回合 · 当前评价完成 ${rate('selected_evaluation_complete')} · 未来推演中断率 ${rate('future_incomplete')} · 思考超时率 ${rate('time_limit_reached')} · 备用方案率 ${rate('fallback_used')} · 总额度耗尽率 ${rate('budget_exhausted')}</small>`;
 }).join('');
}
function renderDuels(){
 $('duel-rows').innerHTML=runs.filter(r=>r.kind==='ai-duel').map(r=>{
  const p=runProgress(r),s=r.result?.summary||r.progress?.summary||{},decided=(s.a_wins||0)+(s.b_wins||0),total=s.completed_games||0,ci=s.a_score_pair_bootstrap_95;
  const seats=['player','ai'].map((seat,i)=>{const x=s.by_a_seat?.[seat]||{};return `A ${i?'后手':'先手'}：${x.A||0} 胜 / ${x.B||0} 负 / ${x.draw||0} 未结束`}).join('<br>');
  return `<tr><td><strong>${esc(r.name)}</strong><small>${new Date(r.created*1000).toLocaleString('zh-CN')}</small><small>A ${esc(duelLabel(r.options.a,r.strength_scale))}</small><small>B ${esc(duelLabel(r.options.b,r.strength_scale))}</small><small>种子 ${r.options.seed_start} 起 · ${r.options.max_rounds} 回合上限</small></td><td>${esc(status[r.status]||r.status)}<small>${p.text} · 耗时 ${formatElapsed(elapsedSeconds(r))}</small><progress max="${p.p.total||1}" value="${p.p.completed||0}"></progress>${stopControl(r)}${r.error?`<small class="error">${esc(r.error)}</small>`:''}<button data-duel-export="${esc(r.id)}">导出记录与实际参数</button></td><td>A ${s.a_wins||0} 胜 / B ${s.b_wins||0} 胜 / 未结束 ${s.draws||0}<small>A 胜率 ${duelRate(s.a_decisive_win_rate)}（${s.a_wins||0}/${decided}） · B 胜率 ${duelRate(decided?(s.b_wins||0)/decided:null)}</small><small>未结束率 ${duelRate(s.draw_rate)}（${s.draws||0}/${total}）</small><small>A 得分率 ${duelRate(s.a_score_rate)} · B 得分率 ${duelRate(finite(s.a_score_rate)?1-s.a_score_rate:null)}</small><small>A 得分率 95% 区间：${ci?.length===2?duelRate(ci[0])+'–'+duelRate(ci[1]):'未计算（完成至少两对种子后提供）'}</small><small>平均模拟回合 ${number(s.mean_rounds)}（含未结束局）</small>${duelThinking(s.decisions||r.progress?.decisions)}</td><td>${seats}</td></tr>`;
 }).join('')||'<tr><td colspan="4">还没有 AI 对战记录。</td></tr>';
}
async function startDuel(){
 if(submitting||savingNotes||launching)return;
 renderDirty();const reason=syncDraftFields()||draftBlockReason()||duelBlockReason();if(reason)throw Error(reason);
 const options=duelOptions(),notesText=$('notes').value;submitting=true;renderDirty();
 try{const cid=await saveDraft();await saveConfigNotes(cid,notesText);const r=await api('api/duel',{config_id:cid,options});runRevision++;runs.unshift(r);renderRuns();message('AI 对战已启动，可继续提交其他模拟。')}
 finally{submitting=false;renderDirty()}
}
async function init(){data=await api('api/bootstrap');Q=data.definitions.map(([q])=>q);configs=data.configs;runs=data.runs;aiValues=clone(data.ai.parameters);duelValues.a=clone(data.ai.parameters);duelValues.b=clone(data.ai.parameters);profiles.b.loading=true;
 for(const side of ['q','a'])profiles[side].strength=Number($(profileSlider(side)).value);
 $('definitions-title').textContent=`先看懂这 ${Q.length} 个数`;$('metrics-range').textContent=`${Q[0]}–${Q[Q.length-1]}`;
 $('definitions').innerHTML=data.definitions.map(([q,name,text])=>`<article><strong>${q} ${esc(name)}</strong><p>${esc(text)}</p></article>`).join('');
 $('sort').innerHTML=option('created','最新优先')+data.definitions.map(([q,n])=>option(q,q+' '+n)).join('');$('run-head').innerHTML='<tr><th>配置 / 模拟条件</th><th>状态</th>'+Q.map(q=>`<th><button data-sort="${q}">${q} ${esc(labelQ(q))} ↕</button></th>`).join('')+'<th>比较</th></tr>';
 renderSelectors();selectSource('default');for(const side of ['q','a','b']){renderAI(side);bindAIProfile(side)}renderBudget();renderRuns();renderComparison();renderDirty();message('本地模拟器已连接。先修改参数，也可导入任意合法的完整卡表。');
 $('duel-run').onclick=safe(startDuel);
 for(const id of ['pairs','rounds','seed']){$('duel-'+id).oninput=renderDirty;$('duel-'+id).onchange=renderDirty}
 $('duel-rows').onclick=safe(async e=>{const button=e.target.closest('button');if(!button||button.disabled)return;if(button.dataset.stopRun)return stopRun(button.dataset.stopRun);const r=runs.find(x=>x.id===button.dataset.duelExport);if(r)download('AI对战-'+r.id+'.json',r)});
 $('source').onchange=safe(()=>{if((dirty||notesChanged())&&!confirm('当前未保存的配置或备注将被替换，继续吗？')){$('source').value=sourceId;return}selectSource($('source').value)});
 $('card-search').oninput=renderCards;$('kind').onchange=renderCards;$('card-rows').oninput=changeField;$('card-rows').onchange=changeField;$('game-fields').oninput=changeField;$('game-fields').onchange=changeField;
 $('name').oninput=renderDirty;$('name').onchange=renderDirty;
 $('import').onchange=safe(async e=>{const f=e.target.files[0];if(!f)return;if(f.size>2000000)throw Error('卡表文件不能超过2MB');const raw=JSON.parse(await f.text());const importedName=(typeof raw._name==='string'&&raw._name.trim())||f.name.replace(/\.json$/i,'');const cards=clone(raw);delete cards._name;const c=await api('api/config',{source_id:sourceId,name:importedName,imported_name:importedName,source_file:f.name,cards});c.notes=c.notes||{text:''};if(!config(c.id))configs.push(c);renderSelectors();selectSource(c.id);message(`已导入“${c.name}”，并显示在起点配置中；旧指标不会混入新评估。`);e.target.value=''});
 $('export').onclick=safe(async()=>{formValid(false);await saveJsonAs('cards.json',draft)});
 for(const id of ['pairs','max-rounds','seed']){$(id).oninput=()=>{renderBudget();renderDirty()};$(id).onchange=$(id).oninput}
 $('run').onclick=safe(async()=>{if(profiles.q.loading||profiles.q.error||submitting||savingNotes||launching)return;formValid();renderDirty();assertRunnableDraft();const notesText=$('notes').value,runOptions=options();submitting=true;renderDirty();try{const cid=await saveDraft();await saveConfigNotes(cid,notesText);const r=await api('api/run',{config_id:cid,options:runOptions});runRevision++;if(!runs.some(x=>x.id===r.id))runs.unshift(r);renderRuns();message(`已按“${r.name}”保存并启动真实Godot模拟，可继续提交其他模拟。`)}finally{submitting=false;renderDirty()}});
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
 await loadProfile(Number($('duel-b-strength').value),'b');
}
init().catch(e=>message('无法连接本地工具：'+e.message+'。请双击项目根目录「启动手动调参.command」，不要直接打开此HTML。',true));
