// SPDX-License-Identifier: AGPL-3.0-only
"use strict";

const $ = id => document.getElementById(id);
const clone = value => structuredClone(value);
let baseline, candidate, bot, presets, profiles;
let strengthProfiles = {};
let sourceCards, sourceId;
let defaultProfiles, legacyBudgetMs;
let legacyPolicyDefaults = {};
let savedNotes = "", notesReady = false;
let comparableRecords = [];
let historyItems = [];
const chosenBots = {};
let projectCardsId;
let projectCardsName = "项目默认";
let loading = false;
let activeView = "balance";
let library = {cards:[], bot:[]};
let histories = {bot:[], balance:[]};
const presetChoice = {};
const strengthChoice = {};
const strategyNames = {q:"标准策略", a:"策略 A", b:"策略 B"};
const fieldLabels = {
  price:"价格", purchasable:"可购买", description:"牌面说明", name:"牌名",
  work_seconds:"每份工作基础耗时（秒）", work_capacity:"每批处理上限", work_income_multiplier:"工作收入倍率",
  can_work:"可处理工作", refund:"开除返还", transfer_capacity:"甩锅数量",
  can_be_meeting_target:"可被拉会", can_be_strike_target:"可受罢工影响", meeting_multiplier:"开会人数倍率",
  max_per_owner:"每方持有上限", cost_per_employee:"每名员工招聘费用", recruitment:"老板招聘",
  flight_seconds:"罢工飞行时间（秒）", work_role:"工会生产标准",
  income:"每份工作收入", money:"起始金钱", groups:"开局牌组", speed_multiplier:"速度倍率",
  seconds:"耗时（秒）", upgrades:"提升卷度配方", to:"卷度提升后", cost:"咖啡用量",
  minimum_targets:"最少目标数", base_targets:"基础目标数", duration_seconds:"持续时间（秒）",
  recovery_seconds:"冷却时间（秒）", auto_repeat:"自动重复", coffee_per_person:"每人产咖啡数",
  cost_per_work:"每份工作成本", minimum_people:"最低保留人数", slots:"传送带槽位",
  interval_seconds:"刷新间隔（秒）",
  pool:"掉落权重", purchase_priority:"采购优先级", tool_priority:"工具优先级",
  first_action_seconds:"首次行动时间（秒）", max_tool_copies:"同类工具上限",
  max_support_people:"辅助人员上限", production_reserve_people:"生产预留人员",
  transfer_batch_size:"每批交接工作数", max_card_copies:"各卡持有上限",
  decision_budget_ms:"固定思考时限（毫秒）", decision_budget_ratio:"思考时间占行动间隔的比例",
  initial:"开局资源", conveyor:"传送带", fire:"开除"
};
const presetLabels = {min:"最低",low:"偏低",mid:"标准",high:"偏高",max:"最高"};
const statusLabels = {running:"运行中",done:"完成",error:"失败",cancelled:"已停止",interrupted:"已中断"};
const sourceLabels = {manual:"手动保存",experiment:"实验自动保存",legacy:"历史导入"};

