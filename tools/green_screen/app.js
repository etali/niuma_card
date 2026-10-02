// Copyright (C) 2026 etali (https://github.com/etali)
// SPDX-License-Identifier: AGPL-3.0-only
// See LICENSE in the project root.

// 界面逻辑：文件读取、预览渲染、导出。
// 抠像算法在 chroma.js，ZIP 打包在 zip.js。

'use strict';

const PREVIEW_MAX = 512;   // 预览按此边长缩放，保证拖滑杆时不卡
const items = [];          // { id, name, bitmap, preview, keyColor, crop, seeds, el, ... }
let seq = 0;
let renderToken = 0;       // 参数一变就自增，用来丢弃过期的渲染任务
let pickingFor = null;     // 吸管取色状态
let seedPicking = false;   // 点选背景连通区域的状态

const $ = (id) => document.getElementById(id);
const els = {
  drop: $('drop'), fileInput: $('fileInput'), pickBtn: $('pickBtn'),
  panel: $('panel'), grid: $('grid'), status: $('status'),
  mode: $('mode'), modeField: $('modeField'), keyMethod: $('keyMethod'),
  keyMode: $('keyMode'), keyColorField: $('keyColorField'),
  keyColor: $('keyColor'), eyedropper: $('eyedropper'),
  regionMode: $('regionMode'), seedField: $('seedField'),
  seedBtn: $('seedBtn'), seedClearBtn: $('seedClearBtn'), seedTip: $('seedTip'),
  trim: $('trim'), trimPadField: $('trimPadField'), checker: $('checker'),
  zipBtn: $('zipBtn'), allBtn: $('allBtn'), addBtn: $('addBtn'),
  clearBtn: $('clearBtn'), resetBtn: $('resetBtn'),
  lightbox: $('lightbox'), lbStage: $('lbStage'), lbCanvas: $('lbCanvas'),
  lbName: $('lbName'), lbToggle: $('lbToggle'), lbClose: $('lbClose'),
  lbCropBtn: $('lbCropBtn'), cropOverlay: $('cropOverlay'), cropRect: $('cropRect'),
  cropApply: $('cropApply'), cropReset: $('cropReset'), cropCancel: $('cropCancel'),
  cropHint: $('cropHint'),
};

// 滑杆 id → 是否整数，用于同步 <output> 显示
const SLIDERS = {
  threshold: false, distTolerance: true, softness: false, despill: false,
  darkFloor: true, hueTolerance: false, shrink: true, feather: true, trimPadding: true,
};

/** 从界面收集全局参数。裁切框和种子点是逐图的，在 itemOptions 里并进来。 */
function readOptions() {
  const o = {
    keyMethod: els.keyMethod.value,
    mode: els.mode.value,
    threshold: +$('threshold').value,
    distTolerance: +$('distTolerance').value,
    softness: +$('softness').value,
    despill: +$('despill').value,
    darkFloor: +$('darkFloor').value,
    hueTolerance: +$('hueTolerance').value,
    regionMode: els.regionMode.value,
    shrink: +$('shrink').value,
    feather: +$('feather').value,
    trim: els.trim.checked,
    trimPadding: +$('trimPadding').value,
  };
  if (els.keyMode.value === 'manual') o.keyColor = hexToRgb(els.keyColor.value);
  return o;
}

/** 全局参数 + 这张图自己的裁切框和种子点。 */
function itemOptions(item, opts) {
  return Object.assign({}, opts, { crop: item.crop, seeds: item.seeds });
}

/**
 * 判定方式决定哪些滑杆有意义，没意义的藏起来。
 * 「自动」时各图可能走不同的路，两套都留着——藏掉反而让人以为参数没了。
 */
function syncMethodUI() {
  const picked = els.keyMethod.value;
  let showChroma = true, showDistance = true;
  if (picked === 'chroma') showDistance = false;
  else if (picked === 'distance') showChroma = false;
  else {
    // 自动：所有图都走同一条路时，才敢按那条路收起另一套
    const methods = new Set(items.map((i) => i.method).filter(Boolean));
    if (methods.size === 1) {
      const only = [...methods][0];
      showChroma = only === 'chroma';
      showDistance = only === 'distance';
    }
  }
  for (const el of document.querySelectorAll('.chroma-only')) el.hidden = !showChroma;
  for (const el of document.querySelectorAll('.distance-only')) el.hidden = !showDistance;
}

