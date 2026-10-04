// Copyright (C) 2026 etali (https://github.com/etali)
// SPDX-License-Identifier: AGPL-3.0-only
// See LICENSE in the project root.

'use strict';

const assert = require('node:assert/strict');
const {readFileSync} = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const web = path.join(__dirname, '../tools/balance');
const html = readFileSync(path.join(web, 'report.html'), 'utf8');
const script = readFileSync(path.join(web, 'report.js'), 'utf8');
const decode = text => text.replace(/&(amp|lt|gt|quot|#39);/g,
  (_, entity) => ({amp:'&', lt:'<', gt:'>', quot:'"', '#39':"'"})[entity]);

// Only the DOM surface used by this page: inputs, selectors, delegated events,
// validity, and node identity. No browser or third-party package is required.
class Element {
  constructor(tag, attributes = {}, ownerDocument = null) {
    this.tagName = tag.toUpperCase();
    this.attributes = attributes;
    this.ownerDocument = ownerDocument;
    this.children = [];
    this.parentElement = null;
    this.dataset = Object.fromEntries(Object.entries(attributes)
      .filter(([key]) => key.startsWith('data-'))
      .map(([key, value]) => [key.slice(5).replace(/-([a-z])/g, (_, c) => c.toUpperCase()), value]));
    this.value = attributes.value || '';
    this.disabled = Object.hasOwn(attributes, 'disabled');
    this.hidden = Object.hasOwn(attributes, 'hidden');
    this.required = Object.hasOwn(attributes, 'required');
    this.open = Object.hasOwn(attributes, 'open');
    this.innerHTMLWrites = 0;
    this.validityReports = 0;
    this.classes = new Set((attributes.class || '').split(/\s+/).filter(Boolean));
    this.classList = {
      contains: name => this.classes.has(name),
      toggle: (name, force) => {
        const add = force === undefined ? !this.classes.has(name) : force;
        if (add) this.classes.add(name); else this.classes.delete(name);
        return add;
      },
    };
  }
  get id() { return this.attributes.id; }
  get type() { return this.attributes.type || ''; }
  get isConnected() {
    let root = this;
    while (root.parentElement) root = root.parentElement;
    return root === this.ownerDocument;
  }
  get valueAsNumber() { return this.value === '' ? NaN : Number(this.value); }
  get options() { return this.querySelectorAll('option'); }
  get textContent() { return this.children.map(child => typeof child === 'string' ? child : child.textContent).join(''); }
  set textContent(value) { this.children = [String(value)]; }
  get innerHTML() { return this._html || ''; }
  set innerHTML(value) {
    this._html = value;
    this.innerHTMLWrites++;
    for (const child of this.children) if (child instanceof Element) child.parentElement = null;
    this.children = [];
    parse(value, this);
    if (this.tagName === 'SELECT') this.value = this.options[0]?.value || '';
  }
  getAttribute(name) { return this.attributes[name] ?? null; }
  setAttribute(name, value) { this.attributes[name] = String(value); }
  matches(selector) {
    const tag = selector.match(/^[\w-]+/);
    if (tag && this.tagName !== tag[0].toUpperCase()) return false;
    const id = selector.match(/#([\w-]+)/);
    if (id && this.id !== id[1]) return false;
    for (const match of selector.matchAll(/\.([\w-]+)/g)) if (!this.classes.has(match[1])) return false;
    for (const match of selector.matchAll(/\[([\w-]+)(?:=["']?([^\]"']+)["']?)?\]/g)) {
      if (!Object.hasOwn(this.attributes, match[1])) return false;
      if (match[2] !== undefined && this.attributes[match[1]] !== match[2]) return false;
    }
    return true;
  }
  closest(selector) {
    for (let node = this; node; node = node.parentElement) if (node.matches(selector)) return node;
    return null;
  }
  querySelectorAll(selector) {
    const selectors = selector.split(',').map(part => part.trim().split(/\s+/));
    const matches = node => selectors.some(parts => {
      if (!node.matches(parts.at(-1))) return false;
      let parent = node.parentElement;
      for (let i = parts.length - 2; i >= 0; i--) {
        while (parent && !parent.matches(parts[i])) parent = parent.parentElement;
        if (!parent) return false;
        parent = parent.parentElement;
      }
      return true;
    });
    const result = [];
    const visit = node => {
      for (const child of node.children) if (child instanceof Element) {
        if (matches(child)) result.push(child);
        visit(child);
      }
    };
    visit(this);
    return result;
  }
  querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }
  checkValidity() {
    if (!['number','range'].includes(this.type)) return !this.required || this.value !== '';
    if (this.value === '') return !this.required;
    const number = this.valueAsNumber;
    const min = Number(this.attributes.min ?? -Infinity);
    const max = Number(this.attributes.max ?? Infinity);
    const step = Number(this.attributes.step || 1);
    const offset = (number - (Number.isFinite(min) ? min : 0)) / step;
    return Number.isFinite(number) && number >= min && number <= max &&
      Math.abs(offset - Math.round(offset)) < 1e-8;
  }
  reportValidity() { this.validityReports++; return this.checkValidity(); }
  focus() { this.ownerDocument.activeElement = this; }
  scrollIntoView() { this.ownerDocument.scrollEvents.push(this); }
  async dispatch(type) {
    const event = {type, target:this};
    for (let node = this; node; node = node.parentElement) {
      event.currentTarget = node;
      if (node['on' + type]) await node['on' + type](event);
    }
  }
  async click() { if (!this.disabled) await this.dispatch('click'); }
}

function parse(source, root) {
  const stack = [root];
  for (const token of source.matchAll(/<!--[\s\S]*?-->|<![^>]*>|<\/?[\w-]+\b[^>]*>|[^<]+/g)) {
    const text = token[0];
    if (text.startsWith('<!')) continue;
    if (text.startsWith('</')) { if (stack.length > 1) stack.pop(); continue; }
    if (!text.startsWith('<')) { stack.at(-1).children.push(decode(text)); continue; }
    const tag = text.match(/^<([\w-]+)/)[1];
    const attrs = {};
    const attributes = text.slice(tag.length + 1, -1);
    for (const match of attributes.matchAll(/([\w-]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+)))?/g)) {
      attrs[match[1]] = decode(match[2] ?? match[3] ?? match[4] ?? '');
    }
    const node = new Element(tag, attrs, root.ownerDocument || root);
    node.parentElement = stack.at(-1);
    node.parentElement.children.push(node);
    if (!/^(input|img|link|meta|br|hr|col)$/i.test(tag) && !text.endsWith('/>')) stack.push(node);
  }
}

const metricDefinitions = [
  ['Q1', '先手胜率', '说明', '%'], ['Q2', '平均结束回合', '说明', '回合'],
  ['Q3', '未结束比例', '说明', '%'], ['Q4', '有效反馈比例', '说明', '%'],
  ['Q5', '双方攻击比例', '说明', '%'], ['Q6', '卡牌使用覆盖', '说明', '%'],
  ['Q7', '升级后成功生产', '说明', '%'], ['Q8', '局均最大现金数', '说明', '现金'],
  ['Q9', '局均最大用户数', '说明', '用户'],
  ['Q10', '获胜方式多样性', '说明', '种'],
  ['Q11', '典当后获胜比例', '说明', '%'],
];

async function workbench({notes = {}, withRuns = false, activeRun = false, activeRuns = [], notesGate, configGate, runGate,
  playGate, playError, profileGate, profileResolver, runMetrics = {}, runParameters = {}, runVersions = {}, definitions = metricDefinitions, realTimers = false,
  savePicker = false, exportPath, stopGates = {}, stopFailures = {}, stopStatuses = {}, pollGates = [], fieldLimits = {}, profileParameters, ai = {model:'test-model', schema:[], parameters:{}}} = {}) {
  const document = new Element('document');
  document.ownerDocument = document;
  document.scrollEvents = [];
  document.getElementById = id => document.querySelector('#' + id);
  document.createElement = tag => new Element(tag, {}, document);
  parse(html, document);
  for (const select of document.querySelectorAll('select')) select.value = select.options[0]?.value || '';
  const cards = {
    _game:{start_cash:10, start_user:2},
    alpha:{name:'甲卡', kind:'product', price:2, weight:2},
    beta:{name:'乙卡', kind:'product', price:3, weight:2},
    legend:{name:'传说卡', kind:'legend', price:-1, weight:0, pawn:6},
  };
  const baseline = {id:'default', name:'默认卡表', cards, notes:{text:notes.default || ''}};
  const alternateCards = structuredClone(cards);
  alternateCards.alpha.weight = 5;
  alternateCards.alpha.pawn = 3;
  const alternate = {id:'alternate', name:'已有配置', cards:alternateCards, notes:{text:notes.alternate || ''}};
  const completeRun = (id, config, created) => ({
    id, config_id:config.id, name:config.name, cards:config.cards, created, finished:created + 1,
    status:'complete', engine_fingerprint:'test-engine',
    options:{pairs:5, max_rounds:40, seed_start:1001, model:'test-model', strength:1},
    result:{meta:{metric_version:runVersions[id] || 'test', ai_parameters:runParameters[id] || {}}, metrics:runMetrics[id] || {}},
    notes:{text:'这次评估的旧备注不应覆盖配置备注'},
  });
  const data = {
    token:'test-token', configs:[baseline, alternate],
    runs:withRuns ? [completeRun('default-new', baseline, 2), completeRun('default-old', baseline, 1),
      completeRun('alternate-run', alternate, 3)] : [],
    fields:[
      {card:'_game', field:'start_cash', name:'开局资源', label:'初始现金'},
      {card:'_game', field:'start_user', name:'开局资源', label:'初始用户'},
      ...['alpha', 'beta'].flatMap(card => ['price', 'weight'].map(field => ({card, field, name:cards[card].name, label:field}))),
      ...['alpha', 'beta', 'legend'].map(card => ({card, field:'pawn', name:cards[card].name,
        label:'出售价格', min:0, optional:card !== 'legend'})),
    ],
    definitions,
    ai,
  };
  for (const field of data.fields) Object.assign(field, fieldLimits[field.card+'.'+field.field] || {});
  for (const [index, id] of [...(activeRun ? ['active-run'] : []), ...activeRuns].entries()) {
    data.runs.push({...completeRun(id, baseline, 4 + index), status:'running', finished:null, result:null,
      progress:{completed:2, total:10, round:4, metrics:runMetrics[id] || {}}});
  }
  const isActive = run => ['queued', 'running', 'stopping'].includes(run.status);
  const activeIds = () => data.runs.filter(isActive).map(run => run.id);
  let runSequence = 0;
  const requests = [];
  const profileRequests = [];
  const saved = new Map(data.configs.map(config => [config.id, config]));
  const fetch = async (url, options = {}) => {
    const body = options.body ? JSON.parse(options.body) : undefined;
    requests.push({url, body});
    let result;
    if (url === 'api/bootstrap') result = {...data, active_run_ids:activeIds()};
    else if (url === 'api/runs') {
      result = structuredClone({runs:data.runs, active_run_ids:activeIds()});
      if (pollGates.length) await pollGates.shift();
    }
    else if (url === 'api/stop') {
      if (stopGates[body.run_id]) await stopGates[body.run_id];
      const running = data.runs.find(run => run.id === body.run_id);
      const error = stopFailures[body.run_id] || (!running && '未知的模拟记录');
      if (error) return {ok:false, json:async () => ({error})};
      const stopping = isActive(running);
      if (stopping) {
        running.status = stopStatuses[body.run_id] || 'cancelled';
        if (!isActive(running)) running.finished = Date.now() / 1000;
      }
      result = {stopping, run_id:running.id, status:running.status};
    }
    else if (url === 'api/config') {
      if (configGate) await configGate;
      result = {id:'saved-version', name:body.name, cards:body.cards, notes:{text:''}};
      saved.set(result.id, result);
    } else if (url === 'api/notes') {
      if (notesGate) await notesGate;
      assert.ok(saved.has(body.id), '备注只能写入已经保存的配置');
      result = {text:body.text, updated:10};
      saved.get(body.id).notes = result;
    } else if (url === 'api/run' || url === 'api/duel') {
      if (runGate) await runGate;
      const config = saved.get(body.config_id);
      result = {id:'run-' + ++runSequence, config_id:config.id, name:config.name, cards:config.cards,
        status:'queued', created:10 + runSequence, options:body.options,strength_scale:'overall-v1'};
      if(url==='api/duel')result.kind='ai-duel';
      data.runs.push(result);
    } else if (url === 'api/play') {
      if (playGate) await playGate;
      if (playError) return {ok:false, json:async () => ({error:playError})};
      const config = saved.get(body.config_id);
      assert.ok(config, '只能使用已保存配置启动游戏');
      result = {config_id:config.id, name:config.name, pid:12345, cards_path:'/tmp/manual-balance-play/cards.json'};
    } else if (url === 'api/export') result = {path:body.path};
    else if (url === 'api/profile') {
      profileRequests.push(body);
      if (profileGate && profileRequests.length > 1) await profileGate;
      result = profileResolver ? await profileResolver(body,profileRequests.length) :
        {token:data.token, parameters:profileParameters ?? ai.parameters};
    } else throw Error('Unexpected request: ' + url);
    return {ok:true, json:async () => structuredClone(result)};
  };
  const intervals = [];
  const timerHandles = [];
  const downloads = [];
  const fileSaves = [];
  const prompts = [];
  const window = {addEventListener() {}};
  if (savePicker) window.showSaveFilePicker = async options => {
    const file = {options:structuredClone(options), writes:[], closed:false};
    fileSaves.push(file);
    return {name:options.suggestedName, createWritable:async () => ({
      write:async text => { file.writes.push(text); },
      close:async () => { file.closed = true; },
    })};
  };
  const context = vm.createContext({document, fetch, console, Blob, setInterval:(callback, delay) => {
    intervals.push(callback);
    if (realTimers) timerHandles.push(setInterval(callback, delay));
  }, setTimeout:realTimers ? setTimeout : () => 0,
    URL:{createObjectURL(blob) { downloads.push(blob); return 'blob:test'; }, revokeObjectURL() {}},
    window, confirm:() => true,
    prompt:(message, suggested) => { prompts.push({message, suggested}); return exportPath === undefined ? suggested : exportPath; }});
  vm.runInContext(script, context, {filename:'report.js'});
  await new Promise(resolve => setImmediate(resolve));
  const $ = id => document.getElementById(id);
  assert.equal(typeof $('run').onclick, 'function', $('message').textContent);
  requests.length=0; // 初始化 B 强度所用的只读请求，与用户操作分开断言。
  return {
    profileRequests:()=>structuredClone(profileRequests),
    $, document, fileSaves, prompts,
    dispose:() => timerHandles.forEach(clearInterval),
    pollCount:() => requests.filter(request => request.url === 'api/runs').length,
    updateRun:(id, patch) => Object.assign(data.runs.find(run => run.id === id), structuredClone(patch)),
    readRun:id => structuredClone(data.runs.find(run => run.id === id)),
    row:id => $('run-rows').querySelector(`tr[data-run-id="${id}"]`),
    stopButton:id => $('run-rows').querySelector(`button[data-stop-run="${id}"]`),
    posts:() => requests.filter(request => request.body !== undefined),
    exported:async () => Promise.all(downloads.map(async blob => JSON.parse(await blob.text()))),
    savedNotes:id => saved.get(id).notes.text,
    savedCards:id => structuredClone(saved.get(id).cards),
    field:(card, field) => document.querySelector(`input[data-card="${card}"][data-field="${field}"]`),
    async name(value) { $('name').value = value; await $('name').dispatch('input'); },
    async source(id) { $('source').value = id; await $('source').dispatch('change'); },
    async notes(text) { $('notes').value = text; await $('notes').dispatch('input'); },
    async tick() {
      for (const callback of intervals) callback();
      await new Promise(resolve => setImmediate(resolve));
    },
    async blocked(reason) {
      assert.equal($('run').disabled, true, '不满足运行条件时必须将按钮置灰');
      assert.match($('run-reason').textContent, reason, '按钮旁应说明无法运行的原因');
      assert.notEqual($('run-reason').hidden, true, '无法运行的原因应当可见');
      assert.equal($('dirty').classList.contains('error'), true, '编辑区应强调待修正的问题');
      await $('run').click();
      assert.deepEqual(requests.filter(request => request.body !== undefined), []);
    },
    ready() {
      assert.equal($('run').disabled, false, $('run-reason').textContent);
      assert.equal($('dirty').classList.contains('error'), false, '修正后应清除错误强调');
    },
    async run() { assert.equal($('run').disabled, false, $('dirty').textContent); await $('run').click(); },
  };
}

