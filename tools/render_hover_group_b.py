#!/usr/bin/env python3
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
"""原 PNG 固定画布：生产牌与传奇牌的局部语义姿势，输出 build 中的完整帧。"""
import math
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

from render_hover_common import (
    NativePainter, ROOT, FPS, OUT, path, polygon_mask, rect_mask, ellipse_mask,
    content, affine_pose, gradient_fill, painted_polygon, dilate_disk, ease,
    stroke_path, run,
)

INK=(25,22,17,255)


def component(source,seed,channel='alpha'):
    p=np.asarray(source)
    if channel=='alpha':
        b=(p[:,:,3]>8)
    else:
        b=(p[:,:,:3].max(axis=2)<80)&(p[:,:,3]>240)
    # Pillow floodfill writes through pixel access; fromarray may be read-only.
    m=Image.fromarray(b.astype('uint8')*255).copy()
    if m.getpixel(seed)!=255:
        raise ValueError(f'原图取样点不在 {channel} 主体内: {seed}')
    ImageDraw.floodfill(m,seed,128)
    return m.point(lambda a:255 if a==128 else 0)


def transparent_erase(canvas,mask):
    # Erasure is a coverage domain, not a new object edge. Partially clearing an
    # AA selection then filling it a second time leaves a hollow polygon seam.
    coverage=mask.point(lambda a:255 if a>0 else 0)
    canvas.paste(Image.new('RGBA',canvas.size),(0,0),coverage)


def pose_xy(point,pivot,angle=0,dx=0,dy=0):
    x,y=point;px,py=pivot;c,s=math.cos(angle),math.sin(angle)
    return px+c*(x-px)-s*(y-py)+dx,py+s*(x-px)+c*(y-py)+dy


def pulse(t,start,duration):
    u=(t-start)/duration
    return math.sin(math.pi*max(0,min(1,u)))**2 if 0<u<1 else 0


def paper_fill(source,mask,box):
    return gradient_fill(source,mask,box,
                         lambda p:(p[:,:,0]>215)&(p[:,:,1]>205)&(p[:,:,2]>170))


def filled_outline(source,seed):
    outline=component(source,seed,'dark')
    x0,y0,x1,y1=outline.getbbox()
    box=(max(0,x0-3),max(0,y0-3),min(source.width,x1+3),min(source.height,y1+3))
    part=outline.crop(box).copy()
    ImageDraw.floodfill(part,(0,0),128)
    part=part.point(lambda a:0 if a==128 else 255)
    result=Image.new('L',source.size);result.paste(part,box[:2])
    return result.filter(ImageFilter.MaxFilter(3))


def cream_component(source,seed):
    p=np.asarray(source)
    b=(p[:,:,0]>220)&(p[:,:,1]>210)&(p[:,:,2]>180)&(p[:,:,3]>240)
    m=Image.fromarray(b.astype('uint8')*255).copy()
    if m.getpixel(seed)!=255:raise ValueError(f'原纸色取样点改变: {seed}')
    ImageDraw.floodfill(m,seed,128)
    return m.point(lambda a:255 if a==128 else 0)


def warm_component(source,seed):
    p=np.asarray(source)
    b=(p[:,:,0]>155)&(p[:,:,1]>120)&(p[:,:,2]>75)&(p[:,:,3]>240)
    m=Image.fromarray(b.astype('uint8')*255).copy()
    if m.getpixel(seed)!=255:raise ValueError(f'原暖纸色取样点改变: {seed}')
    ImageDraw.floodfill(m,seed,128)
    return m.point(lambda a:255 if a==128 else 0)


def fill_from_region(source,region,output_mask):
    """Fit only the semantic region, excluding adjacent paper objects."""
    a=np.asarray(source);ys,xs=np.where(np.asarray(region)>0)
    xs=xs[::3];ys=ys[::3]
    mat=np.stack((np.ones(len(xs)),xs/source.width,ys/source.height),axis=1)
    fit=np.linalg.lstsq(mat,a[ys,xs,:3].astype(float),rcond=None)[0]
    oy,ox=np.where(np.asarray(output_mask)>0)
    vals=np.clip(np.rint(np.stack((np.ones(len(ox)),ox/source.width,oy/source.height),axis=1)@fit),0,255).astype('uint8')
    out=np.zeros_like(a);out[oy,ox,:3]=vals;out[oy,ox,3]=np.asarray(output_mask)[oy,ox]
    return Image.fromarray(out)


def extend_ray(canvas,a,b,amount,width=13,color=INK):
    if amount<.01:return
    dx,dy=b[0]-a[0],b[1]-a[1];n=math.hypot(dx,dy)
    if n<1:return
    stroke_path(canvas,[a,(b[0]+dx/n*amount,b[1]+dy/n*amount)],width,color)


