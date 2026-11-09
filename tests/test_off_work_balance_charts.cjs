// SPDX-License-Identifier: AGPL-3.0-only
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, '../tools/balance/off_work_workbench.js'), 'utf8');
// This DOM models content and SVG attributes; visual layout is reviewed in-browser.
class Element {
  constructor(tag) { this.tagName = tag.toUpperCase(); this.children = []; this.dataset = {}; this.style = {}; this.attributes = {}; }
  append(...nodes) { this.children.push(...nodes); }
  replaceChildren(...nodes) { this.children = []; this.append(...nodes); }
  get textContent() { return this.children.map(n => n.textContent ?? String(n)).join(''); }
  set textContent(value) { this.replaceChildren(String(value)); }
  setAttribute(key, value) {
    this.attributes[key] = String(value);
    if (key === 'style') this.style = Object.fromEntries(String(value).split(';').filter(Boolean).map(rule => {
      const [property, ...parts] = rule.split(':'); return [property.trim(), parts.join(':').trim()];
    }));
    if (key.startsWith('data-')) this.dataset[key.slice(5).replace(/-([a-z])/g, (_, c) => c.toUpperCase())] = String(value);
  }
  getAttribute(key) { return this.attributes[key] ?? (key.startsWith('data-') ? this.dataset[key.slice(5).replace(/-([a-z])/g, (_, c) => c.toUpperCase())] : null); }
  get classList() { return {add:(...names) => {this.className = [this.className || '', ...names].join(' ');}}; }
  createTHead() { const node = new Element('thead'); this.append(node); return node; }
  createTBody() { const node = new Element('tbody'); this.append(node); return node; }
  insertRow() { const node = new Element('tr'); this.append(node); return node; }
}
function descendants(node, predicate) {
  return node.children.filter(x => x instanceof Element).flatMap(child => [
    ...(predicate(child) ? [child] : []), ...descendants(child, predicate),
  ]);
}
const figures = node => descendants(node, x => x.tagName === 'FIGURE');
const bars = node => descendants(node, x => x.tagName === 'RECT');
const widths = node => bars(node).map(x => Number.parseFloat(x.getAttribute('width')));
const metric = (value, denominator = 2, numerator = value * denominator) => ({value, denominator, numerator});
const summary = metrics => ({balance_metrics:{version:2, ...metrics}});
const batches = (left, right) => [{name:'A · 基线',result:left},{name:'B · 候选',result:right}];