for (const savePicker of [true, false]) {
  test(`导出未保存草稿为可直接替换的 cards.json：${savePicker ? '浏览器保存窗口' : '备用保存 API'}`, async () => {
    const exportPath = '/tmp/用户选择的位置/cards.json';
    const ui = await workbench({savePicker, exportPath, notes:{default:'原配置备注'}});
    const expected = ui.savedCards('default');
    await ui.name('名称不会成为导出文件名');
    for (const [card, field, value] of [['_game', 'start_cash', 14], ['alpha', 'weight', 6], ['alpha', 'pawn', 0]]) {
      const input = ui.field(card, field);
      input.value = String(value);
      await input.dispatch('input');
      expected[card][field] = value;
    }
    await ui.notes('未保存的试玩备注不能混入卡表');
    ui.$('pairs').value = '0';
    await ui.$('pairs').dispatch('input');
    assert.equal(ui.$('run').disabled, true, '模拟参数无效不应阻止导出有效卡表');
    assert.equal(ui.$('export').textContent, '导出 cards.json…');
    assert.match(ui.$('export-hint').textContent, /直接替换项目 data\/cards\.json.*当前编辑的参数/);

    await ui.$('export').click();

    if (savePicker) {
      assert.equal(ui.fileSaves.length, 1);
      const file = ui.fileSaves[0];
      assert.equal(file.options.suggestedName, 'cards.json');
      assert.deepEqual(file.options.types[0].accept, {'application/json':['.json']});
      assert.equal(file.writes.length, 1);
      assert.deepEqual(JSON.parse(file.writes[0]), expected, '保存文件只含当前完整卡表，不含配置或运行元信息');
      assert.equal(file.closed, true, '保存后关闭文件流，确保内容落盘');
      assert.deepEqual(ui.prompts, []);
      assert.deepEqual(ui.posts(), [], '本地保存不应新增配置、运行或写备注');
    } else {
      assert.equal(ui.fileSaves.length, 0);
      assert.equal(ui.prompts.length, 1);
      assert.equal(ui.prompts[0].suggested, 'cards.json');
      assert.deepEqual(ui.posts(), [{url:'api/export', body:{path:exportPath, obj:expected}}],
        '备用通道只导出纯卡表到所选路径，不新增配置、运行或写备注');
    }
    assert.equal(ui.$('source').value, 'default', '导出不应将草稿变成已保存版本');
    assert.equal(ui.$('name').value, '名称不会成为导出文件名');
    assert.equal(ui.$('notes').value, '未保存的试玩备注不能混入卡表');
    assert.equal(ui.savedNotes('default'), '原配置备注');
    assert.notDeepEqual(ui.savedCards('default'), expected, '导出不应覆盖起点配置');
  });
}

for (const order of ['name-first', 'weight-first']) {
  test(`保存当前输入与编辑顺序无关：${order}`, async () => {
    const ui = await workbench();
    const changeWeight = async () => {
      const input = ui.field('alpha', 'weight');
      input.value = '6';
      await input.dispatch('input');
      await input.dispatch('change');
    };
    if (order === 'name-first') {
      await ui.name('提高甲卡权重');
      await ui.blocked(/修改至少一个卡牌参数/);
      await changeWeight();
    } else {
      await changeWeight();
      await ui.blocked(/新.*名称/);
      await ui.name('提高甲卡权重');
    }
    ui.ready();
    await ui.run();
    assert.deepEqual(ui.posts().map(request => request.url), ['api/config', 'api/run']);
    assert.equal(ui.posts()[0].body.name, '提高甲卡权重');
    assert.equal(ui.posts()[0].body.cards.alpha.weight, 6);
    assert.equal(ui.posts()[1].body.config_id, 'saved-version');
  });
}

test('只改卡牌参数时置灰并提示新名称，补全新名称后恢复', async () => {
  const ui = await workbench();
  const input = ui.field('alpha', 'price');
  input.value = '4';
  await input.dispatch('input');
  await ui.blocked(/新.*名称/);
  await ui.name('提高甲卡价格');
  ui.ready();
});

test('名称和参数不变时复用当前配置，仅新增运行', async () => {
  const ui = await workbench();
  ui.ready();
  await ui.run();
  assert.deepEqual(ui.posts().map(request => request.url), ['api/run']);
  assert.equal(ui.posts()[0].body.config_id, 'default');
});

function deferred() {
  let resolve;
  const promise = new Promise(done => { resolve = done; });
  return {promise, resolve};
}

test('已有任务运行时可连续提交同一配置，各次生成独立记录和停止按钮', async () => {
  const ui = await workbench({activeRun:true});
  assert.equal(ui.$('stop'), null, '移除运行区的全局停止按钮');
  ui.ready();
  await ui.run();
  ui.ready();
  await ui.run();
  ui.ready();
  assert.deepEqual(ui.posts().map(request => request.url), ['api/run', 'api/run']);
  assert.ok(ui.posts().every(request => request.body.config_id === 'default'));
  for (const id of ['active-run', 'run-1', 'run-2']) {
    assert.ok(ui.row(id));
    assert.equal(ui.stopButton(id).disabled, false);
  }
  await ui.tick();
  assert.equal(ui.$('run-rows').querySelectorAll('tr[data-run-id]').length, 3);
  assert.match(ui.$('budget').textContent, /可并行提交/);
});

test('提交期间防止双击，保存等待期间修改模拟参数不改变本次点击的快照', async () => {
  const configGate = deferred();
  const ui = await workbench({activeRun:true, configGate:configGate.promise});
  await ui.name('新的并行配置');
  ui.field('alpha', 'weight').value = '6';
  await ui.field('alpha', 'weight').dispatch('input');
  const submitting = ui.run();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(ui.$('run').disabled, true);
  await ui.$('run').click();
  ui.$('pairs').value = '9';
  ui.$('max-rounds').value = '70';
  ui.$('seed').value = '2222';
  await ui.$('pairs').dispatch('input');
  configGate.resolve();
  await submitting;
  const submitted = ui.posts().filter(request => request.url === 'api/run');
  assert.equal(submitted.length, 1);
  assert.deepEqual(submitted[0].body.options, {pairs:5, max_rounds:40, seed_start:1001,
    model:'test-model', strength:0.5, ai_parameters:{}});
  ui.ready();
  await ui.run();
  assert.equal(ui.posts().filter(request => request.url === 'api/config').length, 1);
  assert.equal(ui.readRun('run-2').options.pairs, 9);
  assert.equal(ui.readRun('run-2').options.max_rounds, 70);
  assert.equal(ui.readRun('run-2').options.seed_start, 2222);
});

test('创建模拟的 POST 返回前持续防双击，返回后立即允许下一项', async () => {
  const runGate = deferred();
  const ui = await workbench({activeRun:true, runGate:runGate.promise});
  const submitting = ui.run();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(ui.$('run').disabled, true);
  await ui.$('run').click();
  await ui.tick();
  assert.equal(ui.$('run').disabled, true, '轮询其他任务不能解除本次提交锁');
  assert.equal(ui.posts().filter(request => request.url === 'api/run').length, 1);
  assert.equal(ui.stopButton('active-run').disabled, false);
  runGate.resolve();
  await submitting;
  ui.ready();
  await ui.run();
  assert.equal(ui.posts().filter(request => request.url === 'api/run').length, 2);
});

test('各行可并行停止，重复点击受保护，其他任务与新增任务继续运行且分布状态不串行', async () => {
  const first = deferred(), second = deferred();
  const metrics = observedMetrics(40, 25, victoryMetric([1, 1, 0]));
  const ui = await workbench({withRuns:true, activeRuns:['first', 'second'],
    stopGates:{first:first.promise, second:second.promise},
    runMetrics:{first:metrics, second:metrics, 'default-old':metrics}});
  const details = id => ui.row(id).querySelector('.run-win-distribution');
  for (const id of ['first', 'default-old']) {
    details(id).open = true;
    await details(id).dispatch('toggle');
  }
  const scrolls = ui.document.scrollEvents.length;
  const stoppingFirst = ui.stopButton('first').click();
  assert.equal(ui.stopButton('first').disabled, true);
  assert.match(ui.stopButton('first').textContent, /正在停止/);
  assert.equal(ui.stopButton('second').disabled, false);
  await ui.stopButton('first').click();
  ui.updateRun('second', {progress:{completed:6, total:10, round:8, metrics}});
  await ui.tick();
  assert.equal(ui.stopButton('first').disabled, true, '轮询返回 running 也不能解锁正在请求停止的行');
  assert.match(ui.row('second').textContent, /6\/10局.*第8回合/);
  await ui.run();
  assert.ok(ui.stopButton('run-1'), '停止另一项时仍然可以提交新模拟');
  const stoppingSecond = ui.stopButton('second').click();
  assert.equal(ui.stopButton('first').disabled, true);
  assert.equal(ui.stopButton('second').disabled, true);
  ui.$('direction').value = 'asc';
  await ui.$('direction').dispatch('change');
  assert.deepEqual(['first', 'second', 'default-old'].map(id => details(id).open), [true, false, true]);
  first.resolve();
  await stoppingFirst;
  assert.equal(ui.stopButton('first'), null);
  assert.equal(ui.stopButton('second').disabled, true);
  assert.equal(ui.stopButton('run-1').disabled, false);
  second.resolve();
  await stoppingSecond;
  assert.equal(ui.stopButton('second'), null);
  assert.equal(ui.readRun('run-1').status, 'queued');
  assert.deepEqual(ui.posts().filter(request => request.url === 'api/stop').map(request => request.body),
    [{run_id:'first'}, {run_id:'second'}]);
  assert.deepEqual(['first', 'second', 'default-old'].map(id => details(id).open), [true, false, true]);
  for (const element of ui.$('run-rows').querySelectorAll('details')) await element.dispatch('toggle');
  assert.equal(ui.document.scrollEvents.length, scrolls, '排序、新任务、停止和刷新均不应重复滚动');
});

test('停止请求失败时该行显示错误并恢复操作，重试不会停止其他任务', async () => {
  const stopFailures = {first:'请求失败：未知模拟记录'};
  const ui = await workbench({activeRuns:['first', 'second'], stopFailures});
  await ui.stopButton('first').click();
  assert.match(ui.row('first').querySelector('.run-stop-error').textContent, /未知模拟记录/);
  assert.equal(ui.stopButton('first').disabled, false);
  assert.equal(ui.stopButton('second').disabled, false);
  assert.equal(ui.readRun('second').status, 'running');
  ui.ready();
  delete stopFailures.first;
  await ui.stopButton('first').click();
  assert.equal(ui.stopButton('first'), null);
  assert.equal(ui.row('first').querySelector('.run-stop-error'), null);
  assert.equal(ui.stopButton('second').disabled, false);
});

test('停止请求期间任务已完成视为正常终态，不误报失败或保留可点击按钮', async () => {
  const stopGate = deferred();
  const ui = await workbench({activeRuns:['first', 'second'], stopGates:{first:stopGate.promise}});
  const stopping = ui.stopButton('first').click();
  const metrics = observedMetrics(40, 25, victoryMetric([1, 1, 0]), 20);
  ui.updateRun('first', {status:'complete', finished:20,
    result:{meta:{metric_version:'test', ai_parameters:{}}, metrics}});
  stopGate.resolve();
  await stopping;
  assert.match(ui.row('first').textContent, /已完成/);
  assert.equal(ui.stopButton('first'), null);
  assert.equal(ui.row('first').querySelector('.run-stop-error'), null);
  assert.equal(ui.$('message').classList.contains('error'), false);
  assert.equal(ui.stopButton('second').disabled, false);
  assert.equal(ui.$('run-a').value, 'first', '停止响应先报 complete、GET 才带结果时仍须加入比较');
  assert.equal(ui.$('run-b').value, 'first');
  assert.match(ui.$('run-a').options.find(option => option.value === 'first').textContent, /11\/11项有值/);
  assert.match(ui.$('metric-diff').textContent, /40\.0现金/);
  assert.match(ui.$('metric-diff').textContent, /20\.0%/);
  assert.doesNotMatch(ui.$('compare-notice').textContent, /未选择|没有可用/);
});