class Chunwan(NativePainter):
    card='chunwan';count=36;mode='loop'
    boxes=((276,359,820,944),(372,182,904,365),
           (214,468,306,835),(826,472,926,875))
    notes='电视、支脚、外轮廓与圆牌中心固定。原画圆牌正面的星与纸色转一圈，原透视轮廓不改；结中心不动，左右蝶翼从中心展开后回位。'

    def __init__(self):
        super().__init__()
        left=path(((397,298),(381,256),(409,194),(454,203)),
                  ((454,203),(502,211),(554,243),(593,266)),
                  ((593,266),(590,286),(587,312),(577,334)),
                  ((577,334),(499,346),(429,358),(399,333)),
                  ((399,333),(391,325),(390,311),(397,298)))
        right=path(((662,264),(707,236),(775,195),(829,204)),
                   ((829,204),(885,203),(885,259),(868,322)),
                   ((868,322),(863,355),(825,362),(787,355)),
                   ((787,355),(731,350),(693,339),(658,325)),
                   ((658,325),(659,303),(663,287),(662,264)))
        self.wing_masks=[polygon_mask(self.size,p,True).filter(ImageFilter.MaxFilter(13)) for p in (left,right)]
        self.wings=[content(self.original,m) for m in self.wing_masks]
        self.wing_bg=self.original.copy()
        for m in self.wing_masks:transparent_erase(self.wing_bg,m)
        self.knot_mask=polygon_mask(self.size,[(573,239),(646,235),(676,256),
            (674,319),(659,348),(610,356),(571,337)],True)
        # Interior only. The outer rim is a fixed perspective silhouette of a
        # rotating round disc; it must never become a wobbling ellipse.
        self.disc_mask=polygon_mask(self.size,path(
            ((556,431),(448,421),(354,500),(338,631)),
            ((338,631),(321,766),(397,861),(520,868)),
            ((520,868),(650,882),(743,795),(751,665)),
            ((751,665),(759,531),(669,440),(556,431))),True)
        # The only directional detail on a round disc is the star. Extract its
        # full closed native contour, never an interior ellipse carrying a
        # second copy of the circular ink rim.
        region=np.asarray(self.original)[506:790,386:684]
        ys,xs=np.where((region[:,:,:3].max(axis=2)<80)&(region[:,:,3]>240))
        near=(xs+386-535)**2+(ys+506-520)**2
        at=int(np.argmin(near));seed=(int(xs[at])+386,int(ys[at])+506)
        self.star_mask=filled_outline(self.original,seed)
        if self.star_mask.getbbox()[2]-self.star_mask.getbbox()[0]>330:
            raise ValueError('春晚星形取样误带圆牌墨边')
        self.star=content(self.original,self.star_mask)
        self.disc_fill=gradient_fill(self.original,self.star_mask,(364,442,747,846),
            lambda p:(p[:,:,0]>220)&(p[:,:,1]>170)&(p[:,:,2]<200))
        self.disc_center=(545,651)
        self.rays=[((281,501),(294,516)),((270,571),(260,566)),
                   ((249,772),(239,779)),((274,807),(255,828)),
                   ((873,514),(894,494)),((887,581),(905,572)),
                   ((879,770),(901,782)),((860,831),(877,852))]

    def paint(self,t):
        if t>=2.75:return self.original.copy()
        c=self.wing_bg.copy()
        spread=.036*pulse(t,.25,2.45)
        c.alpha_composite(affine_pose(self.wings[0],(589,289),sx=1+spread,sy=1+spread*.35))
        c.alpha_composite(affine_pose(self.wings[1],(662,289),sx=1+spread,sy=1+spread*.35))
        c.paste(self.original,mask=self.knot_mask)
        # Full color interior spins once, while transparent sampling edges are
        # backed by original gold and hidden behind the native rim.
        angle=2*math.pi*ease((t-.3)/2.25)
        c.paste(self.disc_fill,mask=self.star_mask)
        c.alpha_composite(affine_pose(self.star,self.disc_center,angle=angle))
        for k,(a,b) in enumerate(self.rays):
            extend_ray(c,a,b,15*pulse(t,.45+k*.18,.48),12,(255,246,218,255))
        return c


class Banxiaoshi(NativePainter):
    card='banxiaoshi';count=42;mode='loop'
    boxes=((253,20,1230,1214),)
    notes='原完整车、人、货物和绑带作为同一承重对象上下颠簸，轮胎内印迹转动，五道速度线向后掠过；整车留在画面内，不裁车轮或货物。'

    def __init__(self):
        super().__init__()
        self.rig_mask=dilate_disk(component(self.original,(427,1053)),6)
        self.rig=content(self.original,self.rig_mask)
        self.background=self.original.copy();transparent_erase(self.background,self.rig_mask)
        self.grey=[]
        p=np.asarray(self.original)
        for box,center,r in [((350,990,487,1125),(427,1053),57),
                             ((638,1033,779,1153),(710,1091),53)]:
            m=np.asarray(rect_mask(self.size,(box,)))
            selected=(p[:,:,0]>28)&(p[:,:,0]<95)&(p[:,:,3]>240)
            selected&=np.max(p[:,:,:3],axis=2)-np.min(p[:,:,:3],axis=2)<25
            self.grey.append((Image.fromarray(np.where(selected,m,0).astype('uint8')),center,r))

    @staticmethod
    def motion(t):
        env=ease((t-.3)/.38)*(1-ease((t-2.72)/.38))
        phase=2*math.pi*2.0*(t-.3)
        return 5*math.sin(phase+math.pi/3)*env,28*math.sin(phase)*env,.005*math.sin(phase-.5)*env,env

    def paint(self,t):
        if t>=3.2:return self.original.copy()
        dx,dy,angle,env=self.motion(t)
        if env<.00001:return self.original.copy()
        c=self.background.copy()
        for k in range(5):
            phase=(t*2.2+k/5)%1
            length=(45+55*phase)*env
            end=(1030+130*phase,805+65*k)
            stroke_path(c,[(end[0]-length,end[1]),end],10*env,INK)
        rig=self.rig.copy()
        for mask,center,r in self.grey:
            mark=Image.new('RGBA',self.size)
            phase=2*math.pi*1.8*(t-.3)
            for j in range(2):
                a=phase+j*math.pi
                start=(center[0]+(r-18)*math.cos(a),center[1]+(r-18)*math.sin(a))
                end=(center[0]+(r-3)*math.cos(a),center[1]+(r-3)*math.sin(a))
                stroke_path(mark,[start,end],7,(126,115,94,255))
            rig.alpha_composite(content(mark,mask))
        c.alpha_composite(affine_pose(rig,(560,1070),angle=angle,dx=dx,dy=dy))
        return c


