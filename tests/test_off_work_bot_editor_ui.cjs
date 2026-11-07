// SPDX-License-Identifier: AGPL-3.0-only
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const root = path.join(__dirname, '..');
const source = fs.readFileSync(path.join(root, 'tools/balance/off_work_workbench.js'), 'utf8');
const html = fs.readFileSync(path.join(root, 'tools/balance/off_work_workbench.html'), 'utf8');
const defaults = JSON.parse(fs.readFileSync(path.join(root, 'data/off_work_bot.json'), 'utf8'));
const cards = JSON.parse(fs.readFileSync(path.join(root, 'data/off_work_cards.json'), 'utf8'));
const copy = value => JSON.parse(JSON.stringify(value));

// A small DOM for real field events, validity, selection values, and reparenting.
// Layout is intentionally outside this behavior regression.
class Element {
  constructor(tag, attrs = {}) {
    this.tagName = tag.toUpperCase();
    this.children = [];
    this.attributes = {...attrs};
    this.dataset = {};
    this.listeners = {};
    this.value = attrs.value ?? '';
    Object.assign(this, attrs);
    for (const [key, value] of Object.entries(attrs)) {
      if (key.startsWith('data-')) this.dataset[key.slice(5)] = value;
    }
  }
  append(...nodes) {
    const firstOption = this.tagName === 'SELECT' && !this.options.length;
    for (const node of nodes) {
      if (node instanceof Element) {
        if (node.parentElement) node.parentElement.children = node.parentElement.children.filter(item => item !== node);
        node.parentElement = this;
      }
      this.children.push(node);
    }
    if (firstOption) this.selectedOption = this.options[0] || null;
  }
  add(node) { this.append(node); }
  replaceChildren(...nodes) {
    for (const child of this.children) if (child instanceof Element) child.parentElement = null;
    this.children = [];
    this.append(...nodes);
  }
  get textContent() { return this.children.map(child => child.textContent ?? String(child)).join(''); }
  set textContent(value) { this.replaceChildren(String(value)); }
  get value() {
    return this.tagName === 'SELECT' ? this.selectedOption?.value ?? '' : this.rawValue;
  }
  set value(value) {
    if (this.tagName === 'SELECT') this.selectedOption = this.options.find(option => option.value === String(value)) || null;
    else this.rawValue = String(value);
  }
  get valueAsNumber() { return this.value === '' ? NaN : Number(this.value); }
  get options() { return this.querySelectorAll('option'); }
  get validity() {
    if (this.customValidity) return {valid:false};
    if (this.type !== 'number') return {valid:true};
    const value = this.valueAsNumber;
    const step = this.step && this.step !== 'any' ? Number(this.step) : 0;
    return {valid:Number.isFinite(value) && value >= Number(this.min ?? -Infinity) && value <= Number(this.max ?? Infinity)
      && (!step || Math.abs((value - Number(this.min ?? 0)) / step - Math.round((value - Number(this.min ?? 0)) / step)) < 1e-8)};
  }
  setCustomValidity(message) { this.customValidity = message; }
  reportValidity() { return this.validity.valid; }
  setAttribute(key, value) { this.attributes[key] = String(value); }
  addEventListener(type, listener) { (this.listeners[type] ??= []).push(listener); }
  async dispatch(type) {
    const event = {type, target:this, preventDefault() {}};
    for (const listener of this.listeners[type] || []) await listener(event);
    if (this['on' + type]) await this['on' + type](event);
  }
  matches(selector) {
    if (selector === '*') return true;
    if (selector === ':invalid') return !this.validity.valid;
    if (selector.startsWith('#')) return this.id === selector.slice(1);
    const attr = selector.match(/^\[([^=\]]+)(?:="([^"]*)")?\]$/);
    if (attr) {
      const value = attr[1].startsWith('data-') ? this.dataset[attr[1].slice(5)] : this.attributes[attr[1]];
      return value !== undefined && (attr[2] === undefined || value === attr[2]);
    }
    return this.tagName === selector.toUpperCase();
  }
  querySelectorAll(selector) {
    const found = [];
    for (const child of this.children) if (child instanceof Element) {
      if (child.matches(selector)) found.push(child);
      found.push(...child.querySelectorAll(selector));
    }
    return found;
  }
  querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }
}
function page() {
  const document = new Element('document');
  const stack = [document];
  for (const token of html.matchAll(/<!--[\s\S]*?-->|<![^>]*>|<\/?[\w-]+\b[^>]*>|[^<]+/g)) {
    const text = token[0];
    if (text.startsWith('<!')) continue;
    if (text.startsWith('</')) { stack.pop(); continue; }
    if (!text.startsWith('<')) { stack.at(-1).append(text); continue; }
    const tag = text.match(/^<([\w-]+)/)[1];
    const attrs = {};
    for (const attr of text.slice(tag.length + 1, -1).matchAll(/([\w-]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+)))?/g)) {
      attrs[attr[1]] = attr[2] ?? attr[3] ?? attr[4] ?? '';
    }
    const node = new Element(tag, attrs);
    stack.at(-1).append(node);
    if (!/^(input|img|link|meta|br|hr|col)$/i.test(tag)) stack.push(node);
  }
  document.createElement = tag => new Element(tag);
  document.getElementById = id => document.querySelector('#' + id);
  return document;
}
function loadFunctions(context,names) {
  for (const name of names) {
    const match = source.match(new RegExp('^(?:async )?function '+name+'[(][^]*?^}', 'm'));
    assert.ok(match, `production function ${name} exists`);
    vm.runInContext(match[0], context);
  }
}
function harness() {
  const document = page();
  const requests = [];
  const openedHistory = [];
  const alternate = copy(cards);
  alternate.cards.employee.price += 1;
  const savedCards = {
    project:{id:'project',name:'项目默认',data:copy(cards)},
    alternate:{id:'alternate',name:'候选卡表',data:alternate},
  };
  const plain = copy(defaults.bot);
  delete plain.owner;
  const context = vm.createContext({document, structuredClone, Number, Date, console,
    $:id => document.getElementById(id), clone:structuredClone,
    Option:function(text, value) { const node = new Element('option'); node.textContent = text; node.value = value; return node; },
    bot:copy(defaults), candidate:copy(alternate), sourceCards:copy(alternate), baseline:copy(cards), profiles:{}, legacyBudgetMs:12,
    legacyPolicyDefaults:{search_max_depth:4,search_root_width:3,search_reply_width:2,...copy(defaults.compatibility?.algorithm_defaults || {})},
    defaultProfiles:{q:copy(plain),a:copy(plain),b:copy(plain)},
    strategyNames:{}, chosenBots:{}, presetChoice:{}, comparisonGeneration:0, previousComparison:'',
    presets:{low:{decision_budget_ratio:.1},mid:{decision_budget_ratio:.5}},
    presetLabels:{low:'偏低',mid:'标准'}, fieldLabels:{decision_budget_ms:'固定思考时限（毫秒）'},
    activeView:'balance', loading:false, projectCardsId:'project', sourceId:'alternate',
    library:{cards:[{id:'alternate',name:'候选卡表'}],bot:[]},
    historyItems:[{id:'old',kind:'balance',status:'done',configs:{cards:'project'}},
      {id:'new',kind:'bot',status:'done',configs:{cards:'alternate'}}], comparableRecords:[],
    dateTime:String, comparisonCardName:() => '历史卡表',
    controls() {}, renderSources() {}, budgetNote() {}, renderHistory() {}, errorText(message='') { document.getElementById('error').textContent = message; },
    refreshLibrary:async () => {}, refreshHistory:async () => {}, showComparison:async () => {},
    openHistoryRecord:async id => { openedHistory.push(id); }, notesReady:false, savedNotes:'',
    fetch:async (url, options) => {
      const body = options.body ? JSON.parse(options.body) : undefined;
      requests.push({url, body});
      if (url.startsWith('api/library/') && options.method === 'GET') {
        return {ok:true,json:async () => copy(savedCards[url.split('/').at(-1)])};
      }
      return {ok:true, json:async () => ({id:'saved-strategy',name:body.name,card_name:body.card_name})};
    }, window:{confirm:() => true},
  });
  context.selectCards = async record => {
    context.sourceId = record.id;
    context.sourceCards = copy(record.data);
    context.candidate = copy(record.data);
    context.$('cardName').value = record.name;
  };
  loadFunctions(context,['element','same','displayName','caption','field','details','number','profilePreset','budgetText','setProfile',
    'renderProfiles','valid','api','busy','saveWithConfirmation','saveVersion','currentCardsName','run',
    'availableCards','botCardsId','renderBotCards','selectBotCards','matchingConditions','comparisonChoices',
    'populateRecords','selection','swapComparison','loadLinkedComparison','refreshComparison','view']);
  const cardChange = source.match(/^\$\("botCards"\)\.onchange = .*;$/m);
  assert.ok(cardChange,'shared card selector binds the real change handler');
  vm.runInContext(cardChange[0],context);
  for (const side of ['q','a','b']) context.setProfile(side, plain, '策略 '+side);
  context.renderProfiles();
  for (const [id, value] of [['seed','1001'],['pairs','1'],['cap','60']]) context.$(id).value = value;
  return {ui:context,document,requests,savedCards,openedHistory};
}
function input(ui, side, key) { return ui.$('profile-'+side).querySelector(`[data-path="${key}"]`); }
async function edit(ui, side, key, value) {
  const node = input(ui,side,key);
  assert.ok(node, `${side}.${key} has an editor`);
  if (typeof value === 'boolean') node.checked = value;
  else node.value = typeof value === 'object' ? JSON.stringify(value) : String(value);
  await node.dispatch('input');
}