test('服务端已接受停止但进程仍在退出时保持该行置灰，终态由后续轮询更新', async () => {
  const ui = await workbench({activeRuns:['first', 'second'], stopStatuses:{first:'stopping'}});
  await ui.stopButton('first').click();
  assert.equal(ui.stopButton('first').disabled, true);
  assert.match(ui.stopButton('first').textContent, /正在停止/);
  await ui.stopButton('first').click();
  await ui.tick();
  assert.equal(ui.stopButton('first').disabled, true);
  assert.equal(ui.stopButton('second').disabled, false);
  assert.equal(ui.posts().filter(request => request.url === 'api/stop').length, 1);
  ui.ready();
  ui.updateRun('first', {status:'cancelled', finished:30});
  await ui.tick();
  assert.equal(ui.stopButton('first'), null);
  assert.match(ui.row('first').textContent, /已停止/);
});

test('停止前发出的旧轮询不能重新启用已停止任务，重试读取最新状态', async () => {
  const oldPoll = deferred(), freshPoll = deferred();
  const ui = await workbench({activeRuns:['first', 'second'], pollGates:[oldPoll.promise, freshPoll.promise]});
  await ui.tick();
  assert.equal(ui.pollCount(), 1);
  await ui.stopButton('first').click();
  assert.equal(ui.stopButton('first'), null);
  oldPoll.resolve();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(ui.pollCount(), 2, '丢弃停止前的快照后应重新读取');
  assert.equal(ui.stopButton('first'), null, '新快照仍在途时也不能被旧 running 响应恢复');
  freshPoll.resolve();
  await new Promise(resolve => setImmediate(resolve));
  assert.match(ui.row('first').textContent, /已停止/);
  assert.equal(ui.stopButton('second').disabled, false);
});

test('同一轮询中多个任务完成时，比较自动选择匹配配置中最新的记录', async () => {
  const ui = await workbench({activeRuns:['newer', 'older']});
  const result = {meta:{metric_version:'test', ai_parameters:{}}, metrics:observedMetrics(40, 25)};
  ui.updateRun('newer', {created:20, status:'complete', finished:25, result});
  ui.updateRun('older', {created:10, status:'complete', finished:25, result});
  await ui.tick();
  assert.equal(ui.$('run-a').value, 'newer');
  assert.equal(ui.$('run-b').value, 'newer');
  assert.equal(ui.stopButton('newer'), null);
  assert.equal(ui.stopButton('older'), null);
});

test('仅修改名称时置灰并提示参数要求，恢复原名后允许复用', async () => {
  const ui = await workbench();
  await ui.name('仅改名称');
  await ui.blocked(/修改至少一个卡牌参数/);
  await ui.name('默认卡表');
  ui.ready();
});

test('名称重复时置灰并指出占用名称，换成未使用名称立即恢复', async () => {
  const ui = await workbench();
  const weight = ui.field('alpha', 'weight');
  weight.value = '6';
  await weight.dispatch('input');
  await ui.name('已有配置');
  await ui.blocked(/已有配置.*(?:使用|占用|已存在)/);
  assert.equal(ui.$('name').getAttribute('aria-invalid'), 'true');
  assert.equal(ui.$('name-error').hidden, false);
  assert.match(ui.$('name-error').textContent, /已有配置/);
  await ui.name('未占用的新配置');
  ui.ready();
  assert.equal(ui.$('name').getAttribute('aria-invalid'), 'false');
  assert.equal(ui.$('name-error').hidden, true);
  await ui.run();
  assert.equal(ui.posts()[0].body.name, '未占用的新配置');
});

test('空名称和纯空白名称立即置灰，填回原名称后恢复', async () => {
  const ui = await workbench();
  for (const name of ['', '   ']) {
    await ui.name(name);
    await ui.blocked(/填写.*名称/);
    assert.equal(ui.$('name').getAttribute('aria-invalid'), 'true');
    assert.equal(ui.$('name-error').hidden, false);
    await ui.name('默认卡表');
    ui.ready();
  }
});

test('切换起点配置不会把旧输入同步进新配置，未再修改时直接复用', async () => {
  const ui = await workbench();
  await ui.name('待放弃的草稿');
  const input = ui.field('alpha', 'weight');
  input.value = '9';
  await input.dispatch('input');
  ui.$('source').value = 'alternate';
  await ui.$('source').dispatch('change');
  assert.equal(Number(ui.field('alpha', 'weight').value), 5);
  assert.equal(ui.$('name').value, '已有配置');
  await ui.run();
  assert.deepEqual(ui.posts().map(request => request.url), ['api/run']);
  assert.equal(ui.posts()[0].body.config_id, 'alternate');
});

test('权重只触发 change 也能解除先改名称造成的禁用', async () => {
  const ui = await workbench();
  await ui.name('只触发change');
  await ui.blocked(/修改至少一个卡牌参数/);
  const weight = ui.field('alpha', 'weight');
  weight.value = '8';
  await weight.dispatch('change');
  ui.ready();
  await ui.run();
  assert.equal(ui.posts()[0].body.cards.alpha.weight, 8);
});

test('权重漏发 input/change 后定时刷新恢复按钮并保存当前值', async () => {
  const ui = await workbench();
  await ui.name('漏事件回归');
  await ui.blocked(/修改至少一个卡牌参数/);
  ui.field('alpha', 'weight').value = '8';
  await ui.tick();
  ui.ready();
  await ui.run();
  assert.deepEqual(ui.posts().map(request => request.url), ['api/config', 'api/run']);
  assert.equal(ui.posts()[0].body.cards.alpha.weight, 8);
});

test('非法卡牌数值立即置灰并明确提示，恢复合法值后解除禁用', async () => {
  const ui = await workbench();
  await ui.name('非法数值回归');
  const input = ui.field('alpha', 'price');
  for (const invalid of ['0', '1.5', '', '2147483648']) {
    input.value = '4';
    await input.dispatch('input');
    input.value = invalid;
    await input.dispatch('input');
    await ui.blocked(/正整数/);
    input.value = '4';
    await input.dispatch('input');
    ui.ready();
  }
});

test('编辑器按服务端字段上限限制输入并阻止超限保存', async () => {
  const ui = await workbench({fieldLimits:{'_game.start_user':{max:200}, 'alpha.pawn':{max:1000}}});
  await ui.name('资源规模边界');
  const input = ui.field('_game', 'start_user');
  assert.equal(input.getAttribute('max'), '200');
  assert.equal(ui.field('alpha', 'pawn').getAttribute('max'), '1000');
  input.value = '201';
  await input.dispatch('input');
  await ui.blocked(/不超过200/);
  assert.equal(ui.$('save-config').disabled, true);
  input.value = '200';
  await input.dispatch('input');
  ui.ready();
});

test('模拟参数非法值即时置灰，修正后恢复且不要求修改配置名称', async () => {
  const ui = await workbench();
  for (const [id, invalid, valid] of [
    ['pairs', '0', '5'], ['pairs', '', '5'], ['max-rounds', '0', '40'],
    ['max-rounds', '1.5', '40'], ['seed', '0', '1001'],
  ]) {
    const input = ui.$(id);
    input.value = invalid;
    await input.dispatch('input');
    await ui.blocked(/种子|回合|数值|参数/);
    input.value = valid;
    await input.dispatch('input');
    ui.ready();
  }
  await ui.run();
  assert.deepEqual(ui.posts().map(request => request.url), ['api/run']);
  assert.equal(ui.posts()[0].body.config_id, 'default');
});

test('权重提交原位更新概率，保留输入节点及未提交的其他输入', async () => {
  const ui = await workbench();
  const rows = ui.$('card-rows');
  const renders = rows.innerHTMLWrites;
  const weight = ui.field('alpha', 'weight');
  const other = ui.field('beta', 'price');
  other.value = '9';
  weight.value = '6';
  weight.focus();
  await weight.dispatch('input');
  await weight.dispatch('change');
  assert.equal(rows.innerHTMLWrites, renders, '提交权重不能重建整张卡牌表');
  assert.equal(ui.field('alpha', 'weight'), weight);
  assert.equal(ui.field('beta', 'price'), other);
  assert.equal(other.value, '9');
  assert.equal(ui.document.activeElement, weight);
  assert.deepEqual(rows.querySelectorAll('meter').map(meter => Number(meter.value)), [75, 25]);
});

test('试玩备注属于编辑卡牌配置，切换配置时展示该配置的当前备注', async () => {
  const ui = await workbench({notes:{default:'默认卡表节奏偏慢', alternate:'已有配置抽卡更顺畅'}});
  const editor = ui.document.querySelector('.editor');
  assert.ok(ui.$('notes').closest('.editor') === editor, '试玩备注应位于编辑卡牌配置内');
  assert.ok(ui.$('save-notes').closest('.editor') === editor, '备注保存按钮应位于编辑卡牌配置内');
  const fields = editor.querySelectorAll('input,textarea');
  assert.ok(fields.indexOf(ui.$('notes')) > fields.indexOf(ui.$('name')));
  assert.ok(fields.indexOf(ui.$('notes')) < fields.indexOf(ui.field('alpha', 'price')),
    '备注应靠近配置名称，不能藏在整张卡表后');
  assert.equal(ui.$('notes').value, '默认卡表节奏偏慢');
  assert.match(ui.$('notes-name').textContent, /默认卡表/);
  await ui.source('alternate');
  assert.equal(ui.$('name').value, '已有配置');
  assert.equal(ui.$('notes').value, '已有配置抽卡更顺畅');
  assert.match(ui.$('notes-name').textContent, /已有配置/);
  await ui.source('default');
  assert.equal(ui.$('notes').value, '默认卡表节奏偏慢');
  assert.deepEqual(ui.posts(), []);
});

test('切换比较配置或评估记录不会改写正在编辑的配置备注', async () => {
  const ui = await workbench({notes:{default:'默认配置备注', alternate:'另一配置备注'}, withRuns:true});
  await ui.notes('尚未保存的默认配置试玩感受');
  ui.$('run-a').value = 'default-old';
  await ui.$('run-a').dispatch('change');
  ui.$('compare-b').value = 'alternate';
  await ui.$('compare-b').dispatch('change');
  await ui.document.querySelector('button[data-run="alternate-run"][data-side="a"]').click();
  await ui.$('swap').click();
  await ui.tick();
  assert.equal(ui.$('source').value, 'default');
  assert.equal(ui.$('notes').value, '尚未保存的默认配置试玩感受');
  assert.match(ui.$('notes-name').textContent, /默认卡表/);
  assert.deepEqual(ui.posts(), []);
});

for (const id of ['default', 'alternate']) {
  test(`已有配置可单独保存试玩备注，不创建配置或模拟：${id}`, async () => {
    const ui = await workbench({notes:{default:'默认旧备注', alternate:'其他旧备注'}});
    await ui.source(id);
    ui.$('pairs').value = '0';
    await ui.$('pairs').dispatch('input');
    await ui.notes('独立保存的新试玩备注');
    assert.equal(ui.$('save-notes').disabled, false, '备注不应受到模拟参数校验或默认配置身份限制');
    await ui.$('save-notes').click();
    assert.deepEqual(ui.posts(), [{url:'api/notes', body:{id, text:'独立保存的新试玩备注'}}]);
    assert.equal(ui.savedNotes(id), '独立保存的新试玩备注');
    await ui.source(id === 'default' ? 'alternate' : 'default');
    await ui.source(id);
    assert.equal(ui.$('notes').value, '独立保存的新试玩备注');
  });
}

test('新配置草稿可通过保存备注独立落盘，备注不会覆盖起点配置', async () => {
  const ui = await workbench({notes:{default:'起点配置原备注'}});
  await ui.name('新配置独立备注');
  const price = ui.field('alpha', 'price');
  price.value = '4';
  await price.dispatch('input');
  await ui.notes('只属于新配置的备注');
  ui.$('pairs').value = '0';
  await ui.$('pairs').dispatch('input');
  assert.equal(ui.$('save-notes').disabled, false, '保存配置与备注不依赖模拟参数');
  await ui.$('save-notes').click();
  assert.deepEqual(ui.posts().map(request => request.url), ['api/config', 'api/notes']);
  assert.equal(ui.posts()[0].body.name, '新配置独立备注');
  assert.equal(ui.posts()[0].body.cards.alpha.price, 4);
  assert.deepEqual(ui.posts()[1].body, {id:'saved-version', text:'只属于新配置的备注'});
  assert.equal(ui.savedNotes('default'), '起点配置原备注');
  assert.equal(ui.$('source').value, 'saved-version');
  assert.equal(ui.$('notes').value, '只属于新配置的备注');
  await ui.source('default');
  assert.equal(ui.$('notes').value, '起点配置原备注');
  await ui.source('saved-version');
  assert.equal(ui.$('notes').value, '只属于新配置的备注');
});

test('保存并运行新配置时保留并保存当前备注草稿', async () => {
  const ui = await workbench({notes:{default:'原版本备注'}});
  await ui.name('带备注运行的新配置');
  const weight = ui.field('alpha', 'weight');
  weight.value = '8';
  await weight.dispatch('input');
  await ui.notes('新版本试玩感受不能在保存配置后丢失');
  await ui.run();
  assert.deepEqual(ui.posts().map(request => request.url), ['api/config', 'api/notes', 'api/run']);
  assert.deepEqual(ui.posts()[1].body, {id:'saved-version', text:'新版本试玩感受不能在保存配置后丢失'});
  assert.equal(ui.posts()[2].body.config_id, 'saved-version');
  assert.equal(ui.savedNotes('default'), '原版本备注');
  assert.equal(ui.$('notes').value, '新版本试玩感受不能在保存配置后丢失');
});

