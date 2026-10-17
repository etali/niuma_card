// Copyright (C) 2026 etali (https://github.com/etali)
// SPDX-License-Identifier: AGPL-3.0-only
'use strict';

// imagegen 唯一原稿 → 原生完整帧 → Godot cubic 384 → 无损 hdelta。
// 仅局部原像素运动：没有光流、混帧、整图抖动、运行时图层或几何重画。
// 原稿与完整帧归档 build；--install 才替换正式资源。
const fs = require('node:fs'), path = require('node:path');
const crypto = require('node:crypto'), zlib = require('node:zlib');
const {spawnSync} = require('node:child_process');
const {PNG} = require('pngjs');
const {createCanvas, ImageData} = require('@napi-rs/canvas');
const ROOT = path.resolve(__dirname, '..');
const OUT = path.join(ROOT, 'build/art_generation/role_icons_generated');
const FPS = 12, cards = ['geiwo', 'idea'];
const args = process.argv.slice(2), sourceIndex = args.indexOf('--source-dir');
const sources = path.resolve(sourceIndex >= 0 ? args[sourceIndex + 1] : path.join(OUT, 'sources'));
const install = args.includes('--install');
const hash = data => crypto.createHash('sha256').update(data).digest('hex');
const ease = t => { t = Math.min(1, Math.max(0, t)); return t*t*(3-2*t); };

function component(source, sx, sy) {
  const {width:w, height:h, data} = source, start=sy*w+sx;
  if(data[start*4+3]<16) throw Error(`连通种子不在墨迹内：${sx},${sy}`);
  const mask=new Uint8Array(w*h), queue=new Int32Array(w*h);
  let end=1; mask[start]=1; queue[0]=start;
  for(let i=0;i<end;i++) {
    const p=queue[i],x=p%w;
    for(const n of [p-w,p+w,...(x?[p-1]:[]),...(x<w-1?[p+1]:[])]) {
      if(n<0||n>=w*h||mask[n]||data[n*4+3]<16) continue;
      mask[n]=1;queue[end++]=n;
    }
  }
  // 连同原图墨迹完整的抗锯齿边缘取样，不带矩形内其他对象。
  const full=new Uint8Array(mask);
  for(let i=0;i<end;i++) {
    const p=queue[i],x=p%w,y=Math.floor(p/w);
    for(let dy=-3;dy<=3;dy++) for(let dx=-3;dx<=3;dx++) {
      if(x+dx>=0&&x+dx<w&&y+dy>=0&&y+dy<h) full[(y+dy)*w+x+dx]=1;
    }
  }
  return full;
}

function layer(source, seeds) {
  const data=new Uint8ClampedArray(source.data.length),mask=new Uint8Array(source.width*source.height);
  for(const seed of seeds) {const item=component(source,...seed);for(let p=0;p<mask.length;p++) if(item[p]) mask[p]=1;}
  for(let p=0;p<mask.length;p++) if(mask[p]) data.set(source.data.subarray(p*4,p*4+4),p*4);
  const canvas=createCanvas(source.width,source.height);
  canvas.getContext('2d').putImageData(new ImageData(data,source.width,source.height),0,0);
  return {canvas,mask};
}

function pose(ctx,image,pivot,dx,dy,angle) {
  ctx.save();ctx.translate(pivot[0]+dx,pivot[1]+dy);ctx.rotate(angle*Math.PI/180);
  ctx.translate(-pivot[0],-pivot[1]);ctx.drawImage(image,0,0);ctx.restore();
}

function compositeUnder(moving,stationary) {
  const out=Buffer.from(stationary);
  for(let p=0;p<out.length;p+=4) {
    const ma=moving[p+3]/255,sa=stationary[p+3]/255;
    if(!ma||sa===1) continue;
    const alpha=sa+ma*(1-sa);
    for(let c=0;c<3;c++) out[p+c]=Math.round((stationary[p+c]*sa+moving[p+c]*ma*(1-sa))/alpha);
    out[p+3]=Math.round(alpha*255);
  }
  return out;
}

function writePNG(file,w,h,data) {
  fs.mkdirSync(path.dirname(file),{recursive:true});
  fs.writeFileSync(file,PNG.sync.write({width:w,height:h,data}));
}