test('loading sparse and complete archived policies fills defaults while preserving their time mode', () => {
  const {ui} = harness();
  const sparse = {think_seconds:4.9,buy_chance:.48};
  const archived = copy(sparse);
  for (const side of ['a','b','q']) {
    ui.setProfile(side,sparse,'旧策略');
    assert.equal(ui.profiles[side].decision_budget_ms,12);
    assert.equal(ui.profiles[side].decision_budget_ratio,undefined);
    assert.equal(ui.profiles[side].search_max_depth,defaults.bot.search_max_depth);
    assert.equal(ui.profiles[side].think_seconds,4.9);
    assert.equal(ui.profiles[side].owner,undefined);
    assert.equal(Object.keys(ui.profiles[side]).length,Object.keys(defaults.bot).length - 1);
  }
  assert.deepEqual(sparse,archived,'loading never mutates the archived object');
  const completeLegacy = copy(defaults.bot);
  for (const key of ['owner','decision_budget_ratio','search_max_depth','search_root_width','search_reply_width']) delete completeLegacy[key];
  ui.setProfile('a',completeLegacy,'旧完整策略');
  assert.equal(ui.profiles.a.decision_budget_ms,12);
  ui.setProfile('b',{...sparse,decision_budget_ms:24},'固定毫秒');
  ui.setProfile('q',{...sparse,decision_budget_ms:24,decision_budget_ratio:.7},'比例时限');
  assert.equal(ui.profiles.b.decision_budget_ratio,undefined);
  assert.equal(ui.profiles.b.decision_budget_ms,24);
  assert.equal(ui.profiles.q.decision_budget_ms,undefined);
  assert.equal(ui.profiles.q.decision_budget_ratio,.7);
  ui.renderProfiles();
  assert.ok(input(ui,'b','decision_budget_ms'));
  assert.equal(input(ui,'b','decision_budget_ratio'),null);
  assert.ok(input(ui,'q','decision_budget_ratio'));
  assert.equal(input(ui,'q','decision_budget_ms'),null);
});

