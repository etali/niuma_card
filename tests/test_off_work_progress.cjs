// SPDX-License-Identifier: AGPL-3.0-only
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, '../tools/balance/off_work_workbench.js'), 'utf8');
// Exercise the production row renderer and poll handler without parsing a page.
class Node {
  constructor(tag) { this.tagName = tag; this.children = []; this.attributes = {}; }
  append(...children) { this.children.push(...children); }
  replaceChildren(...children) { this.children = children; }
  setAttribute(key, value) { this.attributes[key] = String(value); }
  get textContent() { return this.children.map(child => child.textContent ?? child).join(''); }
  set textContent(text) { this.children = [String(text)]; }
}
function harness() {
  const context = vm.createContext({document:{createElement:tag => new Node(tag)},
    statusLabels:{running:'运行中',done:'完成',cancelled:'已停止',error:'失败',interrupted:'已中断'},
    dateTime:String, number:String, metricReading:() => '未记录', acquisitionCell:() => new Node('span'),
    historyGeneration:0, histories:{balance:[],bot:[]}, historyItems:[], comparableRecords:[],
    storageWarnings:() => {}, refreshLibrary:async () => {}, refreshComparison:async () => {},
    CustomEvent:class { constructor(type, options) { this.type = type; this.detail = options.detail; } }
  });
  for (const name of ['element','stacked','secondsText','historyProgress','historyValues','same','acceptHistory','refreshHistory']) {
    const fn = source.match(new RegExp('^(?:async )?function '+name+'\\([^]*?^}', 'm'));
    assert.ok(fn, `production function ${name} exists`);
    vm.runInContext(fn[0], context);
  }
  return context;
}
const progress = cell => cell.children.find(child => child.tagName === 'progress');
const record = patch => ({id:'run-1',kind:'bot',status:'running',completed:0,total:60,
  created_at:'2026-11-07T00:00:00Z',summary:{games:0,a_wins:0,b_wins:0},...patch});

test('balance and BOT records render real completed-game progress in every job state', () => {
  const ui = harness();
  for (const kind of ['balance','bot']) {
    for (const [status,completed,label] of [['running',0,'运行中'],['running',21,'运行中'],
      ['done',60,'完成'],['cancelled',21,'已停止'],['interrupted',4,'已中断'],['error',0,'失败']]) {
      const item = record({kind,status,completed,summary:{games:completed}});
      const cell = ui.historyValues(item,kind)[2];
      assert.equal(progress(cell).value,completed);
      assert.equal(progress(cell).max,60);
      assert.equal(progress(cell).attributes['aria-label'],'实验进度');
      assert.match(cell.textContent,new RegExp(label));
      assert.match(cell.textContent,new RegExp(`${completed} / 60 局`));
    }
  }
});

test('current-match time never claims an unfinished game is complete', () => {
  const ui = harness();
  const cell = ui.historyValues(record({summary:{games:0,current_match:{seconds:45}}}),'bot')[2];
  assert.equal(progress(cell).value,0);
  assert.match(cell.textContent,/0 \/ 60 局 · 本局 45 秒/);
});

test('a BOT history row identifies both policies and their result from the same duel', () => {
  const ui = harness();
  const cells = ui.historyValues(record({card_name:'共用卡表',a_name:'深搜策略',b_name:'快速策略',
    completed:8,total:8,status:'done',summary:{games:8,a_wins:3,b_wins:1,draws:2,timeouts:2}}),'bot');
  assert.equal(cells.length,6,'one duel remains one history row');
  assert.match(cells[1].textContent,/共用卡表/);
  assert.match(cells[1].textContent,/A.*深搜策略/);
  assert.match(cells[1].textContent,/B.*快速策略/);
  assert.match(cells[4].textContent,/A 75%/);
  assert.match(cells[4].textContent,/B 25%/);
  assert.equal(cells[5],2);
  assert.equal(progress(cells[2]).value,8);
});

test('BOT history keeps every returned duel in newest-first order across cards and job states', () => {
  const ui = harness();
  const items = [
    record({id:'new-running',configs:{cards:'current'},status:'running'}),
    record({id:'other-card',configs:{cards:'other'},status:'done'}),
    record({id:'stopped',configs:{cards:'current'},status:'cancelled'}),
    record({id:'balance-only',kind:'balance',status:'done'}),
    record({id:'legacy',kind:'legacy',status:'done'}),
  ];
  ui.acceptHistory({items});
  assert.deepEqual(Array.from(ui.histories.bot,row => row.id),['new-running','other-card','stopped','legacy']);
  assert.deepEqual(Array.from(ui.histories.balance,row => row.id),['balance-only','legacy']);
});

test('legacy history uses known finished games and leaves missing progress unclaimed', () => {
  const ui = harness();
  const done = ui.historyValues(record({kind:'legacy',status:'done',completed:0,total:0,summary:{games:12}}),'balance')[2];
  assert.equal(progress(done).value,12);
  assert.equal(progress(done).max,12);
  for (const status of ['error','cancelled','interrupted']) {
    const cell = ui.historyValues({status,kind:'legacy'},'bot')[2];
    assert.equal(progress(cell),undefined);
    assert.match(cell.textContent,/进度未记录/);
    assert.doesNotMatch(cell.textContent,/undefined|NaN|100%/);
  }
  const unknown = ui.historyValues({status:'running'},'bot')[2];
  assert.equal(progress(unknown).value,undefined,'unknown running progress stays indeterminate');
  assert.match(unknown.textContent,/进度未记录/);
});

test('polling advances each record in place and preserves expanded details', async () => {
  for (const kind of ['balance','bot']) {
    const ui = harness();
    const initial = record({kind});
    ui.activeView = kind;
    ui.histories[kind] = [initial];
    const updates = [];
    const detail = {classList:{contains:name => name === 'history-detail'},dispatchEvent:event => updates.push(event)};
    const row = {cells:ui.historyValues(initial,kind).map(value => {
      const cell = new Node('td'); cell.append(value); return cell;
    }),querySelector:() => null,nextElementSibling:detail};
    const originalCell = row.cells[2];
    ui.$ = id => { assert.equal(id,'historyTable'); return {querySelector:() => row}; };
    ui.renderHistory = () => assert.fail('progress polling must not replace the history table');
    const next = record({kind,completed:21,summary:{games:21,a_wins:12,b_wins:9,current_match:{seconds:7}}});
    ui.api = async route => { assert.equal(route,'/api/history'); return {items:[next]}; };
    await ui.refreshHistory();
    assert.equal(row.cells[2],originalCell);
    assert.equal(progress(originalCell.children[0]).value,21);
    assert.equal(progress(originalCell.children[0]).max,60);
    assert.equal(row.nextElementSibling,detail);
    assert.equal(updates.length,1);
    assert.equal(updates[0].type,'jobprogress');
    assert.equal(updates[0].detail.completed,21);
  }
});