class Tuanzhang(NativePainter):
    card='tuanzhang';count=48;mode='loop'
    boxes=((350,532,714,908),(747,806,950,1048),(1040,220,1275,600))
    notes='原屏幕三人包含头、身体、举手和双脚，依次完整跃起再落回；手机边框和前排五蛋不动。后蛋明显起伏，喇叭原声线持续向外传播。'

    def __init__(self):
        super().__init__()
        self.people=[];removed=Image.new('L',self.size)
        for seed,start,height in [((500,594),.40,45),((438,744),1.22,48),
                                  ((591,731),2.04,46)]:
            mask=dilate_disk(filled_outline(self.original,seed),2)
            mask=mask.point(lambda a:255 if a>0 else 0)
            self.people.append((content(self.original,mask),mask,start,height))
            removed=Image.fromarray(np.maximum(np.asarray(removed),np.asarray(mask)))
        self.people_bg=paper_fill(self.original,removed,(365,540,709,906))
        # Native rear central egg can move only behind the complete original
        # foreground eggs. Its invisible lower half is a rounded shell, never a
        # rectangular cropped image.
        egg_path=path(((847,861),(816,861),(795,891),(778,930)),
                      ((778,930),(766,983),(798,1009),(846,1009)),
                      ((846,1009),(894,1009),(919,969),(916,930)),
                      ((916,930),(918,897),(883,861),(847,861)))
        em=polygon_mask(self.size,egg_path,True)
        own_paper=cream_component(self.original,(842,905))
        self.egg=fill_from_region(self.original,own_paper,em)
        lower=path(((781,913),(765,969),(793,1009),(846,1009)),
                   ((846,1009),(895,1009),(923,965),(910,913)))
        stroke_path(self.egg,lower,16,INK)
        # The native upper silhouette stays exact. Sampling below y=925 would
        # include the OTHER front egg's old dark edge and duplicate that edge.
        upper=Image.fromarray(np.minimum(np.asarray(em),
                         np.asarray(rect_mask(self.size,((755,845,940,917),)))))
        self.egg.alpha_composite(content(self.original,upper))
        self.egg_mask=dilate_disk(cream_component(self.original,(842,905)),18)
        # The native rear egg stands outside the right edge of the phone, with
        # transparent space behind it. No source screen needs to be invented.
        self.egg_bg=self.original.copy()
        transparent_erase(self.egg_bg,self.egg_mask)
        # Sample every fixed egg's actual filled region plus its entire native
        # dark outline. Approximate polygons were leaving old arcs and clips.
        fm=rect_mask(self.size,((527,1059,1110,1176),))
        for seed in ((629,969),(788,987),(932,1006),(719,901),(987,925)):
            own=cream_component(self.original,seed)
            expanded=dilate_disk(own,16)
            # Expanded white masks must not restore the neighbouring moving
            # egg's cream pixels. Include only this fill and native dark edge.
            a=np.asarray(self.original)
            native=Image.fromarray(np.where((np.asarray(own)>0)|
                ((a[:,:,:3].max(axis=2)<160)&(a[:,:,3]>8)),
                np.asarray(expanded),0).astype('uint8'))
            fm=Image.fromarray(np.maximum(np.asarray(fm),np.asarray(native)))
        # Original tray upper lip is foreground too, below the row of eggs.
        lip=polygon_mask(self.size,[(542,1007),(947,1041),(1058,970),
                                  (1078,988),(969,1083),(536,1041)],True)
        fm=Image.fromarray(np.maximum(np.asarray(fm),np.asarray(lip)))
        self.egg_front=fm

    def paint(self,t):
        if t>=3.72:return self.original.copy()
        c=self.people_bg.copy()
        for user,mask,start,height in self.people:
            dy=-round(height*pulse(t,start,.82))
            moved=affine_pose(user,(0,0),dy=dy)
            # Native source pixels on an opaque screen must not be alpha
            # composited twice. Integer translations keep faces/feet exact.
            c.paste(moved,mask=moved.getchannel('A').point(lambda a:255 if a>0 else 0))
        bounce=30*pulse(t,2.68,.64)
        if bounce>.01:
            c.paste(self.egg_bg,mask=self.egg_mask)
            c.alpha_composite(affine_pose(self.egg,(842,939),dy=-bounce))
            c.paste(self.original,mask=self.egg_front)
        for k,(a,b) in enumerate([((1090,334),(1131,298)),((1110,415),(1187,391)),
                                    ((1116,496),(1182,523))]):
            amount=max(pulse(t,.30+k*.12+j*.85,.68) for j in range(4))
            extend_ray(c,a,b,51*amount,22,INK)
        return c