function hexToRgb(hex) {
  const v = parseInt(hex.slice(1), 16);
  return [(v >> 16) & 255, (v >> 8) & 255, v & 255];
}

function rgbToHex([r, g, b]) {
  return '#' + [r, g, b].map((x) => Math.round(x).toString(16).padStart(2, '0')).join('');
}

function setStatus(msg) {
  els.status.textContent = msg || '';
}

/** 把 bitmap 画到指定边长内，返回 {canvas, ctx, imageData}。 */
function rasterize(bitmap, maxSize) {
  const scale = maxSize ? Math.min(1, maxSize / Math.max(bitmap.width, bitmap.height)) : 1;
  const w = Math.max(1, Math.round(bitmap.width * scale));
  const h = Math.max(1, Math.round(bitmap.height * scale));
  const canvas = document.createElement('canvas');
  canvas.width = w;
  canvas.height = h;
  const ctx = canvas.getContext('2d', { willReadFrequently: true });
  ctx.drawImage(bitmap, 0, 0, w, h);
  return { canvas, ctx, imageData: ctx.getImageData(0, 0, w, h) };
}

/** 把抠好的数据写进 canvas。 */
function paint(canvas, result) {
  canvas.width = result.width;
  canvas.height = result.height;
  const ctx = canvas.getContext('2d');
  ctx.putImageData(new ImageData(result.data, result.width, result.height), 0, 0);
}

// ---------- 文件加载 ----------

async function addFiles(fileList) {
  const files = [...fileList].filter((f) => f.type.startsWith('image/'));
  const skipped = fileList.length - files.length;
  if (!files.length) {
    setStatus(skipped ? '没有可用的图片文件' : '');
    return;
  }

  setStatus(`正在读取 ${files.length} 张…`);
  for (const file of files) {
    try {
      // imageOrientation 让相机照片按 EXIF 方向摆正
      const bitmap = await createImageBitmap(file, { imageOrientation: 'from-image' });
      const item = {
        id: ++seq,
        name: file.name,
        bitmap,
        preview: rasterize(bitmap, PREVIEW_MAX),
        keyColor: null,
        method: null,
        crop: null,          // {x,y,w,h} 归一化到原图
        seeds: [],           // [{x,y}] 归一化到原图
        showOriginal: false,
      };
      items.push(item);
      buildCard(item);
    } catch (err) {
      console.error('读取失败', file.name, err);
      setStatus(`${file.name} 读取失败，已跳过`);
    }
  }

  els.panel.hidden = false;
  els.drop.classList.add('compact');
  renderAll();
}

/** 建卡片 DOM。 */
function buildCard(item) {
  const card = document.createElement('div');
  card.className = 'card';

  const holder = document.createElement('div');
  holder.className = 'card-canvas' + (els.checker.checked ? ' checker' : '');
  const canvas = document.createElement('canvas');
  holder.appendChild(canvas);
  holder.addEventListener('click', (e) => {
    if (pickingFor !== null) pickColorFrom(item, canvas, e);
    else if (seedPicking) addSeedFrom(item, canvas, e);
    else openLightbox(item);
  });

  const info = document.createElement('div');
  info.className = 'card-info';
  const name = document.createElement('div');
  name.className = 'card-name';
  name.textContent = item.name;
  name.title = item.name;
  const meta = document.createElement('div');
  meta.className = 'card-meta';
  meta.textContent = `${item.bitmap.width}×${item.bitmap.height}`;
  info.append(name, meta);

  const actions = document.createElement('div');
  actions.className = 'card-actions';
  const crop = document.createElement('button');
  crop.type = 'button';
  crop.className = 'btn-mini';
  crop.textContent = '裁切';
  crop.addEventListener('click', () => { openLightbox(item); enterCropMode(); });
  const dl = document.createElement('button');
  dl.type = 'button';
  dl.className = 'btn-mini';
  dl.textContent = '下载 PNG';
  dl.addEventListener('click', () => downloadOne(item));
  const rm = document.createElement('button');
  rm.type = 'button';
  rm.className = 'btn-mini';
  rm.textContent = '移除';
  rm.addEventListener('click', () => removeItem(item));
  actions.append(crop, dl, rm);

  card.append(holder, info, actions);
  els.grid.appendChild(card);

  Object.assign(item, { el: card, holder, canvas, metaEl: meta });
}