test('保存备注等待响应时切换配置，完成后仍更新原配置且保留新配置输入', async () => {
  let release;
  const notesGate = new Promise(resolve => { release = resolve; });
  const ui = await workbench({notes:{default:'默认原备注', alternate:'其他原备注'}, notesGate});
  await ui.source('alternate');
  await ui.notes('其他配置已保存的新备注');
  const saving = ui.$('save-notes').click();
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(ui.posts(), [{url:'api/notes', body:{id:'alternate', text:'其他配置已保存的新备注'}}]);
  await ui.source('default');
  assert.equal(ui.$('notes').value, '默认原备注');
  await ui.notes('默认配置尚未保存的输入');
  release();
  await saving;
  assert.equal(ui.$('source').value, 'default');
  assert.equal(ui.$('notes').value, '默认配置尚未保存的输入');
  assert.match(ui.$('notes-name').textContent, /默认卡表/);
  assert.equal(ui.savedNotes('default'), '默认原备注');
  assert.equal(ui.savedNotes('alternate'), '其他配置已保存的新备注');
  await ui.source('alternate');
  assert.equal(ui.$('notes').value, '其他配置已保存的新备注');
  await ui.source('default');
  assert.equal(ui.$('notes').value, '默认原备注', '异步响应不能误写到后来选中的配置');
});

test('保存新配置等待响应时切换配置，备注保存到新配置且不切回当前编辑器', async () => {
  let release;
  const configGate = new Promise(resolve => { release = resolve; });
  const ui = await workbench({notes:{default:'默认原备注', alternate:'其他原备注'}, configGate});
  await ui.name('异步保存的新配置');
  const weight = ui.field('alpha', 'weight');
  weight.value = '8';
  await weight.dispatch('input');
  await ui.notes('新配置自己的试玩备注');
  const saving = ui.$('save-notes').click();
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(ui.posts().map(request => request.url), ['api/config']);
  assert.equal(ui.posts()[0].body.name, '异步保存的新配置');
  assert.equal(ui.posts()[0].body.cards.alpha.weight, 8);
  await ui.source('alternate');
  assert.equal(ui.$('name').value, '已有配置');
  assert.equal(ui.$('notes').value, '其他原备注');
  release();
  await saving;
  assert.deepEqual(ui.posts().map(request => request.url), ['api/config', 'api/notes']);
  assert.deepEqual(ui.posts()[1].body, {id:'saved-version', text:'新配置自己的试玩备注'});
  assert.equal(ui.$('source').value, 'alternate', '保存完成不能强行切回已离开的配置');
  assert.equal(ui.$('name').value, '已有配置');
  assert.equal(Number(ui.field('alpha', 'weight').value), 5);
  assert.equal(ui.$('notes').value, '其他原备注');
  assert.match(ui.$('notes-name').textContent, /已有配置/);
  assert.equal(ui.savedNotes('default'), '默认原备注');
  assert.equal(ui.savedNotes('alternate'), '其他原备注');
  await ui.source('saved-version');
  assert.equal(ui.$('name').value, '异步保存的新配置');
  assert.equal(Number(ui.field('alpha', 'weight').value), 8);
  assert.equal(ui.$('notes').value, '新配置自己的试玩备注');
});

test('出售价格支持零值，显式设置零也计入配置改动', async () => {
  const ui = await workbench();
  const pawn = ui.field('alpha', 'pawn');
  assert.ok(pawn, '卡牌表应提供出售价格输入');
  assert.equal(pawn.getAttribute('min'), '0');
  assert.equal(pawn.getAttribute('step'), '1');
  assert.equal(pawn.required, false);
  assert.equal(pawn.value, '', '未覆盖出售价格时使用空值表示自动');
  assert.equal(ui.field('legend', 'pawn').required, true, '传说卡原有的显式出售价格不能删除');
  pawn.value = '0';
  await pawn.dispatch('input');
  assert.equal(pawn.classList.contains('changed'), true);
  await ui.name('零元出售配置');
  ui.ready();
  await ui.run();
  assert.deepEqual(ui.posts().map(request => request.url), ['api/config', 'api/run']);
  assert.equal(ui.posts()[0].body.cards.alpha.pawn, 0);
});

test('清空可选出售价格恢复自动计算，保存时删除覆盖值并正确展示差异', async () => {
  const ui = await workbench();
  await ui.source('alternate');
  const pawn = ui.field('alpha', 'pawn');
  assert.equal(Number(pawn.value), 3);
  pawn.value = '';
  await pawn.dispatch('input');
  assert.equal(pawn.classList.contains('changed'), true);
  await ui.name('恢复自动出售价格');
  ui.ready();
  await ui.run();
  assert.equal(Object.hasOwn(ui.posts()[0].body.cards.alpha, 'pawn'), false,
    '恢复自动计算应删除 pawn，而不是把空值保存成 0 或 null');
  ui.$('compare-a').value = 'alternate';
  await ui.$('compare-a').dispatch('change');
  ui.$('compare-b').value = 'saved-version';
  await ui.$('compare-b').dispatch('change');
  const row = ui.$('card-diff').querySelectorAll('tr').find(tr => /甲卡/.test(tr.textContent) && /出售价格/.test(tr.textContent));
  assert.ok(row, '显式出售价格与自动出售价格之间应展示差异');
  assert.match(row.textContent, /自动/);
  assert.doesNotMatch(row.textContent, /undefined|NaN|null/);
});

test('非法出售价格阻止保存和试玩，传说卡出售价格不可留空', async () => {
  const ui = await workbench();
  await ui.name('出售价格校验');
  for (const [card, invalid] of [['alpha', '-1'], ['alpha', '1.5'], ['alpha', '2147483648'], ['legend', '']]) {
    const pawn = ui.field(card, 'pawn');
    pawn.value = invalid;
    await pawn.dispatch('input');
    assert.equal(ui.$('run').disabled, true);
    assert.equal(ui.$('play').disabled, true);
    assert.equal(ui.$('save-notes').disabled, true);
    assert.match(ui.$('play-reason').textContent, /出售价格|整数|数值/);
    await ui.$('play').click();
    assert.deepEqual(ui.posts(), []);
    pawn.value = '0';
    await pawn.dispatch('input');
    ui.ready();
    assert.equal(ui.$('play').disabled, false);
  }
});

test('以已有配置启动游戏只请求试玩，不新增配置或评估记录', async () => {
  const ui = await workbench();
  assert.ok(ui.$('play').closest('.editor'), '试玩入口应位于编辑卡牌配置区');
  assert.equal(ui.$('play').disabled, false, ui.$('play-reason').textContent);
  await ui.$('play').click();
  assert.deepEqual(ui.posts(), [{url:'api/play', body:{config_id:'default'}}]);
  assert.match(ui.$('message').textContent, /默认卡表/);
});

test('新配置试玩先保存卡表和备注，再以新配置启动游戏', async () => {
  const ui = await workbench({notes:{default:'原配置试玩备注'}});
  await ui.name('实际试玩新配置');
  const pawn = ui.field('alpha', 'pawn');
  pawn.value = '4';
  await pawn.dispatch('input');
  await ui.notes('新卡表与新出售价格的试玩备注');
  assert.equal(ui.$('play').disabled, false, ui.$('play-reason').textContent);
  await ui.$('play').click();
  assert.deepEqual(ui.posts().map(request => request.url), ['api/config', 'api/notes', 'api/play']);
  assert.equal(ui.posts()[0].body.name, '实际试玩新配置');
  assert.equal(ui.posts()[0].body.cards.alpha.pawn, 4);
  assert.deepEqual(ui.posts()[1].body, {id:'saved-version', text:'新卡表与新出售价格的试玩备注'});
  assert.deepEqual(ui.posts()[2].body, {config_id:'saved-version'});
  assert.equal(ui.savedNotes('default'), '原配置试玩备注');
});

test('试玩沿用配置名称规则，同名修改参数时置灰且不发启动请求', async () => {
  const ui = await workbench();
  const pawn = ui.field('alpha', 'pawn');
  pawn.value = '0';
  await pawn.dispatch('input');
  assert.equal(ui.$('play').disabled, true);
  assert.match(ui.$('play-reason').textContent, /新.*名称|同名/);
  await ui.$('play').click();
  assert.deepEqual(ui.posts(), []);
  await ui.name('不同名称可以试玩');
  assert.equal(ui.$('play').disabled, false);
});

test('评估正在运行、AI 参数正在加载以及非法模拟参数都不阻止试玩', async () => {
  let release;
  const profileGate = new Promise(resolve => { release = resolve; });
  const ui = await workbench({activeRun:true, profileGate});
  ui.$('pairs').value = '0';
  await ui.$('pairs').dispatch('input');
  ui.$('strength').value = '0.6';
  const loading = ui.$('strength').dispatch('change');
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(ui.$('run').disabled, true);
  assert.equal(ui.$('play').disabled, false, ui.$('play-reason').textContent);
  await ui.$('play').click();
  assert.deepEqual(ui.posts(), [
    {url:'api/profile', body:{strength:0.6}},
    {url:'api/play', body:{config_id:'default'}},
  ]);
  release();
  await loading;
});

test('游戏启动失败时展示服务端错误并恢复试玩按钮', async () => {
  const ui = await workbench({playError:'找不到 Godot 可执行文件'});
  await ui.$('play').click();
  assert.deepEqual(ui.posts(), [{url:'api/play', body:{config_id:'default'}}]);
  assert.match(ui.$('message').textContent, /找不到 Godot 可执行文件/);
  assert.equal(ui.$('message').classList.contains('error'), true);
  assert.equal(ui.$('play').disabled, false, '启动失败后应允许修复问题并重试');
});

test('启动游戏请求尚未完成时置灰并阻止重复启动', async () => {
  let release;
  const playGate = new Promise(resolve => { release = resolve; });
  const ui = await workbench({playGate});
  const launching = ui.$('play').click();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(ui.$('play').disabled, true);
  assert.match(ui.$('play-reason').textContent, /启动|稍候|请等待/);
  await ui.$('play').click();
  assert.deepEqual(ui.posts(), [{url:'api/play', body:{config_id:'default'}}]);
  release();
  await launching;
  assert.equal(ui.$('play').disabled, false);
});

function observedMetrics(cash, users, diversity, pawnWin) {
  return Object.fromEntries(metricDefinitions.filter(([q]) =>
    (q !== 'Q8' || cash !== undefined) && (q !== 'Q9' || users !== undefined)
      && (q !== 'Q10' || diversity !== undefined) && (q !== 'Q11' || pawnWin !== undefined)).map(([q, , , unit]) => {
    if (q === 'Q10') return [q, diversity];
    const value = q === 'Q8' ? cash : q === 'Q9' ? users : q === 'Q11' ? pawnWin : q === 'Q2' ? 20 : 50;
    return [q, {value, unit, numerator:value * (unit === '%' ? 0.1 : 10), denominator:10,
      ...(q === 'Q7' ? {definition:'upgrade-production-v1'} : {})}];
  }));
}

function victoryMetric(counts, extra = {}) {
  const categories = [
    ['cash_threshold', '普通现金达标'], ['cash_depletion', '对手现金清零'],
    ['user_depletion', '对手用户清零'], ['legend_cashout:server-legend', '报告中的传说变现达标'],
    ['legend_cashout:other-legend', '另一传说变现达标'], ['legend_cashout:third-legend', '第三传说变现达标'],
    ['legend_cashout:mixed', '多种传说共同变现达标'],
  ];
  const classified = counts.reduce((sum, n) => sum + n, 0);
  const entropy = classified ? -counts.filter(n => n > 0).reduce((sum, n) => sum + n / classified * Math.log(n / classified), 0) : null;
  return {value:entropy === null ? null : Math.exp(entropy), unit:'种', numerator:null,
    denominator:classified, classified_games:classified, unclassified_wins:0,
    observed_categories:counts.filter(n => n > 0).length, category_count:counts.length,
    distribution:counts.map((count, i) => ({id:categories[i][0], label:categories[i][1], count,
      percentage:classified ? count / classified * 100 : null})), ...extra};
}

test('指标列、说明、空表跨度和选项数量跟随后端定义扩展到 Q11', async () => {
  const ui = await workbench();
  assert.equal(ui.$('definitions').querySelectorAll('article').length, 11);
  assert.equal(ui.$('definitions-title').textContent, '先看懂这 11 个数');
  assert.equal(ui.$('metrics-range').textContent, 'Q1–Q11');
  assert.equal(ui.$('run-head').querySelectorAll('th').length, 14);
  assert.equal(ui.$('run-rows').querySelector('td').getAttribute('colspan'), '14');
  assert.equal(ui.$('metric-diff').querySelectorAll('tr').length, 11);
  assert.equal(ui.$('sort').options.length, 12);
  assert.match(ui.$('sort').options.at(-1).textContent, /Q11 典当后获胜比例/);
  assert.match(ui.$('metric-chart').querySelector('[data-metric-chart="percentage"]').textContent, /Q7 升级后成功生产.*Q11 典当后获胜比例/);
  // A smaller backend definition set must also control every rendered count.
  const subset = await workbench({definitions:metricDefinitions.slice(7, 9)});
  assert.equal(subset.$('definitions-title').textContent, '先看懂这 2 个数');
  assert.equal(subset.$('run-head').querySelectorAll('th').length, 5);
  assert.equal(subset.$('run-rows').querySelector('td').getAttribute('colspan'), '5');
  assert.equal(subset.$('metric-diff').querySelectorAll('tr').length, 2);
  assert.equal(subset.$('metric-chart').querySelector('[data-metric-chart="percentage"]'), null);
  assert.equal(subset.$('win-distributions').hidden, true);
});

test('现金与用户峰值使用各自数量轴，超过 100 不截断且差值保留对应单位', async () => {
  const ui = await workbench({withRuns:true, runMetrics:{
    'default-new':observedMetrics(400, 250), 'alternate-run':observedMetrics(800, 125),
  }});
  ui.$('compare-b').value = 'alternate';
  await ui.$('compare-b').dispatch('change');
  const rows = ui.$('metric-diff').querySelectorAll('tr');
  assert.match(rows[7].textContent, /400\.0现金/);
  assert.match(rows[7].querySelector('.delta').textContent, /\+400\.0 现金/);
  assert.match(rows[8].querySelector('.delta').textContent, /-125\.0 用户/);
  assert.match(rows[0].querySelector('.delta').textContent, /个百分点/);
  assert.match(rows[1].querySelector('.delta').textContent, /回合/);
  const percent = ui.$('metric-chart').querySelector('[data-metric-chart="percentage"]');
  assert.doesNotMatch(percent.textContent, /Q8|Q9|最大现金|最大用户/);
  const cash = ui.$('metric-chart').querySelector('[data-metric-chart="Q8"]');
  const users = ui.$('metric-chart').querySelector('[data-metric-chart="Q9"]');
  assert.match(cash.textContent, /800\.0 现金/);
  assert.match(users.textContent, /250\.0 用户/);
  assert.doesNotMatch(cash.textContent + users.textContent, /%|百分点/);
  const cashWidths = cash.querySelectorAll('rect').map(rect => Number(rect.getAttribute('width')));
  const userWidths = users.querySelectorAll('rect').map(rect => Number(rect.getAttribute('width')));
  assert.equal(cashWidths[1] / cashWidths[0], 2, '400 与 800 的条形长度应为 1:2，不能截到 100');
  assert.equal(userWidths[0] / userWidths[1], 2, '用户图应独立使用自己的最大值缩放');
  assert.equal(Math.max(...cashWidths), Math.max(...userWidths), '现金与用户采用独立数量轴');
  await ui.$('export-diff').click();
  const [exported] = await ui.exported();
  assert.equal(exported.metric_difference.Q8, 400);
  assert.equal(exported.metric_difference.Q9, -125);
});