test('A B and shared Q expose every policy field with Chinese label and English identifier', async () => {
  const {ui} = harness();
  const metadata = [...defaults.preferences.knobs,...defaults.preferences.fields];
  const keys = Object.keys(defaults.bot).filter(key => key !== 'owner');
  for (const side of ['a','b','q']) {
    assert.equal(ui.$('profile-'+side).querySelectorAll('[data-path]').length,keys.length);
    if (side !== 'q') assert.equal(ui.$('profile-'+side).querySelector('details').open,true);
    for (const key of keys) {
      const node = input(ui,side,key);
      const label = node.parentElement;
      assert.equal(label.querySelector('code').textContent,key);
      assert.ok(label.textContent.includes(metadata.find(item => item.key === key).label));
      const old = ui.profiles[side][key];
      const spec = metadata.find(item => item.key === key);
      const changed = typeof old === 'boolean' ? !old : Array.isArray(old) ? [...old].reverse()
        : typeof old === 'object' ? {...old,coffee:6} : numericChange(old,spec);
      await edit(ui,side,key,changed);
      assert.deepEqual(copy(ui.profiles[side][key]),changed,`${side}.${key} input updates the submitted policy`);
    }
  }
});

test('archived algorithm defaults survive later project tuning and explicit overrides win', () => {
  const {ui} = harness();
  const legacy = defaults.compatibility.algorithm_defaults;
  const keys = Object.keys(legacy);
  assert.ok(keys.includes('material_batch_limit') && keys.includes('fallback_probe_group_limit'));
  const archived = copy(defaults.bot);
  for (const key of keys) delete archived[key];
  delete archived.owner;
  const before = copy(archived);
  for (const key of keys) {
    const spec = defaults.preferences.knobs.find(item => item.key === key);
    ui.bot.bot[key] = numericChange(legacy[key],spec);
  }
  for (const side of ['a','b','q']) {
    ui.setProfile(side,archived,'历史策略');
    for (const key of keys) assert.equal(ui.profiles[side][key],legacy[key],`${side}.${key} retains its recorded-era behavior`);
    ui.setProfile(side,{...archived,...ui.bot.bot},'已调策略');
    for (const key of keys) assert.equal(ui.profiles[side][key],ui.bot.bot[key],`${side}.${key} keeps an explicit saved override`);
  }
  assert.deepEqual(archived,before,'archived input remains immutable');
});