function removeItem(item) {
  const i = items.indexOf(item);
  if (i >= 0) items.splice(i, 1);
  item.el.remove();
  item.bitmap.close?.();
  if (!items.length) {
    els.panel.hidden = true;
    els.drop.classList.remove('compact');
    setStatus('');
  } else {
    setStatus(`${items.length} 张待导出`);
  }
}

function clearAll() {
  for (const item of items) {
    item.el.remove();
    item.bitmap.close?.();
  }
  items.length = 0;
  els.grid.innerHTML = '';
  els.panel.hidden = true;
  els.drop.classList.remove('compact');
  els.fileInput.value = '';
  setStatus('');
}

// ---------- 预览 ----------

/** 逐张刷新预览。参数再变时靠 token 作废本轮，避免旧结果盖掉新结果。 */
async function renderAll() {
  const token = ++renderToken;
  const opts = readOptions();

  for (const item of items) {
    if (token !== renderToken) return;
    renderOne(item, opts);
    // 让出主线程，图多时界面不至于卡住
    await new Promise((r) => requestAnimationFrame(r));
  }
  if (token === renderToken) {
    syncMethodUI();
    setStatus(`${items.length} 张待导出`);
  }
}

const METHOD_LABEL = { chroma: '色度键', distance: '颜色距离' };

function renderOne(item, opts) {
  if (item.showOriginal) {
    const { canvas } = item.preview;
    item.canvas.width = canvas.width;
    item.canvas.height = canvas.height;
    item.canvas.getContext('2d').drawImage(canvas, 0, 0);
    return;
  }
  const src = item.preview.imageData;
  const result = chromaKey(
    { data: src.data, width: src.width, height: src.height }, itemOptions(item, opts));
  item.keyColor = result.keyColor;
  item.method = result.method;
  // 留着给点选用：把预览图上的点击位置换算回原图坐标要靠它
  item.lastResult = { offset: result.offset, source: result.source, width: result.width, height: result.height };
  paint(item.canvas, result);
  drawSeedMarks(item, result);

  const bits = [
    `${item.bitmap.width}×${item.bitmap.height}`,
    `幕布 ${rgbToHex(result.keyColor)}`,
    METHOD_LABEL[result.method] || result.method,
  ];
  if (item.crop) bits.push('已裁切');
  if (opts.regionMode === 'seeds') bits.push(`点选 ${item.seeds.length}`);
  item.metaEl.textContent = bits.join(' · ');
}

/** 在预览图上标出点选的种子点，位置按裁切/trim 的偏移换算。 */
function drawSeedMarks(item, result) {
  if (els.regionMode.value !== 'seeds' || !item.seeds.length) return;
  const ctx = item.canvas.getContext('2d');
  const sx = result.source.width, sy = result.source.height;
  ctx.save();
  ctx.lineWidth = 1.5;
  for (const s of item.seeds) {
    const x = s.x * sx - result.offset.x;
    const y = s.y * sy - result.offset.y;
    if (x < 0 || y < 0 || x > result.width || y > result.height) continue;
    ctx.beginPath();
    ctx.arc(x, y, 5, 0, Math.PI * 2);
    ctx.strokeStyle = '#000';
    ctx.stroke();
    ctx.beginPath();
    ctx.arc(x, y, 4, 0, Math.PI * 2);
    ctx.strokeStyle = '#4ea3ff';
    ctx.stroke();
  }
  ctx.restore();
}

/** 全分辨率处理，用于导出。 */
function processFull(item, opts) {
  const { imageData } = rasterize(item.bitmap, 0);
  // 自动识别时锁定预览里已确认的幕布色和判定方式，保证导出和预览一致
  const o = itemOptions(item, opts);
  if (!o.keyColor && item.keyColor) o.keyColor = item.keyColor;
  if (o.keyMethod === 'auto' && item.method) o.keyMethod = item.method;
  return chromaKey({ data: imageData.data, width: imageData.width, height: imageData.height }, o);
}

function resultToBlob(result) {
  const canvas = document.createElement('canvas');
  paint(canvas, result);
  return new Promise((resolve) => canvas.toBlob(resolve, 'image/png'));
}

