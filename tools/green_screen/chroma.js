// Copyright (C) 2026 etali (https://github.com/etali)
// SPDX-License-Identifier: AGPL-3.0-only
// See LICENSE in the project root.

// 抠像核心算法。
// 纯函数、不碰 DOM，方便单独在 Node 或控制台里验证。
//
// 两套判定方式：
//   chroma   —— 色度键。看「某个通道比另两个高出多少」，绿幕/蓝幕走这条。
//   distance —— 颜色距离。看「离幕布色差多远」，白/灰/黑等无彩色幕布只能走这条，
//               因为无彩色的三个通道相等，色度键在它身上没有可测量的量。

'use strict';

/** 默认参数。app.js 里的滑杆都以此为初值。 */
const DEFAULT_OPTIONS = {
  keyColor: null,      // [r,g,b]；null 表示自动从边缘取背景色
  keyMethod: 'auto',   // auto=按幕布色饱和度自动选 / chroma=色度键 / distance=颜色距离
  mode: 'balanced',    // 仅 chroma 有效。balanced=相对纯度（明暗不均也扣得干净）/ soft=绝对差值（发丝更柔）
  threshold: 0.28,     // 仅 chroma 有效。低于此纯度的像素完全保留
  distTolerance: 40,   // 仅 distance 有效。与幕布色的通道最大差值在此以内的像素完全扣除
  softness: 0.22,      // 阈值往上的过渡宽度，越大边缘越柔
  darkFloor: 12,       // 仅 chroma 有效。暗部保护：超出量小于它的像素一律当前景
  hueTolerance: 0.55,  // 仅 chroma 有效。色相容差（0..1）
  despill: 0.9,        // 仅 chroma 有效。去溢色强度：削掉前景边缘吃到的绿边
  regionMode: 'all',   // all=全图同色一起扣 / border=只扣连到画面边缘的 / seeds=只扣点选的连通区域
  seeds: [],           // regionMode=seeds 时的种子点，[{x,y}]，归一化到原图 0..1
  crop: null,          // 裁切框 {x,y,w,h}，归一化到原图 0..1；null 表示不裁
  shrink: 0,           // 蒙版收缩像素数，用来啃掉一圈残留亮边
  feather: 0,          // 蒙版羽化半径
  trim: false,         // 是否裁掉四周全透明的空白
  trimPadding: 0,      // 裁切后保留的边距
};

/** 幕布色饱和度低于此值就没法用色度键判定，自动改走颜色距离。 */
const ACHROMATIC_SATURATION = 0.25;

/** 连通扩散时，「算背景候选」的 alpha 上限（0..255）。比这更不透明的像素不参与扩散。 */
const REGION_CANDIDATE_ALPHA = 128;

/** 边框样本里饱和像素占比超过它，就认定是彩色幕布，走色度键。 */
const CHROMATIC_SAMPLE_RATIO = 0.25;

/** 平滑阶跃：x<=a 得 0，x>=b 得 1，中间三次平滑过渡。 */
function smoothstep(a, b, x) {
  if (b <= a) return x < a ? 0 : 1;
  const t = Math.min(1, Math.max(0, (x - a) / (b - a)));
  return t * t * (3 - 2 * t);
}

function clamp01(x) {
  return x < 0 ? 0 : x > 1 ? 1 : x;
}

/** RGB(0..255) 取色相，返回 0..1；无彩色返回 -1。 */
function rgbHue(r, g, b) {
  const mx = Math.max(r, g, b);
  const mn = Math.min(r, g, b);
  const d = mx - mn;
  if (d === 0) return -1;
  let h;
  if (mx === r) h = ((g - b) / d) % 6;
  else if (mx === g) h = (b - r) / d + 2;
  else h = (r - g) / d + 4;
  h /= 6;
  return h < 0 ? h + 1 : h;
}

/** 两个色相的环形距离，归一化到 0..1（1 = 正对面）。 */
function hueDistance(h1, h2) {
  if (h1 < 0 || h2 < 0) return 0;
  const d = Math.abs(h1 - h2);
  return (d > 0.5 ? 1 - d : d) * 2;
}