function draw(card) {
  const input=path.join(sources,card+'.png');
  if(!fs.existsSync(input)) throw Error(`缺少 imagegen 高清原稿：${input}；不会用旧几何图或放大 384 成品替代。`);
  const src=PNG.sync.read(fs.readFileSync(input)),{width:w,height:h}=src;
  if(w!==1254||h!==1254) throw Error(`${card} 原稿尺寸改变，需重标动画坐标：${w}×${h}`);
  const selected=card==='geiwo'
    ? [layer(src,[[960,400],[805,320],[780,395],[1160,520],[1130,575]])]
    : [[627,400],[627,110],[404,212],[853,211],[329,395],[926,395]].map(p=>layer(src,[p]));
  const base=Buffer.from(src.data);
  for(const item of selected) for(let p=0;p<item.mask.length;p++) if(item.mask[p]) base.fill(0,p*4,p*4+4);
  const count=card==='geiwo'?38:42,mode=card==='geiwo'?'once':'loop';
  const box=card==='geiwo'?[570,180,1220,920]:[230,10,1050,785];
  const hashes=[],fixedChanges=[],canvas=createCanvas(w,h),ctx=canvas.getContext('2d');
  for(let i=0;i<count;i++) {
    let data;
    if(i<4||(mode==='loop'&&i>=count-3)) data=Buffer.from(src.data);
    else {
      ctx.clearRect(0,0,w,h);
      if(card==='geiwo') {
        // 待拿卡先轻抬，再落到原掌心；原手在前，接触后自然遮住卡的下缘。
        const t=i/FPS,reach=ease((t-.65)/1.3),lift=Math.sin(Math.PI*ease((t-.25)/.4));
        const settle=t>1.95&&t<2.45?Math.sin((t-1.95)/.5*Math.PI*2)*7*(1-(t-1.95)/.5):0;
        pose(ctx,selected[0].canvas,[984,418],-120*reach+8*lift,230*reach-18*lift+settle,-12*reach);
      } else {
        // 灯泡轻摆上浮，原五束射线错峰舒展；下方两张升级牌完全固定。
        const t=Math.min(1,(i-3)/(count-7)),bell=Math.sin(Math.PI*t)**2;
        const angle=4*Math.sin(t*Math.PI*4)*bell,lift=-18*bell;
        pose(ctx,selected[0].canvas,[627,720],0,lift,angle);
        [[627,115],[404,213],[852,213],[329,395],[926,395]].forEach((center,k)=>{
          const wave=Math.sin(Math.PI*Math.min(1,Math.max(0,(t-k*.025)/.87)))**2;
          const length=Math.hypot(center[0]-627,center[1]-420),spread=20*wave;
          // 射线独立沿径向伸展，不跟着灯泡旋转，避免最上方射线出画。
          pose(ctx,selected[k+1].canvas,center,(center[0]-627)/length*spread,(center[1]-420)/length*spread+lift,0);
        });
      }
      data=compositeUnder(ctx.getImageData(0,0,w,h).data,base);
    }
    let changed=0;
    for(let y=0;y<h;y++) for(let x=0;x<w;x++) {
      if(x>=box[0]&&x<box[2]&&y>=box[1]&&y<box[3]) continue;
      const p=(y*w+x)*4;
      if(data[p]!==src.data[p]||data[p+1]!==src.data[p+1]||data[p+2]!==src.data[p+2]||data[p+3]!==src.data[p+3]) changed++;
    }
    if(changed) throw Error(`${card} 第 ${i} 帧改变了 ${changed} 个固定像素`);
    hashes.push(hash(data));fixedChanges.push(changed);
    writePNG(path.join(OUT,card,'native',`${String(i).padStart(3,'0')}.png`),w,h,data);
  }
  if(new Set(hashes.slice(-3)).size!==1) throw Error(`${card} 末三帧未停稳`);
  const report={card,source:input,source_rgba_sha256:hash(src.data),size:[w,h],frames:count,fps:FPS,play_mode:mode,
    edit_boxes:[box],fixed_changed_pixels:fixedChanges,rgba_sha256:hashes,user_review:'pending',
    method:'imagegen unique base; original-pixel local motion; fixed foreground occlusion'};
  fs.writeFileSync(path.join(OUT,card,'drawing.json'),JSON.stringify(report,null,2)+'\n');
  return report;
}