function element(tag, text, className) {
  const node = document.createElement(tag);
  if (text !== undefined) node.textContent = text;
  if (className) node.className = className;
  return node;
}
function displayName(key) {
  return fieldLabels[key] || candidate?.cards[key]?.name || key;
}
function errorText(message = "") {
  $("error").textContent = message;
  $("error").hidden = !message;
  if (message) $("error").scrollIntoView({block:"nearest"});
}
async function api(path, method = "GET", body) {
  const response = await fetch(path.replace(/^\//, ""), {
    method,
    headers:body ? {"Content-Type":"application/json"} : {},
    body:body ? JSON.stringify(body) : undefined
  });
  const result = await response.json();
  if (!response.ok) {
    const error = Error(result.error || "请求失败（" + response.status + "）");
    error.status = response.status;
    error.details = result;
    throw error;
  }
  return result;
}
async function saveWithConfirmation(path, body) {
  let request = clone(body);
  for (;;) {
    try {return await api(path,"POST",request);}
    catch (error) {
      if (error.status !== 409 || error.details.code !== "name_conflict") throw error;
      const conflicts = error.details.conflicts;
      const names = conflicts.map(conflict =>
        (conflict.kind === "cards" ? "卡牌配置" : "BOT 策略") + "「" + conflict.name + "」");
      const message = "以下同名配置的参数已发生变化。\n\n" + [...new Set(names)].join("\n") +
        "\n\n确认覆盖这些配置？";
      if (!window.confirm(message)) return null;
      if (path === "/api/run") {
        const overwrites = {...request.overwrites};
        for (const conflict of conflicts) overwrites[conflict.slot] = conflict.current_id;
        request = {...request,overwrites};
      } else request = {...request,overwrite_id:conflicts[0].current_id};
    }
  }
}
function same(a, b) {
  if (a === b) return true;
  if (!a || !b || typeof a !== "object" || typeof b !== "object" || Array.isArray(a) !== Array.isArray(b)) return false;
  return Object.keys(a).length === Object.keys(b).length &&
    Object.keys(a).every(key => Object.hasOwn(b,key) && same(a[key],b[key]));
}
function valid(container) {
  const invalid = container.querySelector(":invalid");
  if (!invalid) return true;
  for (let parent = invalid.parentElement; parent; parent = parent.parentElement) {
    if (parent.tagName === "TR" && parent.hidden) {
      $("card-search").value = "";
      $("card-kind").value = "";
      filterCards();
    }
    if (parent.tagName === "DETAILS") parent.open = true;
  }
  invalid.reportValidity();
  return false;
}
function controls() {
  const dirty = candidate && !same(sourceCards,candidate);
  const marketIssue = marketPoolIssue();
  $("dirty").textContent = dirty ? "当前卡表含未保存的修改。" : "参数与载入的卡表一致。";
  document.querySelectorAll("[data-edit]").forEach(node => {node.disabled = !baseline || loading;});
  $("run").textContent = activeView === "bot" ? "保存卡表及 A、B 策略并对战" : "保存并运行当前配置";
  $("runSaveScope").textContent = activeView === "bot"
    ? "将保存共用卡表「" + currentCardsName() + "」、BOT A「" + strategyNames.a + "」和 BOT B「" + strategyNames.b + "」，再启动一条对战记录。相同参数复用已有配置；同名修改会先确认覆盖。"
    : "将保存当前卡表和双方共用的 BOT 策略，再启动一条评估记录。相同参数复用已有配置；同名修改会先确认覆盖。";
  $("duelCards").textContent = "双方共用当前卡表「" + currentCardsName() + "」" + (dirty ? "，含未保存的修改；运行时会自动保存。" : "，本次对战只比较 BOT A 与 BOT B。");
  if (marketIssue) $("duelCards").textContent += " 购牌区权重无效：" + marketIssue + " 请点击“编辑这份卡表”修正。";
  renderBotCards();
  $("playtest").textContent = "试玩当前配置 · " + currentCardsName();
  $("notesStatus").textContent = dirty ? "保存当前卡表后可记录其试玩感受。" :
    (sourceId && notesReady ? "备注随载入的卡表保存。" : "载入已保存卡表后可编辑备注。");
  $("saveNotes").disabled = loading || !sourceId || dirty || $("notes").value === savedNotes || !notesReady;
  for (const id of ["saveCards","export","run","playtest"]) {
    $(id).disabled = !baseline || loading || !!marketIssue;
  }
}
function caption(label, key) {
  const node = element("span",undefined,"field-name");
  node.append(element("span",label),element("code",key));
  return node;
}
function field(parent, object, key, options = {}) {
  const original = object[key];
  const label = element("label");
  label.append(caption(options.label || displayName(key), options.path || key));
  const compound = typeof original === "object" && original !== null;
  const input = element(options.choices ? "select" : compound || key === "description" ? "textarea" : "input");
  input.dataset.edit = "";
  input.dataset.path = options.path || key;
  if (options.choices) {
    input.append(...options.choices.map(([value,text]) => new Option(text,value)));
    input.value = original;
    input.required = true;
  } else if (compound) {
    input.rows = key === "groups" ? 3 : 2;
    input.value = JSON.stringify(original);
  } else if (typeof original === "boolean") {
    input.type = "checkbox";
    input.checked = original;
  } else {
    if (typeof original === "number") {
      input.type = "number";
      input.step = options.step ?? (options.kind === "int" ? "1" : "any");
      if (options.min !== undefined) input.min = options.min;
      if (options.max !== undefined) input.max = options.max;
      input.required = true;
    }
    input.value = original;
    if (typeof original === "number") {
      const rounded = Number(original.toPrecision(12));
      if (Math.abs(original-rounded) <= Math.abs(original)*Number.EPSILON) input.value = rounded;
    }
  }
  if (input.tagName === "TEXTAREA") label.className = "wide";
  if (options.positive && !(Number(original) > 0)) input.setCustomValidity("请输入大于 0 的数值");
  label.append(input);
  if (options.hint) label.append(element("small",options.hint,"field-hint"));
  parent.append(label);
  input.addEventListener("input", () => {
    input.setCustomValidity("");
    let value;
    if (compound) {
      try {
        value = JSON.parse(input.value);
        if (!value || typeof value !== "object" || Array.isArray(value) !== Array.isArray(original)) throw Error();
      } catch {
        input.setCustomValidity(Array.isArray(original) ? "请输入有效的 JSON 数组" : "请输入有效的 JSON 对象");
        controls();
        return;
      }
    } else if (input.type === "number") value = input.valueAsNumber;
    else if (input.type === "checkbox") value = input.checked;
    else value = input.value;
    if (options.positive && !(value > 0)) input.setCustomValidity("请输入大于 0 的数值");
    if (options.choices && !options.choices.some(([key]) => key === value)) input.setCustomValidity("请选择有效选项");
    if (input.validity.valid) {
      object[key] = value;
      options.change?.();
    }
    controls();
  });
  return input;
}
function fields(parent, values, path, excluded = []) {
  for (const key of Object.keys(values)) {
    if (key.startsWith("_") || excluded.includes(key)) continue;
    const options = {path:path + "." + key};
    if (key === "work_seconds" && path === "cards.work") {
      Object.assign(options,{label:"每份工作基础耗时（秒）",min:0,positive:true,
        hint:"员工及各升级等级共用；加班会影响实际工作速度。"});
    } else if (path === "rules.recruitment" && key === "cost_per_employee") {
      Object.assign(options,{label:"每名员工招聘费用",kind:"int",min:1,hint:"须高于购牌区员工价格。"});
    } else if (path === "rules.recruitment" && key === "seconds") {
      Object.assign(options,{label:"招聘耗时（秒）",min:0,positive:true});
    } else if (key === "destination_policy" && path === "rules.income") {
      Object.assign(options,{label:"收入放置位置",choices:[
        ["oldest_cash_pile","最早创建的现金堆"],["newest_cash_pile","最新创建的现金堆"]]});
    } else if (key === "destination_policy" && path === "rules.transfer") {
      Object.assign(options,{label:"甩锅落点",choices:[
        ["largest_work_queue","工作最多的对方牌组"],["new_group","对方新建牌组"]]});
    }
    field(parent,values,key,options);
  }
}
function marketPoolIssue() {
  if (!candidate) return "";
  for (const input of $("market-fields").querySelectorAll("input")) {
    if (!input.validity.valid || !Number.isFinite(input.valueAsNumber) || input.valueAsNumber < 0) {
      return "出场权重须为大于或等于 0 的有限数值，支持小数。";
    }
  }
  const weights = Object.entries(candidate.cards).filter(([,card]) => card.purchasable)
    .map(([id]) => candidate.rules.conveyor.pool[id] ?? 0);
  if (weights.some(value => typeof value !== "number" || !Number.isFinite(value) || value < 0)) {
    return "出场权重须为大于或等于 0 的有限数值，支持小数。";
  }
  const total = weights.reduce((sum,value) => sum + value,0);
  if (!Number.isFinite(total)) return "出场总权重过大，请减小权重后重试。";
  return total > 0 ? "" : "至少一张可购买牌的出场权重必须大于 0。";
}
function updateMarketProbabilities() {
  const issue = marketPoolIssue();
  const entries = Object.entries(candidate.cards).filter(([,card]) => card.purchasable);
  const total = entries.reduce((sum,[id]) => sum + (candidate.rules.conveyor.pool[id] ?? 0),0);
  for (const output of $("market-fields").querySelectorAll("output")) {
    const weight = candidate.rules.conveyor.pool[output.dataset.card] ?? 0;
    const percent = weight / total * 100;
    output.textContent = issue ? "—" : weight > 0 && percent < .01 ? "< 0.01%" : percent.toLocaleString("zh-CN",{maximumFractionDigits:2}) + "%";
  }
  $("market-total").textContent = issue ? "暂时无法计算出现概率" :
    entries.length + " 种可购买牌 · 总权重 " + total.toLocaleString("zh-CN",{maximumSignificantDigits:12});
  $("market-error").textContent = issue;
  $("market-error").hidden = !issue;
  controls();
}
function renderMarketPool() {
  const container = $("market-fields");
  container.replaceChildren();
  const pool = candidate.rules.conveyor.pool;
  for (const [id,card] of Object.entries(candidate.cards)) {
    if (!card.purchasable) continue;
    const row = element("div",undefined,"market-pool-row");
    const weight = {[id]:pool[id] ?? 0};
    const input = field(row,weight,id,{label:card.name,path:"rules.conveyor.pool." + id,min:0,
      change:() => {pool[id] = weight[id];}});
    input.addEventListener("input",updateMarketProbabilities);
    const probability = element("output");
    probability.dataset.card = id;
    probability.setAttribute("aria-label",card.name + "出现概率");
    row.append(probability);
    container.append(row);
  }
  updateMarketProbabilities();
}
function validCards() {
  const issue = marketPoolIssue();
  if (issue) {errorText(issue); valid($("cardsView")); return false;}
  return valid($("cardsView"));
}
function renderInitialFields(parent) {
  const initial = candidate.rules.initial;
  fields(parent,initial,"rules.initial",["groups"]);
  const workFields = element("div",undefined,"global-grid wide");
  const advanced = element("details",undefined,"wide");
  advanced.append(element("summary","高级开局牌组"));
  parent.append(workFields,advanced);
  const refreshWork = () => {
    workFields.replaceChildren();
    if (!Array.isArray(initial.groups)) return;
    const groups = initial.groups.map((group,index) => ({group,index})).filter(({group}) =>
      group && !Array.isArray(group) && typeof group.work === "number");
    for (const {group,index} of groups) {
      field(workFields,group,"work",{
        label:"每方起始工作数量" + (groups.length > 1 ? " · 第 " + (index + 1) + " 组" : ""),
        path:"rules.initial.groups." + index + ".work",kind:"int",min:groups.length > 1 ? 0 : 1,
        hint:groups.length > 1 ? "双方在本组各自获得的工作数量；各组总数须大于 0。" : "双方开局各自获得的工作数量。",
        change:() => {groupInput.value = JSON.stringify(initial.groups); groupInput.setCustomValidity("");}
      });
    }
  };
  const groupInput = field(advanced,initial,"groups",{label:"开局牌组",path:"rules.initial.groups",
    hint:"按组设置开局卡牌；与上方工作数量同步，修改后保留各组布局。",change:refreshWork});
  refreshWork();
}
function renderCards() {
  const root = $("fields");
  root.replaceChildren();
  const grid = $("global-fields");
  grid.replaceChildren();
  renderInitialFields(grid);
  for (const key of ["conveyor","fire","income"]) {
    fields(grid,candidate.rules[key],"rules." + key,key === "conveyor" ? ["pool","employee_every","opening"] : []);
  }
  renderMarketPool();
  const rows = [];
  for (const [id,card] of Object.entries(candidate.cards)) {
    const identity = element("span",undefined,"card-identity-text");
    identity.append(element("strong",card.name),element("code",id));
    identity.append(element("small",card.purchasable ? "可购买" : "合成 / 初始牌"));
    const values = element("div",undefined,"card-fields");
    fields(values,card,"cards." + id,["name","description","art","category","purchasable"]);
    if (candidate.roles[id]) fields(values,candidate.roles[id],"roles." + id,["work_seconds"]);
    if (candidate.rules[id]) fields(values,candidate.rules[id],"rules." + id,["upgrades"]);
    if (id === "boss" && candidate.rules.recruitment) fields(values,candidate.rules.recruitment,"rules.recruitment");
    const upgrade = candidate.rules.coffee.upgrades[id];
    if (upgrade) {
      field(values,upgrade,"cost",{
        label:"提升卷度的咖啡用量 → " + candidate.cards[upgrade.to].name,
        path:"rules.coffee.upgrades." + id + ".cost",kind:"int",min:1
      });
      if (Object.hasOwn(upgrade,"seconds")) {
        field(values,upgrade,"seconds",{label:"提升卷度耗时（秒）",path:"rules.coffee.upgrades." + id + ".seconds"});
      }
    }
    const text = element("details",undefined,"card-copy");
    identity.append(element("small",card.description));
    text.append(element("summary","牌面文字"));
    const copyFields = element("div",undefined,"field-grid");
    field(copyFields,card,"name",{path:"cards." + id + ".name"});
    field(copyFields,card,"description",{path:"cards." + id + ".description"});
    text.append(copyFields);
    values.append(text);
    const thumb = element("img",undefined,"card-thumb");
    thumb.alt = "";
    thumb.src = "/assets/art/icon/" + (card.art === "money" ? "icon_cash" : "work_"+encodeURIComponent(card.art)) + ".png";
    const heading = element("div",undefined,"card-identity");
    heading.append(thumb,identity);
    rows.push([heading,values]);
  }
  const t = table(root,["卡牌 / 效果","可调参数"],rows);
  t.className = "off-card-table";
  t.parentElement.classList.add("edit-scroll");
  const categories = {work:"工作",person:"人员",money:"金钱",tool:"工具",ingredient:"原料"};
  const ids = Object.keys(candidate.cards);
  ids.forEach((id,i) => {t.tBodies[0].rows[i].dataset.card = id;});
  const selected = $("card-kind").value;
  const kinds = new Set(Object.values(candidate.cards).map(card => card.category));
  $("card-kind").replaceChildren(new Option("全部卡牌",""),...Array.from(kinds,k => new Option(categories[k] || k,k)));
  $("card-kind").value = kinds.has(selected) ? selected : "";
  filterCards();
  controls();
}
function filterCards() {
  const query = $("card-search").value.trim().toLowerCase();
  for (const row of $("fields").querySelectorAll("tr[data-card]")) {
    const id = row.dataset.card, card = candidate.cards[id];
    row.hidden = !((id+" "+card.name).toLowerCase().includes(query)) ||
      ($("card-kind").value && card.category !== $("card-kind").value);
  }
}
function renderProfiles() {
  $("profiles").replaceChildren();
  $("sharedProfile").replaceChildren();
  const knobs = new Map([...bot.preferences.knobs,...(bot.preferences.fields || [])].map(k => [k.key,k]));
  for (const side of ["q","a","b"]) {
    const section = element("div",undefined,side === "q" ? "" : "duel-side side-" + side);
    section.id = "profile-" + side;
    const title = side === "q" ? "双方共用 BOT" : "BOT " + side.toUpperCase();
    section.append(element("h3",title));
    const controlsRow = element("div",undefined,"controls");
    section.append(controlsRow);
    const source = element("select");
    source.dataset.edit = "";
    source.id = "source-" + side;
    const sourceLabel = element("label","载入策略","grow");
    sourceLabel.append(source);
    source.onchange = () => busy(async () => {
      const id = source.value;
      const record = id ? await api("/api/library/" + id) : null;
      setProfile(side,record?.data || defaultProfiles[side],record?.name || defaultStrategyNames[side],id);
      renderProfiles();
    });
    const name = element("input");
    name.value = strategyNames[side];
    name.maxLength = 120;
    name.dataset.edit = "";
    name.oninput = () => {strategyNames[side] = name.value; controls();};
    const version = element("label","策略名称");
    version.append(name);
    const save = element("button",side === "q" ? "仅保存共用策略" : "仅保存 BOT " + side.toUpperCase() + " 策略");
    save.dataset.edit = "";
    save.onclick = () => saveVersion("bot",strategyNames[side],profiles[side],side);
    controlsRow.append(sourceLabel,version,save);
    const strength = element("label","强度快捷档位");
    const select = element("select");
    const policy = profiles[side];
    const fixedTimeMode = policy.decision_budget_ms !== undefined;
    select.append(new Option(policy.decision_budget_ms !== undefined ? "固定毫秒（旧策略）" : "自定义","custom"));
    select.options[0].disabled = true;
    for (const [key, preset] of Object.entries(presets)) {
      select.add(new Option((presetLabels[key] || key) + " · " + Number(bot.preferences.presets[key]).toFixed(2),key));
    }
    select.value = presetChoice[side];
    select.dataset.edit = "";
    select.onchange = () => {
      delete policy.decision_budget_ms;
      Object.assign(policy,presets[select.value]);
      presetChoice[side] = select.value;
      strengthChoice[side] = Number(bot.preferences.presets[select.value]);
      renderProfiles();
    };
    strength.append(select);
    controlsRow.append(strength);
    const overall = element("label",undefined,"off-work-overall-strength");
    const heading = element("span",side === "q" ? "双方 BOT 整体强度 " : "BOT " + side.toUpperCase() + " 整体强度 ");
    const readout = element("output");
    readout.id = "off-work-strength-value-" + side;
    readout.setAttribute("for","off-work-strength-" + side);
    heading.append(readout);
    const slider = element("input");
    slider.type = "range";
    slider.id = "off-work-strength-" + side;
    slider.min = "0"; slider.max = "1"; slider.step = "0.01";
    slider.dataset.edit = "";
    slider.setAttribute("aria-label",side === "q" ? "双方 BOT 整体强度" : "BOT " + side.toUpperCase() + " 整体强度");
    slider.setAttribute("aria-describedby","off-work-strength-hint-" + side);
    const hint = element("small","范围 0–1；步长 0.01。联动行动间隔和思考预算；各档使用同一套动作与评价，不限制人员或材料数量。", "input-range");
    hint.id = "off-work-strength-hint-" + side;
    overall.append(heading,slider,hint);
    section.append(overall);
    const syncStrength = () => {
      const value = profileStrength(policy,strengthChoice[side] ?? bot.preferences.default_strength);
      strengthChoice[side] = value;
      slider.value = value ?? bot.preferences.default_strength;
      readout.textContent = value === null ? "自定义" : value.toFixed(2);
      select.value = presetChoice[side] = profilePreset(policy);
    };
    slider.value = bot.preferences.default_strength;
    syncStrength();
    slider.oninput = () => {
      const value = Number(slider.value);
      const parameters = strengthProfiles[value.toFixed(2)];
      if (!parameters) return;
      delete policy.decision_budget_ms;
      Object.assign(policy,clone(parameters));
      strengthChoice[side] = value;
      // Keep the range node alive while dragging; commit rebuilds legacy-mode
      // fields only after the user releases the thumb or presses an arrow key.
      for (const [key,value] of Object.entries(parameters)) {
        const node = section.querySelector('[data-path="' + key + '"]');
        if (!node) continue;
        if (node.type === "checkbox") node.checked = value;
        else node.value = typeof value === "object" ? JSON.stringify(value) : value;
        node.setCustomValidity("");
      }
      const oldBudget = section.querySelector('[data-path="decision_budget_ms"]');
      if (oldBudget) oldBudget.parentElement.hidden = true;
      syncStrength();
      budget.textContent = budgetText(policy);
      controls();
    };
    slider.onchange = () => {
      if (fixedTimeMode) {
        renderProfiles();
        $("off-work-strength-" + side)?.focus?.();
      }
    };
    const budget = element("p",budgetText(policy),"hint");
    budget.id = "decision-budget-" + side;
    budget.setAttribute("aria-live","polite");
    section.append(budget);
    section.append(element("p","搜索深度按单方行动计数：我方一步、对手一步是两层。达到深度上限或时间预算即停止；超时保留最近完成的一层结果。","hint"));
    const all = details(section,title + " 全部参数");
    all.open = side !== "q";
    const groups = new Map();
    for (const key of Object.keys(profiles[side])) {
      const options = {...knobs.get(key),path:key};
      // Interpolated overall-strength values need not be multiples of the
      // manual spinner's suggested step. Preserve the engine's exact values
      // and its min/max bounds instead of blocking save/run with stepMismatch.
      if (options.kind === "float" && Object.values(strengthProfiles).some(profile => Object.hasOwn(profile,key))) options.step = "any";
      const group = options.group || "其他策略";
      if (!groups.has(group)) {
        const block = element("div",undefined,"bot-parameter-group");
        const grid = element("div",undefined,"sim-grid bot-fields");
        block.append(element("h4",group),grid);
        all.append(block);
        groups.set(group,grid);
      }
      if (key === "decision_budget_ms") Object.assign(options,{kind:"int",min:1,max:32});
      options.change = () => {
        syncStrength();
        budget.textContent = budgetText(policy);
      };
      field(groups.get(group),profiles[side],key,options);
    }
    $(side === "q" ? "sharedProfile" : "profiles").append(section);
  }
  renderSources();
  controls();
}
const defaultStrategyNames = {q:"标准策略",a:"策略 A",b:"策略 B"};
function profilePreset(policy) {
  if (policy.decision_budget_ms !== undefined) return "custom";
  return Object.keys(presets).find(key => Object.entries(presets[key]).every(([field,value]) => same(policy[field],value))) || "custom";
}
function profileStrength(policy, preferred = bot.preferences.default_strength) {
  if (policy.decision_budget_ms !== undefined) return null;
  const matches = parameters => parameters && Object.entries(parameters).every(([key,value]) => same(policy[key],value));
  if (Number.isFinite(preferred) && matches(strengthProfiles[preferred.toFixed(2)])) return preferred;
  const key = Object.keys(strengthProfiles).find(key => matches(strengthProfiles[key]));
  return key === undefined ? null : Number(key);
}
function budgetText(policy, measured) {
  if (Number.isFinite(policy?.decision_budget_ratio) && Number.isFinite(policy?.think_seconds)) {
    const product = policy.think_seconds * 1000 * policy.decision_budget_ratio;
    const tolerance = Math.min(1e-8,2*Number.EPSILON*Math.abs(product));
    const ms = measured ?? Math.max(1,Math.floor(product+tolerance));
    return number(policy.think_seconds) + " 游戏秒 × " + number(100*policy.decision_budget_ratio) +
      "% = " + number(ms) + " 毫秒";
  }
  const fixed = measured ?? policy?.decision_budget_ms;
  return Number.isFinite(fixed) ? "固定 " + number(fixed) + " 毫秒" : "未记录";
}
function setProfile(side, data, name, source = "") {
  // Saved strategies may predate fields added to the current engine. Show the
  // same full policy the run will use, without changing an archived time mode.
  profiles[side] = {...clone(bot.bot),...clone(legacyPolicyDefaults),...clone(data)};
  for (const key of Object.keys(profiles[side])) {
    if (!Object.hasOwn(bot.bot,key) && key !== "decision_budget_ms") delete profiles[side][key];
  }
  if (!Object.hasOwn(data,"decision_budget_ratio")) {
    delete profiles[side].decision_budget_ratio;
    profiles[side].decision_budget_ms = data.decision_budget_ms ?? legacyBudgetMs;
  } else {
    delete profiles[side].decision_budget_ms;
  }
  delete profiles[side].owner;
  strategyNames[side] = name;
  chosenBots[side] = source;
  strengthChoice[side] = profileStrength(profiles[side]);
  presetChoice[side] = profilePreset(profiles[side]);
}
function table(parent, headers, rows) {
  const wrap = element("div",undefined,"table-scroll");
  const t = element("table");
  const head = t.createTHead().insertRow();
  for (const name of headers) {
    const th = element("th");
    th.append(name);
    head.append(th);
  }
  const body = t.createTBody();
  for (const row of rows) {
    const tr = body.insertRow();
    for (const value of row) {
      const cell = element("td");
      cell.append(value instanceof Node ? value : String(value));
      tr.append(cell);
    }
  }
  wrap.append(t);
  parent.append(wrap);
  return t;
}
function details(parent,title) {
  const block = element("details");
  block.append(element("summary",title));
  parent.append(block);
  return block;
}
function number(n) {
  return Number.isFinite(n) ? Number(n.toFixed(2)).toLocaleString("zh-CN",{maximumFractionDigits:2}) : "未记录";
}
const balanceMeasures = {
  first_player_win_rate: {label:"先手胜率",sample:"局",formula:"先手胜局 ÷ 有先手的已结束局数，含平局。最先获得行动机会的座位为先手，选择等待也算，同时到点按调度顺序。"},
  mean_finish_seconds: {label:"平均结束时长",sample:"局",unit:"秒",formula:"结束局游戏秒数之和 ÷ 已结束局数，含平局。"},
  timeout_rate: {label:"超时率",sample:"局",formula:"超时局数 ÷ 已模拟局数。"},
  purchase_coverage: {label:"购牌覆盖率",sample:"种",formula:"至少买过一次的可购卡种数 ÷ 全部可购卡种数。"},
  upgrades_per_minute: {label:"平均提升卷度频率",unit:"次/游戏分钟",formula:"双方人员每完成一次喝咖啡提升卷度计一次。"},
  tool_generations_per_minute: {label:"平均道具生成频率",unit:"次/游戏分钟",formula:"摸鱼每完成一批咖啡计一次，一批可产多张。"},
  interferences_per_minute: {label:"平均干扰频率",unit:"次/游戏分钟",formula:"每次有效甩锅、开会或罢工计一次，合计双方的干扰。"}
};
const legacyMeasures = {
  seat0_win_rate: {label:"旧指标 · 0 号位胜率",sample:"局",formula:"0 号位胜局 ÷ 已分胜负局数。"},
  bilateral_interference_rate: {label:"旧指标 · 双向干扰局占比",sample:"局",formula:"双方均有有效干扰的局数 ÷ 已模拟局数。"}
};
const rateFormula = "频率先按每局的次数 ÷ 该局游戏分钟数计算，再按局等权平均。包含平局、超时局和零次事件的局，只计正时长。";
const acquisitionFormula = "按双方在局中获得的张数统计购买、招聘或提升卷度后获得的人员牌和生成的咖啡，占比分母为获得总张数。排除开局发牌、工作和金钱。";
function rateNumber(value) {
  return value.toLocaleString("zh-CN",{maximumFractionDigits:4});
}
function metricReading(summary,key,samples = false) {
  const metric = summary?.balance_metrics?.[key];
  if (!metric || !Number.isFinite(metric.numerator) || !Number.isFinite(metric.denominator)) return "未记录";
  if (metric.denominator > 0 && !Number.isFinite(metric.value)) return "未记录";
  const spec = balanceMeasures[key] || legacyMeasures[key];
  const rate = spec.unit === "次/游戏分钟";
  const format = rate ? rateNumber : number;
  const answer = metric.denominator === 0 ? "未观测" : format(metric.value) + (spec.unit ? " " + spec.unit : "%");
  if (!samples) return answer;
  if (rate) return answer + "（" + number(metric.denominator) + " 局）";
  const amount = number(metric.numerator) + (spec.unit ? " " + spec.unit : "");
  return answer + "（" + amount + " / " + number(metric.denominator) + " " + spec.sample + "）";
}
function stacked(primary,secondary,tip) {
  const box = element("span",undefined,"stacked-cell");
  box.append(element("span",primary),element("small",secondary));
  if (tip) box.title = tip;
  return box;
}
function differentConditions([left,right]) {
  const differences = [];
  if ([left,right].some(batch => batch.status !== "done" || batch.result.games !== 2*batch.request.pairs)) {
    differences.push("完整局数");
  }
  for (const [key,label] of [["seed","起始种子"],["pairs","种子对数"],["max_seconds","单局时限"]]) {
    if (!Number.isFinite(left.request[key]) || left.request[key] !== right.request[key]) differences.push(label);
  }
  if (!Number.isInteger(left.result.balance_metrics?.version) ||
      left.result.balance_metrics.version !== right.result.balance_metrics?.version) differences.push("指标版本");
  for (const side of ["a","b"]) {
    const first = left.result.profiles?.[side], second = right.result.profiles?.[side];
    if (!first || !second || !same(first,second)) differences.push("策略 " + side.toUpperCase());
  }
  if (left.result.godot_version !== right.result.godot_version) differences.push("Godot 版本");
  if (!left.result.simulator_fingerprint || !right.result.simulator_fingerprint) differences.push("模拟器版本未知");
  else if (left.result.simulator_fingerprint !== right.result.simulator_fingerprint) differences.push("模拟器版本");
  return differences;
}
function parameterDifferences(left,right) {
  const changes = [];
  function visit(path, a, b) {
    if (same(a,b)) return;
    if (a && b && typeof a === "object" && typeof b === "object" && !Array.isArray(a) && !Array.isArray(b)) {
      for (const k of new Set([...Object.keys(a),...Object.keys(b)])) visit([...path,k],a[k],b[k]);
    } else changes.push([path.join("."),JSON.stringify(a) ?? "缺少",JSON.stringify(b) ?? "缺少"]);
  }
  visit([],left,right);
  return changes;
}
function balanceTable(root,batches,compare,deltaLabel = "B − A") {
  const measures = {...balanceMeasures};
  for (const [key,spec] of Object.entries(legacyMeasures)) {
    if (batches.some(b => b.result?.balance_metrics?.[key])) measures[key] = spec;
  }
  root.append(element("p",rateFormula,"hint"));
  const rows = Object.entries(measures).map(([key,spec]) => {
    const label = stacked(spec.label,spec.formula);
    const row = [label,...batches.map(({result}) => metricReading(result,key,true))];
    if (compare) {
      const values = batches.map(({result}) => {
        const metric = result.balance_metrics?.[key];
        return metric?.denominator > 0 && Number.isFinite(metric.numerator) ? metric.value : null;
      });
      const difference = values[1]-values[0];
      const format = spec.unit === "次/游戏分钟" ? rateNumber : number;
      row.push(values.every(Number.isFinite)
        ? (difference > 0 ? "+" : "") + format(difference) + " " + (spec.unit || "个百分点")
        : "—");
    }
    return row;
  });
  table(root,["平衡指标",...batches.map(batch => batch.heading || batch.name),...(compare ? [deltaLabel] : [])],rows);
}
function acquisitionTable(root,batches,compare = false) {
  const sets = batches.map(batch => batch.result?.balance_metrics?.card_acquisitions);
  const ids = new Set();
  const maps = sets.map((set,index) => {
    const prefix = batches.length > 1 ? (index === 0 ? "A · " : "B · ") : "";
    const observed = set?.observed_games > 0 && Array.isArray(set.distribution);
    const text = observed
      ? "已观测 " + number(set.observed_games) + " 局，未采集 " + number(set.missing_games) + " 局，共获得 " + number(set.total) + " 张。"
      : "未记录获得卡牌分布。";
    root.append(element("p",prefix + text,"hint"));
    const map = new Map();
    if (observed) for (const card of set.distribution) {
      ids.add(card.id);
      map.set(card.id,card);
    }
    return map;
  });
  if (!ids.size) return;
  const headers = ["卡牌"];
  for (let i=0; i<batches.length; i++) {
    const prefix = batches.length > 1 ? (i === 0 ? "A " : "B ") : "";
    headers.push(prefix + "获得张数",prefix + "占比");
  }
  if (compare) headers.push("B − A（百分点）");
  const sorted = Array.from(ids).sort((a,b) =>
    Math.max(...maps.map(m => m.get(b)?.count ?? 0)) - Math.max(...maps.map(m => m.get(a)?.count ?? 0)));
  const rows = sorted.map(id => {
    const cards = maps.map(m => m.get(id));
    const labels = [...new Set(cards.map(c => c?.label).filter(Boolean))];
    const row = [stacked(labels.join(" / ") || id,id)];
    for (const card of cards) row.push(number(card?.count),card
      ? (Number.isFinite(card.percentage) ? number(card.percentage) + "%" : "未观测")
      : "未记录");
    if (compare) {
      const delta = cards[1]?.percentage - cards[0]?.percentage;
      row.push(cards.every(card => Number.isFinite(card?.percentage)) ? (delta > 0 ? "+" : "") + number(delta) : "—");
    }
    return row;
  });
  table(root,headers,rows);
}
function botDuelReport(root,record,result) {
  const decided = result.a_wins + result.b_wins;
  root.append(element("h3","BOT A 与 BOT B · 本次对战"),
    element("p","共用卡表「" + (record.card_name || record.request.card_name || "历史卡表") + "」。A、B 是策略标识，每个种子交换座位各打一局。","hint"));
  table(root,["对战结果","BOT A","BOT B"],[
    ["策略名称",record.a_name || record.request.a_name || "BOT A",record.b_name || record.request.b_name || "BOT B"],
    ["胜局",number(result.a_wins),number(result.b_wins)],
    ["分胜负胜率",fraction(result.a_wins,decided),fraction(result.b_wins,decided)]
  ]);
  root.append(element("p","已完成 " + number(result.games) + " 局 · 平局 " + number(result.draws) +
    " 局 · 超时 " + number(result.timeouts) + " 局。胜率仅统计已分胜负局。","hint"));
  const policies = ["a","b"].map(side => {
    const policy = {...(result.profiles?.[side] || record.request[side])};
    delete policy.owner;
    return policy;
  });
  const differences = parameterDifferences(...policies);
  if (differences.length) {
    table(details(root,"A、B 策略参数差异（" + differences.length + " 项）"),["参数","BOT A","BOT B"],differences);
  } else root.append(element("p","A、B 使用相同的策略参数。","hint"));
}
function report(root,record,result) {
  const {request,id} = record;
  const name = record.label || "实验";
  root.replaceChildren(element("p",`种子 ${number(request.seed)} 起 · ${number(request.pairs)} 对 · 每局最多 ${number(request.max_seconds)} 游戏秒`,"hint"));
  if (record.kind === "bot") botDuelReport(root,record,result);
  balanceTable(root,[{result,name}],false);
  const acquired = details(root,"各卡获得张数与占比");
  acquired.append(element("p",acquisitionFormula,"hint"));
  acquisitionTable(acquired,[{result}]);
  const rows = [
    ["模拟局数",number(result.games)],["A 胜局",number(result.a_wins)],["B 胜局",number(result.b_wins)],["平局",number(result.draws)],
    ["超时率",fraction(result.timeouts,result.games)],["A 分胜负胜率",fraction(result.a_wins,result.a_wins+result.b_wins)],
    ["平均时长（含超时局）",secondsText(result.mean_seconds)],["累计游戏时长",secondsText(result.simulated_seconds)],
    ["实际计算耗时",secondsText(result.elapsed_seconds)],["快进倍率（倍）",number(result.elapsed_seconds > 0 ? result.simulated_seconds/result.elapsed_seconds : null)]
  ];
  for (const seat of [0,1]) {
    const decided = result.matches?.filter(m => m.a_seat === seat && ["a","b"].includes(m.winner));
    rows.push(["A 在 " + seat + " 号位的分胜负胜率",fraction(decided?.filter(m => m.winner === "a").length,decided?.length)]);
  }
  for (const side of ["a","b"]) {
    for (const [key,label] of [["work","剩余工作"],["money","剩余金钱"]]) {
      const values = result.matches?.map(m => m[side+"_"+key]);
      const mean = values?.length && values.every(Number.isFinite) ? values.reduce((a,b) => a+b,0)/values.length : null;
      rows.push([side.toUpperCase()+" 平均"+label,number(mean)]);
    }
  }
  table(details(root,"对局与计算明细"),["指标","观测值"],rows);
  decisionReport(root,request,result);
  const flowLabels = {
    work_done:"人员完成工作（份）",outsource_done:"外包完成工作（份）",work_transferred:"甩给对方的工作（份）",
    work_income:"工作收入（金钱）",upgrades:"提升卷度（次）",dismissed:"开除人员（人）",dismiss_income:"开除返款（金钱）"
  };
  table(details(root,"工作与收入（双方累计）"),["指标","数量"],
    Object.entries(flowLabels).map(([key,label]) => [label,number(result.flow?.[key])]));
  const cards = request.cards?.cards || {};
  const ids = new Set([...Object.keys(cards).filter(k => cards[k].purchasable),
    ...Object.keys(result.market_offers || {}),...Object.keys(result.purchases || {})]);
  const purchases = Array.from(ids,id => {
    const offers = result.market_offers && (result.market_offers[id] ?? 0);
    const buys = result.purchases && (result.purchases[id] ?? 0);
    return [cards[id]?.name || id,number(offers),number(buys),fraction(buys,offers)];
  });
  table(details(root,"各卡上架与买入（双方累计）"),["卡牌","上架（张）","买入（张）","购入率"],purchases);
  const outcome = {a:"A 胜",b:"B 胜",draw:"平局",timeout:"超时"};
  const box = details(root,name + " · 逐局记录（" + number(result.games) + " 局）");
  box.append(element("p","实验 " + id,"footnote"));
  const body = element("div");
  box.append(body);
  let page = 0;
  function showPage() {
    body.replaceChildren();
    if (!result.matches) {
      body.append(element("p","未记录逐局数据。","hint"));
      return;
    }
    const size = 50, total = Math.ceil(result.matches.length / size);
    const games = result.matches.slice(size*page,size*(page+1));
    table(body,["种子","A 座位","先手座位","结果","游戏秒","提升卷度（次）","生成道具（次）","干扰（次）","A 剩余工作","B 剩余工作","A 金钱","B 金钱"],
      games.map(m => [m.seed,m.a_seat,m.first_seat === -1 ? "无先手" : number(m.first_seat),outcome[m.winner],number(m.seconds),
        number(m.upgrades),number(m.tool_generations),number(m.interferences),m.a_work,m.b_work,m.a_money,m.b_money]));
    if (total <= 1) return;
    const pager = element("div",undefined,"file-actions");
    const prev = element("button","上一页"), next = element("button","下一页");
    prev.disabled = page === 0;
    next.disabled = page + 1 >= total;
    prev.onclick = () => {page--; showPage();};
    next.onclick = () => {page++; showPage();};
    pager.append(prev,element("span",`${page+1} / ${total}`),next);
    body.append(pager);
  }
  box.ontoggle = () => {if (box.open && !body.hasChildNodes()) showPage();};
}
function decisionReport(root,request,result) {
  const section = details(root,"BOT 决策与时限");
  if (!result.decision_stats) {
    section.append(element("p","这份记录未采集逐次决策诊断。","hint"));
    return;
  }
  section.append(element("p","截断统计因时限或取消而提前结束的搜索。超限统计耗时超过预算的决策，逾时弃用统计返回过晚而被丢弃的结果。","hint"));
  const rows = [];
  for (const side of ["a","b"]) {
    for (const [seat,stats] of result.decision_stats[side].entries()) {
      const milliseconds = us => stats.count ? number(us / 1000) : "—";
      rows.push([side.toUpperCase() + " · " + seat + " 号位", budgetText(result.profiles?.[side] || request[side],stats.budget_ms),
        number(stats.count),milliseconds(stats.sum_elapsed_us / stats.count),milliseconds(stats.max_elapsed_us),
        number(stats.searched),number(stats.max_search_depth),number(stats.sum_search_nodes),
        number(stats.cutoffs),number(stats.fallbacks),number(stats.over_budget),number(stats.discarded_late),number(stats.apply_failures)]);
    }
  }
  table(section,["策略 / 座位","单次思考时限","决策数","平均（毫秒）","最长（毫秒）","完成实搜的决策","最大实搜步数","累计实搜节点","截断","保底","超限","逾时弃用","执行失败"],rows);
  const samples = result.decision_samples || [];
  if (!samples.length) return;
  const names = {wait:"等待",activate:"使用工具",move:"调整牌组",buy:"购牌",dismiss:"开除"};
  section.append(element("p","决策样本保留开局选择、不同动作及首次时限异常。展开动作可查看当时比较过的候选。","hint"));
  table(section,["种子 / 游戏秒","策略 / 座位","耗时 / 时限（毫秒）","选择与理由"],samples.map(s => {
    const flags = [s.cutoff && "截断",s.fallback && "保底",s.over_budget && "超限",s.discarded_late && "逾时弃用",!s.applied && "执行失败"].filter(Boolean);
    const choice = element("details");
    choice.append(element("summary",(names[s.kind] || s.kind) + " · " + s.reason + (flags.length ? "（" + flags.join("、") + "）" : "")));
    choice.append(element("p","已评估 " + number(s.evaluated) + " 个候选" +
      (Number.isInteger(s.depth) ? "，完成估值 " + s.depth + " 层。" : "。")));
    if (Number.isInteger(s.search_depth)) {
      choice.append(element("p","实际局面搜索共结算 " + number(s.search_nodes) + " 个节点，完成 " + s.search_depth + " 步。"));
      if (s.principal_variation?.length) {
        const path = element("ol");
        for (const step of s.principal_variation) {
          const card = request.cards?.cards?.[step.card_type]?.name || step.card_type;
          const target = step.group !== undefined ? " · 组 " + step.group : "";
          path.append(element("li",number(step.seconds) + " 游戏秒 · " + step.seat + " 号位 · " +
            (names[step.kind] || step.kind) + (card ? " · " + card : "") + target));
        }
        choice.append(path);
      }
    }
    if (s.shop_reason) choice.append(element("p","购牌判断 · " + s.shop_reason));
    for (const c of s.candidates) {
      const title = request.cards?.cards?.[c.card_type]?.name || c.card_type || names[c.kind] || c.kind;
      choice.append(element("p",title + " · " + number(c.score) + " 分 · " + c.reason));
    }
    return [s.seed + " / " + number(s.seconds),s.side.toUpperCase() + " · " + s.seat + " 号位",
      number(s.elapsed_us/1000) + " / " + number(s.budget_ms),choice];
  }));
}
function fraction(numerator,denominator) {
  if (!Number.isFinite(numerator) || !Number.isFinite(denominator)) return "未记录";
  return denominator ? number(numerator*100/denominator)+"%（"+numerator+" / "+denominator+"）" : "未观测（0 / 0）";
}
function dateTime(value) {
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? value : date.toLocaleString("zh-CN",{hour12:false});
}
function action(label, callback) {
  const button = element("button",label);
  button.dataset.edit = "";
  button.onclick = async () => {
    await busy(callback);
  };
  return button;
}
async function normalizedCards(data) {
  const result = await api("/api/validate","POST",{cards:data});
  return result.cards;
}
async function busy(operation) {
  if (loading) return;
  loading = true;
  controls();
  errorText();
  try {await operation();}
  catch (err) {errorText(err.message);}
  finally {loading = false; controls();}
}
async function saveVersion(kind,name,data,side) {
  if (!(kind === "cards" ? validCards() : valid($("profile-" + side)))) return;
  await busy(async () => {
    const record = await saveWithConfirmation("/api/library/" + kind,{name:name.trim(),data:clone(data)});
    if (!record) return;
    if (kind === "cards") await bindSavedCards(record);
    else chosenBots[side] = record.id;
    await refreshLibrary();
    await refreshComparison();
    $("message").textContent = "已保存「" + record.name + "」。";
  });
}
function renderSources() {
  function options(select,records,id,first) {
    if (!select) return;
    const choices = records.map(record => new Option(record.name+" · "+(sourceLabels[record.source] || record.source),record.id));
    select.replaceChildren(first,...choices.filter(o => o.value !== first.value));
    if (id && !Array.from(select.options).some(option => option.value === id)) select.add(new Option("载入的快照",id));
    select.value = id || first.value;
  }
  options($("source"),library.cards,sourceId,new Option("项目默认卡表",projectCardsId));
  for (const side of ["q","a","b"]) options($("source-" + side),library.bot,chosenBots[side],new Option("项目默认 · " + defaultStrategyNames[side],""));
}
async function selectCards(record) {
  const data = clone(record.data);
  const conveyor = data.rules?.conveyor || {};
  const legacy = !Object.hasOwn(data.cards?.work || {},"work_seconds") ||
    Object.values(data.roles || {}).some(role => Object.hasOwn(role,"work_seconds")) ||
    Object.hasOwn(conveyor,"employee_every") || Object.hasOwn(conveyor,"opening");
  // A running service can still hold an older snapshot in memory. Ask the
  // engine to migrate its data before editing, preserving the archive and ID.
  const normalized = legacy ? await normalizedCards(data) : data;
  sourceId = record.id;
  sourceCards = clone(normalized);
  candidate = clone(normalized);
  $("cardName").value = record.name;
  $("playStatus").textContent = "";
  renderSources();
  renderCards();
  await loadNotes();
}
async function bindSavedCards(record) {
  const draftNote = $("notes").value;
  const changed = draftNote !== savedNotes;
  await selectCards(record);
  if (!changed) return;
  $("notes").value = draftNote;
  try {
    const note = await api("/api/notes","POST",{id:record.id,text:draftNote});
    savedNotes = note.text;
  } catch (err) {
    errorText("卡表已保存，备注写入失败。可点击「保存备注」重试。 " + err.message);
  }
}
async function loadNotes() {
  notesReady = false;
  savedNotes = "";
  $("notes").value = "";
  if (!sourceId) return;
  const record = await api("/api/notes/" + sourceId);
  if (record.id !== sourceId) return;
  notesReady = true;
  savedNotes = record.text;
  $("notes").value = savedNotes;
}
$("notes").oninput = controls;
$("saveNotes").onclick = () => busy(async () => {
  const record = await api("/api/notes","POST",{id:sourceId,text:$("notes").value});
  savedNotes = record.text;
  $("message").textContent = "已保存「" + currentCardsName() + "」的试玩备注。";
});
function storageWarnings(messages) {
  if (!messages?.length) return;
  $("storageWarnings").textContent = messages.join("\n");
  $("storageWarnings").hidden = false;
}
async function refreshLibrary() {
  library = await api("/api/library");
  storageWarnings(library.warnings);
  renderSources();
}
async function restoreExperiment(item) {
  const record = await api("/api/jobs/" + item.id);
  const request = record.request;
  const restored = await normalizedCards(request.cards);
  await selectCards({id:record.configs?.cards,name:record.card_name || record.label || "历史卡表",data:restored});
  const basePolicy = {...(request.bot?.bot || bot.bot)};
  if (!request.bot?.bot) {
    delete basePolicy.decision_budget_ratio;
    delete basePolicy.decision_budget_ms;
  }
  const historical = {};
  for (const side of ["a","b"]) {
    const policy = {...basePolicy,...request[side]};
    if (Object.hasOwn(request[side] || {},"decision_budget_ratio")) delete policy.decision_budget_ms;
    if (Object.hasOwn(request[side] || {},"decision_budget_ms")) delete policy.decision_budget_ratio;
    historical[side] = record.result?.profiles?.[side] || policy;
  }
  if (record.kind === "balance") {
    setProfile("q",historical.a,record.a_name || "历史策略 A",record.configs?.a);
  } else {
    for (const side of ["a","b"]) setProfile(side,historical[side],record[side+"_name"] || "历史策略 " + side.toUpperCase(),record.configs?.[side]);
  }
  $("seed").value = request.seed;
  $("pairs").value = request.pairs;
  $("cap").value = request.max_seconds;
  renderCards();
  renderProfiles();
  budgetNote();
  await view(record.kind === "balance" ? "balance" : "bot");
  $("message").textContent = "已载入 " + dateTime(record.created_at) + " 的实验参数。" +
    (record.kind === "balance" && !same(historical.a,historical.b) ? "该历史实验使用不同策略，新评估将由双方共用原策略 A。" : "");
}
function acquisitionCell(summary, open) {
  const cell = element("div");
  cell.append(element("span",metricReading(summary,"purchase_coverage")));
  const acquired = summary?.balance_metrics?.card_acquisitions;
  if (!acquired?.observed_games) {
    cell.append(element("small","获牌占比未记录","stacked-cell"));
    return cell;
  }
  const box = details(cell,"查看获牌占比");
  box.className = "acquisition-breakdown";
  const output = element("div");
  box.append(output);
  const show = () => {
    if (box.open && !output.hasChildNodes()) acquisitionTable(output,[{result:summary}]);
  };
  box.ontoggle = show;
  box.open = open;
  show();
  return cell;
}
function historyProgress(item) {
  const summary = item.summary;
  const recorded = value => Number.isInteger(value) && value >= 0;
  const completed = item.status === "done" && recorded(summary?.games) ? summary.games
    : recorded(item.completed) ? item.completed : null;
  const total = recorded(item.total) && item.total > 0 ? item.total
    : item.status === "done" && completed > 0 ? completed : null;
  const count = completed === null ? "进度未记录" : total === null ? completed + " 局 · 总局数未记录"
    : completed + " / " + total + " 局";
  const box = element("div",undefined,"run-progress");
  box.append(element("span",statusLabels[item.status] || item.status,"badge"));
  if (total !== null && completed !== null || item.status === "running") {
    const progress = element("progress",count);
    progress.setAttribute("aria-label","实验进度");
    if (total !== null && completed !== null) {
      progress.max = total;
      progress.value = Math.min(completed,total);
    }
    box.append(progress);
  }
  const match = summary?.current_match;
  box.append(element("small",count + (item.status === "running" && match ? " · 本局 " + secondsText(match.seconds) : "")));
  return box;
}
function historyValues(item,kind,openAcquisitions = false) {
  const summary = item.summary;
  const label = item.kind === "legacy" ? "旧实验" : (item.label || "实验");
  const cells = [
    stacked(label,dateTime(item.created_at)),
    stacked(item.card_name || "—","A「" + (item.a_name || "—") + "」 · B「" + (item.b_name || "—") + "」"),
    historyProgress(item),
    stacked(secondsText(summary?.simulated_seconds),secondsText(summary?.elapsed_seconds))
  ];
  if (kind === "balance") {
    return cells.concat([
      metricReading(summary,"first_player_win_rate"),
      stacked(metricReading(summary,"mean_finish_seconds"),"超时 " + metricReading(summary,"timeout_rate")),
      acquisitionCell(summary,openAcquisitions),
      metricReading(summary,"upgrades_per_minute"),metricReading(summary,"tool_generations_per_minute"),
      metricReading(summary,"interferences_per_minute")
    ]);
  }
  const decided = summary ? summary.a_wins + summary.b_wins : null;
  function wins(side) {
    if (!Number.isFinite(decided)) return "未记录";
    return decided ? number(100*summary[side + "_wins"]/decided) + "%" : "未观测";
  }
  return cells.concat([stacked("A " + wins("a"),"B " + wins("b")),summary?.timeouts ?? "—"]);
}
function secondsText(seconds) {
  return Number.isFinite(seconds) ? number(seconds) + " 秒" : "未记录";
}
const stopping = new Set();
async function stopJob(id,button) {
  if (stopping.has(id)) return;
  stopping.add(id);
  button.disabled = true;
  try {
    await api("/api/jobs/" + id,"DELETE");
    await refreshHistory();
  } catch (err) {errorText("停止失败 · " + err.message);}
  finally {stopping.delete(id); button.disabled = false;}
}
function renderHistory(kind) {
  if (activeView !== kind) return;
  const root = $("historyTable");
  const openIds = new Set([...root.querySelectorAll(".history-detail")].map(row => row.previousElementSibling?.dataset.jobId));
  const openAcquisitions = new Set([...root.querySelectorAll(".acquisition-breakdown[open]")].map(box => box.closest("tr[data-job-id]").dataset.jobId));
  root.replaceChildren();
  $("historyTitle").textContent = kind === "bot" ? "对战记录" : "评估记录";
  $("historyHint").textContent = kind === "bot"
    ? "每行是一条共用同一卡表的 A 对 B 实验，最新记录在前。展开详情可查看双方胜局、胜率和策略参数差异；载入参数可恢复当时的卡表及双方策略。"
    : "所有评估记录按时间倒序排列，最新记录在前。";
  const items = histories[kind];
  if (!items.length) {
    root.append(element("p","暂无实验记录。","hint"));
    return;
  }
  const rows = items.map(item => {
    const buttons = element("div",undefined,"row-actions");
    const expand = element("button","展开详情");
    buttons.append(expand,action("载入参数",() => restoreExperiment(item)));
    if (item.status === "running") {
      const stop = element("button","停止","stop-run");
      stop.disabled = stopping.has(item.id);
      stop.onclick = () => stopJob(item.id,stop);
      buttons.append(stop);
    }
    let detailRow;
    expand.onclick = async () => {
      if (detailRow) {
        detailRow.remove();
        detailRow = null;
        expand.textContent = "展开详情";
        return;
      }
      expand.disabled = true;
      try {
        const record = await api("/api/jobs/" + item.id);
        const tr = expand.closest("tr");
        if (!tr?.isConnected) return;
        detailRow = document.createElement("tr");
        detailRow.className = "history-detail";
        const td = detailRow.insertCell();
        td.colSpan = tr.cells.length;
        tr.after(detailRow);
        const full = element("div",undefined,"history-content");
        td.append(full);
        const output = element("div");
        full.append(output);
        function draw(result) {
          const openTitles = new Set([...output.querySelectorAll("details[open] > summary")].map(el => el.textContent));
          if (result) report(output,record,result);
          else output.replaceChildren(element("p",record.error || (statusLabels[record.status] || record.status),"hint"));
          for (const section of output.querySelectorAll("details")) {
            if (openTitles.has(section.firstElementChild.textContent)) section.open = true;
          }
        }
        detailRow.addEventListener("jobprogress",event => draw({...event.detail.summary,decision_samples:record.result?.decision_samples}));
        draw(record.result || record.summary);
        const download = element("button","导出实验记录 JSON");
        download.onclick = async () => {
          try {downloadJson("off-work-"+record.id+".json",await api("/api/jobs/" + record.id));}
          catch (err) {errorText(err.message);}
        };
        full.append(download);
        const parameters = details(full,"完整实验参数");
        parameters.append(element("pre",JSON.stringify(record.request,null,2)));
        expand.textContent = "收起详情";
      } catch (err) {
        detailRow?.remove();
        detailRow = null;
        errorText("读取历史失败 · " + err.message);
      } finally {expand.disabled = false;}
    };
    return [...historyValues(item,kind,openAcquisitions.has(item.id)),buttons];
  });
  const headers = ["实验 / 时间","卡表 / A、B 策略","状态 / 局数",stacked("累计游戏时长","实际计算耗时")];
  if (kind === "balance") {
    headers.push(stacked("先手胜率","含平局的已结束局",balanceMeasures.first_player_win_rate.formula));
    headers.push(stacked("对局节奏","平均结束时长 / 超时率",
      balanceMeasures.mean_finish_seconds.formula + "。 " + balanceMeasures.timeout_rate.formula));
    headers.push(stacked("购牌覆盖率","各卡获得占比",acquisitionFormula));
    for (const key of ["upgrades_per_minute","tool_generations_per_minute","interferences_per_minute"]) {
      const spec = balanceMeasures[key];
      headers.push(stacked(spec.label,spec.unit,spec.formula + rateFormula));
    }
  } else headers.push("A / B 分胜负胜率","超时局");
  const t = table(root,[...headers,"操作"],rows);
  t.classList.add("history-records");
  const entryRows = Array.from(t.tBodies[0].rows);
  items.forEach((item,index) => {
    entryRows[index].dataset.jobId = item.id;
    if (openIds.has(item.id)) entryRows[index].querySelector("button").click();
  });
  controls();
}
let comparisonGeneration = 0;
let previousComparison = "";
function comparisonCardName(record) {
  if (record.configs?.cards === projectCardsId) return "项目默认卡表";
  return record.card_name || "历史卡表";
}
function availableCards() {
  const cards = new Map([[projectCardsId,"项目默认卡表"]]);
  for (const config of library.cards) if (!cards.has(config.id)) cards.set(config.id,config.name);
  for (const run of comparableRecords) {
    const id = run.configs?.cards;
    if (id && !cards.has(id)) cards.set(id,comparisonCardName(run) + " · 历史快照");
  }
  return cards;
}
function botCardsId() {
  return sourceId && same(sourceCards,candidate) ? sourceId : "";
}
function renderBotCards() {
  if (!baseline) return;
  const cards = availableCards();
  const id = botCardsId();
  if (!cards.has(id)) cards.set(id,"当前编辑 · " + currentCardsName() + (id ? "" : "（未保存）"));
  $("botCards").replaceChildren(...Array.from(cards,([key,name]) => new Option(name,key)));
  $("botCards").value = id;
}
async function selectBotCards(id) {
  if (!id) return;
  const record = id === projectCardsId ? {id,name:projectCardsName,data:baseline} : await api("/api/library/" + id);
  await selectCards(record);
  await refreshComparison();
  $("message").textContent = "BOT 双方已共用卡表「" + record.name + "」。";
}
function matchingConditions(a,b) {
  return a && b && a.summary?.simulator_fingerprint && a.summary.simulator_fingerprint === b.summary?.simulator_fingerprint &&
    ["seed","pairs","max_seconds"].every(key => a[key] === b[key]) &&
    ["a","b"].every(key => a.configs?.[key] === b.configs?.[key]) &&
    a.summary?.balance_metrics?.version === b.summary?.balance_metrics?.version;
}
function comparisonChoices(saved) {
  const cards = availableCards();
  for (const side of ["left","right"]) {
    const select = $(side+"Config");
    const prev = saved?.[side === "left" ? 0 : 1]?.config ?? select.value;
    select.replaceChildren(...Array.from(cards,([id,name]) => new Option(name,id)));
    select.value = cards.has(prev) ? prev : (side === "left" ? projectCardsId : cards.has(sourceId) ? sourceId : projectCardsId);
  }
  renderBotCards();
  populateRecords(undefined,saved);
}
function populateRecords(changedSide,saved) {
  for (const side of ["right","left"]) {
    const cid = $(side+"Config").value;
    const select = $(side+"Record");
    const prev = saved?.[side === "left" ? 0 : 1]?.run ?? select.value;
    const relevant = comparableRecords.filter(r => r.configs?.cards === cid)
      .sort((a,b) => Number(b.kind === "balance")-Number(a.kind === "balance"));
    const other = comparableRecords.find(r => r.id === $(side === "left" ? "rightRecord" : "leftRecord").value);
    const match = relevant.find(r => r.id !== other?.id && matchingConditions(r,other));
    select.replaceChildren(...relevant.map(r => new Option(
      dateTime(r.created_at) + " · " + (r.label || "实验") +
      " · " + (r.summary?.games ?? r.total) + " 局 · " + r.id.slice(0,8),r.id)));
    if (!relevant.length) select.add(new Option("尚无已完成的模拟",""));
    const selectionValid = changedSide !== side && relevant.some(r => r.id === prev);
    const preferMatch = side === "left" && changedSide === "right" && cid === projectCardsId;
    select.value = selectionValid ? prev : relevant[0]?.id || "";
    if (match && (preferMatch || !selectionValid)) select.value = match.id;
  }
}
function selection() {
  return ["left","right"].map(side => ({config:$(side+"Config").value,run:$(side+"Record").value}));
}
function recordedParameters(record) {
  const {request,result} = record;
  const params = {...request.cards,实验设置:{
    seed:request.seed,pairs:request.pairs,max_seconds:request.max_seconds,
    metrics_version:result.balance_metrics?.version,godot_version:result.godot_version,simulator_fingerprint:result.simulator_fingerprint
  }};
  if (result.profiles) params.BOT实际策略 = result.profiles;
  else params.BOT请求参数 = {a:request.a,b:request.b};
  return params;
}
async function showComparison() {
  if (activeView !== "balance") return;
  const choices = selection();
  const key = JSON.stringify(choices);
  if (previousComparison === key) return;
  previousComparison = key;
  const generation = ++comparisonGeneration;
  $("comparisonStatus").textContent = "正在读取两份实验快照…";
  const root = $("comparisonResult");
  root.replaceChildren();
  $("comparisonPlayStatus").textContent = "";
  if (choices[0].config === choices[1].config && choices[0].run === choices[1].run) {
    $("comparisonStatus").textContent = "请选择另一份卡表，或同一卡表的另一次模拟。";
    return;
  }
  try {
    const records = await Promise.all(choices.map(c => c.run ? api("/api/jobs/" + c.run) : null));
    const cards = await Promise.all(choices.map(async (c,i) =>
      records[i]?.request.cards || (c.config === projectCardsId ? baseline : (await api("/api/library/" + c.config)).data)));
    if (generation !== comparisonGeneration) return;
    if (records.some(record => record && (record.status !== "done" || !record.result))) throw Error("请选择已完成的实验记录。");
    const batches = records.map((record,index) => {
      const side = index ? "B" : "A";
      const name = side + " · " + availableCards().get(choices[index].config);
      const heading = element("div",undefined,"row-actions");
      heading.append(element("span",name));
      const play = element("button","试玩" + side + "卡表");
      play.dataset.edit = "";
      play.disabled = loading;
      const label = record ? name + "（实验 " + record.id.slice(0,8) + "）" : name;
      play.onclick = () => startPlaytest(label,"comparisonPlayStatus",() => cards[index]);
      heading.append(play);
      return {name,heading,status:record?.status,request:record?.request,result:record?.result};
    });
    const bothMeasured = records.every(Boolean);
    const comparable = bothMeasured && batches.every(b => [1,2].includes(b.result.balance_metrics?.version));
    if (bothMeasured) {
      const differences = differentConditions(batches);
      let message = "实验条件一致，差值为右侧减左侧。";
      if (differences.length) {
        message = "条件不同或缺少记录 · " + differences.join("、") + "。";
        message += comparable ? "下表展示双方都采集且口径一致的指标差。" : "指标版本未知，仅展示两侧观测值。";
      }

      $("comparisonStatus").textContent = message;
      balanceTable(root,batches,comparable,differences.length ? "观测差值（右侧 − 左侧）" : "右侧 − 左侧");
    } else {
      $("comparisonStatus").textContent = "缺少完整模拟的配置仅比较卡表参数。";
      balanceTable(root,batches,false);
    }
    root.append(element("h3","各卡获得张数与占比"),element("p",acquisitionFormula,"hint"));
    acquisitionTable(root,batches,comparable);
    const snapshots = records.map((record,i) => bothMeasured ? recordedParameters(record) : cards[i]);
    const changes = parameterDifferences(snapshots[0],snapshots[1]);
    if (changes.length) {
      root.append(element("h4","参数差异（" + changes.length + " 项）"));
      table(root,["参数","左侧","右侧"],changes);
    } else root.append(element("p","两份快照中记录的参数相同。","hint"));
    for (const [index,snapshot] of snapshots.entries()) {
      const record = records[index];
      const originalName = record && record.card_name && record.card_name !== comparisonCardName(record)
        ? "（实验保存名「" + record.card_name + "」）" : "";
      const block = details(root,batches[index].name + originalName + " · 完整参数");
      block.append(element("pre",JSON.stringify(snapshot,null,2)));
    }
  } catch (err) {
    if (generation === comparisonGeneration) {previousComparison = ""; $("comparisonStatus").textContent = "读取实验失败 · " + err.message;}
  }
}
for (const side of ["left","right"]) {
  $(side+"Config").onchange = () => {populateRecords(side); showComparison();};
  $(side+"Record").onchange = showComparison;
}
function swapComparison() {
  const [left,right] = selection();
  $("leftConfig").value = right.config;
  $("rightConfig").value = left.config;
  populateRecords();
  $("leftRecord").value = right.run;
  $("rightRecord").value = left.run;
  return showComparison();
}
$("swap").onclick = swapComparison;
let historyGeneration = 0;
function acceptHistory(result) {
  historyItems = result.items;
  storageWarnings(result.warnings);
  for (const kind of ["bot","balance"]) {
    histories[kind] = result.items.filter(item => item.kind === kind || item.kind === "legacy");
  }
}
function refreshComparison(saved) {
  comparableRecords = historyItems.filter(item => item.status === "done");
  if (activeView === "bot") {renderBotCards(); return;}
  comparisonChoices(saved);
  return showComparison();
}
async function refreshHistory() {
  const generation = ++historyGeneration;
  const result = await api("/api/history");
  if (generation !== historyGeneration) return;
  const oldRows = histories[activeView], oldIds = new Set([...histories.balance,...histories.bot].map(r => r.id));
  acceptHistory(result);
  const newRows = histories[activeView];
  if (result.items.some(r => !oldIds.has(r.id))) await refreshLibrary();
  if (generation !== historyGeneration) return;
  if (!same(oldRows.map(r => [r.id,r.status]),newRows.map(r => [r.id,r.status]))) {
    renderHistory(activeView);
  } else {
    for (const [index,item] of newRows.entries()) {
      if (item.status !== "running" || same(item,oldRows[index])) continue;
      const row = $("historyTable").querySelector('[data-job-id="'+item.id+'"]');
      if (!row) continue;
      historyValues(item,activeView,!!row.querySelector(".acquisition-breakdown[open]"))
        .forEach((value,i) => row.cells[i].replaceChildren(value));
      const detail = row.nextElementSibling;
      if (detail?.classList.contains("history-detail")) detail.dispatchEvent(new CustomEvent("jobprogress",{detail:item}));
    }
  }
  const completed = historyItems.filter(r => r.status === "done");
  if (!same(completed.map(r => r.id),comparableRecords.map(r => r.id))) await refreshComparison();
}
function view(next) {
  if (next !== activeView) {comparisonGeneration++; previousComparison = "";}
  activeView = next;
  $("balanceComparisonSlot").hidden = next === "bot";
  $("workspace").setAttribute("aria-labelledby","tab-"+next);
  for (const button of document.querySelectorAll("[data-view]")) {
    const active = button.dataset.view === next;
    button.setAttribute("aria-selected",String(active));
    button.tabIndex = active ? 0 : -1;
  }
  $("cardsView").hidden = next !== "balance";
  $("sharedProfile").hidden = next !== "balance";
  $("botView").hidden = next !== "bot";
  $("runnerTitle").textContent = next === "balance" ? "运行平衡模拟" : "运行 BOT 对战";
  controls();
  budgetNote();
  renderHistory(next);
  return refreshComparison();
}
for (const tab of document.querySelectorAll("[data-view]")) {
  tab.onclick = () => {if (baseline) view(tab.dataset.view);};
  tab.onkeydown = event => {
    if (!baseline || !["ArrowLeft","ArrowRight","Home","End"].includes(event.key)) return;
    event.preventDefault();
    const next = event.key === "Home" ? "balance" : event.key === "End" ? "bot" : activeView === "bot" ? "balance" : "bot";
    view(next);
    $("tab-"+next).focus();
  };
}
$("editCards").onclick = () => {view("balance"); $("source").focus();};
$("botCards").onchange = () => busy(() => selectBotCards($("botCards").value));
$("refreshHistory").onclick = () => busy(async () => {await refreshLibrary(); await refreshHistory(); await refreshComparison();});
$("cardName").oninput = controls;
$("card-search").oninput = filterCards;
$("card-kind").onchange = filterCards;
$("source").onchange = () => busy(async () => {
  const id = $("source").value;
  const record = id === projectCardsId ? {id,name:projectCardsName,data:baseline} : await api("/api/library/" + id);
  await selectCards(record);
  $("message").textContent = "已载入卡表「" + record.name + "」。";
});
$("saveCards").onclick = () => saveVersion("cards",$("cardName").value,candidate);
$("file").onchange = async event => {
  const file = event.target.files[0];
  if (!file) return;
  loading = true;
  controls();
  try {
    candidate = await normalizedCards(JSON.parse(await file.text()));
    $("cardName").value = file.name.replace(/\.json$/i,"");
    renderCards();
    controls();
    errorText();
    $("message").textContent = "已载入 " + file.name;
  } catch (err) {errorText("导入失败 · " + err.message);}
  finally {event.target.value = ""; loading = false; controls();}
};
function downloadJson(name,data) {
  const url = URL.createObjectURL(new Blob([JSON.stringify(data,null,2) + "\n"],{type:"application/json"}));
  const anchor = element("a");
  anchor.href = url;
  anchor.download = name;
  anchor.click();
  setTimeout(() => URL.revokeObjectURL(url),1000);
}
$("export").onclick = async () => {
  if (!validCards()) return;
  try {
    const cards = await normalizedCards(clone(candidate));
    downloadJson("off_work_cards.json",cards);
    errorText();
    $("message").textContent = "校验通过，已导出当前卡表。";
  } catch (err) {errorText("导出失败 · " + err.message);}
};
async function startPlaytest(label,statusId,readCards) {
  if (loading || !baseline) return;
  loading = true;
  controls();
  errorText();
  $("comparisonPlayStatus").textContent = "";
  $("playStatus").textContent = "";
  const status = $(statusId);
  status.textContent = "正在启动试玩 · " + label;
  try {
    const cards = await readCards();
    await api("/api/playtest","POST",{cards});
    status.textContent = "试玩已启动 · " + label;
  } catch (err) {
    status.textContent = "试玩启动失败 · " + label + " · " + err.message;
  } finally {
    loading = false;
    controls();
  }
}
function currentCardsName() {
  return $("cardName").value.trim() || "未命名卡表";
}
function playCurrentCards(statusId) {
  if (!validCards()) return;
  return startPlaytest("当前配置「" + currentCardsName() + "」",statusId,() => clone(candidate));
}
$("playtest").onclick = () => playCurrentCards("playStatus");
function budgetNote() {
  const pairs = $("pairs").valueAsNumber;
  const games = pairs * 2;
  const note = $("budget");
  note.textContent = "";
  if (!Number.isSafeInteger(pairs) || pairs < 1 || !Number.isSafeInteger(games)) return;
  const mode = activeView === "bot" ? "BOT PK" : "当前卡表";
  note.textContent = mode + "运行 " + games + " 局（" + pairs + " 个种子，每个种子交换座位各跑一局）。";
}
$("budgetForm").oninput = budgetNote;
$("budgetForm").onsubmit = event => {event.preventDefault(); run();};
async function run() {
  if (loading || !candidate || !valid($("budgetForm"))) return;
  if (marketPoolIssue() || $("cardsView").querySelector(":invalid")) {await view("balance"); validCards(); return;}
  const kind = activeView;
  if (!valid($(kind === "balance" ? "sharedProfile" : "profiles"))) return;
  const seed = $("seed").valueAsNumber;
  const pairs = $("pairs").valueAsNumber;
  const max_seconds = $("cap").valueAsNumber;
  if (max_seconds <= 0 || max_seconds > Number.MAX_SAFE_INTEGER) {
    errorText("单局上限必须为正数，并在可精确表示的秒数范围内。");
    return;
  }
  if (!Number.isSafeInteger(seed) || !Number.isSafeInteger(pairs*2) || pairs-1 > Number.MAX_SAFE_INTEGER-seed) {
    errorText("种子范围或模拟局数超出了可精确表示的整数范围。");
    return;
  }
  const request = {
    seed,pairs,max_seconds,cards:clone(candidate),kind,
    label:kind === "bot" ? "BOT PK" : "卡牌评估",card_name:currentCardsName(),
    a:clone(kind === "bot" ? profiles.a : profiles.q),
    b:clone(kind === "bot" ? profiles.b : profiles.q),
    a_name:kind === "bot" ? strategyNames.a : strategyNames.q,
    b_name:kind === "bot" ? strategyNames.b : strategyNames.q
  };
  await busy(async () => {
    const submitted = await saveWithConfirmation("/api/run",request);
    if (!submitted) return;
    const savedName = submitted.card_name || request.card_name;
    for (const side of kind === "bot" ? ["a","b"] : ["q"]) {
      const slot = side === "q" ? "a" : side;
      setProfile(side,request[slot],submitted[slot+"_name"] || request[slot+"_name"],submitted.configs?.[slot]);
    }
    renderProfiles();
    $("message").textContent = kind === "bot"
      ? "已保存或复用卡表「" + savedName + "」、BOT A「" + strategyNames.a + "」和 BOT B「" + strategyNames.b + "」，已启动一条对战记录（" + (2*pairs) + " 局）。"
      : "已提交「" + savedName + "」的 " + (2*pairs) + " 局模拟，可在对应记录查看进度或停止。";
    await refreshLibrary();
    if (submitted.configs?.cards) {
      await bindSavedCards({id:submitted.configs.cards,name:savedName,data:request.cards});
    }
    await refreshHistory();
  });
}
async function openHistoryRecord(id) {
  const record = await api("/api/jobs/" + id);
  await view(record.kind === "bot" ? "bot" : "balance");
  const row = $("historyTable").querySelector('[data-job-id="'+id+'"]');
  if (!row) throw Error("未找到链接中的历史记录。");
  if (!row.nextElementSibling?.classList.contains("history-detail")) row.querySelector("button").click();
  row.scrollIntoView({block:"center"});
}
async function loadLinkedComparison(params) {
  const linked = ["left","right"].map(side => ({side,id:params.get(side)})).filter(item => item.id);
  if (!linked.length) return;
  for (const item of linked) {
    item.record = comparableRecords.find(record => record.id === item.id);
    if (!item.record) throw Error("链接中的对比实验缺少已完成记录。");
  }
  const botComparison = params.get("view") === "bot" || linked.every(item => item.record.kind === "bot");
  if (botComparison) {
    const cardId = linked[0].record.configs?.cards;
    if (!cardId || linked.some(item => item.record.kind !== "bot" || item.record.configs?.cards !== cardId) ||
        params.has("cards") && params.get("cards") !== cardId) {
      throw Error("BOT 对比必须使用同一份卡表，链接中的记录或卡表不一致。");
    }
    await selectBotCards(cardId);
    await openHistoryRecord(linked[0].id);
    $("message").textContent = "已定位链接中的一条 BOT 对战。每条记录直接比较 A 与 B；其他实验可在历史表中查看。";
    return;
  }
  await view("balance");
  for (const {side,record} of linked) $(side+"Config").value = record.configs.cards;
  populateRecords();
  for (const {side,id} of linked) $(side+"Record").value = id;
  await showComparison();
}
async function loadLinkedRecords() {
  const params = new URLSearchParams(location.search);
  const version = params.get("cards");
  if (version) {
    if (!/^cards_[a-f0-9]{64}$/.test(version)) throw Error("链接中的卡表版本 ID 无效。");
    const saved = await api("/api/library/" + version);
    await selectCards({...saved, data:await normalizedCards(saved.data)});
    $("message").textContent = "已载入链接中的卡表 · " + saved.name;
  }
  const runId = params.get("run");
  if (runId) {
    if (!/^[a-f0-9]{32}$/.test(runId)) throw Error("链接中的实验 ID 无效。");
    await openHistoryRecord(runId);
    return;
  }
  await loadLinkedComparison(params);
}
async function init() {
  loading = true;
  budgetNote();
  controls();
  try {
    if (location.protocol === "file:") throw Error("请从仓库中的「启动手动调参.command」打开工作台。");
    const config = await api("/api/bootstrap");
    projectCardsId = config.project_cards_id;
    projectCardsName = config.default_names?.cards || "项目默认";
    for (const side of ["q","a","b"]) {
      if (config.default_names?.[side]) defaultStrategyNames[side] = config.default_names[side];
    }
    bot = config.bot;
    presets = config.presets;
    strengthProfiles = config.strength_profiles || {};
    legacyBudgetMs = config.legacy_default_budget_ms;
    legacyPolicyDefaults = {...config.legacy_search_defaults,...config.legacy_algorithm_defaults};
    baseline = config.cards;
    profiles = {};
    defaultProfiles = {q:config.default_profiles.balance.a,a:config.default_profiles.bot.a,b:config.default_profiles.bot.b};
    for (const side of ["q","a","b"]) setProfile(side,defaultProfiles[side],defaultStrategyNames[side]);
    const budget = config.default_options;
    $("seed").value = budget.seed;
    $("pairs").value = budget.pairs;
    $("cap").value = budget.max_seconds;
    $("frequency-definition").textContent = rateFormula;
    for (const metric of [...Object.values(balanceMeasures),{label:"各卡获得占比",formula:acquisitionFormula}]) {
      const article = element("article");
      article.append(element("strong",metric.label),element("p",metric.formula));
      $("definitions").append(article);
    }
    library = config.library;
    storageWarnings(library.warnings);
    acceptHistory(config.history);
    await selectCards({id:projectCardsId,name:projectCardsName,data:baseline});
    renderProfiles();
    await view("balance");
    $("message").textContent = "已载入下班卡表和 BOT 策略。";
    await loadLinkedRecords();
  } catch (err) {
    errorText(err.message);
    $("message").textContent = "配置或历史记录载入失败，请检查链接或刷新重试。";
  } finally {
    loading = false;
    controls();
  }
}
async function poll() {
  try {
    if (!document.hidden && baseline && !loading) {
      await refreshHistory();
    }
  } catch (err) {errorText("刷新记录失败 · " + err.message);}
  finally {setTimeout(poll,histories[activeView].some(r => r.status === "running") ? 900 : 5000);}
}
init().then(poll);