test('every algorithm coefficient is an editable numeric field and survives save and both run modes', async () => {
  const {ui,requests} = harness();
  const keys = Object.keys(defaults.compatibility.algorithm_defaults);
  assert.ok(keys.length >= 40,'the behavior test covers all configured limits, horizons, and evaluation coefficients');
  for (const side of ['a','b','q']) {
    for (const key of keys) {
      const spec = defaults.preferences.knobs.find(item => item.key === key);
      const node = input(ui,side,key);
      assert.equal(node.tagName,'INPUT',`${side}.${key} has its own control`);
      assert.equal(node.type,'number');
      assert.equal(node.validity.valid,true,`${side}.${key} default is valid for its min/max/step`);
      assert.equal(node.min,spec.min);
      assert.equal(node.max,spec.max);
      assert.equal(node.step,spec.step);
      assert.ok(node.parentElement.textContent.includes(spec.hint),`${side}.${key} explains its effect`);
      const value = numericChange(ui.profiles[side][key],spec);
      await edit(ui,side,key,value);
      assert.equal(ui.profiles[side][key],value);
    }
    await ui.saveVersion('bot','算法参数 '+side,ui.profiles[side],side);
    const saved = requests.at(-1);
    assert.equal(saved?.url,'api/library/bot');
    for (const key of keys) assert.equal(saved.body.data[key],ui.profiles[side][key]);
  }
  for (const kind of ['bot','balance']) {
    await ui.view(kind);
    await ui.run();
    const request = requests.at(-1);
    assert.equal(request?.url,'api/run');
    for (const side of ['a','b']) {
      const chosen = kind === 'bot' ? side : 'q';
      for (const key of keys) assert.equal(request.body[side][key],ui.profiles[chosen][key]);
    }
  }
});