class Xufei(NativePainter):
    card='xufei';count=54;mode='loop'
    boxes=((91,195,1018,1090),)
    notes='原图仅两层环路。门、通向门的虚线固定；两环各绕原中心推进一圈，钱包向右上出口试探、碰内环后退回，苦嘴加深后复原。'

    def __init__(self):
        super().__init__()
        self.outer_mask=component(self.original,(149,600)).filter(ImageFilter.MaxFilter(3))
        self.inner_mask=component(self.original,(284,573)).filter(ImageFilter.MaxFilter(3))
        self.wallet_mask=component(self.original,(580,643)).filter(ImageFilter.MaxFilter(3))
        if self.inner_mask.getbbox()[2]>900:
            raise ValueError('自动续费内环取样误连到外环')
        self.outer=content(self.original,self.outer_mask)
        self.inner=content(self.original,self.inner_mask)
        self.wallet=content(self.original,self.wallet_mask)
        self.background=self.original.copy()
        for m in (self.outer_mask,self.inner_mask,self.wallet_mask):transparent_erase(self.background,m)
        self.center=(551,643)
        self.face_mask=rect_mask(self.size,((447,631,610,747),))
        self.face_back=gradient_fill(self.original,self.face_mask,(428,587,650,753),
            lambda p:(p[:,:,0]>140)&(p[:,:,0]<225)&(p[:,:,1]>75)&(p[:,:,1]<160))

    def wallet_pose(self,fear):
        if fear<1e-7:return self.wallet
        w=self.wallet.copy();w.paste(self.face_back,mask=self.face_mask)
        stroke_path(w,[(468,668),(490,675-6*fear),(470,690-4*fear)],11,INK)
        stroke_path(w,[(554,646),(535,663+4*fear),(559,669+5*fear)],11,INK)
        stroke_path(w,path(((480,729),(497,697-5*fear),(507,745+8*fear),(523,718)),
                           ((523,718),(538,694-6*fear),(548,739+8*fear),(561,713)),
                           ((561,713),(573,698-3*fear),(583,713),(587,714))),10,INK)
        return w

    def paint(self,t):
        if t>=4.22:return self.original.copy()
        c=self.background.copy()
        ao=2*math.pi*ease((t-.25)/3.8)
        ai=2*math.pi*ease((t-.72)/3.33)
        # Native loops themselves are the only objects transformed: their
        # centers remain fixed. Independent motion marks remain original.
        c.alpha_composite(affine_pose(self.outer,self.center,angle=ao))
        trial=ease((t-.85)/.6)*(1-ease((t-1.75)/.6))
        fear=pulse(t,1.65,2.4)
        c.alpha_composite(affine_pose(self.wallet_pose(fear),(576,645),dx=58*trial,dy=-46*trial))
        # Inner loop is in front of the trying wallet, making the obstruction
        # legible instead of letting its edge cut through the arrow.
        c.alpha_composite(affine_pose(self.inner,self.center,angle=ai))
        return c


class Dujiaoshou(NativePainter):
    card='dujiaoshou';count=42;mode='loop'
    boxes=((694,650,951,901),(685,942,1180,1210),(909,65,1130,291))
    notes='纸模型头、躯干、折线、角、尾与大饼固定。原弯前腿抬起后踏到饼面，脚与饼接触后原有独立饼块向外滑，射线强调，最后连续回位。'

    def __init__(self):
        super().__init__()
        self.pivot=(782,701)
        self.leg_outline=[(779,678),(828,715),(852,740),(858,758),
                          (857,820),(849,867),(829,870),(778,861),
                          (738,850),(737,840),(767,780),(716,743),
                          (735,722),(779,678)]
        # Clear the complete original silhouette, including its soft outer
        # fringe, before drawing a closed pose at the original hinge.
        self.leg_mask=polygon_mask(self.size,self.leg_outline,True).filter(ImageFilter.MaxFilter(13))
        visible_leg=path(((780,690),(803,710),(827,735),(840,750)),
                         ((840,750),(846,776),(843,818),(838,853)),
                         ((838,853),(815,860),(781,853),(750,842)),
                         ((750,842),(755,826),(771,798),(779,780)),
                         ((779,780),(760,760),(742,746),(729,737)),
                         ((729,737),(746,720),(766,702),(780,690)))
        native_face=polygon_mask(self.size,visible_leg,True)
        native_color=paper_fill(self.original,native_face,(773,717,837,842))
        self.leg=content(native_color,native_face)
        stroke_path(self.leg,visible_leg+[visible_leg[0]],13,INK)
        # Three independent native dashes are complete ink components, not
        # rectangular fragments. The two attached crease ends connect to the
        # new contour instead of bringing part of the old contour with them.
        for seed in ((804,735),(820,765),(820,804)):
            crease=dilate_disk(component(self.original,seed,'dark'),2)
            self.leg.alpha_composite(content(self.original,crease))
        stroke_path(self.leg,[(782,698),(790,715)],8,INK)
        stroke_path(self.leg,[(818,835),(816,852)],8,INK)
        self.background=self.original.copy();transparent_erase(self.background,self.leg_mask)
        # The pie edge originally covered by the hoof must be complete before
        # moving it. Only that narrow concealed range is drawn, not the whole pie.
        hidden_edge=path(((718,805),(737,793),(746,796),(759,808)),
                         ((759,808),(775,815),(786,787),(804,804)),
                         ((804,804),(819,817),(820,843),(842,833)),
                         ((842,833),(856,820),(866,840),(881,854)))
        hidden=polygon_mask(self.size,hidden_edge+[(885,890),(714,890)],True)
        fill=paper_fill(self.original,hidden,(450,831,704,914))
        concealed=Image.fromarray(np.where((np.asarray(hidden)>0)&
             (np.asarray(self.leg_mask)>0),255,0).astype('uint8'))
        self.background.paste(fill,mask=concealed)
        hidden_ink=Image.new('RGBA',self.size)
        stroke_path(hidden_ink,hidden_edge,13,INK)
        self.background.alpha_composite(content(hidden_ink,self.leg_mask.point(lambda a:255 if a>0 else 0)))
        # Native fixed body always masks the shoulder joint.
        self.body_fore=polygon_mask(self.size,[(665,656),(800,657),(800,693),
              (791,704),(748,737),(702,768),(683,743)],True)
        # One complete closed slice: top, slanted front, right side and the
        # continuous waved crust. A cream-only selection loses the gold side.
        native_fill=Image.new('L',self.size)
        for seed in ((836,991),(791,1030),(914,1075),(997,973)):
            part=warm_component(self.original,seed)
            native_fill=Image.fromarray(np.maximum(np.asarray(native_fill),np.asarray(part)))
        edge_near=dilate_disk(native_fill,16)
        p=np.asarray(self.original);yy,xx=np.mgrid[:self.size[1],:self.size[0]]
        all_native=(np.asarray(native_fill)>0)|((np.asarray(edge_near)>0)&(p[:,:,3]>0))
        # Shared parent-cake ink above the slice's real top boundary is not a
        # part of the slice; copying it produces a moving L-shaped old corner.
        all_native&=~((xx<978)&(yy<956-.018*(xx-705)))
        self.chunk_mask=Image.fromarray(all_native.astype('uint8')*255)
        self.chunk=content(self.original,self.chunk_mask)
        self.chunk_bg=self.background.copy()
        transparent_erase(self.chunk_bg,self.chunk_mask.filter(ImageFilter.MaxFilter(5)))
        # The exact native selection leaves the parent cake intact, so no wide
        # foreground crop may resurrect the old slice's leftmost black edge.

    def paint(self,t):
        if t>=3.22:return self.original.copy()
        up=ease((t-.3)/.55)*(1-ease((t-.95)/.4))
        stamp=7*pulse(t,1.25,.22)
        chunk=80*ease((t-1.28)/.48)*(1-ease((t-2.25)/.72))
        # Preserve the native slice verbatim until the hoof actually strikes.
        c=(self.chunk_bg if chunk>.001 else self.background).copy()
        if chunk>.001:
            c.alpha_composite(affine_pose(self.chunk,(844,1058),dx=chunk,dy=chunk*.22))
        if up<.00001 and stamp<.00001:
            c.paste(self.original,mask=self.leg_mask.point(lambda a:255 if a>0 else 0))
        else:
            c.alpha_composite(affine_pose(self.leg,self.pivot,angle=-.38*up,dy=stamp))
        c.paste(self.original,mask=self.body_fore)
        for k,(a,b) in enumerate([((935,127),(953,143)),((991,106),(991,86)),
                                  ((1060,181),(1090,183)),((1036,229),(1055,252))]):
            extend_ray(c,a,b,24*pulse(t,1.35+k*.14,.45),12,INK)
        return c


