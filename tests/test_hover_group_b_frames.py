# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
"""PNG 实际像素回归：设备/脸不漂移、前景接触与素材完整性。"""
import json
import os
import unittest
import math
from functools import lru_cache
from pathlib import Path
from PIL import Image, ImageChops
from hover_source_archive import native_art_context

ROOT=Path(__file__).resolve().parents[1]
ART=ROOT/'assets/art'
SOURCE_UI=ROOT/'data/ui.json'
COUNTS={'chunwan':36,'banxiaoshi':42,'tuanzhang':48,'xufei':54,
        'dujiaoshou':42,'guomin':42,'shangshi':42}


@lru_cache(maxsize=24)
def source(card):
    return Image.open(ART/f'icon/icon_{card}.png').convert('RGBA')


@lru_cache(maxsize=24)
def frame(card,index):
    if os.environ.get('CARD_HOVER_CANDIDATES')=='1':
        path=ROOT/f'build/art_generation/native_remaining/{card}/frames/{index:03d}.png'
        return Image.open(path).convert('RGBA')
    config=json.loads(SOURCE_UI.read_text())['art']['hover']['cards'][card]
    files=config.get('files',[])
    if len(files)!=COUNTS[card]:
        raise AssertionError(f'{card} 正式完整帧数量不同：{len(files)} / {COUNTS[card]}')
    return Image.open(ART/files[index]).convert('RGBA')


