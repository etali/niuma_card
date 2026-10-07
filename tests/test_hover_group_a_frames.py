#!/usr/bin/env python3
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
"""复杂组完整 PNG 动作回归：首帧、终态、固定主体、完整纸边与新增人数。"""
import hashlib
import json
import os
import unittest
from collections import deque
from pathlib import Path

from PIL import Image, ImageChops
from hover_source_archive import native_art_context

ROOT=Path(__file__).resolve().parents[1]
ART=ROOT/'assets/art'
SOURCE_UI=ROOT/'data/ui.json'
BUILD=ROOT/'build/art_generation/native_remaining'
COUNTS={'touliu':72,'xinxijianfang':50,'baiyibutie':48,'liulianghe':84,
        'jiaolv':56,'shanzhai':62,'liebian':62,'tuisong':60}


def frames(card):
    if os.environ.get('CARD_HOVER_CANDIDATES')=='1':
        return [BUILD/card/'frames'/f'{i:03d}.png' for i in range(COUNTS[card])]
    entry=json.loads(SOURCE_UI.read_text())['art']['hover']['cards'][card]
    files=entry.get('files')
    if not isinstance(files,list) or len(files)!=COUNTS[card]:
        raise AssertionError(f'{card}: 正式帧数未更新到 {COUNTS[card]}；候选验证须显式设置 CARD_HOVER_CANDIDATES=1')
    return [ART/path for path in files]


def rgba(path):return Image.open(path).convert('RGBA')


def changed(a,b,box):
    return sum(px!=(0,0,0,0) for px in ImageChops.difference(a.crop(box),b.crop(box)).getdata())


def opaque_components(im,box,predicate=None):
    """按真实完整轮廓计算连通分量，检测缺口/裁切和终态方形卡数量。"""
    crop=im.crop(box)
    alpha=crop.getchannel('A');w,h=crop.size
    occupied=bytearray(1 if v>230 else 0 for v in alpha.getdata()) if predicate is None else bytearray(predicate(v) for v in crop.getdata())
    result=[]
    for seed in range(w*h):
        if not occupied[seed]:continue
        occupied[seed]=0;pending=deque([seed]);n=0;xs=[];ys=[]
        while pending:
            p=pending.popleft();y,x=divmod(p,w);n+=1;xs.append(x);ys.append(y)
            for q in ((p-1 if x else -1),(p+1 if x<w-1 else -1),p-w,p+w):
                if 0<=q<w*h and occupied[q]:occupied[q]=0;pending.append(q)
        if n>500:result.append((n,(min(xs),min(ys),max(xs)+1,max(ys)+1)))
    return result