function harness() {
  const context = vm.createContext({Number, console, Node:Element, document:{createElement:tag => new Element(tag),createElementNS:(_,tag) => new Element(tag)}});
  for (const name of ['balanceMeasures','legacyMeasures']) {
    const code = source.match(new RegExp('^const '+name+' = \\{[^]*?^\\};', 'm'));
    assert.ok(code, name); vm.runInContext(code[0], context);
  }
  for (const name of ['rateFormula','acquisitionFormula']) {
    const code = source.match(new RegExp('^const '+name+' = .*;$', 'm'));
    assert.ok(code, name); vm.runInContext(code[0], context);
  }
  const names = ['element','number','rateNumber','metricReading','stacked','table',
    'balanceTable','acquisitionTable', ...Array.from(source.matchAll(/^function (offWork\w+)\(/gm), match => match[1])];
  for (const name of new Set(names)) {
    const code = source.match(new RegExp('^function '+name+'\\([^]*?^}', 'm'));
    assert.ok(code, name); vm.runInContext(code[0], context);
  }
  return context;
}

test('metric observations distinguish recorded zero from absent, invalid and zero-sample values', () => {
  const ui = harness();
  for (const broken of [undefined, metric(null), metric(3,0), metric(3,-1), metric(3,Infinity), metric(3,2,NaN), metric(-1), metric(Infinity)]) {
    assert.equal(ui.offWorkMetricValue(summary({upgrades_per_minute:broken}),'upgrades_per_minute'),null);
  }
  assert.equal(ui.offWorkMetricValue(summary({upgrades_per_minute:metric(0)}),'upgrades_per_minute'),0);
  assert.equal(ui.offWorkMetricValue(summary({upgrades_per_minute:metric(0.125)}),'upgrades_per_minute'),0.125);
});

test('relative changes retain absolute units and distinguish percentage points from percent growth', () => {
  const ui = harness();
  const percent = ui.offWorkChangeText(40,60,'%');
  assert.match(percent,/\+20.*个百分点/);
  assert.match(percent,/\+50.*%/);
  const seconds = ui.offWorkChangeText(400,800,'秒');
  assert.match(seconds,/\+400.*秒/);
  assert.match(seconds,/\+100.*%/);
  const rate = ui.offWorkChangeText(0.02,0.01,'次\/游戏分钟');
  assert.match(rate,/-0\.01.*次\/游戏分钟/);
  assert.match(rate,/-50.*%/);
});

test('zero or absent baselines never produce infinite or invented relative changes', () => {
  const ui = harness();
  for (const text of [ui.offWorkChangeText(0,4,'秒'),ui.offWorkChangeText(0,0,'%'),
    ui.offWorkChangeText(null,4,'秒'),ui.offWorkChangeText(4,null,'秒')]) {
    assert.doesNotMatch(text,/Infinity|NaN|∞/);
  }
  const rising = ui.offWorkChangeText(0,4,'秒');
  assert.match(rising,/\+4.*秒/);
  assert.match(rising,/0/);
  assert.doesNotMatch(rising,/\+100\s*%/,'从零出现不能错误标成增长100%');
  assert.doesNotMatch(ui.offWorkChangeText(4,8,'秒',false),/\+4|\+100|相对.*100/);
});

test('percentage bars use a common 0–100 scale and quantity bars keep independent scales above 100', () => {
  const ui = harness();
  const percent = ui.offWorkBarFigure('rate','先手胜率',[25,50],'%',true);
  assert.deepEqual(widths(percent),[25,50]);
  const seconds = ui.offWorkBarFigure('seconds','平均结束时长',[400,800],'秒',true);
  assert.deepEqual(widths(seconds),[50,100]);
  const frequency = ui.offWorkBarFigure('frequency','平均提升卷度频率',[2,4],'次/游戏分钟',true);
  assert.deepEqual(widths(frequency),[50,100]);
  assert.match(seconds.textContent,/800/);
  assert.match(frequency.textContent,/4/);
});

test('unknown observations have no bar, while recorded zero remains labeled without a fabricated positive width', () => {
  const ui = harness();
  const partial = ui.offWorkBarFigure('partial','频率',[null,0],'次/游戏分钟',true);
  assert.deepEqual(widths(partial),[0]);
  assert.match(partial.textContent,/未观测|未记录/);
  assert.match(partial.textContent,/0/);
  const none = ui.offWorkBarFigure('none','时长',[null,null],'秒',false);
  assert.equal(bars(none).length,0);
  const zeros = ui.offWorkBarFigure('zero','频率',[0,0],'次/游戏分钟',true);
  assert.deepEqual(widths(zeros),[0,0]);
  assert.doesNotMatch(zeros.textContent,/NaN|Infinity/);
});

test('balance comparison renders all measures and unknown versions keep observations without differences', () => {
  const ui = harness();
  const left = summary({first_player_win_rate:metric(50),mean_finish_seconds:metric(200)});
  const right = summary({first_player_win_rate:metric(75),mean_finish_seconds:metric(400)});
  const original = JSON.stringify([left,right]);
  const root = new Element('section');
  ui.balanceTable(root,batches(left,right),true);
  assert.equal(figures(root).length,7);
  const rate = figures(root).find(x => x.dataset.offWorkChart === 'first_player_win_rate');
  assert.ok(rate);
  assert.deepEqual(widths(rate),[50,75]);
  assert.match(rate.textContent,/\+25.*个百分点/);
  const unknownRoot = new Element('section');
  ui.balanceTable(unknownRoot,batches(left,right),false);
  const unknown = figures(unknownRoot).find(x => x.dataset.offWorkChart === 'first_player_win_rate');
  assert.deepEqual(widths(unknown),[50,75]);
  assert.doesNotMatch(unknown.textContent,/\+25|\+50/);
  assert.equal(JSON.stringify([left,right]),original,'rendering must not rewrite archived measurements');
});

test('card share charts preserve missing-side data instead of pretending the card had zero acquisitions', () => {
  const ui = harness();
  const acquired = distribution => summary({card_acquisitions:{observed_games:2,missing_games:0,total:10,distribution}});
  const left = acquired([{id:'employee',label:'员工',count:10,percentage:100}]);
  const right = acquired([{id:'coffee',label:'咖啡',count:10,percentage:100}]);
  const before = JSON.stringify([left,right]);
  const root = new Element('section');
  ui.acquisitionTable(root,batches(left,right),true);
  assert.equal(figures(root).length,2);
  for (const figure of figures(root)) {
    assert.deepEqual(widths(figure),[100]);
    assert.match(figure.textContent,/未观测|未记录/);
    assert.doesNotMatch(figure.textContent,/[+-]100.*百分点/);
  }
  assert.equal(JSON.stringify([left,right]),before);
});


test('small frequencies preserve nonzero values and invalid percentages are not silently clipped', () => {
  const ui = harness();
  const tiny = ui.offWorkBarFigure('tiny','低频事件',[0.00001,0.00002],'次/游戏分钟',true);
  assert.deepEqual(widths(tiny),[50,100]);
  assert.match(tiny.textContent,/0\.00001/);
  assert.match(tiny.textContent,/0\.00002/);
  const invalid = ui.offWorkBarFigure('invalid','比例',[125,-10],'%',true);
  assert.equal(bars(invalid).length,0);
  assert.match(invalid.textContent,/未观测/);
  assert.doesNotMatch(invalid.textContent,/B − A：/);
});

test('the real comparison view disables changes for unknown metric versions and refreshes charts when sides swap', async () => {
  const ui = harness();
  const nodes = Object.fromEntries(['comparisonStatus','comparisonResult','comparisonPlayStatus'].map(id => [id,new Element('div')]));
  const document = {cards:{employee:{name:'员工'}}};
  const record = (id,value) => ({id,status:'done',card_name:id,
    request:{cards:document,seed:10,pairs:1,max_seconds:1800},
    result:{...summary({first_player_win_rate:metric(value)}),games:2,profiles:{a:{think_seconds:6},b:{think_seconds:6}},
      godot_version:'test',simulator_fingerprint:'same'}});
  const records = {left:record('left',25),right:record('right',50)};
  records.left.result.balance_metrics.version = 99;
  records.right.result.balance_metrics.version = 99;
  let choices = [{config:'left',run:'left'},{config:'right',run:'right'}];
  Object.assign(ui,{
    activeView:'balance',previousComparison:'',comparisonGeneration:0,loading:false,
    $:id => nodes[id],selection:() => choices,
    api:async url => records[url.split('/').at(-1)],availableCards:() => new Map([['left','基线'],['right','候选']]),
    recordedParameters:() => ({}),parameterDifferences:() => [],comparisonCardName:r => r.card_name,
  });
  for (const name of ['same','differentConditions','details','showComparison']) {
    const code = source.match(new RegExp('^(?:async )?function '+name+'\\([^]*?^}', 'm'));
    assert.ok(code,name);vm.runInContext(code[0],ui);
  }
  await ui.showComparison();
  assert.match(nodes.comparisonStatus.textContent,/指标版本未知/);
  let chart = figures(nodes.comparisonResult).find(x => x.dataset.offWorkChart === 'first_player_win_rate');
  assert.deepEqual(widths(chart),[25,50]);
  assert.doesNotMatch(chart.textContent,/B − A：/);
  records.left.result.balance_metrics.version = 2;
  records.right.result.balance_metrics.version = 2;
  choices = [choices[1],choices[0]];
  await ui.showComparison();
  assert.match(nodes.comparisonStatus.textContent,/实验条件一致/);
  chart = figures(nodes.comparisonResult).find(x => x.dataset.offWorkChart === 'first_player_win_rate');
  assert.deepEqual(widths(chart),[50,25]);
  assert.match(chart.textContent,/-25.*个百分点/);
  assert.match(chart.textContent,/-50.*%/);
});


test('bar geometry is encoded in SVG attributes without CSP-blocked inline styles', () => {
  const ui = harness();
  const root = new Element('section');
  ui.balanceTable(root,batches(
    summary({mean_finish_seconds:metric(400)}),
    summary({mean_finish_seconds:metric(800)})),true);
  const svg = descendants(root, x => x.tagName === 'SVG');
  assert.ok(svg.length > 0, '有观测值应绘制可缩放SVG条形');
  assert.equal(descendants(root, x => Object.hasOwn(x.attributes,'style')).length,0,
    '服务使用style-src self，图形不能依赖被CSP拒绝的内联style');
  const chart = figures(root).find(x => x.dataset.offWorkChart === 'mean_finish_seconds');
  assert.deepEqual(widths(chart),[50,100]);
});