function pngName(name) {
  return name.replace(/\.[^.]+$/, '') + '.png';
}

function saveBlob(blob, filename) {
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = filename;
  a.click();
  // 立刻 revoke 会让部分浏览器来不及取数据
  setTimeout(() => URL.revokeObjectURL(url), 10000);
}

// ---------- 导出 ----------

async function downloadOne(item) {
  setStatus(`正在导出 ${item.name}…`);
  item.el.classList.add('busy');
  try {
    const blob = await resultToBlob(processFull(item, readOptions()));
    saveBlob(blob, pngName(item.name));
    setStatus(`已导出 ${pngName(item.name)}`);
  } catch (err) {
    console.error(err);
    setStatus(`${item.name} 导出失败：${err.message}`);
  } finally {
    item.el.classList.remove('busy');
  }
}

async function downloadAll(asZip) {
  if (!items.length) return;
  const opts = readOptions();
  const buttons = [els.zipBtn, els.allBtn];
  buttons.forEach((b) => (b.disabled = true));

  const zipFiles = [];
  const used = new Set();
  try {
    for (let i = 0; i < items.length; i++) {
      const item = items[i];
      setStatus(`处理中 ${i + 1}/${items.length}…`);
      await new Promise((r) => requestAnimationFrame(r));

      const blob = await resultToBlob(processFull(item, opts));
      // 同名文件在 ZIP 里加序号区分
      let name = pngName(item.name);
      if (used.has(name)) {
        const base = name.slice(0, -4);
        let k = 2;
        while (used.has(`${base}_${k}.png`)) k++;
        name = `${base}_${k}.png`;
      }
      used.add(name);

      if (asZip) zipFiles.push({ name, data: new Uint8Array(await blob.arrayBuffer()) });
      else saveBlob(blob, name);
    }

    if (asZip) {
      setStatus('打包中…');
      saveBlob(createZip(zipFiles), `cutout_${Date.now()}.zip`);
    }
    setStatus(`完成，共 ${items.length} 张`);
  } catch (err) {
    console.error(err);
    setStatus(`导出失败：${err.message}`);
  } finally {
    buttons.forEach((b) => (b.disabled = false));
  }
}

// ---------- 吸管取色 ----------

/** 把点击位置换算成 canvas 像素坐标；点在留白上返回 null。 */
function canvasPixelFromEvent(canvas, e) {
  const rect = canvas.getBoundingClientRect();
  const scale = Math.min(rect.width / canvas.width, rect.height / canvas.height);
  const dw = canvas.width * scale;
  const dh = canvas.height * scale;
  const ox = rect.left + (rect.width - dw) / 2;
  const oy = rect.top + (rect.height - dh) / 2;
  const x = Math.floor((e.clientX - ox) / scale);
  const y = Math.floor((e.clientY - oy) / scale);
  if (x < 0 || y < 0 || x >= canvas.width || y >= canvas.height) return null;
  return { x, y };
}

function setPicking(on) {
  pickingFor = on ? true : null;
  els.eyedropper.textContent = on ? '取色中…' : '吸管';
  for (const item of items) item.holder.classList.toggle('picking', !!on);
  setStatus(on ? '在任意预览图上点一下幕布区域' : '');
}

function pickColorFrom(item, canvas, e) {
  const pt = canvasPixelFromEvent(canvas, e);
  if (!pt) return;
  // 从原始预览数据取色，抠过的图上背景已经透明了
  const src = item.preview.imageData;
  const i = (pt.y * src.width + pt.x) * 4;
  els.keyColor.value = rgbToHex([src.data[i], src.data[i + 1], src.data[i + 2]]);
  els.keyMode.value = 'manual';
  els.keyColorField.hidden = false;
  setPicking(false);
  renderAll();
}

// ---------- 点选背景连通区域 ----------

function setSeedPicking(on) {
  seedPicking = on;
  els.seedBtn.textContent = on ? '点选中…' : '点选背景';
  for (const item of items) item.holder.classList.toggle('picking', on);
  setStatus(on ? '在预览图上点要扣掉的背景，可点多处；点完再按一下退出' : '');
}

