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
        node.ownerDocument = this.ownerDocument;
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
  focus() { this.ownerDocument.activeElement = this; }
  setAttribute(key, value) { this.attributes[key] = String(value); }
  get classList() { return {add:(...names) => {this.className = [this.className || '',...names].join(' ');}}; }
  createTHead() { const head = new Element('thead'); head.rows = []; this.append(head); return head; }
  createTBody() { const body = new Element('tbody'); body.rows = []; (this.tBodies ??= []).push(body); this.append(body); return body; }
  insertRow() { const row = new Element('tr'); row.cells = []; this.rows.push(row); this.append(row); return row; }
  insertCell() { const cell = new Element('td'); this.cells.push(cell); this.append(cell); return cell; }
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
    const qualified = selector.match(/^([a-z]+)(\[.*\])$/);
    if (qualified) return this.matches(qualified[1]) && this.matches(qualified[2]);
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
  document.ownerDocument = document;
  document.activeElement = null;
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
  document.createElement = tag => Object.assign(new Element(tag),{ownerDocument:document});
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
  const curve = (strength,points) => {
    for (let i=1;i<points.length;i++) if (strength <= points[i][0]) {
      const [x0,y0] = points[i-1], [x1,y1] = points[i];
      return y0 + (y1-y0) * (strength-x0)/(x1-x0);
    }
    return points.at(-1)[1];
  };
  const mapping = strength => {
    const curves = defaults.preferences.strength_curves;
    const think = curve(strength,curves.think_seconds);
    const budgets = curves.decision_budget_ratio.map(([point,ratio]) => [point,ratio*curve(point,curves.think_seconds)]);
    return {think_seconds:think,decision_budget_ratio:curve(strength,budgets)/think};
  };
  const plain = copy(defaults.bot);
  delete plain.owner;
  const context = vm.createContext({document, structuredClone, Number, Date, console,Node:Element,
    $:id => document.getElementById(id), clone:structuredClone,
    Option:function(text, value) { const node = new Element('option'); node.textContent = text; node.value = value; return node; },
    bot:copy(defaults), candidate:copy(alternate), sourceCards:copy(alternate), baseline:copy(cards), profiles:{}, legacyBudgetMs:12,
    legacyPolicyDefaults:{...Object.fromEntries(['search_max_depth','search_root_width','search_reply_width'].map(key => [key,defaults.bot[key]])),...copy(defaults.compatibility?.algorithm_defaults || {})},
    defaultProfiles:{q:copy(plain),a:copy(plain),b:copy(plain)},
    strategyNames:{}, chosenBots:{}, presetChoice:{}, strengthChoice:{}, comparisonGeneration:0, previousComparison:'',
    presets:Object.fromEntries(Object.entries(defaults.preferences.presets).map(([key,strength]) => [key,mapping(strength)])),
    strengthProfiles:Object.fromEntries(Array.from({length:101},(_,index) => [(index/100).toFixed(2),mapping(index/100)])),
    presetLabels:{low:'偏低',mid:'标准'}, fieldLabels:{decision_budget_ms:'固定思考时限（毫秒）'},
    activeView:'balance', loading:false, projectCardsId:'project', projectCardsName:'项目默认', sourceId:'alternate',
    defaultStrategyNames:{q:'标准策略',a:'策略 A',b:'策略 B'},
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
  loadFunctions(context,['element','same','displayName','caption','field','details','number','stacked','parameterFieldOptions','parameterNumber','parameterCardName','parameterMetadata','parameterValue','parameterDifferenceNote','parameterDifferences','profilePreset','profileStrength','budgetText','setProfile',
    'fields','table','filterCards','renderInitialFields','renderCards','marketPoolIssue','updateMarketProbabilities','renderMarketPool','validCards','playCurrentCards','startPlaytest',
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

test('purchase probabilities expose each purchasable card once and save exact fractional weights', async () => {
  const {ui,requests} = harness();
  ui.renderCards();
  const inputs = ui.$('market-fields').querySelectorAll('input');
  const purchasable = Object.entries(ui.candidate.cards).filter(([,card]) => card.purchasable).map(([id]) => id);
  assert.equal(inputs.length,11);
  assert.deepEqual(inputs.map(input => input.dataset.path.split('.').at(-1)),purchasable);
  for (const old of ['employee_every','opening']) {
    assert.equal(ui.$('global-fields').querySelector(`[data-path="rules.conveyor.${old}"]`),null);
  }
  assert.equal(ui.$('fields').querySelectorAll('input').filter(input => input.dataset.path.startsWith('rules.conveyor.pool.')).length,0);
  const weight = id => inputs.find(input => input.dataset.path.endsWith('.'+id));
  const chance = id => ui.$('market-fields').querySelectorAll('output').find(output => output.dataset.card === id).textContent;
  for (const input of inputs) {input.value = '0'; await input.dispatch('input');}
  assert.match(ui.$('market-error').textContent,/至少一张/);
  weight('employee').value = '.5'; await weight('employee').dispatch('input');
  weight('leader').value = '1.5'; await weight('leader').dispatch('input');
  assert.equal(chance('employee'),'25%');
  assert.equal(chance('leader'),'75%');
  assert.equal(chance('strike'),'0%');
  assert.equal(ui.$('market-error').hidden,true);
  assert.match(ui.$('market-total').textContent,/总权重 2$/);
  const expected = copy(ui.candidate.rules.conveyor.pool);
  await ui.saveVersion('cards','分数权重',ui.candidate);
  assert.equal(requests.at(-1).url,'api/library/cards');
  assert.deepEqual(requests.at(-1).body.data.rules.conveyor.pool,expected);
  await ui.run();
  assert.equal(requests.at(-1).url,'api/run');
  assert.deepEqual(requests.at(-1).body.cards.rules.conveyor.pool,expected);
  await ui.playCurrentCards('playStatus');
  assert.equal(requests.at(-1).url,'api/playtest');
  assert.deepEqual(requests.at(-1).body.cards.rules.conveyor.pool,expected);
  const imported = copy(ui.candidate);
  imported.rules.conveyor.pool.employee = 1.5;
  imported.rules.conveyor.pool.leader = .5;
  ui.candidate = imported;
  ui.renderCards();
  assert.equal(chance('employee'),'75%','loading another card document recalculates probabilities');
  assert.equal(chance('leader'),'25%');
});

test('zero or invalid purchase weights block save, both evaluations and current-card playtests', async () => {
  const {ui,requests} = harness();
  ui.renderCards();
  const inputs = ui.$('market-fields').querySelectorAll('input');
  const first = inputs[0];
  for (const input of inputs) {input.value = '0'; await input.dispatch('input');}
  loadFunctions(ui,['controls']);
  for (const value of ['0','','-1','Infinity','NaN']) {
    first.value = value; await first.dispatch('input');
    assert.notEqual(ui.marketPoolIssue(),'');
    assert.equal(ui.$('market-error').hidden,false);
    for (const id of ['saveCards','run','playtest','export']) assert.equal(ui.$(id).disabled,true);
    const count = requests.length;
    await ui.saveVersion('cards','无效权重',ui.candidate);
    for (const mode of ['balance','bot']) {await ui.view(mode); await ui.run();}
    await ui.playCurrentCards('playStatus');
    assert.equal(requests.length,count,'invalid weights never reach a write or launch endpoint');
  }
  first.value = '.01'; await first.dispatch('input');
  assert.equal(ui.marketPoolIssue(),'');
  assert.equal(ui.$('run').disabled,false);
  // Individually finite weights can still overflow their total.
  for (const input of inputs.slice(0,2)) {input.value = '1e308'; await input.dispatch('input');}
  assert.match(ui.marketPoolIssue(),/总权重过大/);
});

test('income placement and transfer destination use Chinese choices with stable saved enum values', async () => {
  const {ui,requests} = harness();
  ui.renderCards();
  for (const [path,label,choices] of [
    ['rules.income.destination_policy','收入放置位置', [['oldest_cash_pile','最早创建的现金堆'],['newest_cash_pile','最新创建的现金堆']]],
    ['rules.transfer.destination_policy','甩锅落点', [['largest_work_queue','工作最多的对方牌组'],['new_group','对方新建牌组']]],
  ]) {
    const select = ui.$('cardsView').querySelector(`[data-path="${path}"]`);
    assert.equal(select.tagName,'SELECT');
    assert.ok(select.parentElement.textContent.includes(label));
    assert.deepEqual(select.options.map(option => [option.value,option.textContent]),choices);
    select.value = choices[1][0]; await select.dispatch('input');
    assert.equal(ui.candidate.rules[path.split('.')[1]].destination_policy,choices[1][0]);
  }
  await ui.saveVersion('cards','落点选项',ui.candidate);
  assert.equal(requests.at(-1).body.data.rules.income.destination_policy,'newest_cash_pile');
  assert.equal(requests.at(-1).body.data.rules.transfer.destination_policy,'new_group');
});

test('initial work is directly editable, shares the group document and reaches save, both evaluations and playtest', async () => {
  const {ui,requests} = harness();
  ui.renderCards();
  const workInput = index => ui.$('global-fields').querySelector(`[data-path="rules.initial.groups.${index}.work"]`);
  const work = workInput(0);
  assert.equal(work.value,'200');
  assert.equal(work.type,'number');
  assert.equal(work.step,'1');
  assert.equal(work.min,1);
  assert.ok(work.parentElement.textContent.includes('每方起始工作数量'));
  const original = copy(ui.candidate.rules.initial.groups);
  work.value = '73'; await work.dispatch('input');
  const expected = copy(original); expected[0].work = 73;
  assert.deepEqual(copy(ui.candidate.rules.initial.groups),expected);
  const advanced = ui.$('global-fields').querySelector('[data-path="rules.initial.groups"]');
  assert.deepEqual(JSON.parse(advanced.value),expected);
  for (const value of ['0','-1','1.5','','Infinity']) {
    work.value = value; await work.dispatch('input');
    assert.equal(work.validity.valid,false);
    assert.equal(ui.candidate.rules.initial.groups[0].work,73);
    const count = requests.length;
    await ui.playCurrentCards('playStatus');
    assert.equal(requests.length,count,'invalid initial count cannot launch a game');
  }
  work.value = '73'; await work.dispatch('input');
  await ui.saveVersion('cards','73份起始工作',ui.candidate);
  assert.deepEqual(requests.at(-1).body.data.rules.initial.groups,expected);
  for (const mode of ['balance','bot']) {
    await ui.view(mode); await ui.run();
    assert.equal(requests.at(-1).url,'api/run');
    assert.deepEqual(requests.at(-1).body.cards.rules.initial.groups,expected);
  }
  await ui.playCurrentCards('playStatus');
  assert.equal(requests.at(-1).url,'api/playtest');
  assert.deepEqual(requests.at(-1).body.cards.rules.initial.groups,expected);

  // Advanced imported layouts remain authoritative; editing either control
  // must update the same group, not retain a stale object or collapse stacks.
  const grouped = [{work:12,employee:1},{overtime:2},{work:61}];
  advanced.value = JSON.stringify(grouped); await advanced.dispatch('input');
  assert.equal(workInput(0).value,'12');
  assert.equal(workInput(2).value,'61');
  assert.ok(workInput(2).parentElement.textContent.includes('第 3 组'));
  advanced.value = '['; await advanced.dispatch('input');
  assert.equal(advanced.validity.valid,false);
  workInput(2).value = '0'; await workInput(2).dispatch('input');
  grouped[2].work = 0;
  assert.equal(advanced.validity.valid,true);
  assert.deepEqual(JSON.parse(advanced.value),grouped);
  assert.deepEqual(copy(ui.candidate.rules.initial.groups),grouped);
  ui.renderCards();
  assert.equal(workInput(0).value,'12');
  assert.equal(workInput(2).value,'0');
});

test('one work duration and both boss recruitment settings render, edit and reach every card payload', async () => {
  const {ui,requests} = harness();
  assert.equal(ui.candidate.cards.work.work_seconds,10);
  assert.ok(Object.values(ui.candidate.roles).every(role => !Object.hasOwn(role,'work_seconds')),
    'installed card data has a single duration source');
  ui.renderCards();
  const inputs = ui.$('cardsView').querySelectorAll('input');
  const work = ui.$('cardsView').querySelector('[data-path="cards.work.work_seconds"]');
  assert.deepEqual(inputs.filter(input => input.dataset.path?.endsWith('.work_seconds')),[work]);
  assert.ok(work.parentElement.textContent.includes('每份工作基础耗时（秒）'));
  assert.ok(work.parentElement.textContent.includes('员工及各升级等级共用；加班会影响实际工作速度。'));
  const fee = ui.$('cardsView').querySelector('[data-path="rules.recruitment.cost_per_employee"]');
  const seconds = ui.$('cardsView').querySelector('[data-path="rules.recruitment.seconds"]');
  for (const [input,label] of [[fee,'每名员工招聘费用'],[seconds,'招聘耗时（秒）']]) {
    assert.ok(input.parentElement.textContent.includes(label));
    let row = input;
    while (row && row.tagName !== 'TR') row = row.parentElement;
    assert.equal(row?.dataset.card,'boss','recruitment controls belong to the boss row');
  }
  assert.equal(fee.step,'1');
  assert.equal(fee.min,1);
  assert.ok(fee.parentElement.textContent.includes('须高于购牌区员工价格。'));
  for (const [input,value] of [[work,2.5],[fee,7],[seconds,3.5]]) {
    input.value = String(value); await input.dispatch('input');
    assert.equal(input.validity.valid,true);
  }
  const checkPayload = data => {
    assert.equal(data.cards.work.work_seconds,2.5);
    assert.equal(data.rules.recruitment.cost_per_employee,7);
    assert.equal(data.rules.recruitment.seconds,3.5);
    assert.ok(Object.values(data.roles).every(role => !Object.hasOwn(role,'work_seconds')));
  };
  await ui.saveVersion('cards','统一工时与招聘',ui.candidate);
  assert.equal(requests.at(-1).url,'api/library/cards'); checkPayload(requests.at(-1).body.data);
  for (const mode of ['balance','bot']) {
    await ui.view(mode); await ui.run();
    assert.equal(requests.at(-1).url,'api/run'); checkPayload(requests.at(-1).body.cards);
  }
  await ui.playCurrentCards('playStatus');
  assert.equal(requests.at(-1).url,'api/playtest'); checkPayload(requests.at(-1).body.cards);
  // Even before server migration, an archived role duration is never offered
  // as a second editor control. Normal imports are migrated by the engine.
  ui.candidate.roles.employee.work_seconds = 99;
  ui.renderCards();
  assert.equal(ui.$('cardsView').querySelector('[data-path="roles.employee.work_seconds"]'),null);
});

test('work and recruitment durations must be positive and employee recruitment fees positive integers', async () => {
  const {ui,requests} = harness();
  ui.renderCards();
  for (const [path,invalid,valid] of [
    ['cards.work.work_seconds',['0','-1','','NaN'],'.01'],
    ['rules.recruitment.seconds',['0','-1','','Infinity'],'.01'],
    ['rules.recruitment.cost_per_employee',['0','-1','1.5',''], '1'],
  ]) {
    const input = ui.$('cardsView').querySelector(`[data-path="${path}"]`);
    const keys = path.split('.');
    const object = keys.slice(0,-1).reduce((object,key) => object[key],ui.candidate);
    const before = object[keys.at(-1)];
    for (const value of invalid) {
      input.value = value; await input.dispatch('input');
      assert.equal(input.validity.valid,false,path+' rejects '+JSON.stringify(value));
      assert.equal(object[keys.at(-1)],before,'invalid input never replaces the effective parameter');
      const count = requests.length;
      await ui.saveVersion('cards','无效参数',ui.candidate);
      await ui.run();
      await ui.playCurrentCards('playStatus');
      assert.equal(requests.length,count,'invalid parameters cannot save or start a game');
    }
    input.value = valid; await input.dispatch('input');
    assert.equal(input.validity.valid,true);
    assert.equal(object[keys.at(-1)],Number(valid));
  }
});

test('selecting an archived card snapshot migrates through the engine and preserves its identity and original data', async () => {
  const {ui,requests} = harness();
  loadFunctions(ui,['normalizedCards','selectCards','loadNotes','bindSavedCards']);
  const archived = {id:'old-schema',name:'旧版卡表',data:copy(cards)};
  delete archived.data.cards.work.work_seconds;
  archived.data.roles.employee.work_seconds = 4.75;
  archived.data.roles.grinder.work_seconds = 2.25;
  archived.data.rules.conveyor.employee_every = 3;
  archived.data.rules.conveyor.opening = ['employee'];
  const original = copy(archived);
  const normalized = copy(cards);
  normalized.cards.work.work_seconds = 7.125; // Only the endpoint chooses migration values.
  ui.fetch = async (url,options) => {
    const body = options.body ? JSON.parse(options.body) : undefined;
    requests.push({url,body});
    if (url === 'api/validate') return {ok:true,json:async () => ({cards:copy(normalized)})};
    if (url.startsWith('api/notes/')) return {ok:true,json:async () => ({id:url.split('/').at(-1),text:'原卡表备注'})};
    if (url === 'api/library/cards') return {ok:true,json:async () => ({id:'new-schema',name:body.name,data:body.data})};
    throw Error('unexpected request '+url);
  };
  await ui.selectCards(archived);
  assert.equal(requests.filter(request => request.url === 'api/validate').length,1);
  assert.deepEqual(requests[0].body.cards,original.data,'the engine receives the intact archived document');
  assert.equal(ui.sourceId,'old-schema','normalization preserves the original note association');
  assert.equal(ui.$('notes').value,'原卡表备注');
  assert.deepEqual(copy(ui.sourceCards),normalized);
  assert.deepEqual(copy(ui.candidate),normalized);
  assert.notEqual(ui.sourceCards,ui.candidate,'edits cannot mutate the normalized baseline');
  assert.equal(ui.$('cardsView').querySelector('[data-path="cards.work.work_seconds"]').value,'7.125');
  assert.equal(ui.$('cardsView').querySelector('[data-path="roles.employee.work_seconds"]'),null);
  assert.equal(ui.same(ui.sourceCards,ui.candidate),true,'migration alone is not presented as a user edit');
  assert.deepEqual(archived,original,'the saved snapshot is never rewritten in place');
  await ui.saveVersion('cards','迁移卡表',ui.candidate);
  assert.deepEqual(requests.find(request => request.url === 'api/library/cards').body.data,normalized);
  assert.equal(requests.filter(request => request.url === 'api/validate').length,1,
    'current-schema save responses do not start another migration');
  for (const field of ['role','employee_every','opening']) {
    const data = copy(normalized);
    if (field === 'role') data.roles.employee.work_seconds = 99;
    else data.rules.conveyor[field] = field === 'opening' ? ['employee'] : 3;
    const before = requests.filter(request => request.url === 'api/validate').length;
    await ui.selectCards({id:'legacy-'+field,name:'旧卡表',data});
    assert.equal(requests.filter(request => request.url === 'api/validate').length,before+1);
    assert.deepEqual(copy(ui.candidate),normalized);
  }
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
  assert.deepEqual([...keys].sort(),['decision_publish_reserve_ratio','decision_publish_reserve_us','evaluation_max_seconds','live_fallback_budget_us','live_snapshot_card_limit','live_snapshot_group_limit']);
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

test('every supported evaluator and realtime parameter is editable and survives save and both run modes', async () => {
  const {ui,requests} = harness();
  const keys = Object.keys(defaults.compatibility.algorithm_defaults);
  assert.ok(keys.includes('evaluation_max_seconds') && keys.includes('live_fallback_budget_us'),'cover the unified evaluator and real-time protections');
  assert.ok(keys.every(key => Object.hasOwn(defaults.bot,key)),'compatibility defaults contain only supported v2 parameters');
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

test('edited search and completion-time parameters reach save and run requests', async () => {
  const {ui,requests} = harness();
  for (const [side,depth] of [['a',8],['b',2],['q',6]]) {
    await edit(ui,side,'search_max_depth',depth);
    await edit(ui,side,'search_root_width',5);
    await edit(ui,side,'search_reply_width',3);
    await edit(ui,side,'evaluation_max_seconds',1810);
    await edit(ui,side,'live_snapshot_card_limit',3000);
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

test('invalid numeric ranges and incomplete input never overwrite or submit a policy', async () => {
  const {ui,requests} = harness();
  for (const side of ['q','a','b']) {
    await ui.view(side === 'q' ? 'balance' : 'bot');
    for (const key of ['search_root_width','evaluation_max_seconds','decision_budget_ratio']) {
      const spec = defaults.preferences.knobs.find(item => item.key === key);
      const original = ui.profiles[side][key];
      const invalid = [spec.min-spec.step,spec.max+spec.step,'','not-a-number'];
      if (key === 'search_root_width') invalid.push(1.5);
      for (const value of invalid) {
        const count = requests.length;
        await edit(ui,side,key,value);
        assert.equal(input(ui,side,key).validity.valid,false,side+'.'+key+' rejects '+JSON.stringify(value));
        assert.equal(ui.profiles[side][key],original,'invalid edits leave the submitted value untouched');
        await ui.saveVersion('bot','invalid',ui.profiles[side],side);
        await ui.run();
        assert.equal(requests.length,count,'invalid numeric input blocks both saving and running');
        await edit(ui,side,key,original);
        assert.equal(input(ui,side,key).validity.valid,true,'a corrected value restores validity');
      }
    }
  }
});

test('obsolete archived heuristic fields are neither rendered nor submitted and the archive stays immutable', async () => {
  const {ui,requests} = harness();
  const obsolete = {buy_chance:.48,desired_people:14,min_reserve:3,max_tool_copies:8,
    max_support_people:2,production_reserve_people:1,material_batch_limit:16,transfer_batch_size:12,
    purchase_priority:['employee','overtime'],tool_priority:['coffee','meeting'],max_card_copies:{overtime:4},
    planner_cash_value_cap:.25,planner_partial_progress_weight:.5,planner_upgrade_chain_bonus_cap:1,
    tree_action_period_floor_seconds:2.8,unknown_future_field:{nested:['preserve','archive']}};
  const archive = {...copy(defaults.bot),...obsolete,think_seconds:3.7,decision_budget_ratio:.6};
  const before = copy(archive);
  const records = [{id:'old-bot',name:'历史完整策略',data:archive}];
  const beforeRecords = copy(records);
  // Unknown keys can arrive both from old records and an old bootstrap response.
  Object.assign(ui.legacyPolicyDefaults,obsolete);
  for (const side of ['q','a','b']) {
    ui.setProfile(side,archive,records[0].name,records[0].id);
    ui.renderProfiles();
    for (const key of Object.keys(obsolete)) {
      assert.equal(input(ui,side,key),null,side+' does not expose '+key);
      assert.equal(Object.hasOwn(ui.profiles[side],key),false,side+' does not retain '+key);
    }
    assert.equal(ui.profiles[side].think_seconds,3.7);
    assert.equal(ui.profiles[side].decision_budget_ratio,.6);
    await ui.saveVersion('bot','迁移策略 '+side,ui.profiles[side],side);
    assert.equal(requests.at(-1).url,'api/library/bot');
    for (const key of Object.keys(obsolete)) assert.equal(Object.hasOwn(requests.at(-1).body.data,key),false,'save excludes '+key);
    await ui.view(side === 'q' ? 'balance' : 'bot');
    await ui.run();
    assert.equal(requests.at(-1).url,'api/run');
    for (const seat of ['a','b']) {
      for (const key of Object.keys(obsolete)) assert.equal(Object.hasOwn(requests.at(-1).body[seat],key),false,'run excludes '+key);
    }
    assert.deepEqual(archive,before,'editing a migrated copy never rewrites the archived document');
    assert.deepEqual(records,beforeRecords,'loading and submitting never change archive names, IDs, or data');
  }
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

test('untouched current defaults use version-safe names on first run and after reselecting', async () => {
  const {ui,requests} = harness();
  const config = {project_cards_id:'project', cards:copy(cards), bot:copy(defaults),
    presets:copy(ui.presets),strength_profiles:copy(ui.strengthProfiles),legacy_default_budget_ms:12,
    default_profiles:{balance:{a:copy(ui.profiles.q)},bot:{a:copy(ui.profiles.a),b:copy(ui.profiles.b)}},
    default_options:{seed:1001,pairs:1,max_seconds:60},library:copy(ui.library),history:{items:[]},
    default_names:{cards:'项目默认（新版）',q:'标准策略（新版）',a:'策略 A（新版 2）',b:'策略 B'}};
  const api = ui.api;
  Object.assign(ui,{location:{protocol:'http:'},rateFormula:'',balanceMeasures:{},acquisitionFormula:'',
    storageWarnings() {},acceptHistory() {},loadLinkedRecords:async () => {},
    api:async () => copy(config)});
  loadFunctions(ui,['init']);
  await ui.init();
  assert.equal(ui.$('error').textContent,'');
  assert.equal(ui.$('cardName').value,config.default_names.cards);
  assert.equal(ui.strategyNames.q,config.default_names.q);
  assert.equal(ui.strategyNames.a,config.default_names.a);
  ui.api = api;
  ui.window.confirm = () => {throw Error('untouched defaults must not ask for an overwrite');};
  await ui.run();
  assert.equal(requests.at(-1).body.card_name,config.default_names.cards);
  assert.equal(requests.at(-1).body.a_name,config.default_names.q);
  await ui.selectBotCards('alternate');
  await ui.selectBotCards('project');
  assert.equal(ui.$('cardName').value,config.default_names.cards,'returning to current built-ins keeps the safe name');
  await ui.view('bot');
  await ui.run();
  assert.equal(requests.at(-1).body.a_name,config.default_names.a);
  assert.equal(requests.at(-1).body.b_name,config.default_names.b);
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
  ui.table = (_root,headers,rows) => tables.push({headers:copy(headers),rows:copy(rows.map(row => row.map(cell => cell instanceof Element ? cell.textContent : cell)))});
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
  assert.deepEqual(tables[1].headers,['参数','BOT A','BOT B','注释（B 相对 A）']);
  assert.match(tables[1].rows[0][0],/最大搜索深度.*search_max_depth/);
  assert.deepEqual(tables[1].rows[0].slice(1,3),['8','2'],'actual evaluated policies take precedence over requested defaults');
  assert.match(tables[1].rows[0][3],/减少 6.*双方交替行动/);
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


test('overall strength sliders update Q A B using engine profiles and retain independent parameters', async () => {
  const {ui,requests} = harness();
  for (const side of ['q','a','b']) {
    await edit(ui,side,'search_root_width',7);
    const range = ui.$('off-work-strength-'+side);
    assert.equal(range.type,'range');
    assert.equal(range.min,'0');
    assert.equal(range.max,'1');
    assert.equal(range.step,'0.01');
    for (const value of ['0.00','0.37','1.00']) {
      range.value = value;
      await range.dispatch('input');
      assert.equal(ui.profiles[side].decision_budget_ratio,ui.strengthProfiles[value].decision_budget_ratio);
      assert.equal(ui.profiles[side].search_root_width,7,'independent search tuning is retained');
      assert.equal(ui.$('off-work-strength-value-'+side).textContent,value);
      assert.equal(input(ui,side,'decision_budget_ratio').value,String(ui.strengthProfiles[value].decision_budget_ratio));
    }
    await range.dispatch('change');
    assert.equal(ui.$('off-work-strength-value-'+side).textContent,'1.00');
  }
  assert.equal(requests.length,0,'dragging needs no asynchronous profile request');
});

test('overall strength upgrades fixed-millisecond policies and detects custom mapped parameters', async () => {
  const {ui} = harness();
  ui.setProfile('b',{think_seconds:3.7,decision_budget_ms:24},'旧策略');
  ui.renderProfiles();
  assert.equal(ui.$('off-work-strength-value-b').textContent,'自定义');
  const slider = ui.$('off-work-strength-b');
  slider.focus();
  ui.strengthProfiles['0.63'].think_seconds = 3.7;
  slider.value = '0.63';
  await slider.dispatch('input');
  await slider.dispatch('change');
  assert.equal(ui.profiles.b.decision_budget_ms,undefined);
  assert.equal(ui.profiles.b.decision_budget_ratio,ui.strengthProfiles['0.63'].decision_budget_ratio);
  assert.notEqual(ui.$('off-work-strength-b'),slider,'legacy time mode rebuilds the fields on release');
  assert.equal(ui.document.activeElement,ui.$('off-work-strength-b'),'focus follows the replacement strength slider');
  assert.equal(ui.profiles.b.think_seconds,3.7);
  assert.equal(input(ui,'b','decision_budget_ms'),null);
  await edit(ui,'b','think_seconds',3.8);
  assert.equal(ui.$('off-work-strength-value-b').textContent,'自定义');
});


test('all 101 real engine profiles preserve exact mappings, focus, save and run values in Q A B', async () => {
  const os = require('node:os');
  const {spawnSync} = require('node:child_process');
  const engine = [process.env.GODOT,'/opt/homebrew/bin/godot','/Applications/Godot.app/Contents/MacOS/Godot'].find(file => file && fs.existsSync(file)) || 'godot';
  const directory = fs.mkdtempSync(path.join(os.tmpdir(),'off-work-strength-ui-'));
  try {
    const request = path.join(directory,'request.json');
    const result = path.join(directory,'result.json');
    fs.writeFileSync(request,JSON.stringify({presets_only:true}));
    const run = spawnSync(engine,['--headless','--path',root,'--script','res://tools/balance/off_work_run.gd','--','--request='+request,'--output='+result],{encoding:'utf8',timeout:20000});
    assert.equal(run.status,0,run.stdout + run.stderr);
    assert.doesNotMatch(run.stdout+run.stderr,/SCRIPT ERROR|Parse Error/);
    const actual = JSON.parse(fs.readFileSync(result,'utf8'));
    assert.equal(actual.error,undefined);
    assert.equal(Object.keys(actual.strength_profiles).length,101);
    const linkedKeys = ['decision_budget_ratio','think_seconds'];
    for (const parameters of Object.values(actual.strength_profiles)) {
      assert.deepEqual(Object.keys(parameters).sort(),linkedKeys,'only cadence and actual calculation allowance are linked');
    }
    const {ui,requests} = harness();
    ui.strengthProfiles = actual.strength_profiles;
    ui.presets = actual.presets;
    ui.renderProfiles();
    for (const side of ['q','a','b']) {
      await edit(ui,side,'search_root_width',7);
      await edit(ui,side,'evaluation_max_seconds',1810);
      for (const key of linkedKeys) assert.equal(String(input(ui,side,key).step),'any',key+' keeps full mapping precision');
      for (const [strength,parameters] of Object.entries(actual.strength_profiles)) {
        const slider = ui.$('off-work-strength-'+side);
        slider.focus();
        slider.value = strength;
        await slider.dispatch('input');
        await slider.dispatch('change');
        assert.equal(ui.$('off-work-strength-'+side),slider,'normal slider interaction does not replace the focused control');
        assert.equal(ui.document.activeElement,slider,'focus remains available for the next keyboard arrow');
        for (const [key,value] of Object.entries(parameters)) {
          assert.equal(ui.profiles[side][key],value,side+' '+strength+' '+key+' matches the engine exactly');
          assert.equal(Number(input(ui,side,key).value),value,'field preserves engine numeric precision');
          assert.equal(input(ui,side,key).validity.valid,true,side+' '+strength+' '+key+' has no stepMismatch');
        }
        assert.equal(ui.$('profile-'+side).querySelector(':invalid'),null);
        assert.equal(ui.profiles[side].search_root_width,7);
        assert.equal(ui.profiles[side].evaluation_max_seconds,1810);
        assert.equal(ui.$('off-work-strength-value-'+side).textContent,strength);
        await ui.saveVersion('bot','真实映射 '+side+' '+strength,ui.profiles[side],side);
        const saved = requests.at(-1);
        assert.equal(saved.url,'api/library/bot');
        for (const [key,value] of Object.entries(parameters)) assert.equal(saved.body.data[key],value,'save retains '+side+' '+strength+' '+key);
        assert.equal(saved.body.data.evaluation_max_seconds,1810);
        await ui.view(side === 'q' ? 'balance' : 'bot');
        await ui.run();
        const submitted = requests.at(-1);
        assert.equal(submitted.url,'api/run');
        for (const seat of side === 'q' ? ['a','b'] : [side]) {
          for (const [key,value] of Object.entries(parameters)) assert.equal(submitted.body[seat][key],value,'run retains '+side+' '+strength+' '+key);
          assert.equal(submitted.body[seat].search_root_width,7);
          assert.equal(submitted.body[seat].evaluation_max_seconds,1810);
        }
      }
      for (const linkedKey of linkedKeys) {
        const slider = ui.$('off-work-strength-'+side);
        slider.value = '0.50';
        await slider.dispatch('input');
        assert.equal(ui.presetChoice[side],'mid');
        const offset = linkedKey === 'think_seconds' ? .03 : .001;
        await edit(ui,side,linkedKey,actual.strength_profiles['0.50'][linkedKey]+offset);
        assert.equal(ui.$('off-work-strength-value-'+side).textContent,'自定义','editing '+linkedKey+' invalidates the overall match');
        assert.equal(ui.presetChoice[side],'custom');
      }
    }
    assert.equal(requests.filter(row => row.url === 'api/library/bot').length,303,'all 101 points are saved from every editor');
    assert.equal(requests.filter(row => row.url === 'api/run').length,303,'all 101 points are submitted from every editor');
  } finally { fs.rmSync(directory,{recursive:true,force:true}); }
});


test('参数差异按快照解释价格、升级与每方工作，保留原始字段并且不修改配置', () => {
  const {ui} = harness();
  const left = copy(cards), right = copy(cards);
  right.cards.employee.name = '研发员工';
  right.cards.employee.price = 2;
  right.rules.initial.groups[0].work = 800;
  right.rules.initial.groups[1].employee = 2;
  right.rules.coffee.upgrades.workaholic.cost = 3;
  right.rules.recruitment.cost_per_employee = 10;
  const before = JSON.stringify([left,right]);
  const rows = ui.parameterDifferences(left,right);
  const row = path => rows.find(r => r[0].querySelector('small').textContent === path);
  assert.match(row('cards.employee.price')[0].textContent,/员工 \/ 研发员工/);
  assert.deepEqual(copy(row('cards.employee.price').slice(1,3)),['4 钱','2 钱']);
  assert.match(row('cards.employee.price')[3],/减少 2 钱.*买入/);
  assert.deepEqual(copy(row('rules.initial.groups.0.work').slice(1,3)),['200 份\/方','800 份\/方']);
  assert.match(row('rules.initial.groups.0.work')[3],/每方总工作 200 → 800 份；双方合计 400 → 1,600 份/);
  assert.match(row('rules.initial.groups.1.employee')[0].textContent,/第 2 组.*员工/);
  assert.match(row('rules.coffee.upgrades.workaholic.cost')[0].textContent,/肝帝 → 打工皇帝/);
  assert.match(row('rules.coffee.upgrades.workaholic.cost')[3],/不是累计到最高级/);
  assert.match(row('rules.recruitment.cost_per_employee')[3],/每招募一名员工/);
  assert.equal(JSON.stringify([left,right]),before);
});

test('权重差异用各自卡表的总权重归一，权重不等于概率', () => {
  const {ui} = harness();
  const left = copy(cards), right = copy(cards);
  for (const c of [left,right]) {
    for (const key of Object.keys(c.rules.conveyor.pool)) c.rules.conveyor.pool[key] = 0;
  }
  left.rules.conveyor.pool.employee = 1;
  left.rules.conveyor.pool.coffee = 1;
  right.rules.conveyor.pool.employee = 2;
  right.rules.conveyor.pool.coffee = 6;
  const rows = ui.parameterDifferences(left,right);
  const row = rows.find(r => r[0].querySelector('small').textContent === 'rules.conveyor.pool.employee');
  assert.match(row[3],/增加 1/);
  assert.match(row[3],/权重不是百分比/);
  assert.match(row[3],/50% → 25%/,'weight increased while normalized probability decreased');
  right.rules.conveyor.pool.coffee = -1;
  assert.match(ui.parameterDifferences(left,right).find(r => r[0].querySelector('small').textContent === 'rules.conveyor.pool.employee')[3],/无法计算/);
});

test('参数注释区分缺失与零，未知字段不臆测效果，文本安全保留', () => {
  const {ui} = harness();
  const left = {rules:{initial:{}}};
  const right = {rules:{initial:{groups:[{work:2},{employee:1}]}},'<img src=x onerror=bad>':0};
  const rows = ui.parameterDifferences(left,right);
  const added = rows.find(r => r[0].querySelector('small').textContent === 'rules.initial.groups.1.employee');
  assert.equal(added[1],'缺少');
  assert.equal(added[2],'1 张/方');
  assert.match(added[3],/新增.*不能视为 0/);
  const unknown = rows.find(r => r[0].querySelector('small').textContent.includes('<img'));
  assert.equal(unknown[0].querySelector('img'),null);
  assert.match(unknown[3],/未提供.*不推断/);
  const removed = ui.parameterDifferences({old_field:1},{}).at(0);
  assert.equal(removed[2],'缺少');
  assert.match(removed[3],/右侧未记录/);
  const empty = ui.parameterDifferences({}, {historical_empty:{}}).at(0);
  assert.equal(empty[1],'缺少');
  assert.equal(empty[2],'{}','adding an empty object remains an observable parameter difference');
});

test('完整开局数组中的稀疏牌种计数按零解释，未知数组仍保留缺少', () => {
  const {ui} = harness();
  const left = {rules:{initial:{groups:[{work:2,employee:1}]}}};
  const right = {rules:{initial:{groups:[{work:2},{coffee:2}]}}};
  const before = JSON.stringify([left,right]);
  const find = (rows,path) => rows.find(row => row[0].querySelector('small').textContent === path);
  const rows = ui.parameterDifferences(left,right);
  const removed = find(rows,'rules.initial.groups.0.employee');
  assert.deepEqual(copy(removed.slice(1,3)),['1 张/方','0 张/方']);
  assert.match(removed[3],/减少 1 张\/方/);
  assert.doesNotMatch(removed[3],/未记录|不能视为 0/);
  const added = find(rows,'rules.initial.groups.1.coffee');
  assert.deepEqual(copy(added.slice(1,3)),['0 张/方','2 张/方']);
  assert.match(added[3],/增加 2 张\/方/);
  assert.equal(JSON.stringify([left,right]),before,'normalization does not mutate saved layouts');
  const unknown = find(ui.parameterDifferences({rules:{initial:{}}},right),'rules.initial.groups.1.coffee');
  assert.equal(unknown[1],'缺少');
  assert.match(unknown[3],/未记录.*不能视为 0/);
});

test('BOT差异复用现有旋钮说明，实验上限不会解释为目标时长', () => {
  const {ui} = harness();
  const rows = ui.parameterDifferences({BOT实际策略:{a:{think_seconds:6}},实验设置:{max_seconds:1800}},
    {BOT实际策略:{a:{think_seconds:3}},实验设置:{max_seconds:2400}});
  const botRow = rows.find(r => r[0].querySelector('small').textContent.includes('think_seconds'));
  assert.match(botRow[0].textContent,/行动间隔（游戏秒）/);
  assert.match(botRow[3],/减少 3 秒.*搜索中双方错开半个间隔/);
  const capRow = rows.find(r => r[0].querySelector('small').textContent.includes('max_seconds'));
  assert.match(capRow[3],/不是目标对局长度/);
});