/** HSV 意义上的饱和度，0..1。白/灰/黑得 0。 */
function rgbSaturation(r, g, b) {
  const mx = Math.max(r, g, b);
  if (mx <= 0) return 0;
  return (mx - Math.min(r, g, b)) / mx;
}

/**
 * 定下这张图该用哪套判定方式。
 * 幕布色是无彩色（白、灰、黑）时色度键无从下手——三个通道相等，
 * 「某通道高出多少」恒为 0，反而会把偏色的前景当成幕布扣掉。
 */
function resolveMethod(keyMethod, keyColor) {
  if (keyMethod === 'chroma' || keyMethod === 'distance') return keyMethod;
  return rgbSaturation(keyColor[0], keyColor[1], keyColor[2]) < ACHROMATIC_SATURATION
    ? 'distance' : 'chroma';
}

/** 沿四周边框采样，返回 [r,g,b] 数组。band 取短边 2%。 */
function sampleBorder(data, width, height) {
  const band = Math.max(2, Math.round(Math.min(width, height) * 0.02));
  const step = Math.max(1, Math.round(Math.min(width, height) / 256));
  const out = [];
  const push = (x, y) => {
    const i = (y * width + x) * 4;
    out.push([data[i], data[i + 1], data[i + 2]]);
  };
  for (let y = 0; y < band; y++) {
    for (let x = 0; x < width; x += step) { push(x, y); push(x, height - 1 - y); }
  }
  for (let x = 0; x < band; x++) {
    for (let y = 0; y < height; y += step) { push(x, y); push(width - 1 - x, y); }
  }
  return out;
}

/**
 * 色度键用的幕布色：取边框上「主通道超出量最大」的一批像素求均值。
 * 比直接取角点稳——角点常落在暗角或阴影里。
 */
function detectKeyColorChroma(data, width, height) {
  const samples = sampleBorder(data, width, height);
  if (!samples.length) return [0, 255, 0];
  // 先看边框整体偏哪个通道，再按那个通道的超出量排序
  let sr = 0, sg = 0, sb = 0;
  for (const [r, g, b] of samples) { sr += r; sg += g; sb += b; }
  const d = sg >= sr && sg >= sb ? 1 : sb >= sr ? 2 : 0;
  const excess = (c) => c[d] - Math.max(c[(d + 1) % 3], c[(d + 2) % 3]);

  const sorted = samples.slice().sort((a, b) => excess(b) - excess(a));
  const keep = Math.max(1, Math.round(sorted.length * 0.25));
  let r = 0, g = 0, b = 0;
  for (let i = 0; i < keep; i++) { r += sorted[i][0]; g += sorted[i][1]; b += sorted[i][2]; }
  return [Math.round(r / keep), Math.round(g / keep), Math.round(b / keep)];
}

/**
 * 颜色距离用的幕布色：取边框各通道中位数。
 * 中位数比均值抗干扰——边框上蹭进来一点前景不会把结果拽偏。
 */
function detectKeyColorMedian(data, width, height) {
  const samples = sampleBorder(data, width, height);
  if (!samples.length) return [255, 255, 255];
  const mid = (ch) => {
    const v = samples.map((c) => c[ch]).sort((a, b) => a - b);
    return v[v.length >> 1];
  };
  return [mid(0), mid(1), mid(2)];
}

/**
 * 自动识别幕布色，同时定下判定方式。
 *
 * 判定方式不能只看中位数那一个颜色：边框上混进前景时中位数会落到一个
 * 不代表幕布的颜色上（一半绿一半白，中位数可能是白），于是绿幕被误判成白幕。
 * 改成数「边框里有多少像素是饱和的」——只要够一批，就是彩色幕布。
 */
function detectKey(data, width, height, keyMethod) {
  const samples = sampleBorder(data, width, height);
  let method = keyMethod;
  if (method !== 'chroma' && method !== 'distance') {
    let chromatic = 0;
    for (const [r, g, b] of samples) {
      if (rgbSaturation(r, g, b) >= ACHROMATIC_SATURATION) chromatic++;
    }
    const ratio = samples.length ? chromatic / samples.length : 0;
    method = ratio >= CHROMATIC_SAMPLE_RATIO ? 'chroma' : 'distance';
  }
  return {
    method,
    keyColor: method === 'chroma'
      ? detectKeyColorChroma(data, width, height)
      : detectKeyColorMedian(data, width, height),
  };
}