def keys(card):
    n=COUNTS[card]
    return sorted(set((0,4,n//4,n//2,3*n//4,n-2,n-1)))


def pixels(image):
    # Pillow 13 renamed this API; both forms expose native pixel tuples and
    # keep the regression runnable with the project's existing Pillow only.
    return getattr(image,'get_flattened_data',image.getdata)()


class NativeProductionLegendaryFrames(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        global ART, SOURCE_UI
        SOURCE_UI, ART = native_art_context()
        source.cache_clear()
        frame.cache_clear()

    def equal_region(self,card,index,box):
        self.assertEqual(frame(card,index).crop(box).tobytes(),source(card).crop(box).tobytes(),
                         f'{card} 帧 {index} 原位固定区域改变：{box}')

    def test_first_hold_final_pose_and_native_canvas(self):
        for card,count in COUNTS.items():
            with self.subTest(card=card):
                original=source(card)
                for i in (0,1,2,3,count-1):
                    self.assertEqual(frame(card,i).tobytes(),original.tobytes())
                for i in keys(card):
                    self.assertEqual(frame(card,i).size,original.size)
                    self.assertEqual(frame(card,i).mode,'RGBA')
                changed={frame(card,i).tobytes() for i in keys(card)[1:-1]}
                self.assertGreater(len(changed),2,f'{card} 没有足够的真实相邻姿势')

    def test_chunwan_native_rim_knot_television_stay_fixed(self):
        boxes=((598,259,649,316),(306,575,322,731),(752,591,772,710),
               (476,888,629,914),(956,486,1035,904),(1069,509,1104,842),
               (966,982,1029,1042))
        for i in keys('chunwan'):
            for box in boxes:self.equal_region('chunwan',i,box)

    def test_banxiaoshi_complete_load_and_wheels_vibrate_together(self):
        tops=[];bottoms=[];areas=[]
        for i in range(5,35):
            a=frame('banxiaoshi',i)
            # The cargo top and wheels are independent observations of one
            # complete rig. Both must move visibly, without cropping the load.
            cargo=a.crop((620,20,1000,600)).getchannel('A').point(lambda v:255 if v>200 else 0)
            wheels=a.crop((330,990,800,1214)).getchannel('A').point(lambda v:255 if v>200 else 0)
            tops.append(cargo.getbbox()[1]+20)
            bottoms.append(wheels.getbbox()[3]-1+990)
            areas.append(sum(a.crop((330,20,1000,1214)).getchannel('A').histogram()[201:]))
        self.assertGreaterEqual(max(tops)-min(tops),45)
        self.assertGreaterEqual(max(bottoms)-min(bottoms),45)
        self.assertLess(max(areas)/min(areas),1.035,'整车颠簸丢失了货物或车轮')
        self.assertGreater(min(tops),35)
        self.assertLess(max(bottoms),1205)

    def test_banxiaoshi_binding_stays_closed_and_tail_points_right(self):
        native=source('banxiaoshi')
        for i in (8,11,18,29):
            a=frame('banxiaoshi',i)
            # The strap's narrow paper channel remains surrounded by two black
            # edges at its moving location, rather than tearing under the load.
            found=False
            for y in range(400,491):
                row=list(pixels(a.crop((810,y,875,y+1))))
                ink=[x for x,p in enumerate(row) if max(p[:3])<90 and p[3]>235]
                if len(ink)<15:continue
                inside=[x for x,p in enumerate(row) if min(p[:3])>170 and p[3]>235 and
                        min(ink)<x<max(ink)]
                if 1<=len(inside)<=9:found=True;break
            self.assertTrue(found,(i,'完整绑带中间没有原纸色窄缝'))
            tail=a.crop((1010,790,1210,1130))
            self.assertGreater(sum(max(p[:3])<80 and p[3]>240 for p in pixels(tail)),80)
            self.assertEqual(a.crop((160,760,270,920)).tobytes(),
                             native.crop((160,760,270,920)).tobytes())

    def test_tuanzhang_phone_and_all_foreground_eggs_stay_fixed(self):
        boxes=((363,283,463,309),(709,590,737,652),
               (606,957,660,995),(752,972,811,1017),(886,1002,949,1030),
               (689,883,734,917),(951,920,998,956),(721,1083,788,1120))
        for i in keys('tuanzhang')+[33,35,38]:
            for box in boxes:self.equal_region('tuanzhang',i,box)

    def test_tuanzhang_three_native_whole_people_jump_then_egg_bounces(self):
        # Faces and every opaque foot pixel retain their native values at the
        # three sequential jump peaks; translating heads alone cannot pass.
        for i,dy,face,feet in ((10,-45,(480,617,528,655),(470,723,548,753)),
                              (20,-47,(417,770,463,808),(395,867,480,901)),
                              (29,-45,(570,754,618,795),(552,850,641,884))):
            target=(face[0],face[1]+dy,face[2],face[3]+dy)
            self.assertEqual(frame('tuanzhang',i).crop(target).tobytes(),
                             source('tuanzhang').crop(face).tobytes())
            a=source('tuanzhang').crop(feet);b=frame('tuanzhang',i).crop(
                (feet[0],feet[1]+dy,feet[2],feet[3]+dy))
            core=[q for p,q in zip(pixels(a),pixels(b)) if max(p[:3])<80 and p[3]>245]
            self.assertGreater(len(core),60)
            self.assertTrue(all(max(q[:3])<90 for q in core),(i,'跳起的脚被裁断'))
        original=source('tuanzhang').crop((814,849,885,893)).tobytes()
        self.assertNotEqual(frame('tuanzhang',36).crop((814,849,885,893)).tobytes(),original)
        self.equal_region('tuanzhang',40,(814,849,885,893))
        for i in (35,36,38):
            for box in ((476,617,528,655),(417,770,463,808),(570,754,618,795)):
                self.equal_region('tuanzhang',i,box)

    def test_xufei_door_static_wallet_attempt_has_one_direction(self):
        for i in keys('xufei'):
            for box in ((1080,213,1205,385),(1050,417,1126,483)):
                self.equal_region('xufei',i,box)
        # First trial reaches right/up. Native stitching in the wallet's upper
        # edge follows the same translation; it cannot be a drifting whole card.
        original=source('xufei').crop((525,547,560,565))
        trial=frame('xufei',18).crop((583,501,618,519))
        self.assertEqual(trial.tobytes(),original.tobytes())
        self.equal_region('xufei',40,(625,741,690,770))

    def test_dujiaoshou_paper_body_large_pie_and_slice_faces_remain_complete(self):
        for i in keys('dujiaoshou'):
            for box in ((674,408,899,515),(479,598,631,721),(655,483,676,651),
                        (325,1064,470,1125),(533,1114,639,1139),(257,921,422,948)):
                self.equal_region('dujiaoshou',i,box)
        for i in (21,31,36):
            self.equal_region('dujiaoshou',i,(703,675,875,885))
        # All three native slice faces move together. The gold right side must
        # not be omitted by a cream-only selection.
        for i in (21,22):
            moved=frame('dujiaoshou',i)
            for x,y in ((835,992),(791,1031),(914,1075),(967,1023),(995,975)):
                a=source('dujiaoshou').getpixel((x,y));b=moved.getpixel((x+80,y+18))
                self.assertGreater(b[3],235,(i,x,y,'切块表面被裁空'))
                self.assertLessEqual(max(abs(a[k]-b[k]) for k in range(3)),3,
                                     (i,x,y,'移动切块的原色或墨线改变'))

    def test_guomin_phone_vibrates_and_three_native_people_jump(self):
        box=(584,541,694,626);native=source('guomin').crop(box).tobytes();positions=[];translations={}
        for i in (8,10,13,17,19,23,27,30):
            matches=[]
            for dx in range(-12,13):
                for dy in range(-5,6):
                    moved=(box[0]+dx,box[1]+dy,box[2]+dx,box[3]+dy)
                    if frame('guomin',i).crop(moved).tobytes()==native:matches.append((dx,dy))
            self.assertEqual(len(matches),1,(i,'手机内原图不能作为完整物体定位'))
            positions.append(matches[0][0])
            translations[i]=matches[0]
        self.assertGreaterEqual(max(positions)-min(positions),20)
        for i,dy,face,feet in ((10,-52,(245,790,322,845),(191,1000,346,1050)),
                              (19,-62,(461,924,548,983),(396,1108,570,1150)),
                              (27,-56,(947,842,1034,909),(920,1040,1095,1090))):
            a=source('guomin').crop(face);b=frame('guomin',i).crop(
                (face[0],face[1]+dy,face[2],face[3]+dy))
            diff=ImageChops.difference(a.convert('RGB'),b.convert('RGB'))
            self.assertLessEqual(max(high for low,high in diff.getextrema()),3,(i,'原脸被重画'))
            a=source('guomin').crop(feet);b=frame('guomin',i).crop(
                (feet[0],feet[1]+dy,feet[2],feet[3]+dy))
            core=[q for p,q in zip(pixels(a),pixels(b)) if max(p[:3])<80 and p[3]>245]
            self.assertTrue(all(max(q[:3])<95 and q[3]>235 for q in core),(i,'原腿脚被裁断'))
        dx,dy=translations[19]
        empty=frame('guomin',19).crop((580+dx,980+dy,618+dx,1010+dy))
        self.assertTrue(all(min(p[:3])>180 and p[3]>240 for p in pixels(empty)),
                        '跳起后手机纸面仍有旧手臂弧线或裂口')

    def test_shangshi_fixed_hanger_and_strike_before_bell_motion(self):
        for i in keys('shangshi'):
            self.equal_region('shangshi',i,(603,184,651,248))
        for i in (4,7,10):
            self.equal_region('shangshi',i,(624,475,790,610))
            self.equal_region('shangshi',i,(633,976,738,1077))
        self.assertNotEqual(frame('shangshi',12).crop((624,475,790,610)).tobytes(),
                            source('shangshi').crop((624,475,790,610)).tobytes())
        # The small third white section in the handle must move with the whole
        # mallet. Omitting it leaves a literal transparent break in the handle.
        for i in (7,12,15):
            t=i/12
            smooth=lambda u:(max(0,min(1,u))**2)*(3-2*max(0,min(1,u)))
            wind=-.165*smooth((t-.30)/.32)*(1-smooth((t-.64)/.23))
            u=(t-.88)/.55
            recoil=-.062*math.sin(math.pi*u)**2 if 0<u<1 else 0
            c,s=math.cos(wind+recoil),math.sin(wind+recoil)
            for x,y in ((240,950),(237,955),(245,954)):
                q=(round(162+c*(x-162)-s*(y-1079)),round(1079+s*(x-162)+c*(y-1079)))
                p=frame('shangshi',i).getpixel(q)
                self.assertGreater(p[3],235,(i,q,'槌柄中央仍有透明断口'))
        for i in (7,12,15):
            a=frame('shangshi',i)
            for y in range(735,801):
                row=pixels(a.crop((375,y,445,y+1)))
                core=sum(max(p[:3])<90 and p[3]>240 for p in row)
                self.assertGreaterEqual(core,13,(i,y,'钟壁墨边中途断开'))
        self.assertLessEqual(max(frame('shangshi',7).getpixel((416,760))[:3]),15,
                             '补全钟壁的墨色比原轮廓明显变浅')


if __name__=='__main__':unittest.main()