function numericChange(value,spec) {
  const choices = [value + spec.step,value - spec.step,spec.min,spec.max].map(n => Number(n.toPrecision(12)));
  const changed = choices.find(n => n !== value && n >= spec.min && n <= spec.max &&
    Math.abs((n - spec.min) / spec.step - Math.round((n - spec.min) / spec.step)) < 1e-8);
  assert.notEqual(changed,undefined,`${spec.key} has another valid editable value`);
  return changed;
}

test('edited search options and structured policies reach save and run requests', async () => {
  const {ui,requests} = harness();
  for (const [side,depth] of [['a',8],['b',2],['q',6]]) {
    await edit(ui,side,'search_max_depth',depth);
    await edit(ui,side,'search_root_width',5);
    await edit(ui,side,'search_reply_width',3);
    await edit(ui,side,'purchase_priority',['employee','coffee']);
    await edit(ui,side,'max_card_copies',{coffee:6});
    const saveLabel = side === 'q' ? /保存.*共用.*策略/ : new RegExp('保存.*BOT '+side.toUpperCase()+'.*策略');
    const button = ui.$('profile-'+side).querySelectorAll('button').find(node => saveLabel.test(node.textContent));
    assert.ok(button,`${side} identifies exactly which policy is saved`);
    await button.onclick();
    const saved = requests.at(-1);
    assert.equal(saved.url,'api/library/bot');
    assert.deepEqual(saved.body.data,copy(ui.profiles[side]));
    assert.equal(saved.body.data.search_max_depth,depth);
  }
  for (const kind of ['bot','balance']) {
    await ui.view(kind);
    await ui.run();
    const request = requests.at(-1);
    assert.equal(request.url,'api/run');
    assert.equal(request.body.kind,kind);
    assert.deepEqual(request.body.a,copy(ui.profiles[kind === 'bot' ? 'a' : 'q']));
    assert.deepEqual(request.body.b,copy(ui.profiles[kind === 'bot' ? 'b' : 'q']));
    assert.equal(request.body.pairs,1);
  }
  assert.equal(ui.$('error').textContent,'');
});

test('invalid search ranges and malformed arrays cannot overwrite or submit a policy', async () => {
  const {ui,requests} = harness();
  const before = copy(ui.profiles.a);
  await edit(ui,'a','search_root_width',0);
  assert.equal(ui.profiles.a.search_root_width,before.search_root_width);
  await ui.saveVersion('bot','invalid',ui.profiles.a,'a');
  assert.equal(requests.length,0);
  await edit(ui,'a','search_root_width',4);
  input(ui,'a','purchase_priority').value = '{bad json';
  await input(ui,'a','purchase_priority').dispatch('input');
  assert.deepEqual(copy(ui.profiles.a.purchase_priority),before.purchase_priority);
  await ui.view('bot');
  await ui.run();
  assert.equal(requests.length,0);
});