test('历史 Q1–Q7 记录缺少峰值时显示未观测，排序置后且比较导出为 null', async () => {
  const ui = await workbench({withRuns:true, runMetrics:{
    'default-old':observedMetrics(), 'default-new':observedMetrics(400, 250),
    'alternate-run':observedMetrics(800, 125),
  }});
  const oldOption = ui.$('run-a').options.find(option => option.value === 'default-old');
  const newOption = ui.$('run-a').options.find(option => option.value === 'default-new');
  assert.match(oldOption.textContent, /7\/11项有值/);
  assert.match(newOption.textContent, /9\/11项有值/);
  ui.$('sort').value = 'Q8';
  await ui.$('sort').dispatch('change');
  const ids = () => ui.$('run-rows').querySelectorAll('tr').map(row => row.querySelector('button[data-run]').dataset.run);
  assert.deepEqual(ids(), ['alternate-run', 'default-new', 'default-old']);
  ui.$('direction').value = 'asc';
  await ui.$('direction').dispatch('change');
  assert.deepEqual(ids(), ['default-new', 'alternate-run', 'default-old']);
  const oldRow = ui.$('run-rows').querySelectorAll('tr').at(-1);
  assert.equal(oldRow.querySelectorAll('td')[9].textContent, '未观测');
  assert.equal(oldRow.querySelectorAll('td')[10].textContent, '未观测');
  ui.$('run-a').value = 'default-old';
  await ui.$('run-a').dispatch('change');
  ui.$('compare-b').value = 'alternate';
  await ui.$('compare-b').dispatch('change');
  for (const row of ui.$('metric-diff').querySelectorAll('tr').slice(7)) {
    assert.equal(row.querySelectorAll('td')[1].textContent, '未观测');
    assert.equal(row.querySelector('.delta').textContent, '未观测');
  }
  const cash = ui.$('metric-chart').querySelector('[data-metric-chart="Q8"]');
  assert.match(cash.textContent, /未观测/);
  assert.equal(cash.querySelectorAll('rect').length, 1, '缺失指标不能绘制零值条形');
  await ui.$('export-diff').click();
  const [exported] = await ui.exported();
  assert.equal(exported.metric_difference.Q8, null);
  assert.equal(exported.metric_difference.Q9, null);
  assert.equal(exported.metric_difference.Q1, 0);
});

test('评估运行中的阶段性峰值也显示在 Q8、Q9 列', async () => {
  const ui = await workbench({activeRun:true, runMetrics:{'active-run':observedMetrics(320, 140)}});
  const row = ui.$('run-rows').querySelector('tr');
  assert.match(row.querySelectorAll('td')[9].textContent, /320\.0现金/);
  assert.match(row.querySelectorAll('td')[10].textContent, /140\.0用户/);
  assert.equal(row.querySelectorAll('td').length, 14);
});

test('切换 A 或 B 的模拟记录立即刷新指标、差值与未观测图形', async () => {
  const oldMetrics = observedMetrics();
  oldMetrics.Q1 = {...oldMetrics.Q1, value:30, numerator:3};
  const ui = await workbench({withRuns:true, runMetrics:{
    'default-old':oldMetrics, 'default-new':observedMetrics(400, 250),
  }});
  const metricRow = q => ui.$('metric-diff').querySelectorAll('tr').find(row =>
    row.querySelector('strong').textContent.startsWith(q + ' '));
  const peakBars = () => ui.$('metric-chart').querySelector('[data-metric-chart="Q8"]').querySelectorAll('rect').length;
  assert.equal(ui.$('run-a').value, 'default-new');
  assert.equal(ui.$('run-b').value, 'default-new');
  assert.equal(metricRow('Q8').querySelector('.delta').textContent, '0.0 现金');
  for (const [side, column, expectedDelta] of [['a', 1, '+20.0 个百分点'], ['b', 2, '-20.0 个百分点']]) {
    ui.$('run-' + side).value = 'default-old';
    await ui.$('run-' + side).dispatch('change');
    assert.equal(metricRow('Q1').querySelector('.delta').textContent, expectedDelta);
    assert.equal(metricRow('Q8').querySelectorAll('td')[column].textContent, '未观测');
    assert.equal(metricRow('Q9').querySelectorAll('td')[column].textContent, '未观测');
    assert.equal(metricRow('Q8').querySelector('.delta').textContent, '未观测');
    assert.equal(peakBars(), 1);
    ui.$('run-' + side).value = 'default-new';
    await ui.$('run-' + side).dispatch('change');
    assert.equal(metricRow('Q8').querySelector('.delta').textContent, '0.0 现金');
    assert.equal(metricRow('Q9').querySelector('.delta').textContent, '0.0 用户');
    assert.equal(peakBars(), 2);
  }
});

test('Q10 使用报告分类上限的独立种数轴，并展示完整分布及正确算术差', async () => {
  const single = victoryMetric([10, 0, 0, 0, 0, 0, 0]);
  const varied = victoryMetric([2, 2, 0, 0]);
  const ui = await workbench({withRuns:true, runMetrics:{
    'default-new':observedMetrics(40, 25, single), 'default-old':observedMetrics(40, 25),
    'alternate-run':observedMetrics(50, 30, varied),
  }});
  ui.$('compare-b').value = 'alternate';
  await ui.$('compare-b').dispatch('change');
  const row = ui.$('metric-diff').querySelectorAll('tr').find(row => row.querySelector('strong').textContent.startsWith('Q10 '));
  assert.match(row.textContent, /Q10 获胜方式多样性/);
  assert.match(row.querySelectorAll('td')[1].textContent, /1\.0种.*已归类 10 局.*配置上限 7 种/);
  assert.match(row.querySelectorAll('td')[2].textContent, /2\.0种.*已归类 4 局.*配置上限 4 种/);
  assert.doesNotMatch(row.textContent, /null|undefined|null \/|百分点/);
  assert.equal(row.querySelector('.delta').textContent, '+1.0 种');
  const chart = ui.$('metric-chart').querySelector('[data-metric-chart="Q10"]');
  assert.match(chart.textContent, /7\.0 种/);
  const widths = chart.querySelectorAll('rect').map(rect => Number(rect.getAttribute('width')));
  assert.ok(Math.abs(widths[0] - 380 / 7) < 1e-8, '单一获胜方式必须仅占配置上限的一份，不能画满条');
  assert.equal(widths[1] / widths[0], 2);
  assert.doesNotMatch(ui.$('metric-chart').querySelector('[data-metric-chart="percentage"]').textContent, /Q10|获胜方式/);
  const a = ui.$('win-distributions').querySelector('[data-win-distribution="a"]');
  const b = ui.$('win-distributions').querySelector('[data-win-distribution="b"]');
  assert.equal(a.querySelectorAll('[data-win-method]').length, 7);
  assert.equal(b.querySelectorAll('[data-win-method]').length, 4);
  assert.match(a.querySelector('[data-win-method="legend_cashout:server-legend"]').textContent, /报告中的传说变现达标00\.0%/);
  assert.match(a.querySelector('[data-win-method="legend_cashout:mixed"]').textContent, /多种传说共同变现达标/);
  assert.match(b.querySelector('[data-win-method="cash_depletion"]').textContent, /对手现金清零250\.0%/);
  assert.match(ui.$('run-rows').querySelector('button[data-run="default-new"]').closest('tr').querySelector('.run-win-distribution').textContent, /查看获胜分布.*已归类 10 局/);
  await ui.$('export-diff').click();
  const [exported] = await ui.exported();
  assert.equal(exported.metric_difference.Q10, 1);
  assert.deepEqual(exported.run_a.result.metrics.Q10, single);
  assert.deepEqual(exported.run_b.result.metrics.Q10, varied);
});

test('Q10 对旧报告与零已归类胜局显示未观测，排序置后且不假造分布', async () => {
  const none = victoryMetric([0, 0, 0, 0, 0, 0, 0], {unclassified_wins:2});
  const ui = await workbench({withRuns:true, runMetrics:{
    'default-new':observedMetrics(40, 25, none), 'default-old':observedMetrics(40, 25),
    'alternate-run':observedMetrics(40, 25, victoryMetric([3, 0, 0])),
  }});
  ui.$('compare-b').value = 'alternate';
  await ui.$('compare-b').dispatch('change');
  const distribution = () => ui.$('win-distributions').querySelector('[data-win-distribution="a"]');
  assert.match(distribution().textContent, /未观测：没有已归类胜局/);
  assert.match(distribution().textContent, /已归类 0 局.*未归类胜局 2 局/);
  assert.equal(distribution().querySelectorAll('[data-win-method]').length, 7, '配置支持的零次分类仍然显示');
  for (const direction of ['asc', 'desc']) {
    ui.$('sort').value = 'Q10';
    ui.$('direction').value = direction;
    await ui.$('sort').dispatch('change');
    assert.equal(ui.$('run-rows').querySelector('button[data-run]').dataset.run, 'alternate-run');
  }
  ui.$('run-a').value = 'default-old';
  await ui.$('run-a').dispatch('change');
  assert.match(distribution().textContent, /未观测：该记录没有获胜方式统计/);
  assert.equal(distribution().querySelectorAll('[data-win-method]').length, 0);
  const row = ui.$('metric-diff').querySelectorAll('tr').find(row => row.querySelector('strong').textContent.startsWith('Q10 '));
  assert.equal(row.querySelectorAll('td')[1].textContent, '未观测');
  assert.equal(row.querySelector('.delta').textContent, '未观测');
  assert.equal(ui.$('metric-chart').querySelector('[data-metric-chart="Q10"]').querySelectorAll('rect').length, 1);
  await ui.$('export-diff').click();
  const [exported] = await ui.exported();
  assert.equal(exported.metric_difference.Q10, null);
  assert.equal(Object.hasOwn(exported.run_a.result.metrics, 'Q10'), false);
});

test('切换模拟记录同步刷新 Q10 分布；进行中的记录仅展示后端已归类样本', async () => {
  const first = victoryMetric([1, 1, 0, 0, 0, 0, 0]);
  const mixed = victoryMetric([0, 0, 0, 0, 0, 0, 5]);
  const ui = await workbench({withRuns:true, activeRun:true, runMetrics:{
    'default-new':observedMetrics(40, 25, mixed), 'default-old':observedMetrics(40, 25, first),
    'active-run':observedMetrics(40, 25, first),
  }});
  const active = ui.$('run-rows').querySelector('button[data-run="active-run"]').closest('tr');
  assert.match(active.querySelector('.run-win-distribution').textContent, /已归类 2 局/);
  assert.match(active.children[1].textContent, /2\/10局/);
  assert.match(active.children[11].textContent, /^2\.0种/);
  for (const side of ['a', 'b']) {
    const selected = () => ui.$('win-distributions').querySelector('[data-win-distribution="' + side + '"]');
    assert.match(selected().querySelector('[data-win-method="legend_cashout:mixed"]').textContent, /5100\.0%/);
    ui.$('run-' + side).value = 'default-old';
    await ui.$('run-' + side).dispatch('change');
    assert.match(selected().textContent, /已归类 2 局/);
    assert.match(selected().querySelector('[data-win-method="cash_threshold"]').textContent, /150\.0%/);
    assert.match(selected().querySelector('[data-win-method="legend_cashout:mixed"]').textContent, /00\.0%/);
  }
});