/**
 * 记下一个种子点。存的是原图归一化坐标——
 * 预览图和导出图分辨率不同，裁切框也可能之后再改，只有归一化的坐标两边都对得上。
 */
function addSeedFrom(item, canvas, e) {
  const pt = canvasPixelFromEvent(canvas, e);
  if (!pt) return;
  // 预览画的是抠完（可能已裁切/trim）的图，得先还原回原图坐标
  const r = item.lastResult;
  if (!r) return;
  const x = (pt.x + r.offset.x) / r.source.width;
  const y = (pt.y + r.offset.y) / r.source.height;
  item.seeds.push({ x, y });
  renderAll();
}

function clearSeeds() {
  for (const item of items) item.seeds = [];
  setSeedPicking(false);
  renderAll();
}

// ---------- 放大预览 ----------

const LIGHTBOX_MAX = 1400;   // 放大预览用中等分辨率，够看细节又不至于等太久
let lbItem = null;

function openLightbox(item) {
  lbItem = item;
  els.lbName.textContent = item.name;
  els.lbToggle.textContent = '看原图';
  els.lightbox.hidden = false;
  exitCropMode();
  drawLightbox(false);
}

function drawLightbox(original) {
  if (!lbItem) return;
  const { canvas, imageData } = rasterize(lbItem.bitmap, LIGHTBOX_MAX);
  if (original) {
    els.lbCanvas.width = canvas.width;
    els.lbCanvas.height = canvas.height;
    els.lbCanvas.getContext('2d').drawImage(canvas, 0, 0);
    return;
  }
  const opts = itemOptions(lbItem, readOptions());
  if (!opts.keyColor && lbItem.keyColor) opts.keyColor = lbItem.keyColor;
  if (opts.keyMethod === 'auto' && lbItem.method) opts.keyMethod = lbItem.method;
  paint(els.lbCanvas, chromaKey(
    { data: imageData.data, width: imageData.width, height: imageData.height }, opts));
}

function closeLightbox() {
  exitCropMode();
  els.lightbox.hidden = true;
  lbItem = null;
}

// ---------- 裁切 ----------

let cropping = false;
let cropDrag = null;         // 拖拽中的 {x0,y0,x1,y1}，单位是 stage 内的 px
let cropStage = null;        // {w,h} 当前 stage 的显示尺寸
let dragging = false;        // 是否正在拖

/**
 * 进裁切模式：显示未抠图的原图，把 canvas 的显示尺寸钉死。
 * CSS 里 canvas 是 max-width + object-fit:contain，元素框和画面框未必重合，
 * 不钉死的话拖出来的框会和图错位。
 */
function enterCropMode() {
  if (!lbItem) return;
  cropping = true;

  const { canvas } = rasterize(lbItem.bitmap, LIGHTBOX_MAX);
  els.lbCanvas.width = canvas.width;
  els.lbCanvas.height = canvas.height;
  els.lbCanvas.getContext('2d').drawImage(canvas, 0, 0);

  // 按 CSS 里那对上限算出实际显示尺寸，overlay 用同一组数
  const maxW = window.innerWidth * 0.88;
  const maxH = window.innerHeight * 0.8;
  const scale = Math.min(1, maxW / canvas.width, maxH / canvas.height);
  cropStage = { w: Math.round(canvas.width * scale), h: Math.round(canvas.height * scale) };
  els.lbCanvas.style.width = cropStage.w + 'px';
  els.lbCanvas.style.height = cropStage.h + 'px';
  els.lbStage.style.width = cropStage.w + 'px';
  els.lbStage.style.height = cropStage.h + 'px';

  els.cropOverlay.hidden = false;
  els.cropHint.hidden = false;
  for (const b of [els.cropApply, els.cropReset, els.cropCancel]) b.hidden = false;
  for (const b of [els.lbToggle, els.lbCropBtn]) b.hidden = true;

  // 已有裁切框就先画出来，方便在它基础上重来
  if (lbItem.crop) {
    cropDrag = {
      x0: lbItem.crop.x * cropStage.w,
      y0: lbItem.crop.y * cropStage.h,
      x1: (lbItem.crop.x + lbItem.crop.w) * cropStage.w,
      y1: (lbItem.crop.y + lbItem.crop.h) * cropStage.h,
    };
  } else {
    cropDrag = null;
  }
  paintCropRect();
}