test('BOT tab keeps one duel editor and leaves balance comparison selections in place', async () => {
  const {ui,document} = harness();
  await ui.refreshComparison();
  ui.$('leftConfig').value = 'project';
  ui.$('rightConfig').value = 'alternate';
  ui.$('leftRecord').value = 'old';
  ui.$('rightRecord').value = 'new';
  const comparison = ui.$('comparison');
  const selectors = ['leftConfig','rightConfig','leftRecord','rightRecord'].map(id => ui.$(id));
  const values = selectors.map(node => node.value);
  await ui.view('bot');
  assert.equal(ui.$('botComparisonSlot'),null,'BOT no longer has a second experiment comparison slot');
  assert.equal(comparison.parentElement,ui.$('balanceComparisonSlot'));
  assert.equal(ui.$('balanceComparisonSlot').hidden,true);
  assert.equal(ui.$('botView').hidden,false);
  assert.equal(ui.$('botView').querySelector('#leftRecord'),null);
  assert.equal(ui.$('botView').querySelector('#rightRecord'),null);
  assert.equal(ui.$('botCards').value,'alternate');
  assert.deepEqual(selectors.map(node => node.value),values,'entering BOT does not overwrite balance selections');
  await ui.refreshComparison();
  assert.deepEqual(selectors.map(node => node.value),values,'BOT polling does not change balance selectors');
  await ui.view('balance');
  assert.equal(comparison.parentElement,ui.$('balanceComparisonSlot'));
  assert.equal(ui.$('balanceComparisonSlot').hidden,false);
  assert.deepEqual(selectors.map(node => node.value),values);
  assert.deepEqual(['leftConfig','rightConfig','leftRecord','rightRecord'].map(id => ui.$(id)),selectors);
  assert.equal(document.querySelectorAll('#comparison').length,1);
});

test('the run action explicitly saves the shared card and both BOT policies', async () => {
  const {ui} = harness();
  loadFunctions(ui,['controls']);
  await ui.view('bot');
  assert.equal(ui.$('run').textContent,'保存卡表及 A、B 策略并对战');
  assert.match(ui.$('runSaveScope').textContent,/卡表/);
  assert.match(ui.$('runSaveScope').textContent,/A/);
  assert.match(ui.$('runSaveScope').textContent,/B/);
  assert.match(ui.$('runSaveScope').textContent,/复用/);
  assert.doesNotMatch(ui.$('duelCards').textContent,/历史对比/);
  for (const side of ['a','b']) {
    const buttons = ui.$('profile-'+side).querySelectorAll('button');
    assert.ok(buttons.some(button => button.textContent === '仅保存 BOT '+side.toUpperCase()+' 策略'));
  }
  ui.candidate.cards.employee.price += 1;
  ui.controls();
  assert.equal(ui.$('botCards').value,'');
  assert.match(ui.$('botCards').options.find(option => !option.value).textContent,/未保存/);
  assert.match(ui.$('runSaveScope').textContent,/卡表/,'unsaved cards are included in the save scope');
  await ui.view('balance');
  assert.equal(ui.$('run').textContent,'保存并运行当前配置');
});

test('one shared card selection updates the next match without replacing either BOT', async () => {
  const {ui,requests,savedCards} = harness();
  await ui.view('bot');
  const strategies = copy(ui.profiles);
  ui.$('botCards').value = 'project';
  await ui.$('botCards').dispatch('change');
  assert.equal(ui.$('botCards').value,'project');
  assert.equal(ui.botCardsId(),'project');
  assert.deepEqual(copy(ui.profiles),strategies,'choosing a card does not replace either BOT');
  await ui.run();
  assert.deepEqual(requests.at(-1).body.cards,savedCards.project.data);
  ui.$('botCards').value = 'alternate';
  await ui.$('botCards').dispatch('change');
  assert.equal(ui.$('botCards').value,'alternate');
  assert.equal(ui.botCardsId(),'alternate');
  await ui.run();
  assert.deepEqual(requests.at(-1).body.cards,savedCards.alternate.data);
  assert.equal(requests.at(-1).body.a.cards,undefined);
  assert.equal(requests.at(-1).body.b.cards,undefined);
});

