# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""第一批完整帧验收：设备不漂移、内容方向、原物体复用与实际露底。"""
import hashlib
import json
import unittest
from pathlib import Path

from PIL import Image, ImageDraw
from hover_source_archive import native_art_context

ROOT=Path(__file__).resolve().parents[1]
ART=ROOT/'assets/art'
COUNTS={'baoyue':34,'pinshaoshao':34,'shuabuting':34,'ditui':42,'waimai':34}


class HoverBatch01Test(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        global ART
        source_ui, ART = native_art_context()
        cls.hover=json.loads(source_ui.read_text())['art']['hover']

    def original(self,card):
        return Image.open(ART/f'icon/icon_{card}.png').convert('RGBA')

    def frame(self,card,index):
        return Image.open(ART/self.hover['cards'][card]['files'][index]).convert('RGBA')

    def test_native_frames_original_start_and_loop_end(self):
        self.assertEqual(self.hover['fps'],12)
        for card,count in COUNTS.items():
            with self.subTest(card=card):
                config=self.hover['cards'][card]
                original=self.original(card)
                self.assertEqual(config['frames'],count)
                self.assertEqual(len(config['files']),count)
                self.assertEqual(config['frame_size'],list(original.size))
                self.assertEqual(config['play_mode'],'once' if card=='pinshaoshao' else 'loop')
                self.assertEqual(self.frame(card,0).tobytes(),original.tobytes())
                self.assertEqual(self.frame(card,3).tobytes(),original.tobytes())
                if card!='pinshaoshao':
                    self.assertEqual(self.frame(card,count-1).tobytes(),original.tobytes())
                hashes=set()
                for filename in set(config['files']):
                    frame=Image.open(ART/filename).convert('RGBA')
                    self.assertEqual(frame.size,original.size)
                    self.assertEqual(frame.getchannel('A').getextrema()[0],0)
                    hashes.add(hashlib.sha256(frame.tobytes()).digest())
                self.assertGreaterEqual(len(hashes),24)
        self.assertEqual(self.original('baoyue').size,(1310,1201))

    def test_fixed_devices_people_and_background_pixels(self):
        # 根据实际插画选择固定对象，不使用生成工具的活动 mask 来反向定义正确性。
        regions={
            'baoyue':((0,0,1310,169),(0,986,1310,1201)),
            'pinshaoshao':((0,0,1254,168),(0,1082,1254,1254)),
            'shuabuting':((540,186,967,302),(885,376,942,574),(332,981,447,1067)),
            # 蛋托的固定边角/前壁来自实际原图，不能因内部补画改变透视形状。
            'ditui':((70,116,536,484),(184,311,478,615),(316,753,458,840),(222,890,424,1098),
                     (480,986,594,1046),(700,1025,780,1107),(1040,920,1155,996),
                     (680,1090,840,1140),(1165,810,1225,860),(479,900,570,928)),
            'waimai':((350,165,620,357),(563,345,603,370),(0,1104,1254,1254)),
        }
        for card,boxes in regions.items():
            original=self.original(card)
            for filename in set(self.hover['cards'][card]['files']):
                frame=Image.open(ART/filename).convert('RGBA')
                for box in boxes:
                    with self.subTest(card=card,frame=filename,box=box):
                        self.assertEqual(frame.crop(box).tobytes(),original.crop(box).tobytes())

    def test_scroll_content_moves_down_phone_axis(self):
        # 追踪首格右侧黑色播放三角，向下输送应同时略向左；不能向上回卷。
        centers=[]
        for i in (0,5,6):
            frame=self.frame('shuabuting',i)
            points=[]
            for y in range(375,480):
                for x in range(763,827):
                    r,g,b,a=frame.getpixel((x,y))
                    if a>240 and max(r,g,b)<65:
                        points.append((x,y))
            self.assertGreater(len(points),200)
            centers.append(tuple(sum(p[k] for p in points)/len(points) for k in (0,1)))
        self.assertGreater(centers[1][1],centers[0][1]+5)
        self.assertGreater(centers[2][1],centers[1][1]+5)
        self.assertLess(centers[2][0],centers[0][0])

    def test_egg_original_details_reach_hold_and_reveal_complete_background(self):
        original=self.original('ditui')
        held=self.frame('ditui',22)
        # 原鸡蛋内部纹理随同一枚蛋平移；没有用一枚新小蛋代替大蛋。
        for x,y in ((800,750),(870,695),(886,673)):
            before=original.getpixel((x,y))
            after=held.getpixel((x-80,y-210))
            self.assertLessEqual(max(abs(a-b) for a,b in zip(before[:3],after[:3])),2)
        # 原前蛋右侧边缘现在应露出完整后排蛋的奶油底色，没有残留旧轮廓。
        self.assertGreater(held.getpixel((983,850))[0],220)
        # 蛋托露出的金色底面与手实际触蛋的位置仍不透明。
        self.assertGreater(held.getpixel((795,918))[3],245)
        self.assertLess(max(held.getpixel((534,629))[:3]),90)
        # 拿稳区间不是快速一闪而过。
        self.assertEqual(self.frame('ditui',19).crop((550,385,900,850)).tobytes(),
                         self.frame('ditui',25).crop((550,385,900,850)).tobytes())

    def test_subscription_scissors_have_two_complete_blades(self):
        # 0.33 秒至回位前，下侧刀面一直存在且保持原厚度，不能塌成一条线。
        # 这一区域不含钱包、握柄或铆钉，白色像素来自两片金属刀面。
        for i in range(4,COUNTS['baoyue']-1):
            frame=self.frame('baoyue',i)
            metal=[]
            for y in range(610,695):
                for x in range(980,1060):
                    r,g,b,a=frame.getpixel((x,y))
                    if a>240 and min(r,g,b)>220:
                        metal.append((x,y))
            with self.subTest(frame=i):
                self.assertGreater(len(metal),650)
        # 初次开合时下刀刃中段仍是宽刀面，不是只剩上刀刃的白色区域。
        for i in (4,5,6,7):
            frame=self.frame('baoyue',i)
            column=[y for y in range(640,685)
                    if frame.getpixel((1020,y))[3]>240
                    and min(frame.getpixel((1020,y))[:3])>220]
            self.assertGreaterEqual(len(column),12)

    def test_subscription_scissors_have_solid_faces_and_connected_neck(self):
        # 用户指出的细白线：刀面左半段应只有两块完整填充，不能出现旧轮廓夹出的细缝。
        # 检查区避开铆钉、握柄与循环箭头；直接检查正式导出 PNG，不读取绘制蒙版。
        for i in range(4,COUNTS['baoyue']-1):
            roi=self.frame('baoyue',i).crop((971,560,1058,705))
            mask=Image.new('L',roi.size)
            pixels=mask.load()
            for y in range(roi.height):
                for x in range(roi.width):
                    r,g,b,a=roi.getpixel((x,y))
                    pixels[x,y]=255 if a>240 and min(r,g,b)>220 else 0
            faces=[]
            while mask.getbbox():
                x0,y0,x1,y1=mask.getbbox()
                seed=next((x,y) for y in range(y0,y1) for x in range(x0,x1)
                          if mask.getpixel((x,y))==255)
                ImageDraw.floodfill(mask,seed,128)
                area=mask.histogram()[128]
                if area>25:
                    faces.append(area)
                mask=mask.point(lambda a:0 if a==128 else a)
            with self.subTest(frame=i):
                self.assertEqual(len(faces),2)
                self.assertGreater(min(faces),500)
        # 合拢时原金色细颈保持不透明，里面不夹带另一侧握柄的黑线。
        for i in range(12,20):
            frame=self.frame('baoyue',i)
            for point in ((1092,706),(1101,714),(1103,726)):
                r,g,b,a=frame.getpixel(point)
                with self.subTest(frame=i,neck=point):
                    self.assertGreater(a,245)
                    self.assertGreater(r,230)
                    self.assertGreater(g,210)
                    self.assertGreater(b,155)
        # 原铆钉中心固定，不能在两刀刃交叠时凭空多画一圈。
        original=self.original('baoyue')
        for i in range(4,COUNTS['baoyue']-1):
            actual=self.frame('baoyue',i).getpixel((1072,678))
            self.assertEqual(actual[:3],original.getpixel((1072,678))[:3])

    def test_discount_scissors_are_larger_keep_warm_hands_and_fear_result_holds(self):
        original=self.original('pinshaoshao')
        final=self.frame('pinshaoshao',33)
        # 放大沿刀尖接触区连续发生，首帧仍为原图；手掌底色不变成亮白或荧光色。
        for before,after in (((234,692),(206,703)),((1054,906),(1080,913))):
            self.assertLessEqual(max(abs(a-b) for a,b in zip(original.getpixel(before)[:3],
                                                           final.getpixel(after)[:3])),3)
        left=(65,585,355,840);right=(935,795,1225,1035)
        def visible(im,box):
            return im.crop(box).getchannel('A').point(lambda a:255 if a>240 else 0).getbbox()
        # 直接比较正式 PNG 的实际握柄/手臂外缘，避免仅验证一个 scale 常量。
        self.assertLess(visible(final,left)[0],visible(original,left)[0]-40)
        self.assertGreater(visible(final,right)[2],visible(original,right)[2]+40)
        self.assertNotEqual(final.crop((460,470,711,666)).tobytes(),
                            original.crop((460,470,711,666)).tobytes())
        self.assertEqual(self.frame('pinshaoshao',31).tobytes(),final.tobytes())

    def test_discount_scissors_handle_holes_are_enclosed_and_not_nicked(self):
        # 真正闭合的握柄孔应与外部透明背景断开。边界有缺口时孔会连到外部，
        # 只查某个金色取样点不能发现这种问题。避开闭合时手掌合理遮住上环的阶段。
        for i in (4,17,33):
            for box in ((60,570,355,840),(935,795,1220,1045)):
                frame=self.frame('pinshaoshao',i)
                mask=frame.crop(box).getchannel('A').point(lambda a:255 if a<16 else 0)
                w,h=mask.size
                boundary=[(x,y) for x in range(w) for y in (0,h-1)]
                boundary.extend((x,y) for y in range(h) for x in (0,w-1))
                for point in boundary:
                    if mask.getpixel(point)==255:
                        ImageDraw.floodfill(mask,point,128)
                mask=mask.point(lambda a:0 if a==128 else a)
                enclosed=[]
                while mask.getbbox():
                    x0,y0,x1,y1=mask.getbbox()
                    seed=next((x,y) for y in range(y0,y1) for x in range(x0,x1)
                              if mask.getpixel((x,y))==255)
                    ImageDraw.floodfill(mask,seed,128)
                    area=mask.histogram()[128]
                    if area>50:
                        enclosed.append(area)
                    mask=mask.point(lambda a:0 if a==128 else a)
                with self.subTest(frame=i,scissors=box):
                    self.assertGreaterEqual(len(enclosed),2)
                    self.assertGreater(min(enclosed),400)
        # 用户指出的小方孔来自透明的原图像素被贴入新刀颈，此处现在应完整。
        for i in (19,25,33):
            self.assertGreater(self.frame('pinshaoshao',i).getpixel((985,895))[3],245)

    def test_delivery_stays_on_canvas_and_both_wheels_bounce_with_vehicle(self):
        original=self.original('waimai')
        def bottom(frame,x):
            return max(y for y in range(1010,1103)
                       if frame.getpixel((x,y))[3]>240 and max(frame.getpixel((x,y))[:3])<85)
        reference=[bottom(original,x) for x in (470,795)]
        shifts=[]
        for i in range(COUNTS['waimai']):
            frame=self.frame('waimai',i)
            offsets=[bottom(frame,x)-base for x,base in zip((470,795),reference)]
            self.assertLessEqual(abs(offsets[0]-offsets[1]),1)
            shifts.append(offsets[1])
            # 两轮与车身统一上下颠簸，轮毂不水平离开原位置。
            for p in ((470,995+offsets[0]),(795,1017+offsets[1])):
                self.assertLess(max(frame.getpixel(p)[:3]),85)
                self.assertGreater(frame.getpixel(p)[3],240)
            # 原 PNG 外围有极低 alpha 的生成残点，范围检查针对可见主体。
            box=frame.getchannel('A').point(lambda a:255 if a>192 else 0).getbbox()
            self.assertGreater(box[0],120)
            self.assertLess(box[2],1215)
            self.assertLess(box[3],1103)
        self.assertGreaterEqual(max(shifts)-min(shifts),18)
        self.assertEqual(shifts[-1],0)

    def test_delivery_top_bow_stays_complete_when_vehicle_bounces_up(self):
        original=self.original('waimai')
        for index,shift in ((9,-10),(26,-9)):
            moved=self.frame('waimai',index)
            # 整个原蝴蝶结顶弧向上移动，不能在旧活动域 y374 处被截平。
            for y in range(374,420):
                for x in range(444,498):
                    pixel=original.getpixel((x,y))
                    if pixel[3]>240:
                        actual=moved.getpixel((x,y+shift))
                        self.assertGreater(actual[3],235,(index,x,y,'顶弧被裁掉'))
                        self.assertLessEqual(max(abs(a-b) for a,b in zip(actual[:3],pixel[:3])),1)
            ink=[y for y in range(358,410) for x in range(444,498)
                 if moved.getpixel((x,y))[3]>240 and max(moved.getpixel((x,y))[:3])<85]
            self.assertLess(min(ink),370)

    def test_discount_scissors_keep_solid_metal_during_closing(self):
        # 右侧刀刃中段在闭合时也必须是完整刀面，旧版本这里只剩 7 像素细条。
        for i in range(4,33):
            frame=self.frame('pinshaoshao',i)
            metal=[y for y in range(797,900) if frame.getpixel((906,y))[3]>240
                   and min(frame.getpixel((906,y))[:3])>225]
            with self.subTest(frame=i):
                self.assertGreaterEqual(len(metal),15)

    def test_delivery_cord_is_one_complete_stroke(self):
        # 杆端以下只有一根完整绳，不残留旧的直绳或因矩形取样变成台阶。
        for i in range(4,33):
            frame=self.frame('waimai',i)
            for y in range(530,620):
                xs=[x for x in range(970,1080) if frame.getpixel((x,y))[3]>192]
                with self.subTest(frame=i,row=y):
                    self.assertTrue(xs)
                    self.assertGreaterEqual(len(xs),12)
                    self.assertLessEqual(xs[-1]-xs[0]+1,17)

    def test_revealed_tray_keeps_whole_front_edge_and_old_finger_is_erased(self):
        original=self.original('ditui')
        for i in (14,22,28):
            frame=self.frame('ditui',i)
            for point in ((610,959),(650,976),(700,996),(930,968),(990,940)):
                with self.subTest(frame=i,edge=point):
                    self.assertEqual(frame.getpixel(point),original.getpixel(point))
        # 手臂已经伸向鸡蛋，此时原竖起的手指位置必须是补齐的奶油背景。
        for i in (14,22):
            self.assertGreater(self.frame('ditui',i).getpixel((537,780))[0],220)

    def test_revealed_opening_is_square_in_tray_perspective_at_original_size(self):
        for i in (19,22,25):
            frame=self.frame('ditui',i)
            # 孔前两边接续原图露出的孔沿，后两边遵循同一透视。
            # 四个角与四边中段检验方孔的范围，旧圆槽不能通过。
            for point in ((605,918),(794,847),(979,908),(790,979),
                          (700,882),(887,878),(700,950),(890,943)):
                r,g,b,a=frame.getpixel(point)
                with self.subTest(frame=i,edge=point):
                    self.assertGreater(a,240)
                    self.assertLess(max(r,g,b),100)
            # 原孔宽约374；靠近左右角的内部也属于开口，不能缩成小圆槽。
            for point in ((640,915),(943,915),(790,918)):
                r,g,b,a=frame.getpixel(point)
                with self.subTest(frame=i,inside=point):
                    self.assertGreater(a,245)
                    self.assertGreater(r,195)
                    self.assertLess(r,235)
                    self.assertGreater(g,165)
                    self.assertLess(g,210)
                    self.assertLess(b,145)
            # 原圆槽的上下弧现在应是连续孔内颜色，不保留第二个圆圈。
            for box in ((710,890,840,908),(710,933,840,947)):
                data=frame.crop(box).tobytes()
                ink=sum(1 for r,g,b,a in zip(data[0::4],data[1::4],data[2::4],data[3::4])
                        if max(r,g,b)<80 and a>240)
                with self.subTest(frame=i,inside=box):
                    self.assertEqual(ink,0)

    def test_lifted_egg_keeps_entire_original_reflection_stroke(self):
        # 原长反光线有独立的完整笔画；旧内部取样把其中 518 个实心像素裁成了奶油底色。
        box=(820,630,960,750)
        source=self.original('ditui').crop(box)
        ink=Image.new('L',source.size);pixels=ink.load()
        for y in range(source.height):
            for x in range(source.width):
                r,g,b,a=source.getpixel((x,y))
                pixels[x,y]=255 if max(r,g,b)<80 and a>240 else 0
        ImageDraw.floodfill(ink,(888-box[0],672-box[1]),128)
        points=[(x,y) for y in range(source.height) for x in range(source.width)
                if ink.getpixel((x,y))==128]
        self.assertGreater(len(points),700)
        for i in (19,22,25):
            frame=self.frame('ditui',i)
            for x,y in points:
                expected=source.getpixel((x,y))[:3]
                actual=frame.getpixel((x+box[0]-80,y+box[1]-210))[:3]
                with self.subTest(frame=i,pixel=(x,y)):
                    self.assertLessEqual(max(abs(a-b) for a,b in zip(expected,actual)),3)

    def test_egg_rest_pose_is_original_before_lift_and_while_releasing(self):
        original=self.original('ditui')
        # 原静止构图的蛋壳接触边缘应在尚未拿起和已落稳时直接恢复，
        # 不能等手撤回后再多等数帧突然补线；手臂是此时唯一变化的区域。
        for i in (7,10,12,34,36,38):
            frame=self.frame('ditui',i)
            with self.subTest(frame=i):
                self.assertEqual(frame.crop((680,610,995,1040)).tobytes(),
                                 original.crop((680,610,995,1040)).tobytes())

    def test_lifted_egg_has_a_solid_round_lower_half_above_the_slot(self):
        for i in (19,22,25):
            frame=self.frame('ditui',i)
            # 旧截半蛋在这些下半区域没有蛋壳，完整卵形必须有连续奶油色实体。
            for box in ((620,740,800,790),(650,790,775,817)):
                pixels=list(frame.crop(box).getdata())
                solid=[p for p in pixels if p[3]>240 and p[0]>225 and p[1]>215 and p[2]>185]
                with self.subTest(frame=i,bottom=box):
                    self.assertGreater(len(solid),len(pixels)*.97)
            # 圆底最低处有完整墨边，已完整离开原方形蛋托。
            r,g,b,a=frame.getpixel((710,838))
            self.assertGreater(a,245)
            self.assertLess(max(r,g,b),80)
            # 方形孔的前角接续原孔位，完整圆底与固定孔沿各自保留。
            r,g,b,a=frame.getpixel((790,979))
            self.assertGreater(a,245)
            self.assertLess(max(r,g,b),80)
            # 在左右转入圆底的位置，不应存在旧的矩形取样接头或透明孔。
            for x,y in ((529,685),(893,685)):
                near=frame.crop((x-5,y-4,x+6,y+5))
                self.assertGreater(sum(1 for p in near.getdata() if p[3]>240 and max(p[:3])<80),30)

    def test_scroll_removes_old_orbit_edges_instead_of_leaving_empty_lines(self):
        # 日月绕到右侧后，旧射线和旧箭头处不能保留低 alpha 的空轮廓。
        # 原 PNG 画面外围有 alpha <= 8 的生成残点，不能把它们当成实体墨线。
        frame=self.frame('shuabuting',11)
        for box in ((958,525,997,546),(954,700,964,718)):
            self.assertLessEqual(frame.crop(box).getchannel('A').getextrema()[1],8)

    def test_scroll_sun_and_all_eight_rays_stay_complete(self):
        # 用金币色太阳圆面的实际重心追踪位置，再核对原射线；不从绘制工具取运动坐标。
        box=(927,380,1234,958)
        def sun(frame):
            crop=frame.crop(box)
            rgba=crop.tobytes()
            points=[(j//4%crop.width+box[0],j//4//crop.width+box[1])
                    for j in range(0,len(rgba),4)
                    if rgba[j]>235 and rgba[j+1]>175 and rgba[j+2]<160 and rgba[j+3]>240]
            self.assertTrue(points)
            return len(points),tuple(sum(p[k] for p in points)/len(points) for k in (0,1))
        original=self.original('shuabuting');area,center=sun(original)
        samples=((1040,459),(994,482),(979,536),(1000,580),
                 (1053,592),(1093,566),(1111,522),(1095,474))
        for i in range(4,33):
            frame=self.frame('shuabuting',i);actual_area,actual=sun(frame)
            self.assertEqual(actual_area,area)
            dx,dy=(round(actual[k]-center[k]) for k in (0,1))
            for x,y in samples:
                with self.subTest(frame=i,ray=(x,y)):
                    self.assertGreater(frame.getpixel((x+dx,y+dy))[3],240)

    def test_native_import_settings_match_original(self):
        keys=('compress/mode','mipmaps/generate','process/fix_alpha_border',
              'process/premult_alpha','process/size_limit')
        def settings(p):
            return {k:v for line in p.read_text().splitlines() if '=' in line
                    for k,v in [line.split('=',1)] if k in keys}
        for card in COUNTS:
            reference=settings(ART/f'icon/icon_{card}.png.import')
            for filename in set(self.hover['cards'][card]['files']):
                with self.subTest(card=card,frame=filename):
                    self.assertEqual(settings(ART/(filename+'.import')),reference)


if __name__=='__main__':
    unittest.main()
