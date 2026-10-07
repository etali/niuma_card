# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
"""攻击/增益牌整帧回归，读取实际 PNG，不导入绘制蒙版。"""
import hashlib
import json
import os
import unittest
from pathlib import Path
from PIL import Image, ImageDraw
from hover_source_archive import native_art_context

ROOT=Path(__file__).resolve().parents[1]
ART=ROOT/'assets/art'
COUNTS={'butie':49,'heigongguan':49,'zuokong':43,'eryouxuan':37,
        'chaping':25,'yinqing996':49,'resou':49,'jiangjia':37}
LOOPS={'resou','jiangjia'}


class GroupCFramesTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        global ART
        source_ui, ART = native_art_context()
        cls.entries=json.loads(source_ui.read_text())['art']['hover']['cards']

    def original(self,card):
        return Image.open(ART/f'icon/icon_{card}.png').convert('RGBA')

    def frame(self,card,index):
        if os.environ.get('CARD_HOVER_CANDIDATES')=='1':
            return Image.open(ROOT/f'build/art_generation/native_remaining/{card}/frames/{index:03d}.png').convert('RGBA')
        entry=self.entries[card]
        if 'files' in entry:
            return Image.open(ART/entry['files'][index]).convert('RGBA')
        raise AssertionError(f'{card} 高清制作归档缺少完整 PNG 路径')

    def test_native_start_end_and_real_poses(self):
        for card,count in COUNTS.items():
            with self.subTest(card=card):
                original=self.original(card)
                for i in range(4):self.assertEqual(self.frame(card,i).tobytes(),original.tobytes())
                hashes=set()
                for i in range(count):
                    frame=self.frame(card,i)
                    self.assertEqual(frame.size,original.size)
                    self.assertEqual(frame.mode,'RGBA')
                    hashes.add(hashlib.sha256(frame.tobytes()).hexdigest())
                self.assertGreaterEqual(len(hashes),12)
                final=self.frame(card,count-1)
                if card in LOOPS:
                    self.assertEqual(final.tobytes(),original.tobytes())
                    self.assertEqual(self.frame(card,count-2).tobytes(),original.tobytes())
                else:
                    self.assertNotEqual(final.tobytes(),original.tobytes())
                    self.assertEqual(final.tobytes(),self.frame(card,count-3).tobytes())

    def test_fixed_reference_objects_do_not_drift(self):
        regions={
            'butie':((64,208,499,509),(781,208,1191,509)),
            'heigongguan':((19,402,450,670),(68,721,399,961)),
            'zuokong':((687,330,964,465),(884,224,932,281)),
            'eryouxuan':((118,216,552,601),(724,218,1154,513),(188,605,499,1043)),
            'chaping':((506,974,605,1040),(558,706,600,746)),
            'yinqing996':((120,970,988,1085),(726,639,827,731),(925,625,1054,719)),
            'resou':((338,783,792,1155),(899,650,920,660)),
            'jiangjia':((185,610,412,710),(198,842,313,937)),
        }
        for card,boxes in regions.items():
            original=self.original(card)
            for i in range(4,COUNTS[card]):
                for box in boxes:
                    with self.subTest(card=card,frame=i,box=box):
                        self.assertEqual(self.frame(card,i).crop(box).tobytes(),original.crop(box).tobytes())

    def test_report_paper_is_complete_when_coin_rolls_away(self):
        # 原顶部钱堆的后面仍有报告奶油纸面，滚开后不能出现绿色透明洞。
        final=self.frame('zuokong',42)
        for p in ((627,825),(638,854),(648,885)):
            r,g,b,a=final.getpixel(p)
            self.assertGreater(a,240)
            self.assertGreater(r,210)
        # 纸面的上半文字与下降折线仍然一像素不移。
        original=self.original('zuokong')
        self.assertEqual(final.crop((686,326,920,465)).tobytes(),original.crop((686,326,920,465)).tobytes())

    def test_two_scissor_handles_keep_enclosed_holes_and_gold_necks(self):
        for i in (4,9,12,18,36):
            frame=self.frame('eryouxuan',i)
            # 两个握柄金色实体足够厚；孔不是用缺口破开外边缘。
            for box in ((677,524,847,687),(671,703,847,838)):
                gold=sum(1 for r,g,b,a in frame.crop(box).get_flattened_data() if a>240 and r>220 and 175<g<240 and b<170)
                self.assertGreater(gold,2600)
            # 两片完整刀面均存在，并非只有空墨线。
            cream=sum(1 for r,g,b,a in frame.crop((853,710,1051,882)).get_flattened_data() if a>240 and min(r,g,b)>215)
            self.assertGreater(cream,3800)
        # 左边道路永远连通且与原图一致。
        orig=self.original('eryouxuan')
        self.assertEqual(self.frame('eryouxuan',36).crop((188,605,499,1043)).tobytes(),orig.crop((188,605,499,1043)).tobytes())

    def test_bad_reviews_strike_in_order_before_new_cracks(self):
        # 每个新增表面裂纹在其对应气泡接触前后出现，原手机裂纹保持。
        checks=((4,8,(554,592,611,665)),(8,12,(776,570,818,655)),(12,17,(697,849,744,922)))
        for before,after,box in checks:
            a=self.frame('chaping',before);b=self.frame('chaping',after)
            self.assertNotEqual(a.crop(box).tobytes(),b.crop(box).tobytes())
        for i in range(4,25):
            # 手机中心仍是实心屏幕，增加的是裂纹，没有被镂空。
            self.assertGreater(self.frame('chaping',i).getpixel((647,710))[3],240)

    def test_report_loses_five_full_coins_without_hollow_old_coin(self):
        original=self.original('zuokong');final=self.frame('zuokong',42)
        # 两枚孤立原币必须整体离开；不能只擦 ¥ 中的金色小格留下旧圆环。
        for box in ((230,579,414,746),(112,767,287,947)):
            self.assertLessEqual(final.crop(box).getchannel('A').getextrema()[1],8)
        def goldarea(im):
            return sum(1 for r,g,b,a in im.get_flattened_data() if a>240 and r>230 and g>170 and b<175)
        self.assertLess(goldarea(final),goldarea(original)*.35)
        # 留下右下币的中心、外圈和实心币面仍是唯一原稿像素。
        for point in ((710,1045),(710,1090),(750,1050)):
            self.assertEqual(final.getpixel(point),original.getpixel(point))

    def test_smoke_main_cloud_moves_in_first_second_and_mouth_is_solid(self):
        original=self.original('heigongguan');early=self.frame('heigongguan',12)
        box=(800,330,1100,500)
        changed=sum(a!=b for a,b in zip(original.crop(box).get_flattened_data(),early.crop(box).get_flattened_data()))
        self.assertGreater(changed,18000)
        final=self.frame('heigongguan',48)
        for point in ((590,850),(607,875),(553,815)):
            r,g,b,a=final.getpixel(point)
            self.assertGreater(a,240)
            self.assertGreater(r,225)
            self.assertGreater(g,180)

    def test_review_old_tail_is_removed_and_phone_contact_is_opaque(self):
        for i in (4,9,15,24):
            im=self.frame('chaping',i)
            # 原左泡尾 x230/640 的独立墨三角不能留在泡下。
            self.assertLessEqual(im.crop((215,640,250,650)).getchannel('A').getextrema()[1],8)
            # 原尾移开后，完整手机左边和屏幕承接前景泡，不能露透明裁口。
            for point in ((485,665),(520,675),(544,640),(647,710)):
                self.assertGreater(im.getpixel(point)[3],240)

    def test_trending_pushpin_tip_is_fixed_and_flame_tip_has_large_motion(self):
        a=self.frame('resou',13);b=self.frame('resou',22)
        self.assertEqual(a.crop((555,740,575,756)).tobytes(),b.crop((555,740,575,756)).tobytes())
        original=self.original('resou')
        # 火尖的原位置明显回收，且下部主体仍存在，动作不只是加粗整圈边。
        self.assertIsNone(a.crop((770,90,845,230)).getchannel('A').getbbox())
        self.assertGreater(sum(1 for p in a.crop((600,350,1000,600)).get_flattened_data() if p[3]>240),50000)
        self.assertEqual(a.crop((338,783,792,1155)).tobytes(),original.crop((338,783,792,1155)).tobytes())

    def test_engine_keeps_head_and_emits_two_complete_pages(self):
        original=self.original('yinqing996')
        for i in (8,12,24,36,48):
            frame=self.frame('yinqing996',i)
            self.assertEqual(frame.crop((452,564,608,697)).tobytes(),original.crop((452,564,608,697)).tobytes())
            # 原出纸口和轮轴均原位。
            self.assertEqual(frame.crop((940,708,995,733)).tobytes(),original.crop((940,708,995,733)).tobytes())
        # 最后两张纸各有一个清楚的勾，在交错纸上，不是一次送出一叠静态纸。
        final=self.frame('yinqing996',48)
        ink=sum(1 for r,g,b,a in final.crop((1010,787,1169,949)).get_flattened_data() if a>240 and max(r,g,b)<75)
        self.assertGreater(ink,1700)
        self.assertNotEqual(self.frame('yinqing996',20).crop((980,747,1226,1110)).tobytes(),
                            final.crop((980,747,1226,1110)).tobytes())

    def test_engine_rightward_run_plants_in_front_then_pushes_back(self):
        original=self.original('yinqing996')
        # 接触面直接取原 PNG 的透明内腔下缘；不依赖绘图代码的腿轨迹。
        cavity=original.getchannel('A').point(lambda a:255 if a<8 else 0)
        ImageDraw.floodfill(cavity,(604,474),128)
        ground={x:max(y for y in range(800,970) if cavity.getpixel((x,y))==128)
                for x in range(430,621)}
        contact_centres=[]
        for i in range(12,17):
            frame=self.frame('yinqing996',i);runs=[]
            for x,y in ground.items():
                # 只统计原透明腔中新出现的实心脚底，排除原轮圈墨线。
                touches=any(frame.getpixel((x,y-h))[3]>240 and
                            max(frame.getpixel((x,y-h))[:3])<90 and
                            original.getpixel((x,y-h))[3]<8
                            for h in range(10,18))
                if touches:
                    if runs and x-runs[-1][-1]<=2:runs[-1].append(x)
                    else:runs.append([x])
            foot=max(runs,key=len)
            self.assertGreater(len(foot),30)
            contact_centres.append((foot[0]+foot[-1])/2)
        # 向右跑的承重脚从右前落点向左后蹬，不能反过来在右移时承重。
        self.assertGreater(contact_centres[0],570)
        for before,after in zip(contact_centres,contact_centres[1:]):
            self.assertLess(after-before,-20)
            self.assertGreater(after-before,-45)

    def test_engine_left_tread_moves_up_with_rightward_push(self):
        centres=[]
        for i in (12,13,14):
            frame=self.frame('yinqing996',i);runs=[]
            for y in range(520,721):
                r,g,b,a=frame.getpixel((270,y))
                if a>240 and max(r,g,b)<80:
                    if runs and y-runs[-1][-1]<=2:runs[-1].append(y)
                    else:runs.append([y])
            centres.append([(run[0]+run[-1])/2 for run in runs if len(run)>6])
        y=min(centres[0],key=lambda p:abs(p-615))
        for next_centres in centres[1:]:
            next_y=min(next_centres,key=lambda p:abs(p-y))
            # 左轮带向上等价于轮底向左，匹配脚的后蹬；单帧位移不超过
            # 74px 胎纹间距的一半，避免视觉上误读成反向转动。
            self.assertLess(next_y-y,-15)
            self.assertGreater(next_y-y,-37)
            y=next_y

    def test_engine_rightward_fix_preserves_accepted_page_sequence(self):
        # 已验收的完整逐张出纸关键帧，不因腿和轮带反向修正而改变遮挡。
        accepted={
            8:'80d1f4432f7eddb569769b6082bb0172b64ef39cf02d83f37a276a89f5fc91c8',
            18:'59b5717ba63bf60b0eb47808877d402e2934c0cd4e379b326f50137a463db4bc',
            30:'9886bbb0d9e359e370438f3bda980d08f51de2e880a8e0dc743be082b73ba517',
            48:'20e354d19f4775ac108bb858e3d45053d66cf6e191916581b3c468daf3e25825',
        }
        for i,digest in accepted.items():
            pixels=self.frame('yinqing996',i).crop((920,716,1226,1111)).tobytes()
            self.assertEqual(hashlib.sha256(pixels).hexdigest(),digest)

    def test_subsidy_old_coin_tip_is_fully_erased(self):
        # 原右币的顶缘在 y684，活动域不能从 y692 截掉后只留下孤立黑弧。
        for i in (12,24,36,48):
            frame=self.frame('butie',i)
            self.assertEqual(frame.crop((690,677,758,693)).getchannel('A').getbbox(),None)

    def test_engine_front_ring_stays_clear_of_old_tread_ends(self):
        # 原前轮奶油环是闭合独立区域；移动横板不能侵入这圈或留下旧端头。
        original=self.original('yinqing996')
        region=Image.new('L',original.size)
        region.putdata([255 if a>220 and r>220 and g>190 and b>145 else 0
                        for r,g,b,a in original.get_flattened_data()])
        ImageDraw.floodfill(region,(165,640),128)
        points=[]
        for y in range(430,856,13):
            run=[x for x in range(130,380) if region.getpixel((x,y))==128]
            if run:points.extend(((run[-1]-5,y),(run[-1]-10,y)))
        for i in (12,24,36,48):
            frame=self.frame('yinqing996',i)
            for point in points:
                p=original.getpixel(point);q=frame.getpixel(point)
                self.assertLessEqual(max(abs(p[k]-q[k])for k in range(3)),1)
                self.assertGreater(q[3],240)
        # 第12帧旧横板 y609/786 已离开，原端头之外应是完整纸色轮带。
        frame=self.frame('yinqing996',12)
        for point in ((224,609),(241,786),(274,855)):
            r,g,b,a=frame.getpixel(point)
            self.assertGreater(r,230)
            self.assertGreater(g,215)
            self.assertGreater(a,240)

    def test_discount_feet_stay_on_ground_and_price_body_is_rigid(self):
        original=self.original('jiangjia')
        for i in range(4,34):
            frame=self.frame('jiangjia',i)
            for box in ((527,952,582,970),(910,944,970,956)):
                self.assertEqual(frame.crop(box).tobytes(),original.crop(box).tobytes())
        # 牌身仅刚性平移，正中原纸色没有额外拉伸的色块或空线。
        p=original.getpixel((704,747))
        q=self.frame('jiangjia',18).getpixel((704,769))
        self.assertLessEqual(max(abs(x-y)for x,y in zip(p,q)),2)


if __name__=='__main__':unittest.main()