/** 兼容旧调用：detectKeyColor 仍是色度键那套。 */
function detectKeyColor(data, width, height) {
  return detectKeyColorChroma(data, width, height);
}

/**
 * 分离式形态学：pick 取 Math.min 是腐蚀，取 Math.max 是膨胀。
 * 先横后纵，O(w*h*radius)，够快。
 */
function morphAlpha(alpha, width, height, radius, pick, seed) {
  if (radius <= 0) return alpha;
  const tmp = new Uint8ClampedArray(alpha.length);
  for (let y = 0; y < height; y++) {
    const row = y * width;
    for (let x = 0; x < width; x++) {
      let m = seed;
      const x0 = Math.max(0, x - radius), x1 = Math.min(width - 1, x + radius);
      for (let k = x0; k <= x1; k++) m = pick(m, alpha[row + k]);
      tmp[row + x] = m;
    }
  }
  const out = new Uint8ClampedArray(alpha.length);
  for (let x = 0; x < width; x++) {
    for (let y = 0; y < height; y++) {
      let m = seed;
      const y0 = Math.max(0, y - radius), y1 = Math.min(height - 1, y + radius);
      for (let k = y0; k <= y1; k++) m = pick(m, tmp[k * width + x]);
      out[y * width + x] = m;
    }
  }
  return out;
}

/** 腐蚀（取邻域最小值），用来收缩蒙版。 */
function erodeAlpha(alpha, width, height, radius) {
  return morphAlpha(alpha, width, height, radius, Math.min, 255);
}

/** 分离式均值模糊，用来羽化蒙版。 */
function blurAlpha(alpha, width, height, radius) {
  if (radius <= 0) return alpha;
  const win = radius * 2 + 1;
  const tmp = new Float32Array(alpha.length);
  for (let y = 0; y < height; y++) {
    const row = y * width;
    let sum = 0;
    for (let k = -radius; k <= radius; k++) sum += alpha[row + Math.min(width - 1, Math.max(0, k))];
    for (let x = 0; x < width; x++) {
      tmp[row + x] = sum / win;
      const outX = Math.min(width - 1, Math.max(0, x - radius));
      const inX = Math.min(width - 1, Math.max(0, x + radius + 1));
      sum += alpha[row + inX] - alpha[row + outX];
    }
  }
  const out = new Uint8ClampedArray(alpha.length);
  for (let x = 0; x < width; x++) {
    let sum = 0;
    for (let k = -radius; k <= radius; k++) sum += tmp[Math.min(height - 1, Math.max(0, k)) * width + x];
    for (let y = 0; y < height; y++) {
      out[y * width + x] = sum / win;
      const outY = Math.min(height - 1, Math.max(0, y - radius));
      const inY = Math.min(height - 1, Math.max(0, y + radius + 1));
      sum += tmp[inY * width + x] - tmp[outY * width + x];
    }
  }
  return out;
}

/**
 * 色度键蒙版：看主通道比另两个高出多少。
 * 返回 alpha（255=完全保留），以及每个像素「有多像幕布」用于去溢色。
 */