class GroupAFrames(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        global ART, SOURCE_UI
        SOURCE_UI, ART = native_art_context()
        cls.paths={c:frames(c) for c in COUNTS}
        cls.static={c:rgba(ART/f'icon/icon_{c}.png') for c in COUNTS}

    def f(self,card,index):return rgba(self.paths[card][index])

    def assert_native_visible_patch(self,current,source):
        # 原 PNG 以254 alpha盖在另一角色/设备上会有1–2阶合法混色；
        # 检验原主体实心纸面/墨边，透明区隐藏RGB不属于可见轮廓。
        for expected,actual in zip(source.getdata(),current.getdata()):
            if expected[3]>230:
                self.assertGreater(actual[3],230)
                self.assertLessEqual(max(abs(a-b) for a,b in zip(actual[:3],expected[:3])),2)

    def test_native_original_start_and_stable_terminal(self):
        for card,count in COUNTS.items():
            with self.subTest(card=card):
                original=self.static[card]
                hashes=[]
                for i,p in enumerate(self.paths[card]):
                    im=rgba(p)
                    self.assertEqual(im.size,original.size)
                    hashes.append(hashlib.sha256(im.tobytes()).hexdigest())
                    if i<=3:self.assertEqual(im.tobytes(),original.tobytes())
                self.assertGreaterEqual(len(set(hashes)),25)
                self.assertEqual(hashes[-1],hashes[-2])
                self.assertEqual(hashes[-1],hashes[-3])
                if card=='tuisong':self.assertEqual(hashes[-1],hashes[0])
                else:self.assertNotEqual(hashes[-1],hashes[0])

    def test_fixed_equipment_and_outer_silhouettes(self):
        fixed={
          'touliu':[(411,511,655,737),(411,391,771,494)],
          'xinxijianfang':[(268,839,488,1078),(794,846,963,1030),(545,72,715,357)],
          'baiyibutie':[(594,60,1065,245),(400,795,495,900),(443,975,498,1020),(248,1069,366,1137)],
          'jiaolv':[(181,514,395,724),(960,272,1075,889)],
          'shanzhai':[(285,201,674,356)],
          'liebian':[(307,169,966,807)],
          'tuisong':[(434,1060,806,1158)],
        }
        for card,boxes in fixed.items():
            for i in range(4,COUNTS[card]):
                for box in boxes:
                    with self.subTest(card=card,frame=i,box=box):
                        self.assertEqual(self.f(card,i).crop(box).tobytes(),self.static[card].crop(box).tobytes())
        # 旋涡原有的不透明本体保持原像素；透明轮廓外允许新用户真实冒出。
        box=(420,485,801,696)
        source=self.static['liulianghe'].crop(box)
        for i in range(4,COUNTS['liulianghe']):
            for original,current in zip(source.getdata(),self.f('liulianghe',i).crop(box).getdata()):
                if original[3]>230:self.assertEqual(current,original)

    def test_touliu_payment_precedes_arriving_users(self):
        old=self.static['touliu']
        # 第一轮投币期间没有新用户；喇叭与窗口保留，金币区已经实质变化。
        self.assertEqual(self.f('touliu',17).crop((814,807,1240,1190)).tobytes(),old.crop((814,807,1240,1190)).tobytes())
        self.assertGreater(changed(self.f('touliu',17),old,(35,450,350,786)),20000)
        # 四个新人严格取本牌原人，终态保留同一原纸色、头身比例和完整脸部。
        terminal=self.f('touliu',71)
        mapping=[((1120,610),(1095,595)),((1071,820),(1120,842)),
                 ((903,879),(1088,1056)),((1120,610),(840,750))]
        for source,target in mapping:
            sx,sy=source;tx,ty=target
            with self.subTest(native_new_user=target):
                self.assert_native_visible_patch(terminal.crop((tx-18,ty-18,tx+18,ty+18)),
                                                 old.crop((sx-18,sy-18,sx+18,sy+18)))
        # 底部新人双脚在画内结束，不能贴着活动域或画布边缘被截平。
        self.assertEqual(terminal.getchannel('A').crop((730,1222,1245,1254)).getextrema(),(0,0))

    def test_touliu_slot_fits_unscaled_native_coin_and_no_cut_limb_sampling(self):
        source=self.static['touliu']
        coin_y=[y for y in range(440,800) if source.getpixel((170,y))[3]>230]
        slot_y=[y for y in range(480,885) if source.getpixel((363,y))[:3]==(42,33,22)]
        self.assertGreater(max(slot_y)-min(slot_y),max(coin_y)-min(coin_y)+8)
        # 原有三人逻辑聚拢，完整原跑姿像素平移，不能以硬切半肢换取摆动。
        terminal=self.f('touliu',71)
        for source_center,target in (((1120,610),(900,610)),((1071,820),(934,842)),((903,879),(820,1027))):
            sx,sy=source_center;tx,ty=target
            self.assertEqual(terminal.crop((tx-18,ty-18,tx+18,ty+18)).tobytes(),
                             source.crop((sx-18,sy-18,sx+18,sy+18)).tobytes())
        # 四肢完整原稿，末端轮廓也应出现在终态，不在局部矩形处消失。
        for x,y in ((1095,595),(1120,842),(1088,1056),(840,750)):
            alpha=terminal.getchannel('A').crop((x-65,y+25,x+75,y+150))
            self.assertGreater(sum(a>230 for a in alpha.getdata()),1000)

    def test_subsidy_original_cone_collapses_into_one_low_wide_heap(self):
        old=self.static['baiyibutie'];terminal=self.f('baiyibutie',47)
        # Track a real original yen face, preserving all native RGBA pixels as the same mountain descends.
        patch=old.crop((615,480,654,530)).tobytes();positions=[]
        for i in (4,8,12,16):
            current=self.f('baiyibutie',i)
            matches=[dy for dy in range(0,351) if current.crop((615,480+dy,654,530+dy)).tobytes()==patch]
            self.assertEqual(len(matches),1)
            positions.append(matches[0])
        self.assertEqual(positions,sorted(positions))
        self.assertGreater(positions[-1]-positions[0],150)
        # The whole high cone is gone; no isolated coin stream can freeze above the ground heap.
        self.assertEqual(terminal.getchannel('A').crop((320,435,1010,730)).getextrema(),(0,0))
        # A single broad, grounded heap remains and spans both sides of the original user.
        for box in ((75,1050,290,1210),(600,940,920,1210),(960,1050,1175,1210)):
            crop=terminal.crop(box)
            gold=sum(a>180 and r>190 and g>150 and b<185 for r,g,b,a in crop.getdata())
            self.assertGreater(gold,3000)
        self.assertEqual(terminal.getchannel('A').crop((0,1225,1254,1254)).getextrema(),(0,0))
        # Adjacent coins no longer leave yellow material inside the newly empty pinching hand.
        for r,g,b,a in terminal.crop((560,260,805,430)).getdata():
            self.assertFalse(a>32 and r>160 and g>125 and b<180 and r-b>.33*(r-29)+5)
        # Neither the user's face, body paper nor the bag's front face is redrawn during collapse.
        for i in range(4,48):
            current=self.f('baiyibutie',i)
            for box in ((400,795,495,900),(443,975,498,1020),(248,1069,366,1137)):
                self.assertEqual(current.crop(box).tobytes(),old.crop(box).tobytes())
        # The empty space above the heap grows continuously; the old three routes never replenish.
        counts=[]
        for i in (8,14,20,26,32,38,47):
            counts.append(sum(a>180 and r>190 and g>150 and b<185
                for r,g,b,a in self.f('baiyibutie',i).crop((350,435,1010,730)).getdata()))
        self.assertEqual(counts,sorted(counts,reverse=True))
        self.assertEqual(counts[-1],0)

    def test_vortex_conical_stream_preserves_original_people_and_full_new_heads(self):
        old=self.static['liulianghe'];terminal=self.f('liulianghe',83)
        # 首动只沿原锥形射线微移，十个原人没有被瞬间替换成规则矩形队列。
        seeds=((674,800),(524,829),(851,879),(471,950),(657,976),
               (798,1007),(356,1090),(741,1106),(587,1155),(967,1117))
        first=((674,803),(520,832),(854,882),(468,953),(657,979),
               (799,1010),(353,1093),(742,1109),(586,1158),(969,1120))
        for (sx,sy),(x,y) in zip(seeds,first):
            self.assert_native_visible_patch(self.f('liulianghe',4).crop((x-10,y-10,x+10,y+10)),
                                             old.crop((sx-10,sy-10,sx+10,sy+10)))
        # 0.5秒原用户向下30px、向外35px，保持原锥形方向和原脸纸色/墨迹。
        self.assert_native_visible_patch(self.f('liulianghe',6).crop((479,849,499,869)),
                                         old.crop((514,819,534,839)))
        self.assertGreater(changed(self.f('liulianghe',6),old,(600,766,750,900)),1500)
        # 新人来自本牌原人：连续帧从真实出口下落20px，并随深度向外展开。
        for i,x,y in ((11,673,830),(12,668,850)):
            self.assert_native_visible_patch(self.f('liulianghe',i).crop((x-10,y-10,x+10,y+10)),
                                             old.crop((647,966,667,986)))
        # 接续发出期间每个检查时刻出口下方都有头身，不能出现旧人清空后再起新批。
        for i in range(6,61,3):
            alpha=self.f('liulianghe',i).getchannel('A').crop((575,774,780,950))
            self.assertGreater(sum(a>230 for a in alpha.getdata()),1500)
            self.assertGreater(changed(self.f('liulianghe',i),self.f('liulianghe',i+3),
                                       (605,766,755,890)),500)
        # 所有十个原人保留，十四个新人沿错落锥形补出，24个完整原脸均可读。
        original_targets=((674,1010),(418,920),(970,999),(430,1000),(650,1096),
                          (846,1127),(330,1122),(745,1130),(581,1188),(976,1130))
        new_targets=((4,574,1033),(2,765,1044),(5,1110,1130),(1,466,1129),
                     (1,805,957),(3,512,963),(2,1075,1047),(6,341,987),
                     (7,878,1031),(5,880,886),(1,674,920),(3,567,874),
                     (5,770,870),(6,674,815))
        targets=tuple((i,x,y) for i,(x,y) in enumerate(original_targets))+new_targets
        self.assertEqual(len(targets),24)
        for i,(index,x,y) in enumerate(targets):
            sx,sy=seeds[index]
            with self.subTest(native_user=i):
                self.assert_native_visible_patch(terminal.crop((x-10,y-10,x+10,y+10)),
                                                 old.crop((sx-10,sy-10,sx+10,sy+10)))
                # 同一原生头部上方轮廓保留，不能被共用水平出口线削平。
                source_head=old.crop((sx-20,sy-27,sx+20,sy-10))
                current_head=terminal.crop((x-20,y-27,x+20,y-10))
                self.assert_native_visible_patch(current_head,source_head)

    def test_vortex_cone_keeps_original_density_and_widens_downward(self):
        old=self.static['liulianghe']
        area=lambda im,box:sum(a>230 for a in im.getchannel('A').crop(box).getdata())
        cone=(140,774,1248,1254);core=(540,930,820,1180)
        original_area=area(old,cone);original_core=area(old,core)
        # 曾有13～25帧旧人先清空、只余一条空心细流；现在原锥体持续保留并增密。
        for i in range(13,26):
            with self.subTest(cone_frame=i):
                current=self.f('liulianghe',i)
                self.assertGreaterEqual(area(current,cone),original_area)
                self.assertGreaterEqual(area(current,core),int(original_core*.95))
        terminal=self.f('liulianghe',83)
        def paper_width(y0,y1):
            xs=[]
            for y in range(y0,y1):
                for x in range(140,1248):
                    r,g,b,a=terminal.getpixel((x,y))
                    if a>230 and min(r,g,b)>180:xs.append(x)
            return max(xs)-min(xs)
        upper=paper_width(774,875);middle=paper_width(875,1035);lower=paper_width(1035,1254)
        self.assertLess(upper,middle)
        self.assertLess(middle,lower)
        self.assertGreater(lower,upper*2)
        self.assertGreater(area(terminal,cone),original_area*1.8)
        # 原/native全身留在画布内，终态的手脚不能贴活动域或底边截平。
        for box in ((0,1249,1254,1254),(1248,739,1254,1254)):
            self.assertEqual(terminal.getchannel('A').crop(box).getextrema(),(0,0))
        # 原PNG左侧透明背景有27个alpha=1墨点；固定区域应精确保留，不能误当裁切人物。
        self.assertEqual(terminal.crop((0,739,140,1254)).tobytes(),
                         old.crop((0,739,140,1254)).tobytes())

    def test_vortex_native_start_complete_terminal_and_fixed_vortex(self):
        old=self.static['liulianghe']
        self.assertEqual(COUNTS['liulianghe'],84)
        for i in range(4):self.assertEqual(self.f('liulianghe',i).tobytes(),old.tobytes())
        terminal=self.f('liulianghe',83)
        for i in (81,82):self.assertEqual(self.f('liulianghe',i).tobytes(),terminal.tobytes())
        self.assertEqual(terminal.size,old.size)
        # 既有旋风本体的原实心像素逐帧不动，不能出现用户形状绿洞。
        box=(420,485,801,696)
        source=old.crop(box)
        for i in range(4,84):
            for original,current in zip(source.getdata(),self.f('liulianghe',i).crop(box).getdata()):
                if original[3]>230:self.assertEqual(current,original)

    def test_push_only_three_existing_native_windows_bounce_with_fixed_phone(self):
        old=self.static['tuisong']
        crosses=((670,165),(950,295),(1115,485))
        shifts=[]
        for i in (14,21,28,35,42):
            current=self.f('tuisong',i)
            matched=[]
            for x,y in crosses:
                source=old.crop((x-20,y-20,x+20,y+20)).tobytes()
                offsets=[dy for dy in range(-90,91) if current.crop((x-20,y-20+dy,x+20,y+20+dy)).tobytes()==source]
                self.assertEqual(len(offsets),1)
                matched.append(offsets[0])
            # 三个原关闭按钮同时同幅移动，没有第四/第五个新增窗口。
            self.assertEqual(len(set(matched)),1)
            shifts.append(matched[0])
            self.assertEqual(current.crop((434,1060,806,1158)).tobytes(),old.crop((434,1060,806,1158)).tobytes())
        self.assertGreater(max(shifts)-min(shifts),70)
        self.assertEqual(self.f('tuisong',59).tobytes(),old.tobytes())

    def test_vortex_repaired_rings_join_original_stripes_without_holes(self):
        terminal=self.f('liulianghe',55)
        profiles=[]
        for x in (704,708,712,716,720,724):
            spans=[];start=None
            for y in range(220,340):
                r,g,b,a=terminal.getpixel((x,y));paper=a>230 and min(r,g)>200 and b>175
                if paper and start is None:start=y
                if start is not None and not paper:spans.append((start,y));start=None
            self.assertEqual(len(spans),3)
            profiles.append(spans)
        for left,right in zip(profiles,profiles[1:]):
            for a,b in zip(left,right):
                self.assertLessEqual(abs(a[0]-b[0]),2)
                self.assertLessEqual(abs(a[1]-b[1]),2)
        for x in range(695,730):
            self.assertGreater(terminal.getpixel((x,270))[3],240)

    def test_new_printed_sheets_have_four_closed_edges(self):
        terminal=self.f('shanzhai',61)
        # 三张新纸向三个方向落位，每张的右边、左边、上边、下边均有实心墨线。
        for dx,dy in ((-260,102),(-105,285),(108,280)):
            for x,y in ((666,699),(639,775),(848,874),(911,775)):
                box=(x+dx-16,y+dy-16,x+dx+17,y+dy+17)
                ink=sum(1 for r,g,b,a in terminal.crop(box).getdata() if a>220 and max(r,g,b)<100)
                with self.subTest(sheet=(dx,dy),edge=(x,y)):
                    self.assertGreater(ink,25)
        # 打印首轮时，后两张的终态位置尚未出现完整纸。
        self.assertGreater(changed(self.f('shanzhai',16),terminal,(535,960,1092,1206)),5000)

    def test_second_fission_produces_four_complete_square_cards(self):
        terminal=self.f('liebian',61)
        comps=opaque_components(terminal,(211,809,1120,1207))
        cards=[(n,box) for n,box in comps if n>12000]
        self.assertEqual(len(cards),4)
        for n,(x0,y0,x1,y1) in cards:
            width,height=x1-x0,y1-y0
            self.assertGreater(width,175);self.assertGreater(height,175)
            self.assertLess(abs(width-height),25)
            self.assertGreater(x0,1);self.assertLess(x1,908)
        # 断口必须附在纸张内：不能有独立于两组纸卡的细长竖墨线。
        for i in range(20,32):
            for n,(x0,y0,x1,y1) in opaque_components(self.f('liebian',i),(211,809,1120,1207)):
                with self.subTest(frame=i,component=(x0,y0,x1,y1)):
                    self.assertGreater(x1-x0,65)
        # 子卡复制时不能把固定分叉箭头末梢采入，一起带到纸卡上方。
        for box in ((342,887,356,889),(524,887,537,889)):
            self.assertEqual(self.f('liebian',31).getchannel('A').crop(box).getextrema(),(0,0))

    def test_corrected_static_sources_have_no_keyboard_or_price_arrow(self):
        phone=self.static['tuisong'];ad=self.static['touliu']
        self.assertEqual(phone.getchannel('A').crop((220,1010,361,1163)).getextrema(),(0,0))
        self.assertEqual(ad.getchannel('A').crop((825,541,997,790)).getextrema(),(0,0))
        # 手机的独立竖向设备完整，底端与屏幕都可见；不是被通知遮住的旧电脑。
        self.assertGreater(phone.getpixel((630,1135))[3],230)
        # 文凭的边框、行线、盖章三个视觉部分都有可见墨线。
        machine=self.static['jiaolv']
        for box in ((557,873,593,927),(600,910,742,928),(759,909,802,946)):
            self.assertGreater(sum(1 for r,g,b,a in machine.crop(box).getdata() if a>220 and max(r,g,b)<100),30)


if __name__=='__main__':unittest.main()