class Guomin(NativePainter):
    card='guomin';count=42;mode='loop'
    boxes=((155,80,1140,1170),)
    notes='原手机左右快速振动，原三名小人连同原双臂、脸、身体、双腿和欢呼短线整体跳起再落回。没有新生手臂；人物遮住的手机纸面、两层边框先完整补齐。'

    def __init__(self):
        super().__init__()
        self.people=[];removed=Image.new('L',self.size)
        specs=[
            (((285,817),(278,929),(361,836)),
             ((203,742,363,893),(222,865,339,989)),
             [[(320,878),(350,850),(393,795)],[(254,967),(213,1029),(231,1037)],
              [(301,971),(315,1001),(310,1033),(332,1038)]],
             [(185,728),(235,706)],.35,52),
            (((480,940),(495,1047),(584,942)),
             ((423,882,579,1020),(441,995,551,1104)),
             [[(539,1002),(575,963),(605,902)],[(468,1080),(408,1128),(421,1138)],
              [(520,1080),(542,1106),(526,1133),(552,1137)]],
             [(502,851),(547,851)],1.05,62),
            (((989,878),(990,975),(909,906)),
             ((913,801,1069,946),(933,920,1037,1031)),
             [[(944,936),(904,905),(865,857)],[(960,1017),(935,1044),(931,1075),(948,1076)],
              [(1014,1017),(1044,1048),(1063,1069),(1048,1079)]],
             [(1048,772),(1073,799)],1.75,56),
        ]
        arr=np.asarray(self.original)
        dark=(arr[:,:,:3].max(axis=2)<235)&(arr[:,:,3]>0)
        for seeds,body_boxes,limbs,marks,start,height in specs:
            parts=[]
            for seed in seeds:
                own=cream_component(self.original,seed)
                # The face's eye/mouth AA can have exactly the threshold RGB
                # value and belong to neither the cream nor black threshold.
                # Fill enclosed interior holes before adding the outer ink.
                x0,y0,x1,y1=own.getbbox();box=(x0-2,y0-2,x1+2,y1+2)
                interior=own.crop(box).copy();ImageDraw.floodfill(interior,(0,0),128)
                interior=interior.point(lambda a:0 if a==128 else 255)
                own=Image.new('L',self.size);own.paste(interior,box[:2]);parts.append(own)
            mask=Image.new('L',self.size)
            for j,own in enumerate(parts):
                near=dilate_disk(own,19)
                if j==1 and start==1.05:
                    guard=polygon_mask(self.size,path(
                        ((471,1000),(456,1017),(439,1044),(443,1069)),
                        ((443,1069),(449,1091),(483,1101),(510,1097)),
                        ((510,1097),(536,1093),(548,1065),(545,1030)),
                        ((545,1030),(544,1013),(541,1002),(535,994))),True)
                elif j==0 and start==1.05:
                    guard=polygon_mask(self.size,path(
                        ((490,880),(458,882),(432,907),(426,950)),
                        ((424,950),(424,992),(452,1019),(495,1021)),
                        ((495,1021),(537,1023),(577,993),(577,953)),
                        ((577,953),(579,912),(544,879),(490,880))),True)
                elif j<2:
                    guard=ellipse_mask(self.size,body_boxes[j])
                else:
                    guide=Image.new('RGBA',self.size)
                    stroke_path(guide,limbs[0],38,(255,255,255,255))
                    guard=guide.getchannel('A')
                    if start==1.05:
                        guard=Image.fromarray(np.maximum(np.asarray(guard),
                              np.asarray(ellipse_mask(self.size,(578,874,638,929)))))
                selected=(np.asarray(own)>0)|((np.asarray(near)>0)&dark)
                part=np.minimum(selected.astype('uint8')*255,np.asarray(guard))
                mask=Image.fromarray(np.maximum(np.asarray(mask),part))
            for points in limbs[1:]:
                guide=Image.new('RGBA',self.size)
                if start==1.05:
                    points=list(points)
                    points[0]=(456,1087) if points[1][0]<500 else (520,1092)
                stroke_path(guide,points,41,(255,255,255,255))
                limb=(np.asarray(guide.getchannel('A'))>0)&dark
                mask=Image.fromarray(np.maximum(np.asarray(mask),limb.astype('uint8')*255))
            # Original cheering marks belong to the person, not the phone.
            for seed in marks:
                x,y=seed;q=arr[y-16:y+17,x-16:x+17]
                ys,xs=np.where((q[:,:,:3].max(axis=2)<80)&(q[:,:,3]>240))
                j=int(np.argmin((xs-16)**2+(ys-16)**2))
                point=(x-16+int(xs[j]),y-16+int(ys[j]))
                mark=component(self.original,point,'dark')
                if mark.getbbox()[2]-mark.getbbox()[0]>80:
                    raise ValueError('国民欢呼短线误连到手机')
                mask=Image.fromarray(np.maximum(np.asarray(mask),np.asarray(dilate_disk(mark,3))))
            if start==1.05:
                yy,xx=np.mgrid[:self.size[1],:self.size[0]]
                # At these two contacts the phone's ink is fused into the
                # person's outer ink in the PNG. The contact continuation is
                # owned by the phone, not a small square on the moving body.
                cut=((yy>=916)&(yy<=938)&(xx<435-.4375*(yy-918)))
                cut|=((yy>=1038)&(yy<=1078)&(xx>545-.13*(yy-1040)))
                mask=Image.fromarray(np.where(cut,0,np.asarray(mask)).astype('uint8'))
            # One pixel of original antialias belongs to the native silhouette.
            # Do not expand a foreground matte into the touching phone edge.
            self.people.append((content(self.original,mask),start,height))
            removed=Image.fromarray(np.maximum(np.asarray(removed),np.asarray(dilate_disk(mask,4))))
        # Erase ownership is deliberately larger than the extracted foreground.
        # Every old outline is removed, including branches joined to a phone
        # outline; clipping the erase to the foreground left thin old arm arcs.
        removed=rect_mask(self.size,((173,699,418,1064),(390,821,640,1156),
                                    (843,740,1093,1101)))
        outer=path(((606,121),(546,114),(497,151),(478,199)),
                   ((478,199),(462,245),(388,701),(352,886)),
                   ((352,886),(333,972),(341,1003),(389,1020)),
                   ((389,1020),(506,1047),(667,1086),(779,1096)),
                   ((779,1096),(807,1110),(845,1080),(870,1000)),
                   ((870,1000),(910,778),(953,553),(986,326)),
                   ((986,326),(1012,264),(971,210),(934,195)),
                   ((934,195),(860,174),(679,130),(606,121)))
        phone_shape=polygon_mask(self.size,outer,True)
        phone=self.original.copy();transparent_erase(phone,removed)
        concealed=Image.fromarray(np.where((np.asarray(removed)>0)&
                   (np.asarray(phone_shape)>0),255,0).astype('uint8'))
        fill=paper_fill(self.original,concealed,(610,760,770,875))
        phone.paste(fill,mask=concealed)
        ink=Image.new('RGBA',self.size)
        stroke_path(ink,path(((478,215),(445,394),(388,701),(352,886)),
                             ((352,886),(333,972),(341,1003),(389,1020)),
                             ((389,1020),(506,1047),(667,1086),(779,1096))),18,INK)
        stroke_path(ink,path(((486,350),(463,495),(410,763),(391,899)),
                             ((391,899),(386,914),(404,921),(425,925)),
                             ((425,925),(540,946),(670,970),(772,986)),
                             ((772,986),(791,991),(797,958),(804,920))),17,INK)
        stroke_path(ink,[(950,300),(825,1000)],18,INK)
        stroke_path(ink,path(((825,1000),(819,1044),(804,1083),(779,1096))),18,INK)
        stroke_path(ink,path(((961,226),(986,247),(995,284),(986,326)),
                             ((986,326),(953,553),(910,778),(870,1000)),
                             ((870,1000),(864,1030),(852,1068),(828,1088)),
                             ((828,1088),(807,1100),(790,1110),(760,1105))),18,INK)
        phone.alpha_composite(content(ink,removed.point(lambda a:255 if a>0 else 0)))
        # Before an occluded contour begins, blend back the native contour over
        # a short clean section. This removes a 1–2 px profile step at the seam
        # without carrying any original hand/head back into the phone.
        transition=np.zeros((self.size[1],self.size[0]),dtype='uint8')
        transition[699:748,340:430]=255
        transition[740:785,800:928]=255
        for y in range(748,775):transition[y,340:430]=round(255*(775-y)/27)
        for y in range(785,813):transition[y,800:928]=round(255*(813-y)/28)
        phone.paste(self.original,mask=Image.fromarray(transition))
        # Erased legs outside the phone cannot leave low-alpha old fragments.
        self.phone=content(phone,phone_shape.filter(ImageFilter.MaxFilter(25)).point(lambda a:255 if a>0 else 0))

    @staticmethod
    def motion(t):
        env=ease((t-.30)/.22)*(1-ease((t-2.85)/.28))
        phase=2*math.pi*2.5*(t-.30)
        return round(12*math.sin(phase)*env),round(5*math.sin(phase+math.pi/3)*env)

    def paint(self,t):
        if t>=3.22:return self.original.copy()
        dx,dy=self.motion(t)
        c=affine_pose(self.phone,(0,0),dx=dx,dy=dy)
        for user,start,height in self.people:
            jump=-round(height*pulse(t,start,1.03))
            moved=affine_pose(user,(0,0),dy=jump)
            c.alpha_composite(moved)
        return c