function maskByChroma(src, n, keyColor, o) {
  const [kr, kg, kb] = keyColor;
  // 找出幕布色的主通道：绿幕→G，蓝幕→B。其余两个通道作为「非幕布」参考。
  let d = 1, o1 = 0, o2 = 2;
  if (kr >= kg && kr >= kb) { d = 0; o1 = 1; o2 = 2; }
  else if (kb >= kg && kb >= kr) { d = 2; o1 = 0; o2 = 1; }

  const keyExcess = Math.max(1, keyColor[d] - Math.max(keyColor[o1], keyColor[o2]));
  const keyRel = Math.max(0.02, keyExcess / Math.max(1, keyColor[d]));
  const keyHue = rgbHue(kr, kg, kb);

  const raw = new Uint8ClampedArray(n);
  for (let p = 0, i = 0; p < n; p++, i += 4) {
    const c = [src[i], src[i + 1], src[i + 2]];
    const excess = c[d] - Math.max(c[o1], c[o2]);

    let score = 0;
    if (excess > 0) {
      // balanced：按「相对纯度」判定，背景明暗不均（阴影里的暗绿）也能一起扣掉。
      // soft：按绝对差值判定，半透明的发丝/边缘过渡更自然。
      score = o.mode === 'soft'
        ? excess / keyExcess
        : (excess / Math.max(1, c[d])) / keyRel;

      // 暗部保护：绿色超出量太小的像素（近黑、灰）不参与抠除
      score *= smoothstep(o.darkFloor, o.darkFloor * 2, excess);

      // 色相闸门：和幕布色相差太远的像素排除在外
      if (o.hueTolerance < 1) {
        const hd = hueDistance(rgbHue(c[0], c[1], c[2]), keyHue);
        score *= 1 - smoothstep(o.hueTolerance * 0.7, o.hueTolerance, hd);
      }
    }
    raw[p] = 255 * (1 - smoothstep(o.threshold, o.threshold + o.softness, score));
  }
  return { raw, channels: { d, o1, o2 } };
}

/**
 * 颜色距离蒙版：看每个像素离幕布色差多远（取三通道里差得最多的那个）。
 * 无彩色幕布（白/灰/黑）只能这么判——距离容差内的一律扣掉，容差外的一律保留，
 * 中间按 softness 给一段过渡。判定只看「离得多近」，不看色相，所以不会像色度键
 * 那样把偏色的前景误当成幕布。
 */
function maskByDistance(src, n, keyColor, o) {
  const [kr, kg, kb] = keyColor;
  const tolIn = Math.max(0, o.distTolerance);
  // softness 0..0.8 折算成 0..~77 个色阶的过渡宽度，和阈值滑杆的手感对齐
  const tolOut = tolIn + Math.max(1, o.softness * 96);

  const raw = new Uint8ClampedArray(n);
  for (let p = 0, i = 0; p < n; p++, i += 4) {
    const dist = Math.max(
      Math.abs(src[i] - kr),
      Math.abs(src[i + 1] - kg),
      Math.abs(src[i + 2] - kb),
    );
    raw[p] = 255 * smoothstep(tolIn, tolOut, dist);
  }
  return { raw, channels: null };
}

/**
 * 从种子点出发做 4 邻域漫水，返回 Uint8Array，1 = 属于被选中的连通区域。
 *
 * 分两级走：
 *   raw < REGION_CANDIDATE_ALPHA（明显是幕布）——标记并继续往外扩散；
 *   raw < 255（边缘那圈半透明过渡）——标记但不再往外扩散。
 * 后者顶替了「把结果整体膨胀几像素」的做法：膨胀是无条件的，会径直穿过
 * 一圈只有 1px 宽的不透明边框，把里面本该保留的区域也吞掉。
 */
function floodFill(raw, width, height, seedIndices) {
  const reached = new Uint8Array(raw.length);
  const stack = [];
  for (const p of seedIndices) {
    if (p >= 0 && p < raw.length && !reached[p] && raw[p] < REGION_CANDIDATE_ALPHA) {
      reached[p] = 1;
      stack.push(p);
    }
  }
  while (stack.length) {
    const p = stack.pop();
    const x = p % width;
    const y = (p - x) / width;
    // 4 邻域：8 邻域会从对角缝里漏到不该扣的区域去
    if (x > 0) visit(p - 1);
    if (x < width - 1) visit(p + 1);
    if (y > 0) visit(p - width);
    if (y < height - 1) visit(p + width);
  }
  return reached;

  function visit(q) {
    if (reached[q] || raw[q] >= 255) return;
    reached[q] = 1;
    if (raw[q] < REGION_CANDIDATE_ALPHA) stack.push(q);
  }
}