test('same or different BOT strength is submitted against exactly one shared card document', async () => {
  const {ui,requests} = harness();
  await ui.view('bot');
  const strength = side => ui.$('profile-'+side).querySelectorAll('select').find(select => select.options.some(option => option.value === 'low'));
  for (const [a,b] of [['mid','mid'],['mid','low']]) {
    for (const [side,value] of [['a',a],['b',b]]) {
      const select = strength(side);
      select.value = value;
      await select.dispatch('change');
    }
    await ui.run();
    const request = requests.at(-1).body;
    assert.equal(request.a.decision_budget_ratio,ui.presets[a].decision_budget_ratio);
    assert.equal(request.b.decision_budget_ratio,ui.presets[b].decision_budget_ratio);
    assert.deepEqual(request.cards,copy(ui.candidate));
    assert.equal(Object.keys(request).filter(key => /cards/i.test(key)).length,1);
  }
});

test('one run request saves both sides and restores the canonical names of reused strategies', async () => {
  const {ui,requests} = harness();
  await ui.view('bot');
  await edit(ui,'a','search_max_depth',8);
  await edit(ui,'b','search_max_depth',2);
  const submittedPolicies = copy(ui.profiles);
  ui.fetch = async (url,options) => {
    requests.push({url,body:JSON.parse(options.body)});
    return {ok:true,json:async () => ({id:'one-duel',card_name:'候选卡表',
      configs:{a:'existing-a',b:'existing-b'},a_name:'已存深搜',b_name:'已存快速'})};
  };
  await ui.run();
  assert.equal(requests.length,1,'a single submit starts one experiment with both strategies');
  assert.equal(requests[0].url,'api/run');
  assert.deepEqual(requests[0].body.a,submittedPolicies.a);
  assert.deepEqual(requests[0].body.b,submittedPolicies.b);
  assert.equal(ui.strategyNames.a,'已存深搜');
  assert.equal(ui.strategyNames.b,'已存快速');
  assert.equal(ui.chosenBots.a,'existing-a');
  assert.equal(ui.chosenBots.b,'existing-b');
  assert.deepEqual(copy(ui.profiles),submittedPolicies,'reuse does not alter either edited strategy');
  assert.match(ui.$('message').textContent,/BOT A.*已存深搜.*BOT B.*已存快速/);
  assert.match(ui.$('message').textContent,/一条对战记录/);
});

test('legacy BOT comparison links open one duel and reject mismatched shared cards', async () => {
  const {ui,requests,openedHistory} = harness();
  ui.historyItems.push({id:'newer',kind:'bot',status:'done',configs:{cards:'alternate'}},
    {id:'project-duel',kind:'bot',status:'done',configs:{cards:'project'}});
  await ui.refreshComparison();
  const requestCount = requests.length;
  await assert.rejects(ui.loadLinkedComparison(new URLSearchParams('left=new&right=project-duel')),/同一份卡表/);
  await assert.rejects(ui.loadLinkedComparison(new URLSearchParams('left=new&right=newer&cards=project')),/同一份卡表/);
  assert.equal(requests.length,requestCount,'invalid links do not load another card');
  assert.deepEqual(openedHistory,[]);
  const balanceSelection = copy(ui.selection());
  await ui.selectBotCards('project');
  await ui.loadLinkedComparison(new URLSearchParams('left=new&right=newer'));
  assert.equal(ui.$('botCards').value,'alternate');
  assert.deepEqual(openedHistory,['new'],'a legacy pair resolves to one complete A-versus-B duel');
  assert.deepEqual(copy(ui.selection()),balanceSelection,'legacy BOT links leave card comparisons alone');
  await ui.loadLinkedComparison(new URLSearchParams('right=newer'));
  assert.deepEqual(openedHistory,['new','newer'],'a right-only legacy link also opens one record');
  await ui.view('bot');
  await assert.rejects(ui.loadLinkedComparison(new URLSearchParams('view=bot&left=new&right=old')),/同一份卡表/);
  await ui.view('balance');
  await ui.loadLinkedComparison(new URLSearchParams('left=old&right=new'));
  assert.equal(ui.activeView,'balance','balance comparisons may still compare different cards');
  assert.deepEqual(copy(ui.selection()),[{config:'project',run:'old'},{config:'alternate',run:'new'}]);
  await ui.swapComparison();
  assert.deepEqual(copy(ui.selection()),[{config:'alternate',run:'new'},{config:'project',run:'old'}]);
});