for (const definition of [undefined, 'upgrade-occurrence-v1']) {
  test(`旧 Q7 口径不参与列表、比较、排序、图表和差值，原始导出保留：${definition || '无标记'}`, async () => {
    const diversity = victoryMetric([1, 1, 0]);
    const legacy = observedMetrics(40, 25, diversity);
    legacy.Q7 = {value:99, unit:'%', numerator:99, denominator:100, ...(definition ? {definition} : {})};
    const fresh = observedMetrics(40, 25, diversity, 20);
    fresh.Q7 = {...fresh.Q7, value:20, numerator:2};
    const alternate = observedMetrics(40, 25, diversity, 80);
    alternate.Q7 = {...alternate.Q7, value:40, numerator:4};
    const ui = await workbench({withRuns:true, runMetrics:{
      'default-new':legacy, 'default-old':fresh, 'alternate-run':alternate,
    }, runVersions:{'default-new':'manual-ten-v3', 'default-old':'manual-eleven-v4', 'alternate-run':'manual-eleven-v4'}});
    const listRow = id => ui.$('run-rows').querySelector(`button[data-run="${id}"]`).closest('tr');
    const comparisonRow = q => ui.$('metric-diff').querySelectorAll('tr').find(row =>
      row.querySelector('strong').textContent.startsWith(q + ' '));
    const legacyCell = listRow('default-new').children[8];
    assert.match(legacyCell.textContent, /^未观测.*Q7口径已更新，请重新评估/);
    assert.doesNotMatch(legacyCell.textContent, /99\.0%/);
    assert.equal(listRow('default-old').children[8].textContent, '20.0%');
    assert.equal(listRow('default-new').children[12].textContent, '未观测', '旧报告缺 Q11 不能当成零');
    assert.match(ui.$('run-a').options.find(x => x.value === 'default-new').textContent, /9\/11项有值/);
    assert.match(ui.$('run-a').options.find(x => x.value === 'default-old').textContent, /11\/11项有值/);
    assert.equal(ui.$('run-a').value, 'default-old', '优先选择新口径完整记录，不能被更新的旧口径记录抢占');
    const order = () => ui.$('run-rows').querySelectorAll('button[data-side="a"]').map(x => x.dataset.run);
    for (const q of ['Q7', 'Q11']) {
      ui.$('sort').value = q;
      for (const [direction, expected] of [
        ['desc', ['alternate-run', 'default-old', 'default-new']],
        ['asc', ['default-old', 'alternate-run', 'default-new']],
      ]) {
        ui.$('direction').value = direction;
        await ui.$('sort').dispatch('change');
        assert.deepEqual(order(), expected, `${q} 缺失或旧口径在两个方向都应排在已观测值之后`);
      }
    }
    ui.$('compare-b').value = 'alternate';
    await ui.$('compare-b').dispatch('change');
    assert.equal(comparisonRow('Q7').querySelector('.delta').textContent, '+20.0 个百分点');
    assert.equal(comparisonRow('Q11').querySelector('.delta').textContent, '+60.0 个百分点');
    await ui.$('export-diff').click();
    const [freshExport] = await ui.exported();
    assert.equal(freshExport.metric_difference.Q7, 20);
    assert.equal(freshExport.metric_difference.Q11, 60);

    ui.$('run-a').value = 'default-new';
    await ui.$('run-a').dispatch('change');
    assert.match(comparisonRow('Q7').children[1].textContent, /^未观测.*重新评估/);
    assert.equal(comparisonRow('Q7').querySelector('.delta').textContent, '未观测');
    assert.equal(comparisonRow('Q11').children[1].textContent, '未观测');
    assert.equal(comparisonRow('Q11').querySelector('.delta').textContent, '未观测');
    const percent = ui.$('metric-chart').querySelector('[data-metric-chart="percentage"]');
    assert.match(percent.textContent, /Q7 升级后成功生产.*Q11 典当后获胜比例/);
    assert.equal(percent.querySelectorAll('rect').length, 12, '旧 Q7 和缺失 Q11 不应绘制条形');
    assert.ok(percent.querySelectorAll('rect').every(x => Number(x.getAttribute('width')) !== 99 * 3.6));
    await ui.$('export-diff').click();
    const [, mixedExport] = await ui.exported();
    assert.equal(mixedExport.metric_difference.Q7, null);
    assert.equal(mixedExport.metric_difference.Q11, null);
    assert.equal(mixedExport.metric_difference.Q1, 0, '其他口径未变的指标仍然正常计算');
    assert.deepEqual(mixedExport.run_a.result.metrics, legacy, '兼容性过滤不可篡改原始历史记录');
    assert.equal(mixedExport.run_a.result.meta.metric_version, 'manual-ten-v3');
    assert.equal(mixedExport.run_b.result.meta.metric_version, 'manual-eleven-v4');
    await ui.$('swap').click();
    assert.match(comparisonRow('Q7').children[2].textContent, /^未观测.*重新评估/);
    assert.equal(comparisonRow('Q7').querySelector('.delta').textContent, '未观测');
    assert.equal(comparisonRow('Q11').children[2].textContent, '未观测');
  });
}

test('阶段性 Q7 也按标记过滤，后续轮询的新 Q7 和零值 Q11 正常显示', async () => {
  const legacy = observedMetrics(40, 25);
  legacy.Q7 = {value:90, unit:'%', numerator:9, denominator:10};
  const ui = await workbench({activeRun:true, runMetrics:{'active-run':legacy}});
  const row = () => ui.$('run-rows').querySelector('button[data-run="active-run"]').closest('tr');
  assert.match(row().children[8].textContent, /^未观测.*重新评估/);
  assert.equal(row().children[12].textContent, '未观测');
  const fresh = observedMetrics(40, 25, undefined, 0);
  fresh.Q7 = {...fresh.Q7, value:0, numerator:0};
  ui.updateRun('active-run', {progress:{completed:10, total:10, metrics:fresh}});
  await ui.tick();
  await ui.tick();
  assert.equal(row().children[8].textContent, '0.0%');
  assert.equal(row().children[12].textContent, '0.0%');
  assert.doesNotMatch(row().children[8].textContent, /重新评估/);
});

test('Q11 是独立的百分比指标，零值有样本且差值使用百分点', async () => {
  const ui = await workbench({withRuns:true, runMetrics:{
    'default-new':observedMetrics(40, 25, undefined, 0),
    'alternate-run':observedMetrics(40, 25, undefined, 80),
  }});
  ui.$('compare-b').value = 'alternate';
  await ui.$('compare-b').dispatch('change');
  const row = ui.$('metric-diff').querySelectorAll('tr').at(-1);
  assert.match(row.children[0].textContent, /^Q11 典当后获胜比例$/);
  assert.equal(row.children[1].textContent, '0.0%0 / 10');
  assert.equal(row.children[2].textContent, '80.0%8 / 10');
  assert.equal(row.querySelector('.delta').textContent, '+80.0 个百分点');
  const percent = ui.$('metric-chart').querySelector('[data-metric-chart="percentage"]');
  const bars = percent.querySelectorAll('rect').slice(-2);
  assert.equal(bars[0].getAttribute('width'), '2', '零值也应显示可辨识的零点条形');
  assert.equal(Number(bars[1].getAttribute('width')), 80 * 3.6);
  assert.equal(ui.$('metric-chart').querySelector('[data-metric-chart="Q11"]'), null);
  await ui.$('export-diff').click();
  const [exported] = await ui.exported();
  assert.equal(exported.metric_difference.Q11, 80);
});

async function waitUntil(predicate, message) {
  const deadline = Date.now() + 5000;
  while (!predicate() && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 25));
  assert.ok(predicate(), message);
}

test('真实定时刷新保持各记录分布开关，更新进度及分布，排序和完成不跳动或串记录', async t => {
  const metrics = observedMetrics(40, 25, victoryMetric([1, 1, 0]));
  const ui = await workbench({withRuns:true, activeRun:true, realTimers:true, runMetrics:{
    'active-run':metrics, 'default-new':metrics, 'default-old':metrics,
    'alternate-run':metrics,
  }});
  t.after(() => ui.dispose());
  const row = id => ui.$('run-rows').querySelector(`button[data-run="${id}"]`).closest('tr');
  const details = id => row(id).querySelector('.run-win-distribution');
  const states = () => ['active-run', 'default-new', 'default-old', 'alternate-run'].map(id => details(id).open);
  const selectionBefore = [ui.$('run-a').value, ui.$('run-b').value];
  const messageBefore = ui.$('message').textContent;
  await details('active-run').click();
  assert.deepEqual([ui.$('run-a').value, ui.$('run-b').value], selectionBefore, '点击分布本体不应触发放入 A/B 的事件委托');
  assert.equal(ui.$('message').textContent, messageBefore, '分布交互不应出现 compare-undefined 错误');
  const oldActive = details('active-run');
  oldActive.open = true; // 浏览器的 toggle 尚未送达，轮询先重建了 DOM。
  details('default-old').open = true;
  await details('default-old').dispatch('toggle');
  assert.equal(ui.document.scrollEvents.length, 1, '用户主动展开时仍可滚入视野');
  const elapsedBefore = row('active-run').children[1].querySelector('small').textContent;
  await waitUntil(() => ui.pollCount() >= 1 && details('active-run') !== oldActive, '页面自身的一秒定时器应刷新记录');
  assert.deepEqual(states(), [true, false, true, false]);
  await oldActive.dispatch('toggle');
  for (const element of ui.$('run-rows').querySelectorAll('details')) await element.dispatch('toggle');
  assert.equal(ui.document.scrollEvents.length, 1, '恢复 open 或旧节点的延迟事件不能每秒触发滚动');

  ui.$('sort').value = 'created';
  ui.$('direction').value = 'asc';
  await ui.$('direction').dispatch('change');
  assert.equal(ui.$('run-rows').querySelector('button[data-run]').dataset.run, 'default-old');
  assert.deepEqual(states(), [true, false, true, false], '状态应跟随记录 ID，不跟随排序位置');
  const oldHistory = details('default-old');
  oldHistory.open = false; // 关闭事件也可能尚未送达。
  const updated = observedMetrics(80, 45, victoryMetric([1, 2, 3]));
  ui.updateRun('active-run', {progress:{completed:6, total:10, round:9, metrics:updated}});
  await waitUntil(() => /6\/10局.*第9回合/.test(row('active-run').children[1].textContent), '后续轮询应继续展示最新进度');
  assert.match(details('active-run').textContent, /已归类 6 局/);
  assert.match(details('active-run').querySelector('[data-win-method="user_depletion"]').textContent, /350\.0%/);
  assert.notEqual(row('active-run').children[1].querySelector('small').textContent, elapsedBefore, '耗时仍应逐秒更新');
  assert.deepEqual(states(), [true, false, false, false], '手动关闭后不能被下次刷新重新展开');
  oldHistory.open = true;
  await oldHistory.dispatch('toggle');
  for (const element of ui.$('run-rows').querySelectorAll('details')) await element.dispatch('toggle');
  assert.equal(ui.document.scrollEvents.length, 1, '脱离文档的延迟展开事件应被忽略');

  ui.updateRun('active-run', {status:'complete', finished:Date.now() / 1000,
    result:{meta:{metric_version:'test', ai_parameters:{}}, metrics:updated}});
  await waitUntil(() => /已完成/.test(row('active-run').children[1].textContent), '完成状态应由真实轮询刷新');
  assert.deepEqual(states(), [true, false, false, false]);
  ui.$('sort').value = 'Q10';
  await ui.$('sort').dispatch('change');
  assert.deepEqual(states(), [true, false, false, false]);
  for (const element of ui.$('run-rows').querySelectorAll('details')) await element.dispatch('toggle');
  assert.equal(ui.document.scrollEvents.length, 1);
});

test('停止模拟的即时重绘和状态轮询均保留当前及历史记录的获胜分布', async t => {
  const metrics = observedMetrics(40, 25, victoryMetric([1, 1, 0]));
  const ui = await workbench({withRuns:true, activeRun:true, realTimers:true,
    runMetrics:{'active-run':metrics, 'default-old':metrics, 'default-new':metrics}});
  t.after(() => ui.dispose());
  const row = id => ui.$('run-rows').querySelector(`button[data-run="${id}"]`).closest('tr');
  const details = id => row(id).querySelector('.run-win-distribution');
  for (const id of ['active-run', 'default-old']) {
    details(id).open = true;
    await details(id).dispatch('toggle');
  }
  const stopping = ui.stopButton('active-run').click();
  assert.match(row('active-run').children[1].textContent, /正在停止/);
  assert.equal(details('active-run').open, true);
  assert.equal(details('default-old').open, true);
  await stopping;
  assert.match(row('active-run').children[1].textContent, /已停止/);
  assert.equal(details('active-run').open, true);
  assert.equal(details('default-old').open, true);
  assert.equal(details('default-new').open, false);
  assert.match(details('active-run').textContent, /已归类 2 局/);
  assert.equal(ui.pollCount(), 1);
  for (const element of ui.$('run-rows').querySelectorAll('details')) await element.dispatch('toggle');
  assert.equal(ui.document.scrollEvents.length, 2, '停止后恢复展开不应重复滚动');
});


test('Q6 展示获得卡牌张数、占比及旧记录缺失，获得卡牌与获胜分布独立保持展开并导出', async () => {
  const fresh = observedMetrics(40, 25, victoryMetric([1, 1, 0]));
  fresh.Q6.acquisitions = {observed_games:2, missing_games:0, total:4, distribution:[
    {id:'yunketang',label:'云课堂',count:3,percentage:75},
    {id:'butie',label:'补贴大战',count:1,percentage:25},
    {id:'jiaolv',label:'焦虑贩卖机',count:0,percentage:0},
  ]};
  const ui = await workbench({withRuns:true, runMetrics:{'default-new':fresh,
    'default-old':observedMetrics(40,25,victoryMetric([1,1,0]))}});
  const row = id => ui.$('run-rows').querySelector(`button[data-run="${id}"]`).closest('tr');
  const acquisition = () => row('default-new').querySelector('.run-acquisition-distribution');
  assert.match(acquisition().textContent, /共获得 4 张（不含现金牌和用户牌）/);
  assert.match(acquisition().querySelector('[data-acquisition-card="yunketang"]').textContent, /云课堂375.0%/);
  assert.match(row('default-old').querySelector('.run-acquisition-distribution').textContent, /未观测/);
  acquisition().open = true;
  await acquisition().dispatch('toggle');
  ui.$('direction').value = 'asc';
  await ui.$('direction').dispatch('change');
  assert.equal(acquisition().open,true);
  assert.equal(row('default-new').querySelector('.run-win-distribution').open,false);
  assert.match(ui.$('acquisition-distributions').textContent, /云课堂375.0%/);
  await ui.$('export-diff').click();
  const [exported] = await ui.exported();
  assert.equal(exported.run_a.result.metrics.Q6.acquisitions.total,4);
});


test('模拟次数和回合可超过500，种子可超过32位；仍检查正整数及组合精度', async () => {
  const ui = await workbench();
  for (const [id,value] of [['pairs','5001'],['max-rounds','10000'],['seed','2147483648']]) {
    ui.$(id).value=value;
    await ui.$(id).dispatch('input');
  }
  ui.ready();
  assert.match(ui.$('budget').textContent,/10002 局.*10000 回合.*2147483648–2147488648/);
  ui.$('pairs').value='1';
  ui.$('seed').value=String(Number.MAX_SAFE_INTEGER);
  await ui.$('seed').dispatch('input');
  ui.ready();
  ui.$('pairs').value='2';
  await ui.$('pairs').dispatch('input');
  await ui.blocked(/最后一个种子/);
  ui.$('seed').value='1';
  ui.$('pairs').value='4503599627370496';
  await ui.$('pairs').dispatch('input');
  await ui.blocked(/总局数/);
  ui.$('pairs').value='9007199254740992';
  await ui.$('pairs').dispatch('input');
  await ui.blocked(/正整数/);
  ui.$('pairs').value='5001';
  ui.$('seed').value='2147483648';
  await ui.$('pairs').dispatch('input');
  ui.ready();
  await ui.run();
  assert.equal(ui.posts().find(x=>x.url==='api/run').body.options.pairs,5001);
});