/** 画面四周一圈里所有「像幕布」的像素，作为 border 模式的种子。 */
function borderSeeds(raw, width, height) {
  const seeds = [];
  for (let x = 0; x < width; x++) {
    seeds.push(x);
    seeds.push((height - 1) * width + x);
  }
  for (let y = 0; y < height; y++) {
    seeds.push(y * width);
    seeds.push(y * width + width - 1);
  }
  return seeds;
}

/**
 * 把点选的坐标换成像素下标。
 * 点歪一两个像素很常见，所以在小邻域里找一个真的「像幕布」的点当种子。
 */
function seedIndicesFromPoints(points, raw, width, height) {
  const out = [];
  const R = Math.max(2, Math.round(Math.min(width, height) * 0.01));
  for (const pt of points) {
    const cx = Math.round(pt.x), cy = Math.round(pt.y);
    if (cx < 0 || cy < 0 || cx >= width || cy >= height) continue;
    let best = -1;
    for (let dy = -R; dy <= R && best < 0; dy++) {
      for (let dx = -R; dx <= R; dx++) {
        const x = cx + dx, y = cy + dy;
        if (x < 0 || y < 0 || x >= width || y >= height) continue;
        const p = y * width + x;
        if (raw[p] < REGION_CANDIDATE_ALPHA) { best = p; break; }
      }
    }
    out.push(best >= 0 ? best : cy * width + cx);
  }
  return out;
}

/**
 * 按连通性限制抠除范围：只有被选中的连通区域保留其透明度，
 * 其他同色但不连通的区域（比如画面中间那块要留的白底）一律恢复不透明。
 */
function limitToRegions(raw, width, height, o, seedPoints) {
  if (o.regionMode !== 'border' && o.regionMode !== 'seeds') return raw;

  const seeds = o.regionMode === 'border'
    ? borderSeeds(raw, width, height)
    : seedIndicesFromPoints(seedPoints, raw, width, height);
  // seeds 模式下一个点都没点，就先什么都不扣，别默默把整张图扣了
  if (!seeds.length) return new Uint8ClampedArray(raw.length).fill(255);

  const reached = floodFill(raw, width, height, seeds);
  const out = new Uint8ClampedArray(raw.length);
  for (let p = 0; p < raw.length; p++) out[p] = reached[p] ? raw[p] : 255;
  return out;
}

/** 归一化裁切框换算成像素矩形，并夹到图内。无效或全图返回 null。 */
function resolveCrop(crop, width, height) {
  if (!crop) return null;
  const x = Math.round(clamp01(crop.x) * width);
  const y = Math.round(clamp01(crop.y) * height);
  const w = Math.round(clamp01(crop.w) * width);
  const h = Math.round(clamp01(crop.h) * height);
  const x0 = Math.min(x, width - 1);
  const y0 = Math.min(y, height - 1);
  const w0 = Math.max(1, Math.min(w, width - x0));
  const h0 = Math.max(1, Math.min(h, height - y0));
  if (x0 === 0 && y0 === 0 && w0 === width && h0 === height) return null;
  return { x: x0, y: y0, w: w0, h: h0 };
}

/** 按像素矩形裁出子图。 */
function cropImage(img, rect) {
  const { data, width } = img;
  const out = new Uint8ClampedArray(rect.w * rect.h * 4);
  for (let y = 0; y < rect.h; y++) {
    const from = ((y + rect.y) * width + rect.x) * 4;
    out.set(data.subarray(from, from + rect.w * 4), y * rect.w * 4);
  }
  return { data: out, width: rect.w, height: rect.h };
}

/**
 * 抠像主函数。
 * @param {{data:Uint8ClampedArray,width:number,height:number}} img 源图（会被复制，不改原数据）
 * @param {object} userOpts 见 DEFAULT_OPTIONS
 * @returns {{data,width,height,keyColor:number[],method:string}}
 */