class Shangshi(NativePainter):
    card='shangshi';count=42;mode='loop'
    boxes=((90,200,1153,1127),)
    notes='挂点固定。钟槌先向外蓄力，回到原敲击位置接触钟壁之后，钟身围绕挂点衰减摆动；钟舌稍晚，完整钟口、钟壁在被遮处先补全，钟口挡住钟舌上段。'

    def __init__(self):
        super().__init__()
        self.anchor=(638,264)
        handle=polygon_mask(self.size,[(375,695),(426,721),(188,1093),
                                      (155,1100),(136,1081)],True)
        head=polygon_mask(self.size,path(
            ((392,576),(414,579),(469,606),(510,619)),
            ((510,619),(546,622),(552,666),(536,710)),
            ((536,710),(525,746),(484,776),(457,756)),
            ((457,756),(416,736),(370,713),(337,693)),
            ((337,693),(313,680),(328,641),(348,610)),
            ((348,610),(365,586),(382,575),(392,576))),True)
        guard=Image.fromarray(np.maximum(np.asarray(handle),np.asarray(head)))
        paper=Image.new('L',self.size)
        for seed in ((360,655),(430,667),(521,670),(333,816),(240,950),(230,980)):
            paper=Image.fromarray(np.maximum(np.asarray(paper),np.asarray(cream_component(self.original,seed))))
        near=dilate_disk(paper,19);arr=np.asarray(self.original)
        owned=(np.asarray(paper)>0)|((np.asarray(near)>0)&(np.asarray(guard)>0)&
              (arr[:,:,:3].max(axis=2)<220)&(arr[:,:,3]>0))
        hammer_pixels=Image.fromarray(np.minimum(owned.astype('uint8')*255,
                                       np.asarray(dilate_disk(guard,2))))
        yy,xx=np.mgrid[:self.size[1],:self.size[0]]
        hammer_pixels=Image.fromarray(np.where((xx>399)&(yy<575+.4*(xx-395)),0,
                                     np.asarray(hammer_pixels)).astype('uint8'))
        self.hammer=content(self.original,hammer_pixels)
        self.hammer_mask=dilate_disk(guard,12).point(lambda a:255 if a>0 else 0)
        # The former approximate polygon omitted 3,938 actual main-object
        # pixels, leaving old side/ring ink behind when the bell swung.
        main=dilate_disk(component(self.original,(700,500)),6)
        self.body_mask=Image.fromarray(np.where(np.asarray(self.hammer_mask)>0,0,
                               np.asarray(main)).astype('uint8'))
        self.body_mask.paste(0,(590,151,674,276))
        self.bell=content(self.original,self.body_mask)
        # Restore a complete cream bell wall and the continuous outer contour
        # hidden behind the mallet. The other existing fold lines stay native.
        hidden_wall=polygon_mask(self.size,path(
            ((424,570),(420,620),(418,680),(417,730)),
            ((417,730),(416,760),(416,780),(414,810)))+
            [(560,810),(560,635),(527,590)],True)
        hidden_wall=Image.fromarray(np.where((np.asarray(hidden_wall)>0)&
                           (np.asarray(self.hammer_mask)>0),255,0).astype('uint8'))
        self.body_mask=Image.fromarray(np.maximum(np.asarray(self.body_mask),np.asarray(hidden_wall)))
        transparent_erase(self.bell,self.hammer_mask)
        wall=paper_fill(self.original,hidden_wall,(550,452,720,785))
        self.bell.paste(wall,mask=hidden_wall)
        contour=Image.new('RGBA',self.size)
        stroke_path(contour,path(((424,570),(420,620),(418,680),(417,730)),
                                ((417,730),(416,760),(416,780),(414,810))),16,INK)
        self.bell.alpha_composite(content(contour,self.hammer_mask))
        # One closed wall section owns the entire outer ink profile through the
        # old hammer contact. A clipped half-stroke at either end produces a
        # diagonal chip in the edge when the bell begins to rotate.
        wall_curve=path(((426,550),(422,590),(420,636),(419,688)),
                        ((419,688),(418,738),(416,792),(411,830)))
        wall_band=rect_mask(self.size,((395,550,450,831),))
        transparent_erase(self.bell,wall_band)
        wall_face=polygon_mask(self.size,wall_curve+[(450,830),(450,550)],True)
        wall_paper=paper_fill(self.original,wall_face,(550,452,720,785))
        self.bell.alpha_composite(content(wall_paper,wall_face))
        wall_ink=Image.new('RGBA',self.size)
        stroke_path(wall_ink,wall_curve,16,(6,2,1,253))
        self.bell.alpha_composite(content(wall_ink,wall_band))
        # The upper ornamental rim crosses the right-hand end of this wall
        # patch. It is a fixed native foreground edge, not part of the repair.
        self.bell.paste(self.original,mask=rect_mask(self.size,((395,790,450,831),)))
        for seed in ((559,681),(551,726),(535,766),(490,783)):
            mark=dilate_disk(component(self.original,seed,'dark'),2)
            if mark.getbbox()[2]-mark.getbbox()[0]<90:
                self.bell.paste(self.original,mask=mark)
        # Remove the original tongue from the bell source. Its hidden upper
        # stem and circle are complete shapes drawn from original paper colors.
        old_tongue=polygon_mask(self.size,[(646,926),(716,925),(728,979),
            (747,996),(752,1046),(726,1085),(637,1085),(620,1048),
            (625,996),(646,976)],True).filter(ImageFilter.MaxFilter(5))
        old_tongue=old_tongue.point(lambda a:255 if a>0 else 0)
        transparent_erase(self.bell,old_tongue)
        yy,xx=np.mgrid[:self.size[1],:self.size[0]]
        # Native inner edge is at y≈1016 for x620, the OUTER bottom edge at
        # y≈1038. Confusing those edges creates two short horizontal spurs.
        outer_y=1039.5-.090*(xx-610)
        inside=Image.fromarray(np.where(yy<=outer_y+7,np.asarray(old_tongue),0).astype('uint8'))
        insidefill=paper_fill(self.original,inside,(767,952,900,992))
        self.bell.paste(insidefill,mask=inside)
        upper_front=Image.fromarray(np.where(yy<=954-.129*(xx-620),np.asarray(old_tongue),0).astype('uint8'))
        self.bell.paste(self.original,mask=upper_front)
        rim_strokes=Image.new('RGBA',self.size)
        stroke_path(rim_strokes,path(((610,1017.5),(655,1013.5),(710,1008.5),(767,1002))),9,(6,4,3,255))
        stroke_path(rim_strokes,path(((610,1039.5),(655,1035.5),(710,1030.5),(767,1025))),15,(6,4,3,255))
        self.bell.alpha_composite(content(rim_strokes,old_tongue))
        self.stem=Image.new('RGBA',self.size)
        stem_shape=[(660,919),(698,915),(704,989),(659,995)]
        sm=polygon_mask(self.size,stem_shape,True)
        sf=paper_fill(self.original,sm,(665,947,695,977))
        painted_polygon(self.stem,stem_shape,sf,INK,13)
        # Native circle is already fully visible. Preserve its pixels instead
        # of redrawing a slightly different circle at the first active frame.
        cm=dilate_disk(cream_component(self.original,(684,1027)),16)
        if cm.getbbox()[2]-cm.getbbox()[0]>115:
            raise ValueError('上市钟舌圆的纸色取样误接到钟口')
        self.tongue_circle=content(self.original,cm)
        # The occlusion edge follows the actual lower edge of the upper mouth
        # rim (x620:y953, x680:y945), not a convenient oval above/below it.
        opening=polygon_mask(self.size,[(396,985),(560,961),(620,953),
            (680,945.5),(750,937),(854,924),(1012,942)]+
            path(((1012,942),(1040,969),(788,1014),(595,1037)),
                 ((595,1037),(503,1047),(422,1044),(396,985))),True)
        # Split mutually exclusive native pixels. Painting the complete bell
        # and then its front twice made the native 253/254-alpha paper opaque.
        opening=opening.point(lambda a:255 if a>=128 else 0)
        self.bell_back=content(self.bell,opening)
        self.bell_front=content(self.bell,opening.point(lambda a:255-a))
        self.background=self.original.copy()
        for m in (self.body_mask,self.hammer_mask,old_tongue):transparent_erase(self.background,m)
        # The hanging block and original independent sound rays stay fixed.
        self.block=rect_mask(self.size,((590,151,674,276),))
        self.background.paste(self.original,mask=self.block)
        self.old_tongue=old_tongue
        self.rays=[((339,548),(364,568)),((389,500),(405,530)),
                   ((869,368),(892,402)),((915,390),(935,428)),
                   ((967,650),(990,690)),((988,682),(1006,724))]

    def paint(self,t):
        if t>=3.22:return self.original.copy()
        windup=-.165*ease((t-.30)/.32)*(1-ease((t-.64)/.23))
        recoil=-.062*pulse(t,.88,.55)
        elapsed=max(0,t-.88)
        stop=1-ease((t-2.73)/.42)
        bell_angle=.049*math.sin(elapsed*2*math.pi*2.15)*math.exp(-1.35*elapsed)*ease(elapsed/.12)*stop
        lag=.077*math.sin(max(0,elapsed-.10)*2*math.pi*2.15)*math.exp(-1.15*elapsed)*ease((elapsed-.10)/.13)*stop
        c=self.background.copy()
        c.alpha_composite(affine_pose(self.bell_back,self.anchor,angle=bell_angle))
        pivot=(681,943);moved=pose_xy(pivot,self.anchor,bell_angle)
        dx,dy=moved[0]-pivot[0],moved[1]-pivot[1]
        c.alpha_composite(affine_pose(self.stem,pivot,angle=bell_angle+lag,dx=dx,dy=dy))
        c.alpha_composite(affine_pose(self.bell_front,self.anchor,angle=bell_angle))
        c.alpha_composite(affine_pose(self.tongue_circle,pivot,angle=bell_angle+lag,dx=dx,dy=dy))
        c.alpha_composite(affine_pose(self.hammer,(162,1079),angle=windup+recoil))
        if t<=.88:
            c.paste(self.original,mask=self.old_tongue)
        c.paste(self.original,mask=self.block)
        for k,(a,b) in enumerate(self.rays):
            extend_ray(c,a,b,13*pulse(t,.91+k*.07,.7),14,INK)
        return c


PAINTERS=(Chunwan,Banxiaoshi,Tuanzhang,Xufei,Dujiaoshou,Guomin,Shangshi)


if __name__=='__main__':run(PAINTERS)