// 与 tools/hover_delta_codec.py 相同的 NCHD v1，只保存完整 RGBA 的无损差分。
function pack(frames,w,h) {
  const timeline=[],unique=[],seen=new Map();
  for(const raw of frames){const key=hash(raw);if(!seen.has(key)){seen.set(key,unique.length);unique.push(raw);}timeline.push(seen.get(key));}
  const header=Buffer.alloc(24+4*timeline.length);header.write('NCHD');
  [1,w,h,timeline.length,unique.length,...timeline].forEach((v,i)=>header.writeUInt32LE(v,4+i*4));
  const chunks=[header];let previous;
  for(const raw of unique) {
    const padded=Buffer.alloc(Math.ceil(raw.length/8)*8);raw.copy(padded);
    let bytes=zlib.deflateSync(padded,{level:9}),mode=0;
    if(previous){const xor=Buffer.from(padded);for(let i=0;i<xor.length;i++) xor[i]^=previous[i];const delta=zlib.deflateSync(xor,{level:9});if(delta.length<bytes.length){bytes=delta;mode=1;}}
    const record=Buffer.alloc(40);record.writeUInt32LE(mode);record.writeUInt32LE(bytes.length,4);Buffer.from(hash(raw),'hex').copy(record,8);
    chunks.push(record,bytes);previous=padded;
  }
  return Buffer.concat(chunks);
}

function finish(reports) {
  const uiPath=path.join(ROOT,'data/ui.json');
  let uiText=fs.readFileSync(uiPath,'utf8');
  for(const r of reports) {
    const frames=Array.from({length:r.frames},(_,i)=>PNG.sync.read(fs.readFileSync(path.join(OUT,r.card,'runtime',`${String(i).padStart(3,'0')}.png`))));
    const raw=frames.map(f=>f.data),encoded=pack(raw,384,384);
    const packed=path.join(OUT,r.card,r.card+'.hdelta');fs.writeFileSync(packed,encoded);
    const sheet=createCanvas(384*5,410),ctx=sheet.getContext('2d');ctx.fillStyle='#b0c69f';ctx.fillRect(0,0,sheet.width,sheet.height);
    [0,10,18,27,r.frames-1].forEach((index,k)=>{const f=frames[index],c=createCanvas(384,384);c.getContext('2d').putImageData(new ImageData(new Uint8ClampedArray(f.data),384,384),0,0);ctx.drawImage(c,k*384,0);ctx.fillStyle='#30291f';ctx.font='16px sans-serif';ctx.fillText(`${index} / ${(index/FPS).toFixed(2)}s`,k*384+15,403);});
    fs.writeFileSync(path.join(OUT,r.card,'keyframes.png'),sheet.toBuffer('image/png'));
    if(install) {
      fs.copyFileSync(path.join(OUT,r.card,'runtime/000.png'),path.join(ROOT,`assets/art/icon/icon_${r.card}.png`));
      fs.copyFileSync(packed,path.join(ROOT,`assets/art/icon/hover/${r.card}.hdelta`));
      // 只改这两项，保留其他配置原有的数字表示（例如 2.0）、缩进与并发改动。
      const entry=new RegExp(`("${r.card}": \\{\\n\\s+"frames": )\\d+(,\\n\\s+"play_mode": )"[^"]+"`);
      if(!entry.test(uiText)) throw Error(`${r.card} 未找到正式 hover 配置`);
      uiText=uiText.replace(entry,(_,prefix,modePrefix)=>`${prefix}${r.frames}${modePrefix}"${r.play_mode}"`);
    }
    console.log(`${r.card}: ${r.frames} 帧，${new Set(raw.map(hash)).size} 个姿势，固定区变化 0；${encoded.length} bytes${install?'，已接入':''}`);
  }
  if(install) {
    uiText=uiText.replaceAll('诙谐手绘简笔画，原色透明插画（tools/gen_role_icons.py 生成）',
      '诙谐手绘简笔画，原色透明插画（imagegen 原稿，局部原像素动画）');
    fs.writeFileSync(uiPath,uiText);
  }
}

fs.mkdirSync(OUT,{recursive:true});
const reports=cards.map(draw),job={limit:384,files:[]};
for(const r of reports) for(let i=0;i<r.frames;i++) {
  const name=String(i).padStart(3,'0')+'.png';job.files.push({source:path.join(OUT,r.card,'native',name),target:path.join(OUT,r.card,'runtime',name),fix_alpha_border:true});
}
const jobFile=path.join(OUT,'resize_job.json');fs.writeFileSync(jobFile,JSON.stringify(job));
const resized=spawnSync(process.env.GODOT||'/Applications/Godot.app/Contents/MacOS/Godot',['--headless','--path',ROOT,'--script','tools/resize_hover_art.gd','--',jobFile],{cwd:ROOT,encoding:'utf8'});
fs.writeFileSync(path.join(OUT,'resize.log'),resized.stdout+resized.stderr);
if(resized.status!==0||/(?:SCRIPT ERROR|^ERROR):/m.test(resized.stdout+resized.stderr)) throw Error(`Godot 缩放失败：${path.join(OUT,'resize.log')}`);
finish(reports);