function exitCropMode() {
  cropping = false;
  cropDrag = null;
  cropStage = null;
  dragging = false;
  els.cropOverlay.hidden = true;
  els.cropRect.hidden = true;
  els.cropHint.hidden = true;
  for (const b of [els.cropApply, els.cropReset, els.cropCancel]) b.hidden = true;
  for (const b of [els.lbToggle, els.lbCropBtn]) b.hidden = false;
  els.lbCanvas.style.width = '';
  els.lbCanvas.style.height = '';
  els.lbStage.style.width = '';
  els.lbStage.style.height = '';
}

function paintCropRect() {
  if (!cropDrag) { els.cropRect.hidden = true; return; }
  const r = normalizedDrag();
  els.cropRect.hidden = false;
  els.cropRect.style.left = r.x + 'px';
  els.cropRect.style.top = r.y + 'px';
  els.cropRect.style.width = r.w + 'px';
  els.cropRect.style.height = r.h + 'px';
}

/** 把拖拽的两个角整理成左上 + 宽高，单位仍是 stage px。 */
function normalizedDrag() {
  const x = Math.min(cropDrag.x0, cropDrag.x1);
  const y = Math.min(cropDrag.y0, cropDrag.y1);
  return { x, y, w: Math.abs(cropDrag.x1 - cropDrag.x0), h: Math.abs(cropDrag.y1 - cropDrag.y0) };
}

function stagePoint(e) {
  const rect = els.cropOverlay.getBoundingClientRect();
  return {
    x: Math.min(rect.width, Math.max(0, e.clientX - rect.left)),
    y: Math.min(rect.height, Math.max(0, e.clientY - rect.top)),
  };
}

function applyCrop() {
  if (!lbItem || !cropDrag || !cropStage) return;
  const r = normalizedDrag();
  // 太小的框基本是误点，忽略
  if (r.w < 4 || r.h < 4) {
    setStatus('裁切框太小，已忽略');
    return;
  }
  lbItem.crop = {
    x: r.x / cropStage.w,
    y: r.y / cropStage.h,
    w: r.w / cropStage.w,
    h: r.h / cropStage.h,
  };
  exitCropMode();
  drawLightbox(false);
  renderAll();
  setStatus(`${lbItem.name} 已裁切`);
}

function resetCrop() {
  if (!lbItem) return;
  lbItem.crop = null;
  exitCropMode();
  drawLightbox(false);
  renderAll();
  setStatus(`${lbItem.name} 已取消裁切`);
}

// ---------- 事件绑定 ----------

let rerenderTimer = null;
function scheduleRender() {
  clearTimeout(rerenderTimer);
  rerenderTimer = setTimeout(renderAll, 120);
}

for (const [id, isInt] of Object.entries(SLIDERS)) {
  const input = $(id);
  const out = $(id + 'Out');
  input.addEventListener('input', () => {
    out.textContent = isInt ? input.value : (+input.value).toFixed(2);
    scheduleRender();
  });
}

els.mode.addEventListener('change', renderAll);
els.keyColor.addEventListener('input', scheduleRender);
els.keyMode.addEventListener('change', () => {
  els.keyColorField.hidden = els.keyMode.value !== 'manual';
  renderAll();
});
els.keyMethod.addEventListener('change', () => {
  syncMethodUI();
  renderAll();
});
els.regionMode.addEventListener('change', () => {
  const seeds = els.regionMode.value === 'seeds';
  els.seedField.hidden = !seeds;
  if (!seeds && seedPicking) setSeedPicking(false);
  renderAll();
});
els.seedBtn.addEventListener('click', () => setSeedPicking(!seedPicking));
els.seedClearBtn.addEventListener('click', clearSeeds);
els.trim.addEventListener('change', () => {
  els.trimPadField.hidden = !els.trim.checked;
  renderAll();
});
els.checker.addEventListener('change', () => {
  for (const item of items) item.holder.classList.toggle('checker', els.checker.checked);
});
els.eyedropper.addEventListener('click', () => setPicking(pickingFor === null));