test('a single duel report compares A and B results and their actual strategy parameters', () => {
  const {ui} = harness();
  loadFunctions(ui,['fraction','parameterDifferences','botDuelReport']);
  const tables = [];
  ui.table = (_root,headers,rows) => tables.push({headers:copy(headers),rows:copy(rows)});
  const output = new Element('div');
  const record = {card_name:'共用卡表',a_name:'深搜策略',b_name:'快速策略',request:{
    a_name:'请求 A',b_name:'请求 B',a:{search_max_depth:4,owner:0},b:{search_max_depth:4,owner:1},
  }};
  const result = {games:8,a_wins:3,b_wins:1,draws:2,timeouts:2,
    profiles:{a:{search_max_depth:8,owner:0},b:{search_max_depth:2,owner:1}}};
  const before = copy({record,result});
  ui.botDuelReport(output,record,result);
  assert.match(output.textContent,/共用卡表/);
  assert.match(output.textContent,/交换座位/);
  assert.match(output.textContent,/已完成 8 局.*平局 2 局.*超时 2 局/);
  assert.deepEqual(tables[0].headers,['对战结果','BOT A','BOT B']);
  assert.deepEqual(tables[0].rows[0],['策略名称','深搜策略','快速策略']);
  assert.deepEqual(tables[0].rows[1],['胜局','3','1']);
  assert.deepEqual(tables[0].rows[2],['分胜负胜率','75%（3 / 4）','25%（1 / 4）']);
  assert.deepEqual(tables[1].headers,['参数','BOT A','BOT B']);
  assert.deepEqual(tables[1].rows,[['search_max_depth','8','2']],'actual evaluated policies take precedence over requested defaults');
  assert.deepEqual({record,result},before,'display never mutates archived snapshots');

  tables.length = 0;
  output.replaceChildren();
  ui.botDuelReport(output,record,{...result,profiles:undefined,a_wins:0,b_wins:0});
  assert.equal(tables.length,1,'seat owner differences are not reported as different strategies');
  assert.match(output.textContent,/相同的策略参数/);
  assert.deepEqual(tables[0].rows[2],['分胜负胜率','未观测（0 / 0）','未观测（0 / 0）']);
});

test('opening a historical duel expands only that row and never collapses an already open record', async () => {
  const {ui} = harness();
  loadFunctions(ui,['openHistoryRecord']);
  let clicks = 0;
  const scrolls = [];
  const row = {nextElementSibling:null,querySelector:selector => {
    assert.equal(selector,'button');
    return {click() { clicks++; row.nextElementSibling = {classList:{contains:name => name === 'history-detail'}}; }};
  },scrollIntoView:options => scrolls.push(copy(options))};
  const originalLookup = ui.$;
  ui.$ = id => id === 'historyTable' ? {querySelector:selector => {
    assert.equal(selector,'[data-job-id="duel-1"]');
    return row;
  }} : originalLookup(id);
  const loads = [];
  ui.api = async path => { loads.push(path); return {id:'duel-1',kind:'bot'}; };
  await ui.openHistoryRecord('duel-1');
  assert.equal(ui.activeView,'bot');
  assert.equal(clicks,1);
  assert.equal(ui.$('balanceComparisonSlot').hidden,true);
  await ui.openHistoryRecord('duel-1');
  assert.equal(clicks,1,'opening a direct link again keeps its existing details visible');
  assert.deepEqual(loads,['/api/jobs/duel-1','/api/jobs/duel-1']);
  assert.deepEqual(scrolls,[{block:'center'},{block:'center'}]);
  ui.$ = id => id === 'historyTable' ? {querySelector:() => null} : originalLookup(id);
  await assert.rejects(ui.openHistoryRecord('duel-1'),/未找到.*历史记录/);
});