function chromaKey(img, userOpts) {
  const o = Object.assign({}, DEFAULT_OPTIONS, userOpts || {});

  // 先裁切，后面所有判定都只看裁剩下的部分——自动取色也不会再被裁掉的区域带偏
  const cropRect = resolveCrop(o.crop, img.width, img.height);
  const base = cropRect ? cropImage(img, cropRect) : img;
  const { width, height } = base;
  const src = base.data;
  const n = width * height;

  let method, keyColor;
  if (o.keyColor) {
    keyColor = o.keyColor;
    method = resolveMethod(o.keyMethod, keyColor);
  } else {
    ({ method, keyColor } = detectKey(src, width, height, o.keyMethod));
  }

  const { raw, channels } = method === 'distance'
    ? maskByDistance(src, n, keyColor, o)
    : maskByChroma(src, n, keyColor, o);

  // 种子点存的是原图归一化坐标，换算到裁剩下的这块里
  const seedPoints = (o.seeds || []).map((s) => ({
    x: s.x * img.width - (cropRect ? cropRect.x : 0),
    y: s.y * img.height - (cropRect ? cropRect.y : 0),
  }));
  const limited = limitToRegions(raw, width, height, o, seedPoints);

  // 收缩 / 羽化
  let mask = erodeAlpha(limited, width, height, Math.round(o.shrink));
  mask = blurAlpha(mask, width, height, Math.round(o.feather));

  // 第二遍：写回颜色 + 去溢色 + 合成 alpha
  const out = new Uint8ClampedArray(src.length);
  for (let p = 0, i = 0; p < n; p++, i += 4) {
    let r = src[i], g = src[i + 1], b = src[i + 2];
    const alpha = mask[p];

    // 去溢色只对色度键有意义：削的是「某通道高出来的部分」。
    // 颜色距离那套幕布色可能是白/灰，没有这个可削的量，硬削会把前景压暗。
    if (channels) {
      const { d, o1, o2 } = channels;
      const c = [r, g, b];
      const strength = 1 - limited[p] / 255; // 该像素本身有多像幕布
      // 全透明像素一律彻底去绿：否则引擎生成 mipmap 时会从透明区吃出绿边
      const dsp = alpha === 0 ? 1 : strength * o.despill;
      if (dsp > 0) {
        const limit = Math.max(c[o1], c[o2]);
        if (c[d] > limit) {
          c[d] = c[d] - (c[d] - limit) * dsp;
          r = c[0]; g = c[1]; b = c[2];
        }
      }
    }

    out[i] = r;
    out[i + 1] = g;
    out[i + 2] = b;
    out[i + 3] = alpha * (src[i + 3] / 255); // 保留源图自身的透明度
  }

  let result = { data: out, width, height, offset: { x: 0, y: 0 } };
  if (o.trim) result = trimTransparent(result, Math.max(0, Math.round(o.trimPadding)));

  result.keyColor = keyColor;
  result.method = method;
  // offset/source 让界面能把归一化的种子点换算回结果图里的像素位置
  result.offset = {
    x: (cropRect ? cropRect.x : 0) + result.offset.x,
    y: (cropRect ? cropRect.y : 0) + result.offset.y,
  };
  result.source = { width: img.width, height: img.height };
  return result;
}

/** 裁掉四周全透明的空白，可留边距。返回值带 offset，指出裁掉了左上多少。 */
function trimTransparent(img, padding) {
  const { data, width, height } = img;
  let minX = width, minY = height, maxX = -1, maxY = -1;
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      if (data[(y * width + x) * 4 + 3] > 0) {
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }
  }
  if (maxX < 0) return Object.assign({ offset: { x: 0, y: 0 } }, img);

  minX = Math.max(0, minX - padding);
  minY = Math.max(0, minY - padding);
  maxX = Math.min(width - 1, maxX + padding);
  maxY = Math.min(height - 1, maxY + padding);

  const w = maxX - minX + 1, h = maxY - minY + 1;
  if (w === width && h === height) return Object.assign({ offset: { x: 0, y: 0 } }, img);

  const out = cropImage(img, { x: minX, y: minY, w, h });
  out.offset = { x: minX, y: minY };
  return out;
}

// 同时支持浏览器 <script> 和 Node（跑 test.js 用）
if (typeof module !== 'undefined' && module.exports) {
  module.exports = {
    chromaKey, detectKeyColor, detectKey, trimTransparent, cropImage, resolveCrop,
    DEFAULT_OPTIONS, rgbHue, hueDistance, rgbSaturation, resolveMethod,
  };
}