els.resetBtn.addEventListener('click', () => {
  els.mode.value = DEFAULT_OPTIONS.mode;
  els.keyMethod.value = DEFAULT_OPTIONS.keyMethod;
  els.keyMode.value = 'auto';
  els.keyColorField.hidden = true;
  els.regionMode.value = DEFAULT_OPTIONS.regionMode;
  els.seedField.hidden = true;
  els.trim.checked = false;
  els.trimPadField.hidden = true;
  if (seedPicking) setSeedPicking(false);
  for (const [id, isInt] of Object.entries(SLIDERS)) {
    const value = DEFAULT_OPTIONS[id];
    $(id).value = value;
    $(id + 'Out').textContent = isInt ? String(value) : (+value).toFixed(2);
  }
  // 裁切和点选是逐图的，「恢复默认」只动全局参数，不擅自清掉逐图的活儿
  syncMethodUI();
  renderAll();
});

els.zipBtn.addEventListener('click', () => downloadAll(true));
els.allBtn.addEventListener('click', () => downloadAll(false));
els.addBtn.addEventListener('click', () => els.fileInput.click());
els.clearBtn.addEventListener('click', clearAll);

els.pickBtn.addEventListener('click', (e) => { e.stopPropagation(); els.fileInput.click(); });
els.drop.addEventListener('click', () => els.fileInput.click());
els.drop.addEventListener('keydown', (e) => {
  if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); els.fileInput.click(); }
});
els.fileInput.addEventListener('change', () => {
  if (els.fileInput.files.length) addFiles(els.fileInput.files);
  els.fileInput.value = ''; // 允许重复选同一批文件
});

for (const type of ['dragenter', 'dragover']) {
  els.drop.addEventListener(type, (e) => { e.preventDefault(); els.drop.classList.add('over'); });
}
for (const type of ['dragleave', 'drop']) {
  els.drop.addEventListener(type, () => els.drop.classList.remove('over'));
}
els.drop.addEventListener('drop', (e) => {
  e.preventDefault();
  if (e.dataTransfer?.files.length) addFiles(e.dataTransfer.files);
});
// 拖到页面别处时不要让浏览器直接打开图片
window.addEventListener('dragover', (e) => e.preventDefault());
window.addEventListener('drop', (e) => e.preventDefault());

els.lbToggle.addEventListener('click', () => {
  const showOriginal = els.lbToggle.textContent === '看原图';
  els.lbToggle.textContent = showOriginal ? '看抠图' : '看原图';
  drawLightbox(showOriginal);
});
els.lbClose.addEventListener('click', closeLightbox);
els.lightbox.addEventListener('click', (e) => { if (e.target === els.lightbox) closeLightbox(); });

els.lbCropBtn.addEventListener('click', enterCropMode);
els.cropApply.addEventListener('click', applyCrop);
els.cropReset.addEventListener('click', resetCrop);
els.cropCancel.addEventListener('click', () => { exitCropMode(); drawLightbox(false); });

els.cropOverlay.addEventListener('pointerdown', (e) => {
  if (!cropping) return;
  e.preventDefault();
  // 捕获指针只为了拖出元素外也还收得到 move，失败不影响拖拽本身，
  // 所以拖拽状态看 dragging，不看 hasPointerCapture。
  try { els.cropOverlay.setPointerCapture(e.pointerId); } catch (_) { /* 不影响 */ }
  const p = stagePoint(e);
  cropDrag = { x0: p.x, y0: p.y, x1: p.x, y1: p.y };
  dragging = true;
  paintCropRect();
});
els.cropOverlay.addEventListener('pointermove', (e) => {
  if (!cropping || !dragging || !cropDrag) return;
  const p = stagePoint(e);
  cropDrag.x1 = p.x;
  cropDrag.y1 = p.y;
  paintCropRect();
});
for (const type of ['pointerup', 'pointercancel']) {
  els.cropOverlay.addEventListener(type, (e) => {
    dragging = false;
    try { els.cropOverlay.releasePointerCapture(e.pointerId); } catch (_) { /* 不影响 */ }
  });
}

window.addEventListener('keydown', (e) => {
  if (e.key === 'Escape') {
    if (cropping) { exitCropMode(); drawLightbox(false); }
    else if (!els.lightbox.hidden) closeLightbox();
    else if (pickingFor !== null) setPicking(false);
    else if (seedPicking) setSeedPicking(false);
  } else if (e.key === 'Enter' && cropping) {
    applyCrop();
  }
});

syncMethodUI();