test('AI小数权重正常启动；范围、步长和整数参数分别校验，每个数值输入都有可见说明', async () => {
  const schema=[
    {key:'upgrade_weight',label:'升级潜力权重',kind:'float',min:0,max:2,step:0.01,hint:'升级价值权重'},
    {key:'protection_bonus',label:'入组保护加成',kind:'float',min:0,max:1,step:0.01,hint:'保护价值'},
    {key:'sales',label:'战略典当候选数',kind:'int',min:0,max:8,step:1,hint:'零关闭'},
  ];
  const ui=await workbench({ai:{model:'test-model',schema,parameters:{upgrade_weight:0.65,protection_bonus:0.15,sales:0}},
    fieldLimits:{'_game.start_cash':{min:1,max:99},'alpha.price':{min:1,max:1000},'alpha.pawn':{min:0,max:1000}}});
  ui.ready();
  const weight=ui.document.querySelector('input[data-ai="upgrade_weight"]');
  assert.match(ui.$('range-ai-upgrade_weight').textContent,/0–2.*可填小数.*步长 0.01/);
  assert.match(ui.$('range-ai-sales').textContent,/0–8.*整数.*步长 1/);
  assert.match(ui.$('range-alpha-price').textContent,/1–1000/);
  assert.match(ui.$('range-alpha-pawn').textContent,/0–1000.*留空自动计算.*0 表示不可出售/);
  for(const input of ui.document.querySelectorAll('input[type=number]')){
    const id=input.getAttribute('aria-describedby');
    assert.ok(id,`数值输入缺少范围说明：${input.id||input.dataset.ai||input.dataset.field}`);
    assert.match(ui.$(id).textContent,/范围.*步长/);
  }
  for(const value of ['0','0.65','1.27','2']){
    weight.value=value;await weight.dispatch('input');ui.ready();
  }
  for(const value of ['-0.01','2.01','0.655','']){
    weight.value=value;await weight.dispatch('input');
    await ui.blocked(/升级潜力权重.*0–2.*可填小数.*0.01/);
    assert.doesNotMatch(ui.$('run-reason').textContent,/正整数/);
  }
  weight.value='0.65';await weight.dispatch('input');ui.ready();
  const sales=ui.document.querySelector('input[data-ai="sales"]');
  sales.value='1.5';await sales.dispatch('input');
  await ui.blocked(/战略典当候选数.*整数/);
  sales.value='0';await sales.dispatch('input');ui.ready();
  ui.$('pairs').value='0.5';await ui.$('pairs').dispatch('input');
  await ui.blocked(/种子对数.*正整数/);
  ui.$('pairs').value='501';await ui.$('pairs').dispatch('input');ui.ready();
  await ui.run();
  assert.deepEqual(ui.posts().find(x=>x.url==='api/run').body.options.ai_parameters,
    {upgrade_weight:0.65,protection_bonus:0.15,sales:0});
});


test('整体强度以滑钮映射全部AI参数，修改滑钮清除逐项覆盖', async () => {
  const schema=[
    {key:'financing_mode',label:'典当动作覆盖',group:'设计能力',kind:'int',min:0,max:2,step:1,hint:'0单张典当；2联合融资'},
    {key:'node_budget',label:'总额度',group:'计算预算',kind:'int',min:1,max:10000000,step:1,hint:'节点额度'},
  ];
  const parameters={financing_mode:0,node_budget:30000};
  const ui=await workbench({ai:{model:'ai',schema,parameters},profileResolver:async({strength})=>({parameters:
    strength===1?{financing_mode:2,node_budget:60000}:strength===0?{financing_mode:0,node_budget:1000}:parameters})});
  const field=key=>ui.$('ai-fields').querySelector(`[data-ai="${key}"]`);
  for(const id of ['strength','duel-a-strength','duel-b-strength']){
    assert.equal(ui.$(id).type,'range');assert.equal(ui.$(id).getAttribute('min'),'0');
    assert.equal(ui.$(id).getAttribute('max'),'1');assert.equal(ui.$(id).getAttribute('step'),'0.01');
    assert.match(ui.$(ui.$(id).getAttribute('aria-describedby')).textContent,/0.5.*默认.*1.*最高/);
  }
  assert.equal(ui.$('strength').value,'0.5');assert.equal(ui.$('duel-a-strength').value,'0.5');
  assert.equal(ui.$('ai-legacy'),null);assert.equal(ui.$('ai-enhanced'),null);
  assert.equal(ui.$('duel-a-preset'),null);assert.equal(ui.$('duel-b-preset'),null);
  assert.deepEqual(ui.profileRequests(),[{strength:0}]);
  assert.equal(field('financing_mode').value,'0');
  assert.match(ui.$('ai-fields').textContent,/设计能力.*计算预算/s);
  field('node_budget').value='1234';await field('node_budget').dispatch('input');
  ui.$('strength').value='1';await ui.$('strength').dispatch('input');
  assert.equal(ui.$('strength-value').textContent,'1.00');assert.equal(ui.$('run').disabled,false);
  assert.equal(field('financing_mode').value,'2');assert.equal(field('node_budget').value,'60000');
  const requestCount=ui.profileRequests().length;
  await ui.$('strength').dispatch('change');
  assert.equal(ui.profileRequests().length,requestCount,'松手不应再次加载同一强度');
  assert.equal(field('financing_mode').value,'2');assert.equal(field('node_budget').value,'60000');
  ui.$('strength').value='0.5';await ui.$('strength').dispatch('change');
  assert.equal(field('financing_mode').value,'0');assert.equal(field('node_budget').value,'30000');
  assert.equal(ui.$('duel-a-fields').querySelector('[data-ai="node_budget"]').value,'30000');
});


test('三处强度滑钮拖动时同步应用全部可调参数，保留表单且不请求映射接口',async()=>{
 const aiConfig=JSON.parse(readFileSync(path.join(__dirname,'../data/ai.json'),'utf8')).search.ai;
 const keys=Object.keys(aiConfig).filter(key=>Array.isArray(aiConfig[key])||typeof aiConfig[key]==='number');
 assert.equal(keys.length,37);
 const schema=keys.map(key=>({key,label:key,kind:'int',min:0,max:10000000,step:1,hint:''}));
 // Deliberately distinct snapshots prove the UI applies server results, rather than its own interpolation.
 const strength_profiles=Object.fromEntries(Array.from({length:101},(_,step)=>[(step/100).toFixed(2),
  Object.fromEntries(keys.map((key,index)=>[key,step*100+index]))]));
 const originalProfiles=structuredClone(strength_profiles);
 const ui=await workbench({ai:{model:'ai',schema,parameters:strength_profiles['0.50'],strength_profiles}});
 const fieldId=side=>side==='q'?'ai-fields':'duel-'+side+'-fields';
 const sliderId=side=>side==='q'?'strength':'duel-'+side+'-strength';
 const fields=Object.fromEntries(['q','a','b'].map(side=>[side,ui.$(fieldId(side)).querySelectorAll('input[data-ai]')]));
 const field=(side,key)=>fields[side].find(input=>input.dataset.ai===key);
 const writes=Object.fromEntries(['q','a','b'].map(side=>[side,ui.$(fieldId(side)).innerHTMLWrites]));
 for(const side of ['q','a','b']){
  const expected=strength_profiles[side==='b'?'0.00':'0.50'];
  for(const input of fields[side])assert.equal(input.value,String(expected[input.dataset.ai]));
  field(side,'node_budget').value=String({q:12345,a:23456,b:34567}[side]);
  await field(side,'node_budget').dispatch('input');
 }
 assert.deepEqual(ui.profileRequests(),[],'初始化B强度也应直接使用映射表');
 for(const side of ['q','a','b']){
  const details=ui.$(fieldId(side)).closest('details');details.open=true;
  const otherValues=Object.fromEntries(['q','a','b'].filter(other=>other!==side).map(other=>[other,field(other,'node_budget').value]));
  const slider=ui.$(sliderId(side));
  if(side==='b'){slider.value='1';await slider.dispatch('input')}
  for(let step=0;step<=100;step++){
   slider.value=(step/100).toFixed(2);const dragging=slider.dispatch('input');
   for(const input of fields[side]){
    assert.equal(input.value,String(strength_profiles[slider.value][input.dataset.ai]),'input未结束时全部参数已更新');
    assert.equal(input.checkValidity(),true);
   }
   assert.equal(ui.$(slider.id+'-value').textContent,slider.value);
   await dragging;
  }
  for(const [other,value] of Object.entries(otherValues))assert.equal(field(other,'node_budget').value,value,'另一侧手动参数不受影响');
  field(side,'node_budget').value='98765';await field(side,'node_budget').dispatch('input');
  await slider.dispatch('change');
  assert.equal(field(side,'node_budget').value,'98765','松手不能覆盖同一强度下的逐项编辑');
  assert.equal(ui.$(fieldId(side)).innerHTMLWrites,writes[side],'拖动过程中不重建表单');
  assert.deepEqual(ui.$(fieldId(side)).querySelectorAll('input[data-ai]'),fields[side]);
  assert.equal(details.open,true);
 }
 assert.deepEqual(ui.profileRequests(),[],'连续拖动不能产生后台映射请求');
 assert.deepEqual(strength_profiles,originalProfiles,'逐项编辑不能修改其他强度的源快照');
 await ui.$('duel-run').click();
 const duel=ui.posts().find(request=>request.url==='api/duel').body.options;
 assert.deepEqual(duel.a.ai_parameters,{...strength_profiles['1.00'],node_budget:98765});
 assert.deepEqual(duel.b.ai_parameters,{...strength_profiles['1.00'],node_budget:98765});
 await ui.run();
 assert.deepEqual(ui.posts().find(request=>request.url==='api/run').body.options.ai_parameters,
  {...strength_profiles['1.00'],node_budget:98765});
});

test('比较实际AI参数并区分未记录字段，不能把缺失值当零', async () => {
 const schema=[{key:'financing_mode',label:'典当动作覆盖',group:'设计能力',kind:'int',min:0,max:2,step:1,hint:''},
 {key:'node_budget',label:'总额度',group:'计算预算',kind:'int',min:1,max:10000000,step:1,hint:''}];
 const ui=await workbench({withRuns:true,ai:{model:'ai',schema,parameters:{financing_mode:0,node_budget:30000}},
 runParameters:{'default-old':{financing_mode:0},'alternate-run':{financing_mode:2,node_budget:60000}}});
 ui.$('compare-a').value='default';await ui.$('compare-a').dispatch('change');
 ui.$('compare-b').value='alternate';await ui.$('compare-b').dispatch('change');
 ui.$('run-a').value='default-old';await ui.$('run-a').dispatch('change');
 ui.$('run-b').value='alternate-run';await ui.$('run-b').dispatch('change');
 assert.match(ui.$('ai-diff').textContent,/设计能力.*典当动作覆盖.*0.*2/s);
 assert.match(ui.$('ai-diff').textContent,/计算预算.*总额度.*未记录.*60000/s);
});


test('AI对战独立强度与参数、独立校验、进度统计、停止及导出', async () => {
 const ui=await workbench();
 ui.$('pairs').value='0';await ui.$('pairs').dispatch('input');
 assert.equal(ui.$('run').disabled,true);
 assert.equal(ui.$('duel-run').disabled,false,'Q模拟参数不应阻止独立AI对战');
 ui.$('duel-a-strength').value='0.7';await ui.$('duel-a-strength').dispatch('change');
 ui.$('duel-b-strength').value='0.2';await ui.$('duel-b-strength').dispatch('change');ui.$('duel-pairs').value='501';
 await ui.$('duel-run').click();
 const request=ui.posts().find(x=>x.url==='api/duel');
 assert.deepEqual(request.body.options,{pairs:501,max_rounds:40,seed_start:1001,
  a:{strength:0.7,ai_parameters:{}},b:{strength:0.2,ai_parameters:{}}});
 assert.doesNotMatch(ui.$('run-rows').textContent,/501/,'AI对战不能混入Q指标评估');
 ui.updateRun('run-1',{status:'running',progress:{completed:3,total:1002,round:4,
  summary:{completed_games:3,a_wins:1,b_wins:0,draws:2,a_decisive_win_rate:1,draw_rate:2/3,a_score_rate:2/3,
    mean_rounds:4,by_a_seat:{player:{A:1,B:0,draw:1},ai:{A:0,B:0,draw:1}}}}});
 await ui.tick();
 assert.match(ui.$('duel-rows').textContent,/A 1 胜 \/ B 0 胜 \/ 未结束 2/);
 assert.match(ui.$('duel-rows').textContent,/A 胜率 100.0%（1\/1）/);
 assert.match(ui.$('duel-rows').textContent,/A 得分率 66.7%/);
 assert.match(ui.$('duel-rows').textContent,/A 先手：1 胜/);
 const stop=ui.$('duel-rows').querySelector('button[data-stop-run="run-1"]');await stop.click();
 assert.equal(ui.posts().at(-1).url,'api/stop');
 assert.equal(ui.posts().at(-1).body.run_id,'run-1');
 await ui.$('duel-rows').querySelector('button[data-duel-export="run-1"]').click();
 const exported=(await ui.exported())[0];assert.equal(exported.kind,'ai-duel');assert.equal(exported.progress.completed,3);
 ui.$('duel-a-strength').value='1.1';await ui.$('duel-a-strength').dispatch('input');
 assert.equal(ui.$('duel-run').disabled,true);
 ui.$('duel-a-strength').value='1';await ui.$('duel-a-strength').dispatch('change');ui.$('duel-seed').value=String(Number.MAX_SAFE_INTEGER);await ui.$('duel-seed').dispatch('input');
 assert.equal(ui.$('duel-run').disabled,true);assert.match(ui.$('duel-reason').textContent,/最后一个种子/);
});

test('AI对战零局显示未观测，完成后的区间与参数可导出',async()=>{
 const ui=await workbench();await ui.$('duel-run').click();
 assert.match(ui.$('duel-rows').textContent,/A 胜率 未观测/);
 const result={a:{parameters:{node_budget:30000}},b:{parameters:{node_budget:1000}},
 summary:{completed_games:4,a_wins:2,b_wins:1,draws:1,a_decisive_win_rate:2/3,draw_rate:.25,a_score_rate:.625,
 a_score_pair_bootstrap_95:[.25,1],mean_rounds:5,decisions:{A:{decisions:4,elapsed_ms:8000,future_depth:6,selected_evaluation_complete:4}}}};
 ui.updateRun('run-1',{status:'complete',finished:20,result,progress:{completed:4,total:4}});await ui.tick();
 assert.match(ui.$('duel-rows').textContent,/25.0%–100.0%/);
 assert.match(ui.$('duel-rows').textContent,/A 平均思考 2.*秒.*平均有效前推 1.5.*回合.*当前评价完成 100.0%/);
 assert.match(ui.$('duel-rows').textContent,/未来推演中断率 未记录.*总额度耗尽率 未记录/);
 assert.match(ui.$('duel-rows').textContent,/B 思考诊断：未记录/);
 assert.equal(ui.$('duel-rows').querySelector('button[data-stop-run="run-1"]'),null);
 await ui.$('duel-rows').querySelector('button[data-duel-export="run-1"]').click();
 assert.deepEqual((await ui.exported())[0].result,result);
 assert.doesNotMatch(ui.$('run-a').textContent,/run-1/);
});


test('AI对战区分当前完成、未来中断与额度耗尽，直接使用后端累计数',async()=>{
 const ui=await workbench();await ui.$('duel-run').click();
 const decisions={
  A:{decisions:4,elapsed_ms:8000,future_depth:4,selected_evaluation_complete:4,future_incomplete:4,budget_exhausted:0},
  B:{decisions:4,elapsed_ms:4000,future_depth:6,selected_evaluation_complete:3,future_incomplete:1,budget_exhausted:2}
 };
 ui.updateRun('run-1',{status:'running',progress:{completed:1,total:4,round:2,summary:{},decisions}});await ui.tick();
 const text=ui.$('duel-rows').textContent;
 assert.match(text,/A 平均思考 2.0 秒.*当前评价完成 100.0%.*未来推演中断率 100.0%.*总额度耗尽率 0.0%/);
 assert.match(text,/B 平均思考 1.0 秒.*当前评价完成 75.0%.*未来推演中断率 25.0%.*总额度耗尽率 50.0%/);
 assert.match(html,/当前评价完成.*不代表未来推演完成/);
 assert.match(html,/总额度耗尽率不能替代未来推演中断率/);
 const finished={A:{...decisions.A,future_incomplete:1,budget_exhausted:3},B:decisions.B};
 ui.updateRun('run-1',{status:'complete',finished:20,result:{summary:{decisions:finished}}});await ui.tick();
 assert.match(ui.$('duel-rows').textContent,/A 平均思考 2.0 秒.*未来推演中断率 25.0%.*总额度耗尽率 75.0%/);
 await ui.$('duel-rows').querySelector('button[data-duel-export="run-1"]').click();
 assert.deepEqual((await ui.exported())[0].result.summary.decisions,finished,'展示比例不能改写后端累计统计');
});

test('AI对战缺失或空诊断不推断为零，没有决策时不显示百分比',async()=>{
 const ui=await workbench();await ui.$('duel-run').click();
 assert.match(ui.$('duel-rows').textContent,/A 思考诊断：未记录.*B 思考诊断：未记录/);
 const decisions={A:{decisions:2,elapsed_ms:1000,future_depth:0,future_incomplete:null},B:{decisions:0,selected_evaluation_complete:0,future_incomplete:0,budget_exhausted:0}};
 ui.updateRun('run-1',{status:'complete',finished:20,result:{summary:{decisions}}});await ui.tick();
 const text=ui.$('duel-rows').textContent;
 assert.match(text,/当前评价完成 未记录.*未来推演中断率 未记录.*总额度耗尽率 未记录/);
 assert.match(text,/B 思考诊断：尚无决策/);
 assert.doesNotMatch(text,/(?:当前评价完成|未来推演中断率|总额度耗尽率) 0.0%/);
});


test('AI对战的无效输入不会阻止卡表Q评估',async()=>{
 const ui=await workbench();ui.$('duel-pairs').value='0';await ui.$('duel-pairs').dispatch('input');
 assert.equal(ui.$('duel-run').disabled,true);assert.equal(ui.$('run').disabled,false);
 await ui.run();assert.equal(ui.posts().at(-1).url,'api/run');
});


test('AI 对战位于页面最下，双方完整呈现全部可调参数并保持各自的修改',async()=>{
 const aiConfig=JSON.parse(readFileSync(path.join(__dirname,'../data/ai.json'),'utf8')).search.ai;
 const keys=Object.keys(aiConfig).filter(key=>Array.isArray(aiConfig[key])||typeof aiConfig[key]==='number');
 const anchor=(key,index)=>Array.isArray(aiConfig[key])?aiConfig[key][index][1]:aiConfig[key];
 assert.equal(keys.length,37,'全部能力、预算与评估参数都应包含');
 const schema=keys.map((key,index)=>({key,label:key,group:index%2?'计算预算':'设计能力',
  kind:['upgrade_weight','attack_discount','protection_bonus','spent_attack_discount'].includes(key)?'float':'int',min:0,max:10000000,step:['upgrade_weight','attack_discount','protection_bonus','spent_attack_discount'].includes(key)?.01:1,hint:'测试参数'}));
 const parameters=Object.fromEntries(keys.map(key=>[key,anchor(key,1)]));
 const strongest=Object.fromEntries(keys.map(key=>[key,anchor(key,2)]));
 const weakest=Object.fromEntries(keys.map(key=>[key,anchor(key,0)]));
 const ui=await workbench({ai:{model:'ai',schema,parameters},profileResolver:async({strength})=>({parameters:strength===1?strongest:strength===0?weakest:parameters})});
 const sections=ui.document.querySelectorAll('section');assert.equal(sections.at(-1).id,'ai-duel');
 assert.ok(html.indexOf('<section id="ai-duel">')>html.indexOf('<section id="comparison">'));
 assert.ok(html.indexOf('<section id="ai-duel">')<html.indexOf('<footer>'));
 const field=(side,key)=>ui.$('duel-'+side+'-fields').querySelector(`[data-ai="${key}"]`);
 for(const side of ['a','b']){
  const fields=ui.$('duel-'+side+'-fields').querySelectorAll('input[data-ai]');
  assert.equal(fields.length,keys.length);assert.deepEqual(fields.map(input=>input.dataset.ai).sort(),keys.slice().sort());
  assert.match(ui.$('duel-'+side+'-fields').textContent,/设计能力.*计算预算/s);
  for(const input of fields){const hint=ui.$(input.getAttribute('aria-describedby'));assert.ok(hint);assert.match(hint.textContent,/范围.*含边界.*步长/)}
 }
 field('a','node_budget').value='777';await field('a','node_budget').dispatch('input');
 field('b','node_budget').value='888';await field('b','node_budget').dispatch('input');
 ui.$('duel-a-strength').value='1';await ui.$('duel-a-strength').dispatch('change');
 for(const key of keys)assert.equal(Number(field('a',key).value),strongest[key]);
 assert.equal(field('b','node_budget').value,'888');
 assert.equal(ui.$('ai-fields').querySelector('[data-ai="node_budget"]').value,String(parameters.node_budget));
 field('a','node_budget').value='999';await field('a','node_budget').dispatch('input');
 ui.$('duel-b-strength').value='0.8';await ui.$('duel-b-strength').dispatch('change');
 assert.equal(field('a','node_budget').value,'999');assert.equal(field('b','node_budget').value,String(parameters.node_budget));
 field('b','node_budget').value='222';await field('b','node_budget').dispatch('input');
 assert.equal(ui.$('duel-run').disabled,false,ui.$('duel-reason').textContent);
 await ui.$('duel-run').click();
 assert.deepEqual(ui.posts().find(request=>request.url==='api/duel').body.options,{
  pairs:5,max_rounds:40,seed_start:1001,a:{strength:1,ai_parameters:{...strongest,node_budget:999}},
  b:{strength:.8,ai_parameters:{...parameters,node_budget:222}},
 });
 field('a','node_budget').value='1.5';await field('a','node_budget').dispatch('input');
 assert.equal(ui.$('duel-run').disabled,true);assert.match(ui.$('duel-reason').textContent,/AI A node_budget.*整数/);
 assert.equal(ui.$('run').disabled,false);
});

for(const side of ['q','a','b'])test(`强度 ${side} 快速拖动时仅接纳最新映射，旧响应不能清除加载状态或覆盖新参数`,async()=>{
 const pending=new Map();
 const schema=[{key:'node_budget',label:'总额度',group:'计算预算',kind:'int',min:1,max:10000000,step:1,hint:''}];
 const ui=await workbench({ai:{model:'ai',schema,parameters:{node_budget:30000}},profileResolver:async({strength})=>{
  if(strength===0)return {parameters:{node_budget:1000}};
  return new Promise(resolve=>pending.set(strength,resolve));
 }});
 const slider=ui.$(side==='q'?'strength':'duel-'+side+'-strength');
 const field=()=>ui.$(side==='q'?'ai-fields':'duel-'+side+'-fields').querySelector('[data-ai="node_budget"]');
 const button=ui.$(side==='q'?'run':'duel-run');
 slider.value='0.7';const older=slider.dispatch('input');await slider.dispatch('change');
 assert.equal(button.disabled,true);assert.equal(field().disabled,true);
 slider.value='0.9';const newer=slider.dispatch('input');await slider.dispatch('change');
 assert.equal(ui.$(slider.id+'-value').textContent,'0.90');
 assert.equal(ui.$(side==='q'?'duel-run':'run').disabled,false,'独立模拟仍能提交');
 pending.get(.9)({parameters:{node_budget:55000}});await newer;
 assert.equal(field().value,'55000');assert.equal(button.disabled,false);
 field().value='43210';await field().dispatch('input');
 pending.get(.7)({parameters:{node_budget:40000}});await older;
 assert.equal(field().value,'43210','过时响应也不能覆盖新的逐项编辑');
 assert.equal(button.disabled,false);assert.equal(field().disabled,false);
 assert.deepEqual(ui.profileRequests(),[{strength:0},{strength:.7},{strength:.9}]);
});

test('旧服务回退也在 input 时读取并立即废弃旧响应，无需等待 change',async()=>{
 let release;
 const schema=[{key:'node_budget',label:'总额度',kind:'int',min:1,max:10000000,step:1,hint:''}];
 const ui=await workbench({ai:{model:'ai',schema,parameters:{node_budget:30000}},profileResolver:async({strength})=>{
  if(strength===.7)return new Promise(resolve=>{release=resolve});
  return {parameters:{node_budget:strength===0?1000:55000}};
 }});
 ui.$('duel-a-strength').value='.7';const older=ui.$('duel-a-strength').dispatch('change');
 ui.$('duel-a-strength').value='.9';await ui.$('duel-a-strength').dispatch('input');
 release({parameters:{node_budget:40000}});await older;
 assert.equal(ui.$('duel-run').disabled,false);assert.equal(ui.$('duel-a-fields').querySelector('[data-ai="node_budget"]').value,'55000');
 await ui.$('duel-a-strength').dispatch('change');assert.equal(ui.$('duel-run').disabled,false);
 assert.equal(ui.$('duel-a-fields').querySelector('[data-ai="node_budget"]').value,'55000');
 assert.deepEqual(ui.profileRequests(),[{strength:0},{strength:.7},{strength:.9}]);
});

test('单方映射失败阻止提交旧参数，可重新拖动恢复且不影响另一类模拟',async()=>{
 const schema=[{key:'node_budget',label:'总额度',kind:'int',min:1,max:10000000,step:1,hint:''}];
 const ui=await workbench({ai:{model:'ai',schema,parameters:{node_budget:30000}},profileResolver:async({strength})=>{
  if(strength===.7)throw Error('测试服务不可用');return {parameters:{node_budget:1000}};
 }});
 ui.$('duel-b-strength').value='.7';await ui.$('duel-b-strength').dispatch('input');
 assert.equal(ui.$('duel-run').disabled,true);assert.equal(ui.$('run').disabled,false);
 assert.match(ui.$('duel-reason').textContent,/AI B 参数读取失败.*重新调整强度/);
 assert.match(ui.$('duel-b-profile-status').textContent,/测试服务不可用/);
 await ui.$('duel-b-strength').dispatch('change');assert.deepEqual(ui.profileRequests(),[{strength:0},{strength:.7}]);
 await ui.$('duel-run').click();assert.equal(ui.posts().filter(request=>request.url==='api/duel').length,0);
 ui.$('duel-b-strength').value='0';await ui.$('duel-b-strength').dispatch('change');assert.equal(ui.$('duel-run').disabled,false);
 await ui.$('duel-run').click();assert.equal(ui.posts().filter(request=>request.url==='api/duel').length,1);
});

test('历史对战记录保留原强度语义，不显示为当前整体强度',async()=>{
 const ui=await workbench();await ui.$('duel-run').click();
 ui.updateRun('run-1',{strength_scale:null,options:{pairs:5,max_rounds:40,seed_start:1001,a:{strength:1,preset:'legacy'},b:{strength:.5,preset:'enhanced'}}});
 await ui.tick();assert.match(ui.$('duel-rows').textContent,/历史参数快照（原强度 1）/);
 assert.match(ui.$('duel-rows').textContent,/历史参数快照（原强度 0.5）/);
 assert.doesNotMatch(ui.$('duel-rows').textContent,/标准配置|增强配置/);
 ui.updateRun('run-1',{options:{pairs:5,max_rounds:40,seed_start:1001,a:{strength:1},b:{strength:.5}}});
 await ui.tick();assert.match(ui.$('duel-rows').textContent,/历史参数快照（原强度 1）/);
 assert.doesNotMatch(ui.$('duel-rows').textContent,/整体强度/);
});

test('Q评估列表和选择器区分历史强度与当前整体强度',async()=>{
 const ui=await workbench({withRuns:true});
 assert.match(ui.$('run-rows').textContent,/AI 历史强度 1（参数快照）/);
 assert.match(ui.$('run-a').textContent,/AI 历史强度 1（参数快照）/);
 assert.doesNotMatch(ui.$('run-rows').textContent,/整体强度/);
 await ui.run();assert.match(ui.$('run-rows').textContent,/AI 整体强度 0.5/);
 await ui.$('duel-run').click();assert.match(ui.$('duel-rows').textContent,/整体强度 0.5.*整体强度 0/s);
});
