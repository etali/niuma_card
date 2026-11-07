#!/usr/bin/env python3
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
"""八张复杂牌：唯一原稿、固定画布中的因果动作，输出原生完整 PNG 帧。"""
import math
import shutil
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageChops
from hover_source_art import native_icon_path, native_icon_write_path

from render_hover_common import (
    ROOT, OUT, NativePainter, run, path, polygon_mask, rect_mask, ellipse_mask,
    content, affine_pose, gradient_fill, painted_polygon, cubic, ease, stroke_path, dilate_disk,
)

INK = (29, 24, 18, 254)
CREAM = (255, 246, 219, 254)
GOLD = (255, 221, 127, 254)
DARK = (38, 31, 23, 254)


def pp(canvas, points, fill=CREAM, width=18, ink=INK):
    painted_polygon(canvas, points, fill, ink, width)


def round_box(canvas, box, radius, fill, width=18, ink=INK):
    x0,y0,x1,y1=box
    points=path(((x0+radius,y0),(x0+radius,y0),(x1-radius,y0),(x1-radius,y0)),
                ((x1-radius,y0),(x1,y0),(x1,y0),(x1,y0+radius)),
                ((x1,y0+radius),(x1,y0+radius),(x1,y1-radius),(x1,y1-radius)),
                ((x1,y1-radius),(x1,y1),(x1,y1),(x1-radius,y1)),
                ((x1-radius,y1),(x1-radius,y1),(x0+radius,y1),(x0+radius,y1)),
                ((x0+radius,y1),(x0,y1),(x0,y1),(x0,y1-radius)),
                ((x0,y1-radius),(x0,y1-radius),(x0,y0+radius),(x0,y0+radius)),
                ((x0,y0+radius),(x0,y0),(x0,y0),(x0+radius,y0)))
    pp(canvas,points,fill,width,ink)


def circle(canvas,center,radius,fill,ink=INK,width=12):
    x,y=center
    points=[(x+radius*math.cos(k*math.tau/120),y+radius*math.sin(k*math.tau/120)) for k in range(120)]
    pp(canvas,points,fill,width,ink)


def shared(name,height):
    src=Image.open(native_icon_path(name)).convert('RGBA')
    src=src.crop(src.getbbox())
    return src.resize((round(src.width*height/src.height),round(height)),Image.Resampling.LANCZOS)


def place(canvas, im, x,y):
    canvas.alpha_composite(im,(round(x),round(y)))


def clear(source,mask):
    result=source.copy();result.paste((0,0,0,0),(0,0,*source.size),mask);return result


def paper_components(source,seeds,grow):
    """选取同一原图的封闭纸色面，外扩到墨边，不采入独立动势线。"""
    pixels=np.asarray(source)
    pale=((pixels[:,:,3]>180)&(pixels[:,:,0]>210)&(pixels[:,:,1]>200)&(pixels[:,:,2]>180)).astype('uint8')*255
    selected=Image.new('L',source.size)
    for seed in seeds:
        if pale[seed[1],seed[0]]!=255:raise ValueError(f'纸色采样点不在闭合纸面内: {seed}')
        white=Image.fromarray(pale.copy()).copy();ImageDraw.floodfill(white,seed,128)
        part=white.point(lambda a:255 if a==128 else 0)
        selected=Image.fromarray(np.maximum(np.asarray(selected),np.asarray(part)))
    return selected.filter(ImageFilter.MaxFilter(grow))


def native_component(source,seed,box):
    """从同牌原稿取完整连通主体，保留原色、原线与轮廓 AA，排除邻近动势线。"""
    roi=rect_mask(source.size,[box]);a=np.asarray(source.getchannel('A'))
    occupied=Image.fromarray(((a>32)&(np.asarray(roi)>128)).astype('uint8')*255).copy()
    ImageDraw.floodfill(occupied,seed,128)
    core=occupied.point(lambda a:255 if a==128 else 0)
    if not core.getbbox():raise ValueError(f'原像素主体采样失败 {seed}')
    other=occupied.point(lambda a:255 if a==255 else 0).filter(ImageFilter.MaxFilter(7))
    grown=core.filter(ImageFilter.MaxFilter(7))
    mask=Image.fromarray(np.maximum(np.asarray(core),np.minimum(np.asarray(grown),255-np.asarray(other))))
    mask=Image.fromarray(np.minimum(np.asarray(mask),np.asarray(roi)))
    return content(source,mask),mask




def fix_touliu_slot():
    """本轮仅授权改投流孔：真实原币直径 + 余量，先下移对孔再水平投入。"""
    folder=OUT/'touliu'/'feedback_v2';folder.mkdir(parents=True,exist_ok=True)
    backup=folder/'original_icon.png';target=native_icon_write_path('touliu')
    if not backup.exists():shutil.copy2(target,backup)
    source=Image.open(backup).convert('RGBA')
    old=rect_mask(source.size,[(325,491,407,869)])
    fill=gradient_fill(source,old,(398,502,419,850),lambda a:(a[:,:,0]>240)&(a[:,:,1]>220)&(a[:,:,2]>185))
    fixed=Image.composite(fill,source,old)
    round_box(fixed,(329,493,399,864),22,(245,226,181,254),16,(24,18,12,254))
    round_box(fixed,(346,505,381,851),11,(42,33,22,254),12,(24,18,12,254))
    # 原币本身完全保持原稿，孔的有效高度337px，动画币的真实圆面325px。
    coin=ellipse_mask(source.size,(35,448,338,785)).filter(ImageFilter.MaxFilter(9))
    fixed=Image.composite(source,fixed,coin)
    fixed.save(target)


def walking_figure(body,hip,shoulder,legs,arm,phase,stride,ink,width):
    """头和躯干是原像素，腿交替迈步、原有手臂反向摆动。"""
    figure=Image.new('RGBA',body.size)
    figure.alpha_composite(body)
    for side,(start,knee,foot) in enumerate(legs):
        s=phase*(1 if side==0 else -1)
        knee=(knee[0]+stride*.42*s,knee[1]-stride*.13*max(0,-s))
        foot=(foot[0]+stride*s,foot[1]-stride*.40*max(0,-s))
        stroke_path(figure,[start,knee,foot],width,ink)
    for start,hand in arm:
        dx,dy=hand[0]-start[0],hand[1]-start[1]
        angle=.33*phase*(1 if start[0]<shoulder[0] else -1)
        hx=start[0]+dx*math.cos(angle)-dy*math.sin(angle)
        hy=start[1]+dx*math.sin(angle)+dy*math.cos(angle)
        stroke_path(figure,[start,(hx,hy)],width,ink)
    return figure


def backup_source(card):
    folder=OUT/card;folder.mkdir(parents=True,exist_ok=True)
    backup=folder/'original_before_static_fix.png'
    src=native_icon_path(card)
    if not backup.exists():shutil.copy2(src,backup)
    return Image.open(backup).convert('RGBA')


def certificate(size,box):
    im=Image.new('RGBA',size)
    x0,y0,x1,y1=box
    pp(im,[(x0,y0),(x1,y0+10),(x1-7,y1),(x0-4,y1-10)],CREAM,14)
    pp(im,[(x0+17,y0+20),(x1-17,y0+26),(x1-23,y1-20),(x0+13,y1-27)],CREAM,5)
    stroke_path(im,[(x0+35,y0+43),(x1-36,y0+48)],8,INK)
    stroke_path(im,[(x0+38,y0+63),(x1-58,y0+67)],6,INK)
    circle(im,(x1-42,y1-43),19,GOLD,width=7)
    pp(im,[(x1-52,y1-26),(x1-62,y1-7),(x1-43,y1-14),(x1-30,y1-2),(x1-30,y1-25)],GOLD,5)
    return im


def fix_static_icons():
    """只修已获授权的三处语义。备份在 build；再次执行仍从同一原稿开始。"""
    src=backup_source('touliu')
    mask=polygon_mask(src.size,[(811,532),(869,538),(949,581),(1003,652),(1016,683),
                               (1055,676),(1000,787),(881,741),(932,706),(888,651),(811,625)],True)
    mask=Image.fromarray(np.minimum(np.asarray(mask.filter(ImageFilter.MaxFilter(17))),
                                   np.asarray(rect_mask(src.size,[(811,510,1060,805)]))))
    fixed=clear(src,mask)
    # 原箭头外围四条线属于箭头动势，删除，不动现有三人的脚和手。
    for pts in [[(862,514),(910,529),(980,575)],[(878,774),(913,798)]]:
        m=Image.new('RGBA',src.size);stroke_path(m,pts,24,(255,255,255,255))
        fixed=clear(fixed,m.getchannel('A'))
    # 删除原箭头的抗锯齿残点，保留三个完整用户；透明处不留细线。
    a=np.asarray(fixed).copy()
    yy,xx=np.mgrid[0:src.height,0:src.width]
    empty=(xx>816)&(xx<1010)&(yy>512)&(yy<816)
    a[empty]=(0,0,0,0)
    fixed=Image.fromarray(a)
    fixed.save(native_icon_write_path('touliu'))

    src=backup_source('jiaolv')
    # 保留托盘前板、侧板及机器原边，托盘内部改成纸质文凭。
    bowl=polygon_mask(src.size,[(510,913),(592,812),(866,825),(857,914),(831,960),(510,931)],True)
    fixed=src.copy();fixed.paste(DARK,(0,0,*src.size),bowl)
    # 真实出货口沿原托盘内后壁，与纸张短边衔接。
    round_box(fixed,(589,811,857,858),7,(47,40,32,254),10)
    paper=certificate(src.size,(561,872,824,969))
    fixed.alpha_composite(paper)
    front=polygon_mask(src.size,[(497,925),(834,963),(832,1054),(500,1008)],True)
    side=polygon_mask(src.size,[(834,953),(867,902),(864,985),(832,1054)],True)
    fixed=Image.composite(src,fixed,front);fixed=Image.composite(src,fixed,side)
    # 原币上方的放光线也删除，避免看成仍在出金币。
    for pts in [[(684,824),(691,846)],[(771,839),(760,861)],[(803,868),(786,879)]]:
        m=Image.new('RGBA',src.size);stroke_path(m,pts,20,(255,255,255,255))
        selected=Image.fromarray(np.minimum(np.asarray(m.getchannel('A')),np.asarray(bowl)))
        fixed.paste(DARK,(0,0,*src.size),selected)
    fixed.alpha_composite(paper)
    fixed=Image.composite(src,fixed,front);fixed=Image.composite(src,fixed,side)
    fixed.save(native_icon_write_path('jiaolv'))

    src=backup_source('tuisong')
    # 全部通知保持原像素；只有下方电脑/键盘换成手机和接在手机屏幕上的弹簧。
    device_mask=polygon_mask(src.size,[(355,704),(585,723),(710,746),(865,771),(918,1179),
                                      (213,1145),(310,1013)],True).filter(ImageFilter.MaxFilter(17))
    fixed=clear(src,device_mask)
    # 原电脑左侧键盘斜边在原轮廓外，完整擦除，不能残留一根悬空墨线。
    left=polygon_mask(src.size,[(202,1092),(354,973),(359,1130),(205,1165)],True).filter(ImageFilter.MaxFilter(19))
    fixed=clear(fixed,left)
    phone=Image.new('RGBA',src.size)
    round_box(phone,(429,716,834,1165),52,CREAM,25)
    round_box(phone,(454,748,808,1112),28,(255,236,177,254),16)
    stroke_path(phone,[(571,1136),(692,1136)],12,INK)
    # 完整擦除旧电脑上的下段弹簧，不能把它截断后留一根空线。
    fixed=clear(fixed,rect_mask(src.size,[(458,650,689,980)]))
    spring=path(((588,654),(540,664),(482,689),(500,716)),
                ((500,716),(527,741),(662,690),(637,730)),
                ((637,730),(618,747),(494,760),(530,793)),
                ((530,793),(573,814),(678,767),(639,818)),
                ((639,818),(613,845),(513,850),(546,878)),
                ((546,878),(583,908),(669,865),(640,919)),
                ((640,919),(629,952),(540,954),(579,980)),
                ((579,980),(601,998),(645,1002),(625,1027)))
    stroke_path(phone,spring,45,INK);stroke_path(phone,spring,24,GOLD)
    fixed.alpha_composite(phone)
    # 只保留三张通知的完整纸面与外墨边，不复制它们下面的旧设备线。
    top=paper_components(src,[(710,550),(930,619),(1020,765)],49)
    top=Image.fromarray(np.maximum(np.asarray(top),np.asarray(rect_mask(src.size,[(0,0,1254,640)]))))
    fixed=Image.composite(src,fixed,top)
    fixed.save(native_icon_write_path('tuisong'))


class Touliu(NativePainter):
    card='touliu';count=72;mode='once'
    boxes=((24,348,410,889),(730,498,1245,1245),(659,485,772,687))
    notes='Coin keeps original native size: aligns 62px down into a 337px slot, then 3 payments. All 7 users are exact same-card native running figures; no canonical user-card substitutes.'
    def __init__(self):
        super().__init__()
        self.coin_mask=ellipse_mask(self.size,(35,448,338,785)).filter(ImageFilter.MaxFilter(9))
        self.coin=content(self.original,self.coin_mask)
        self.base=clear(self.original,self.coin_mask)
        repair=self.base.copy()
        stroke_path(repair,path(((311,493),(308,556),(311,704),(315,791)),((315,791),(317,832),(319,865),(334,875))),31,INK)
        fill=polygon_mask(self.size,[(321,480),(330,478),(330,797),(331,862),(323,849)],True)
        repair.paste(CREAM,(0,0,*self.size),fill)
        self.base=Image.composite(repair,self.base,self.coin_mask)
        # 原金币遮住的孔左缘也必须补完整，不能在币离开后露出空白。
        round_box(self.base,(329,493,399,864),22,(245,226,181,254),16,(24,18,12,254))
        round_box(self.base,(346,505,381,851),11,(42,33,22,254),12,(24,18,12,254))
        self.slot=content(self.original,rect_mask(self.size,[(346,491,405,868)]))
        self.people=[]
        for seed,box,center,target in [
            ((1120,610),(1004,550,1235,779),(1120,635),(900,635)),
            ((1071,820),(979,765,1195,990),(1071,828),(934,850)),
            ((903,879),(809,811,1021,1042),(907,878),(824,1026)),
        ]:
            im,mask=native_component(self.original,seed,box)
            self.people.append((im,center,target))
        self.base=clear(self.base,rect_mask(self.size,[(805,545,1239,1054)]))
    def paint(self,t):
        if t<.65:
            dy=62*ease((t-.25)/.40)
            canvas=self.original.copy();canvas=Image.composite(self.base,canvas,self.coin_mask)
            canvas.alpha_composite(affine_pose(self.coin,(188,615),dy=dy))
            return canvas
        canvas=self.base.copy()
        for start in (.65,1.30,1.95):
            u=ease((t-start)/.60)
            if t>=start and u<1:
                coin=affine_pose(self.coin,(188,615),dx=350*u,dy=62)
                canvas.alpha_composite(content(coin,rect_mask(self.size,[(0,0,346,1254)])))
        canvas.alpha_composite(self.slot)
        if 2.55<t<3.15:
            pulse=math.sin(math.pi*(t-2.55)/.60)
            for k,(a,b) in enumerate([((686,529),(702,510)),((692,575),(722,563)),((692,650),(718,662))]):
                ext=(7 if k==0 else 18)*pulse;dx,dy=b[0]-a[0],b[1]-a[1];length=math.hypot(dx,dy)
                stroke_path(canvas,[b,(b[0]+dx/length*ext,b[1]+dy/length*ext)],14,INK)
        for i,(im,center,target) in enumerate(self.people):
            u=ease((t-2.85-i*.12)/1.50)
            canvas.alpha_composite(affine_pose(im,center,dx=(target[0]-center[0])*u,dy=(target[1]-center[1])*u))
        for i,target in enumerate(((1095,620),(1120,850),(1092,1055),(840,775))):
            start=3.0+i*.27;u=ease((t-start)/1.25)
            if t>start:
                im,center,_=self.people[i%3]
                x=1152+(target[0]-1152)*u
                canvas.alpha_composite(affine_pose(im,center,dx=x-center[0],dy=target[1]-center[1]))
        if t<=2.85:canvas=Image.composite(self.original,canvas,rect_mask(self.size,[(805,498,1254,1254)]))
        return canvas


class Xinxijianfang(NativePainter):
    card='xinxijianfang';count=50;mode='once'
    boxes=((492,476,898,831),)
    notes='Left hand releases phone, reaches existing lower foreground ribbon, lifts it across the opening and withdraws only after sealing.'
    def __init__(self):
        super().__init__()
        self.opening=polygon_mask(self.size,path(((624,493),(707,448),(807,537),(843,622)),
                     ((843,622),(884,736),(851,789),(747,792)),
                     ((747,792),(660,779),(575,746),(533,715)),
                     ((533,715),(499,647),(521,560),(624,493))),True)
        arm=polygon_mask(self.size,[(601,682),(639,702),(675,700),(716,707),(715,744),
                                  (673,761),(612,752),(583,729)],True)
        self.body=self.original.copy();self.body.paste(DARK,(0,0,*self.size),arm)
        # 持机另一手和手机仍取原稿，不动。
        self.foreground=content(self.original,polygon_mask(self.size,[(709,638),(796,640),(794,785),(674,777),(682,746)],True))
    def paint(self,t):
        if t<=.5:return self.original.copy()
        canvas=self.body.copy()
        reach=ease((t-.5)/.75)
        pull=ease((t-1.25)/1.5)
        handx=684+(578-684)*reach+72*pull
        handy=723+(775-723)*reach-291*pull
        # 开始拉动前，手实际接触现有下缘；手与带上边一直同坐标。
        if t<3.25:
            gesture=Image.new('RGBA',self.size)
            stroke_path(gesture,path(((603,696),(564,725),(handx-25,handy+13),(handx,handy))),22,INK)
            circle(gesture,(handx,handy),22,CREAM,width=14)
            canvas.alpha_composite(content(gesture,self.opening))
        canvas.alpha_composite(self.foreground)
        if pull>0:
            left=(533-23*pull,715-148*pull)
            top=(handx,handy)
            right=(847,769-244*pull)
            band=path((left,(left[0]+23,left[1]-34),(top[0]-25,top[1]),top),
                      (top,(696,handy-8),(799,right[1]-13),right),
                      (right,(872,790),(811,809),(725,800)),
                      ((725,800),(654,783),(575,745),(533,715)),
                      ((533,715),(513,676),(502,622),left))
            ribbon=Image.new('RGBA',self.size);pp(ribbon,band,CREAM,21)
            # 前景丝帶约束在原开口内部，茧外形与原缠绕纹全部原样。
            ribbon=content(ribbon,self.opening)
            canvas.alpha_composite(ribbon)
            if pull>.2:
                y=785-150*pull
                line=Image.new('RGBA',self.size)
                stroke_path(line,path(((548,y),(629,y+42),(742,y+36),(835,y-8))),12,INK)
                canvas.alpha_composite(content(line,self.opening))
            withdraw=ease((t-2.75)/.50)
            if withdraw<1:
                hand=Image.new('RGBA',self.size)
                circle(hand,(handx,handy+39*withdraw),20*(1-.28*withdraw),CREAM,width=13)
                above=rect_mask(self.size,[(0,0,1254,max(1,round(handy+8)))])
                visible=Image.fromarray(np.minimum(np.asarray(above),np.asarray(self.opening)))
                canvas.alpha_composite(content(hand,visible))
        return canvas


def subsidy_paper_region(source,seed):
    a=np.asarray(source)
    cream=(a[:,:,0]>210)&(a[:,:,1]>200)&(a[:,:,2]>180)&(a[:,:,3]>180)
    m=Image.fromarray(cream.astype('uint8')*255).copy()
    if m.getpixel(seed)!=255:raise ValueError(f'白纸取样点不在原纸面内：{seed}')
    ImageDraw.floodfill(m,seed,128)
    m=m.point(lambda v:255 if v==128 else 0)
    # Preserve enclosed original eye/mouth/stroke AA, not only threshold RGB.
    x0,y0,x1,y1=m.getbbox();box=(x0-2,y0-2,x1+2,y1+2)
    fill=m.crop(box).copy();ImageDraw.floodfill(fill,(0,0),128)
    fill=fill.point(lambda v:0 if v==128 else 255)
    result=Image.new('L',source.size);result.paste(fill,box[:2])
    return result


def subsidy_combine(size,masks):
    out=np.zeros((size[1],size[0]),dtype='uint8')
    for m in masks:np.maximum(out,np.asarray(m),out=out)
    return Image.fromarray(out)


def subsidy_foreground(source):
    """Return (native-RGBA foreground, semantic L mask), at original origin."""
    a=np.asarray(source);size=source.size
    dark=(a[:,:,:3].max(2)<100)&(a[:,:,3]>0)
    parts=[];ink_repairs=[]

    head_guard=polygon_mask(size,path(
        ((445,752),(389,752),(343,797),(343,852)),
        ((343,852),(343,908),(389,952),(445,952)),
        ((445,952),(503,952),(550,908),(550,852)),
        ((550,852),(550,797),(504,752),(445,752))),True)
    torso_guard=polygon_mask(size,path(
        ((434,930),(455,925),(477,926),(495,929)),
        ((495,929),(517,953),(535,999),(532,1027)),
        ((532,1027),(533,1054),(526,1064),(490,1067)),
        ((490,1067),(456,1072),(423,1068),(419,1045)),
        ((419,1045),(414,1027),(418,969),(434,930))),True)
    bag_guard=polygon_mask(size,path(
        ((278,998),(326,1005),(384,1021),(408,1027)),
        ((408,1027),(419,1026),(417,1040),(416,1057)),
        ((416,1057),(413,1100),(410,1141),(407,1165)),
        ((407,1165),(407,1174),(389,1182),(374,1183)),
        ((374,1183),(322,1169),(256,1152),(224,1143)),
        ((224,1143),(219,1142),(217,1135),(223,1125)),
        ((223,1125),(236,1085),(259,1032),(268,1009)),
        ((268,1009),(270,1000),(274,997),(278,998))),True)
    hand_guard=polygon_mask(size,path(
        ((708,67),(758,62),(819,86),(869,87)),
        ((869,87),(886,88),(916,84),(936,89)),
        ((936,89),(960,143),(985,217),(1005,261)),
        ((1005,261),(961,291),(903,329),(852,332)),
        ((852,332),(820,341),(771,395),(729,413)),
        ((729,413),(704,424),(682,407),(681,385)),
        ((681,385),(678,371),(696,343),(716,326)),
        ((716,326),(741,306),(756,293),(764,272)),
        ((764,272),(766,274),(765,278),(760,278)),
        ((760,278),(740,281),(715,277),(693,278)),
        ((693,278),(679,303),(659,331),(639,350)),
        ((639,350),(619,367),(594,360),(589,342)),
        ((589,342),(583,329),(586,314),(588,306)),
        ((588,306),(564,305),(553,280),(551,249)),
        ((551,249),(555,192),(587,128),(635,93)),
        ((635,93),(656,78),(683,67),(708,67))),True)
    cuff_guard=polygon_mask(size,[(948,45),(1124,239),(1119,254),
                                  (1012,318),(995,309),(905,84)],True)
    for seed,guard,grow in [((450,850),head_guard,17),((470,1000),torso_guard,17),
                            ((310,1100),bag_guard,13),((400,1100),bag_guard,13),
                            ((850,200),hand_guard,20),((1060,200),cuff_guard,20)]:
        own=subsidy_paper_region(source,seed);near=dilate_disk(own,grow)
        sampled=np.where((np.asarray(near)>0)&dark,np.asarray(guard),0).astype('uint8')
        parts.append(Image.fromarray(np.maximum(np.asarray(own),sampled)))

    # Exact original black limbs, confined to their actual bent silhouettes.
    outlines=[path(
        ((511,921),(535,905),(563,878),(578,858)),
        ((578,858),(582,852),(580,844),(585,836)),
        ((585,836),(590,826),(603,825),(611,834)),
        ((611,834),(621,844),(614,855),(607,864)),
        ((607,864),(587,884),(556,909),(530,927)),
        ((530,927),(523,931),(515,926),(511,921))),
        path(((434,944),(410,953),(364,972),(334,979)),
             ((334,979),(325,981),(315,986),(315,995)),
             ((315,995),(315,1005),(331,1008),(345,1004)),
             ((345,1004),(371,993),(411,978),(443,966))),
        path(((440,1053),(455,1053),(468,1054),(478,1055)),
             ((478,1055),(466,1070),(458,1098),(446,1121)),
             ((446,1121),(447,1124),(449,1126),(447,1127)),
             ((447,1127),(459,1127),(471,1131),(472,1140)),
             ((472,1140),(472,1148),(463,1152),(455,1151)),
             ((455,1151),(443,1147),(426,1144),(415,1141)),
             ((415,1141),(406,1140),(405,1130),(410,1118)),
             ((410,1118),(420,1094),(433,1074),(440,1053))),
        path(((505,1057),(511,1057),(518,1050),(526,1049)),
             ((526,1049),(538,1073),(550,1103),(562,1123)),
             ((560,1123),(567,1125),(573,1125),(579,1125)),
             ((579,1125),(595,1125),(597,1144),(582,1149)),
             ((582,1149),(575,1155),(559,1158),(548,1157)),
             ((548,1157),(538,1159),(537,1153),(537,1143)),
             ((537,1143),(530,1116),(518,1080),(505,1057))),
    ]
    for points in outlines:
        guard=polygon_mask(size,points,True)
        parts.append(guard);ink_repairs.append(guard)
    guides=[([(301,1027),(312,994),(326,985),(346,989),(358,1000),(352,1038)],14)]
    for points,width in guides:
        layer=Image.new('RGBA',size);stroke_path(layer,points,width,(255,255,255,255))
        guide=np.asarray(layer.getchannel('A')).copy();guide[:990]=0
        guide[:1006,:311]=0
        parts.append(Image.fromarray(np.where(dark,guide,0).astype('uint8')))

    # Reconstruct only the newly revealed pinch gap.  The upper hand's outer
    # palm and sleeve remain source samples, so no second contour is introduced
    # alongside the unchanged hand on the original first frame.
    pinch_zone=polygon_mask(size,[(660,250),(790,250),(800,335),
                                  (750,420),(660,420)],True)
    pinch_repair=Image.fromarray(((np.asarray(hand_guard).astype('uint16')*
                                  np.asarray(pinch_zone)+127)//255).astype('uint8'))
    parts.append(pinch_repair);ink_repairs.append(pinch_repair)

    mask=subsidy_combine(size,parts)
    # Restore source antialias pixels between cream and dark thresholds.  Those
    # are internal paper/ink transitions, never holes in the actual object.
    mask=mask.filter(ImageFilter.MaxFilter(3)).filter(ImageFilter.MinFilter(3))
    # Reject detached scraps of neighbouring coin rims.  The two true semantic
    # pieces are the upper hand/cuff and the person/bag connected through arm.
    components=mask.point(lambda v:255 if v>8 else 0).copy()
    for seed in [(450,850),(850,200)]:ImageDraw.floodfill(components,seed,128)
    keep=np.asarray(components)==128
    mask=Image.fromarray(np.where(keep,np.asarray(mask),0).astype('uint8'))
    out=a.copy()
    repaired=np.asarray(subsidy_combine(size,ink_repairs))>0
    original_paper=(a[:,:,0]>210)&(a[:,:,1]>200)&(a[:,:,2]>180)&(a[:,:,3]>180)
    # Newly revealed pinches/limb edges are native dark ink, never a remnant
    # yellow money pixel. Existing paper and original dark pixels are copied.
    tinted_coin_edge=((a[:,:,1].astype('int16')-a[:,:,2])>17)&((a[:,:,0].astype('int16')-a[:,:,1])>7)
    repair=repaired&(~dark|tinted_coin_edge|(a[:,:,3]<230))&~original_paper
    out[repair,:3]=(30,23,14)
    native_alpha=np.where(repaired&(a[:,:,3]<230),255,a[:,:,3])
    out[:,:,3]=((native_alpha.astype('uint16')*np.asarray(mask)+127)//255).astype('uint8')
    foreground=Image.fromarray(out)
    return foreground,mask



class Baiyibutie(NativePainter):
    card='baiyibutie';count=48;mode='once'
    boxes=((45,40,1180,1225),)
    notes='The original conical money mountain loses height and settles continuously into its broad native ground heap. No spawned coin streams: original cash field retains pixel color and overlap, three original perimeter coins settle outward, original person/bag/hand remain fixed with complete exposed ink edges.'
    def __init__(self):
        super().__init__()
        self.foreground,self.frontmask=subsidy_foreground(self.original)
        a=np.asarray(self.original)
        fg=np.asarray(self.foreground).copy()
        fringe=(fg[:,:,3]>0)&(fg[:,:,0]>160)&(fg[:,:,1]>125)&(fg[:,:,2]<180)
        fringe&=(fg[:,:,0].astype(float)-fg[:,:,2])>.33*(fg[:,:,0].astype(float)-29)+5
        fg[fringe,:3]=(30,23,14)
        self.foreground=Image.fromarray(fg)
        native=(np.asarray(self.foreground)==a).all(2)&(a[:,:,3]>230)
        native[:260,:]=True
        self.fixed_native=Image.fromarray(native.astype('uint8')*255)
        self.gold=(a[:,:,3]>200)&(a[:,:,0]>190)&(a[:,:,1]>150)&(a[:,:,2]<185)
        self.gold&=(a[:,:,0].astype(float)-a[:,:,2])>.33*(a[:,:,0].astype(float)-29)+5
        # Exact source cash and yen marks; detached movement strokes do not move as loose fragments.
        cash=dilate_disk(Image.fromarray(self.gold.astype('uint8')*255),15)
        cash=ImageChops.subtract(cash,self.frontmask)
        # Never let paper-edge AA masquerade as yellow cash, nor copy old wrist strokes into the falling field.
        bounds=polygon_mask(self.size,[(530,265),(810,265),(840,640),(965,680),(1060,1030),
                         (1180,1090),(1180,1220),(62,1220),(65,1060),(135,850),(288,780),(350,690),
                         (345,475),(467,350),(520,319)],True)
        cash=ImageChops.multiply(cash,bounds)
        hand_near=dilate_disk(subsidy_paper_region(self.original,(850,200)),23)
        cash_array=np.asarray(cash).copy()
        cash_array[(np.asarray(hand_near)>0)&(np.indices(self.gold.shape)[0]<455)]=0
        cash=Image.fromarray(cash_array)
        self.cashmask=cash
        self.field=content(self.original,cash)
        self.side=[]
        for seed in ((409,554),(890,752),(201,921)):
            coin,mask=native_component(self.original,seed,(60,260,1180,1225))
            self.side.append((coin,seed));self.field=clear(self.field,mask)
        # Native whole front-facing coins define the heap's rounded top contour.
        # Retaining all low fragments would leave bits of previously occluding coin rims at the crest.
        floor=rect_mask(self.size,[(60,1020,1180,1225)])
        for seed in ((621,954),(977,963),(840,1005),(314,960),(712,942),(718,969),
                     (244,1015),(182,1035),(392,1013),(542,1035)):
            part=dilate_disk(self.gold_region(seed),13)
            floor=ImageChops.lighter(floor,part)
        self.floor=content(self.field,floor)
        # The three coins hidden by the fingers must become complete objects.
        # Erase their source faces as well as the old hand-shaped edge before
        # replacing them: compositing the cut source faces over a complete coin
        # would reintroduce a thin finger contour and two misaligned yen marks.
        # The three genuinely foreground coins below retain their native pixels.
        frontcoins=subsidy_combine(self.size,[dilate_disk(self.gold_region(seed),13)
                  for seed in ((520,465),(640,530),(780,525))])
        between=subsidy_combine(self.size,[dilate_disk(self.gold_region(seed),13)
                for seed in ((666,427),(704,460))])
        nativebetween=content(self.field,between)
        oldtop=subsidy_combine(self.size,[dilate_disk(self.gold_region(seed),16)
               for seed in ((580,410),(668,380),(749,419))])
        repaired=clear(self.field,oldtop)
        repaired.alpha_composite(nativebetween)
        coinmask=dilate_disk(self.gold_region((704,869)),13)
        coin=content(self.original,coinmask)
        # Back coin, then the left coin, then the originally upper/front coin.
        # All three are same-card closed native silhouettes; the original lower
        # round coins are restored above them, preserving their overlap order.
        for dx,dy in ((33,-408),(-120,-455),(-19,-497)):
            repaired.alpha_composite(affine_pose(coin,(713,841),dx=dx,dy=dy))
        repaired=Image.composite(self.field,repaired,frontcoins)
        self.field=repaired
        # Moving courses become occluded at the real native heap footprint, never through its floor.
        envelope=np.asarray(content(self.original,cash).getchannel('A')).copy();envelope[:1080,:]=255
        self.floor_envelope=Image.fromarray(envelope)
    def gold_region(self,seed):
        region=Image.fromarray(self.gold.astype('uint8')*255).copy()
        if region.getpixel(seed)!=255:
            x,y=seed;ys,xs=np.where(self.gold[y-20:y+21,x-20:x+21])
            if not len(xs):raise ValueError(f'百亿金币采样点不在原金币内: {seed}')
            nearest=int(np.argmin((xs-20)**2+(ys-20)**2))
            seed=(x-20+int(xs[nearest]),y-20+int(ys[nearest]))
        ImageDraw.floodfill(region,seed,128)
        core=region.point(lambda p:255 if p==128 else 0)
        # Fill enclosed yen marks before growing to the genuine native rim.
        outside=core.copy();ImageDraw.floodfill(outside,(0,0),128)
        return outside.point(lambda p:0 if p==128 else 255)
    def paint(self,t):
        canvas=Image.new('RGBA',self.size);age=max(0,min(t,3.5)-.25)
        # One coherent collapse of the actual mountain, not three replacement emitters.
        dy=700*ease(age/3.05)
        canvas.alpha_composite(affine_pose(self.field,(650,750),dy=dy))
        canvas.alpha_composite(self.floor)
        for j,(coin,seed) in enumerate(self.side):
            target=((135,1110),(1070,1075),(195,1110))[j]
            q=ease((age-.10*j)/2.4)
            canvas.alpha_composite(affine_pose(coin,seed,dx=(target[0]-seed[0])*q,
                                               dy=(target[1]-seed[1])*q))
        canvas=content(canvas,self.floor_envelope)
        canvas.alpha_composite(self.foreground)
        return Image.composite(self.original,canvas,self.fixed_native)


class Liulianghe(NativePainter):
    card='liulianghe';count=84;mode='once'
    boxes=((321,54,764,468),(140,650,1248,1254),(422,266,805,464))
    notes='One continuous conical native-user outflow. All ten source users retain their initial anchors then spread down/out along original rays from (674,700); the lower four settle after shorter travel so the original cone never empties into a sparse outline. Fourteen same-card users follow at 0.34s intervals, alternating middle and side trajectories, clear the actual outlet and fan outward with depth. Twenty-four complete terminal users retain native pixels in a naturally staggered narrow-top/wide-base cone, never rectangular rows.'
    def __init__(self):
        super().__init__()
        points=path(((509,77),(597,60),(674,146),(700,245)),
                    ((700,245),(716,327),(700,390),(641,409)),
                    ((641,409),(565,447),(450,418),(394,346)),
                    ((394,346),(324,256),(346,160),(410,110)),
                    ((410,110),(451,79),(487,73),(509,77)))
        self.coinmask=polygon_mask(self.size,points,True).filter(ImageFilter.MaxFilter(13))
        # 原后侧金边的尖端一并包含，不能只拿走大圆面还残留三个黄色像素。
        tiny=ellipse_mask(self.size,(438,390,488,436))
        self.coinmask=Image.fromarray(np.maximum(np.asarray(self.coinmask),np.asarray(tiny)))
        self.coin=content(self.original,self.coinmask)
        self.base=clear(self.original,self.coinmask)
        repair=Image.new('RGBA',self.size)
        # 接续金币原来遮住的旋涡左上口：与原右半口同一透视椭圆。
        # 原图右侧 x=714 的真实边界依次为：墨边 223–239、纸带 240–259、
        # 纸带 279–289、最内条 313–316、前口 426–442。每一条单独接到这些高度，
        # 不能拿一个新椭圆裁在金币轮廓里造成阶梯接缝。
        surface=path(((330,299),(443,244),(592,228),(714,234)),
                     ((714,234),(716,300),(716,387),(714,443)),
                     ((714,443),(589,475),(436,482),(330,478)),
                     ((330,478),(314,413),(314,348),(330,299)))
        sm=polygon_mask(self.size,surface,True)
        repair.paste((29,24,19,254),(0,0,*self.size),sm)
        stroke_path(repair,path(((330,299),(443,244),(592,228),(714,234))),17,(23,19,14,254))
        strips=(
            path(((330,310),(447,253),(601,237),(714,240)),
                 ((714,240),(714,245),(714,254),(714,260)),
                 ((714,260),(608,257),(450,273),(330,334)),
                 ((330,334),(325,327),(325,317),(330,310))),
            path(((371,401),(366,340),(564,278),(714,279)),
                 ((714,279),(714,281),(714,287),(714,289)),
                 ((714,289),(570,289),(380,355),(382,401)),
                 ((382,401),(379,409),(373,409),(371,401))),
            path(((443,410),(436,373),(596,314),(714,313)),
                 ((714,313),(714,314),(714,316),(714,317)),
                 ((714,317),(601,323),(453,380),(455,412)),
                 ((455,412),(451,419),(446,417),(443,410))),
        )
        for strip in strips:
            m=polygon_mask(self.size,strip,True)
            repair.paste((251,243,216,254),(0,0,*self.size),m)
        # 前口也沿原左/右边界接续，完全遮住币后端，但不采入旧币的白色侧齿。
        front=path(((330,432),(441,463),(630,443),(714,426)),
                   ((714,426),(714,432),(714,438),(714,443)),
                   ((714,443),(624,464),(440,485),(330,494)),
                   ((330,494),(323,475),(323,454),(330,432)))
        repair.paste((251,243,216,254),(0,0,*self.size),polygon_mask(self.size,front,True))
        # 单次区域取样保持原生不透明度，不能擦一遍、再叠一遍生成半透明细圈。
        self.base=Image.composite(repair,self.original,self.coinmask)
        self.lip=Image.new('RGBA',self.size)
        # 仅擦掉原动势曲线本身；它们下面的上口墨边不能跟着被擦除。
        motion=Image.new('RGBA',self.size)
        stroke_path(motion,path(((671,121),(698,141),(709,177),(716,200))),24,(255,255,255,255))
        stroke_path(motion,path(((728,131),(746,157),(747,179),(750,184))),23,(255,255,255,255))
        self.base=clear(self.base,motion.getchannel('A'))
        self.people=[]
        for seed in ((674,800),(524,829),(851,879),(471,950),(657,976),(798,1007),(356,1090),(741,1106),(587,1155),(967,1117)):
            im,mask=native_component(self.original,seed,(250,739,1065,1240))
            self.people.append((im,seed))
        self.bottom=rect_mask(self.size,[(250,739,1065,1240)])
        funnel,funnelmask=native_component(self.original,(650,640),(0,0,1254,1254))
        # 原尖端与最上方用户的头恰好接触，alpha 连通域不能直接当旋涡。
        # 将前景严格约束在本体：744px 以下只保留真实尖端，绝不含任何人头/手。
        actual_tip=polygon_mask(self.size,[(638,743),(723,743),(714,755),(700,763),(680,766),(659,762),(647,752)],True)
        physical=Image.fromarray(np.maximum(np.asarray(rect_mask(self.size,[(0,0,1254,744)])),np.asarray(actual_tip)))
        funnelmask=Image.fromarray(np.minimum(np.asarray(funnelmask),np.asarray(physical)))
        self.people=[(clear(im,funnelmask),seed) for im,seed in self.people]
        # 同一原人物的完整头轮廓作为人群前景。密集手脚仍完整绘制在后，
        # 不能让下一人的抬腿穿进上一人的眼睛/嘴巴；不重画、不缩放原脸。
        self.heads=[self.native_head(im,seed) for im,seed in self.people]
        mouth=Image.fromarray(np.minimum(np.asarray(funnelmask),np.asarray(rect_mask(self.size,[(0,739,1254,790)]))))
        self.base=clear(self.base,self.bottom)
        self.base=Image.composite(self.original,self.base,mouth)
        # 人流只需被下方旋风遮挡；顶端投币区不能在末次前景恢复时盖掉运动金币。
        self.funnelmask=Image.fromarray(np.minimum(np.asarray(funnelmask),
            np.asarray(rect_mask(self.size,[(0,420,1254,1254)]))))
        # 原十人沿原射线落位；底部空间较少就短距离落下，不能先离场清空原锥形。
        self.retained={0:1010,1:920,2:999,3:1000,4:1096,5:1127,
                       6:1122,7:1130,8:1188,9:1130}
        # 原人物、原尺寸；目标依锥形逐层变宽，并刻意错开头部，避免三行矩形。
        # 中路/两侧交替补入，再填上方；每0.34s连续出人，不清空原人后再换一批。
        self.stream=(
            (4,(574,1033)),(2,(765,1044)),(5,(1110,1130)),(1,(466,1129)),
            (1,(805,957)),(3,(512,963)),(2,(1075,1047)),(6,(341,987)),
            (7,(878,1031)),(5,(880,886)),(1,(674,920)),(3,(567,874)),
            (5,(770,870)),(6,(674,815)))

    @staticmethod
    def native_head(im,seed):
        a=np.asarray(im)
        paper=(a[:,:,3]>180)&(a[:,:,0]>210)&(a[:,:,1]>200)&(a[:,:,2]>180)
        x,y=seed
        ys,xs=np.where(paper[y-20:y+21,x-20:x+21])
        j=int(np.argmin((xs-20)**2+(ys-20)**2))
        point=(x-20+int(xs[j]),y-20+int(ys[j]))
        region=Image.fromarray(paper.astype('uint8')*255).copy()
        ImageDraw.floodfill(region,point,128)
        core=region.point(lambda v:255 if v==128 else 0)
        exterior=core.copy();ImageDraw.floodfill(exterior,(0,0),128)
        inside=exterior.point(lambda v:0 if v==128 else 255)
        return content(im,dilate_disk(inside,14))

    @staticmethod
    def flow_distance(age,distance=None):
        """共享人流：0.25s内加速至240px/s，落位前48px连续减速。"""
        age=max(0,age);speed=240.0;ramp=.25;brake=48.0
        free=speed*age*age/(2*ramp) if age<ramp else speed*(age-ramp/2)
        if distance is None:return free
        if distance<speed*ramp/2+brake:
            # 画幅底部只需短距离落位时，用同一加减速度的三角速度曲线，
            # 不允许短行程套用48px刹车后负位移，造成起步向上跳。
            acceleration=speed/ramp;deceleration=speed*speed/(2*brake)
            peak=math.sqrt(2*distance/(1/acceleration+1/deceleration))
            accelerating=peak/acceleration;duration=accelerating+peak/deceleration
            if age<accelerating:return acceleration*age*age/2
            return distance-deceleration*max(0,duration-age)**2/2
        begin=(distance-brake)/speed+ramp/2
        if age<=begin:return free
        duration=2*brake/speed;u=min(duration,max(0,age-begin))
        return distance-brake+speed*u-speed*u*u/(2*duration)

    def paint(self,t):
        canvas=self.base.copy()
        u=ease((t-.25)/1.0)
        moved=affine_pose(self.coin,(525,246),dx=130*u,dy=430*u)
        if u<1:canvas.alpha_composite(content(moved,rect_mask(self.size,[(0,0,1254,410)])))
        actors=[]
        heads=[]
        for i,(im,seed) in enumerate(self.people):
            # 一开始即延续原十人锥形：射线比例由原锚点决定，不把原构图瞬间换位。
            age=t-.25
            landing=self.retained.get(i)
            dy=self.flow_distance(age,None if landing is None else landing-seed[1])
            y=seed[1]+dy
            x=674+(seed[0]-674)*(y-700)/(seed[1]-700)
            actors.append((y,affine_pose(im,seed,dx=x-seed[0],dy=dy)))
            heads.append((y,affine_pose(self.heads[i],seed,dx=x-seed[0],dy=dy)))
        for n,(index,target) in enumerate(self.stream):
            start=.25+n*.34
            if t<=start:continue
            im,seed=self.people[index]
            age=t-start
            y=700+self.flow_distance(age,target[1]-700)
            # 先完整越过真实尖端；不在画内设会横切人头的统一裁口。
            clear_y=774-(im.getbbox()[1]-seed[1])
            # 横向展开随下降深度增加；在同一锥体内，下方更宽，上方更窄。
            q=min(1,max(0,(y-clear_y)/max(1,target[1]-clear_y)))
            scatter=q*q*(3-2*q)
            x=674+(target[0]-674)*scatter
            layer=affine_pose(im,seed,dx=x-seed[0],dy=y-seed[1])
            actors.append((y,layer))
            heads.append((y,affine_pose(self.heads[index],seed,dx=x-seed[0],dy=y-seed[1])))
        # 同一条流按远近遮挡：下方的完整脸在前，不能被上一人的脚盖住。
        for _,layer in sorted(actors,key=lambda actor:actor[0]):canvas.alpha_composite(layer)
        for _,layer in sorted(heads,key=lambda actor:actor[0]):canvas.alpha_composite(layer)
        # 只用真实旋涡轮廓作前景遮挡，不能在下方空白处设一条截掉所有头的水平线。
        return Image.composite(self.base,canvas,self.funnelmask)


class Jiaolv(NativePainter):
    card='jiaolv';count=56;mode='once'
    boxes=((459,600,713,804),(490,798,879,1060),(300,693,620,958),(496,398,562,492),(690,409,765,500))
    notes='Anxious customer pays through the actual existing slot; complete framed/stamped diploma moves through outlet and lands behind tray front; same user reaches it.'
    def __init__(self):
        super().__init__()
        self.coinmask=ellipse_mask(self.size,(493,609,686,795)).filter(ImageFilter.MaxFilter(11))
        self.coin=content(self.original,self.coinmask)
        self.base=self.original.copy()
        fill=gradient_fill(self.original,self.coinmask,(398,602,939,967),lambda a:(a[:,:,0]>245)&(a[:,:,1]>225)&(a[:,:,2]>190))
        self.base=Image.composite(fill,self.base,self.coinmask)
        # 修复藏在币背后的原灰色窄投币口，入口方向沿原纵向，币水平进入。
        round_box(self.base,(641,620,691,755),12,(131,122,104,254),16)
        self.slotfront=content(self.base,rect_mask(self.size,[(641,604,712,780)]))
        arm=rect_mask(self.size,[(350,689,564,833)])
        repaired=gradient_fill(self.original,arm,(398,602,939,967),lambda a:(a[:,:,0]>245)&(a[:,:,1]>225)&(a[:,:,2]>190))
        self.base=Image.composite(repaired,self.base,arm)
        # 原手臂遮住的机器左边也是完整竖边，接到下方 x393–412 的原墨边。
        # 不用矩形覆盖边缘后留下 y833 的阶梯断口。
        stroke_path(self.base,[(402,688),(402,838)],20,(26,20,14,254))
        self.headmask=polygon_mask(self.size,path(((293,489),(353,484),(414,519),(438,569)),
                      ((438,569),(485,662),(432,728),(394,750)),
                      ((394,750),(372,760),(342,768),(334,772)),
                      ((334,772),(288,790),(230,778),(202,753)),
                      ((202,753),(166,731),(139,684),(149,619)),
                      ((149,619),(156,544),(215,489),(293,489))),True).filter(ImageFilter.MaxFilter(13))
        self.base=Image.composite(self.original,self.base,self.headmask)
        self.bodymask=polygon_mask(self.size,path(((238,762),(276,770),(318,782),(336,793)),
                      ((336,793),(356,801),(366,812),(372,833)),
                      ((372,833),(385,879),(371,922),(346,939)),
                      ((346,939),(299,960),(233,954),(202,923)),
                      ((202,923),(170,881),(197,808),(238,762))),True).filter(ImageFilter.MaxFilter(9))
        self.base=Image.composite(self.original,self.base,self.bodymask)
        self.hand=content(self.original,ellipse_mask(self.size,(490,710,550,772)))
        self.trayfront=content(self.original,polygon_mask(self.size,[(497,925),(834,963),(832,1054),(500,1008)],True))
        self.trayside=content(self.original,polygon_mask(self.size,[(834,953),(867,902),(864,985),(832,1054)],True))
        self.paper=certificate(self.size,(561,872,824,969))
    def paint(self,t):
        canvas=self.base.copy()
        p=ease((t-.25)/1.25)
        if p<1:
            move=affine_pose(self.coin,(595,707),dx=180*p)
            canvas.alpha_composite(content(move,rect_mask(self.size,[(0,0,646,1254)])))
        canvas.alpha_composite(self.slotfront)
        # 手实际推币，撤手后才开始出货；原人物头、身体、脚完全不移动。
        if .25<t<2.0:
            push=180*p*(1-ease((t-1.50)/.5))
            arm=path(((337,790),(429,768),(486+push,742),(517+push,740)))
            stroke_path(canvas,arm,64,INK);stroke_path(canvas,arm,28,CREAM)
            circle(canvas,(517+push,740),24,(252,239,210,254),width=16)
        elif t<3.25:
            arm=path(((337,790),(429,768),(486,742),(517,740)))
            stroke_path(canvas,arm,64,INK);stroke_path(canvas,arm,28,CREAM)
            circle(canvas,(517,740),24,CREAM,width=16)
        # 第一帧的文凭是已售样张；新文凭从同一个实际出口逐渐送出，仍在前板后。
        if t>=2.0:
            out=ease((t-2)/1.25)
            paper=affine_pose(self.paper,(690,900),dx=14*out,dy=-90*(1-out)-13*out)
            layer=content(paper,polygon_mask(self.size,[(511,852),(860,863),(858,998),(511,977)],True))
            canvas.alpha_composite(layer)
        canvas.alpha_composite(self.trayfront);canvas.alpha_composite(self.trayside)
        if 3.25<t:
            r=ease((t-3.25)/.75)
            hx=520+(585-520)*r;hy=740+(894-740)*r
            arm=path(((337,790),(438,791),(hx-21,hy-11),(hx,hy)))
            stroke_path(canvas,arm,64,INK);stroke_path(canvas,arm,28,CREAM)
            circle(canvas,(hx,hy),21,CREAM,width=14)
        if 1.5<t<2.0:
            # 仅局部嘴角添紧张弧，焦虑脸不替换或晃动。
            tension=math.sin(math.pi*(t-1.5)/.5)
            for x,y in ((526,477),(720,486)):
                stroke_path(canvas,[(x-17,y+8),(x,y-5*tension),(x+17,y+8)],8,INK)
        canvas=Image.composite(self.original,canvas,self.bodymask)
        return canvas


class Shanzhai(NativePainter):
    card='shanzhai';count=62;mode='once'
    boxes=((344,413,731,630),(333,647,1120,1216))
    notes='Three scan-to-print cycles; each full native bulb sheet crosses the real output slot before landing. Original two sheets and all equipment stay fixed.'
    def __init__(self):
        super().__init__()
        outline=path(((623,713),(681,696),(757,677),(809,665)),
                     ((809,665),(821,662),(827,672),(835,682)),
                     ((835,682),(883,736),(927,788),(958,829)),
                     ((958,829),(966,839),(957,843),(946,847)),
                     ((946,847),(875,870),(803,894),(736,915)),
                     ((736,915),(724,919),(720,910),(714,900)),
                     ((714,900),(681,846),(646,787),(611,728)),
                     ((611,728),(605,718),(612,716),(623,713)))
        m=polygon_mask(self.size,outline,True)
        fill=gradient_fill(self.original,m,(625,680,964,920),lambda a:(a[:,:,0]>245)&(a[:,:,1]>220)&(a[:,:,2]>210))
        self.paper=content(fill,m)
        stroke_path(self.paper,outline+[outline[0]],18,INK)
        # 原灯泡与全部射线逐像素随同整张纸移动；新四边是完整闭合轮廓。
        inner=m.filter(ImageFilter.MinFilter(43))
        self.paper.alpha_composite(content(self.original,inner))
        yy,xx=np.mgrid[0:self.size[1],0:self.size[0]]
        exterior=yy>=(-.325*(xx-620)+735)
        self.outside=Image.fromarray((exterior*255).astype('uint8'))
        self.scanmask=polygon_mask(self.size,[(359,487),(593,394),(809,541),(497,649)],True)
    def paint(self,t):
        canvas=self.original.copy()
        for i,(dx,dy) in enumerate(((-260,102),(-105,285),(108,280))):
            start=.5+i*1.25
            elapsed=t-start
            if elapsed<=0:continue
            if elapsed<.25:
                q=elapsed/.25
                x=384+290*q
                scan=Image.new('RGBA',self.size)
                stroke_path(scan,[(x,421),(x+48,615)],14,GOLD)
                canvas.alpha_composite(content(scan,self.scanmask))
            out=ease((elapsed-.20)/.78)
            land=ease((elapsed-.97)/.28)
            paper=affine_pose(self.paper,(780,800),dx=dx*land,dy=-278*(1-out)+dy*land)
            if out<1:
                visible=Image.fromarray(np.minimum(np.asarray(self.outside),np.asarray(rect_mask(self.size,[(598,645,979,955)]))))
                paper=content(paper,visible)
            canvas.alpha_composite(paper)
        return canvas


class Liebian(NativePainter):
    card='liebian';count=62;mode='once'
    boxes=((211,809,1120,1207),)
    notes='Only lower two square cards grow new cracks, separate into four complete square character cards, and keep the four-card terminal.'
    def __init__(self):
        super().__init__()
        self.cards=[]
        self.base=self.original.copy()
        for box,center in [((285,812,611,1142),(448,977)),((658,813,977,1149),(810,979))]:
            roi=rect_mask(self.size,[box])
            occupied=Image.fromarray(((np.asarray(self.original.getchannel('A'))>80)&(np.asarray(roi)>128)).astype('uint8')*255).copy()
            ImageDraw.floodfill(occupied,center,128)
            # 只复制这张完整纸卡连通轮廓；上方固定箭头的独立尾线不属于子卡。
            core=occupied.point(lambda a:255 if a==128 else 0)
            unrelated=occupied.point(lambda a:255 if a==255 else 0).filter(ImageFilter.MaxFilter(7))
            grown=core.filter(ImageFilter.MaxFilter(7))
            # 只补纸边自己的抗锯齿圈，不能外扩后又把近邻固定尾端采回。
            m=Image.fromarray(np.maximum(np.asarray(core),np.minimum(np.asarray(grown),255-np.asarray(unrelated))))
            m=Image.fromarray(np.minimum(np.asarray(m),np.asarray(roi)))
            im=content(self.original,m)
            self.cards.append((im,center,box))
            self.base=clear(self.base,m)
    def paint(self,t):
        canvas=self.base.copy()
        cracks=ease((t-.5)/1.0)
        separation=ease((t-1.5)/1.5)
        finish=ease((t-3.0)/1.25)
        for k,(im,center,box) in enumerate(self.cards):
            cx,cy=center
            if separation<=0:
                canvas.alpha_composite(im)
                if cracks>0:
                    points=[(cx+4,box[1]+18),(cx-13,box[1]+66),(cx+15,box[1]+107),
                            (cx-9,box[1]+153),(cx+14,box[1]+202),(cx-11,box[1]+249),(cx+7,box[3]-18)]
                    n=max(2,round(cracks*(len(points)-1))+1)
                    stroke_path(canvas,points[:n],10,INK)
            else:
                # 断口先分开：两半保留原人图案，内侧补新纸边，再显出完整子卡。
                for side in (0,1):
                    direction=-1 if side==0 else 1
                    targetx=(320,544,759,983)[2*k+side]
                    tx=cx+(targetx-cx)*separation
                    ty=cy+(1120-cy)*(.22*separation+.18*finish)
                    scale=1-.37*separation
                    moved=affine_pose(im,center,sx=scale,sy=scale,dx=tx-cx,dy=ty-cy)
                    # 补全从断口露出的新半边不是凭空淡入：只在裂口宽度随分离增大时显露。
                    yy,xx=np.mgrid[0:self.size[1],0:self.size[0]]
                    full_width=(box[2]-box[0])*scale
                    reveal=full_width*(.50+.50*separation)
                    if side==0:
                        m=(xx>=tx-full_width/2)&(xx<=tx-full_width/2+reveal)
                    else:
                        m=(xx<=tx+full_width/2)&(xx>=tx+full_width/2-reveal)
                    piece=content(moved,Image.fromarray((m*255).astype('uint8')))
                    if separation<.98:
                        # 新纸边就在真正可见的截口上，且接到同一张缩放后的上下纸边。
                        edge=tx-direction*.5*full_width*separation
                        half_height=(box[3]-box[1])*scale/2
                        seam=Image.new('RGBA',self.size)
                        stroke_path(seam,[(edge,ty-half_height+5),(edge,ty+half_height-5)],12*scale,INK)
                        # 墨线在纸内，不能多出悬在外面的独立竖线。
                        seam=content(seam,piece.getchannel('A'))
                        piece.alpha_composite(seam)
                    canvas.alpha_composite(piece)
        return canvas


class Tuisong(NativePainter):
    card='tuisong';count=60;mode='loop'
    boxes=((70,0,1215,1160),)
    notes='Only the three existing native notifications bounce together on their original spring. No new window, glyph, copy or extra notification is created; phone stays fixed and the spring compresses around its true bottom attachment.'
    def __init__(self):
        super().__init__()
        # 补齐原来被弹窗遮住的同一手机，露出时仍是完整设备。
        phone=Image.new('RGBA',self.size)
        round_box(phone,(429,716,834,1165),52,CREAM,25)
        round_box(phone,(454,748,808,1112),28,(255,236,177,254),16)
        stroke_path(phone,[(571,1136),(692,1136)],12,INK)
        spring_path=path(((588,654),(540,664),(482,689),(500,716)),
                ((500,716),(527,741),(662,690),(637,730)),
                ((637,730),(618,747),(494,760),(530,793)),
                ((530,793),(573,814),(678,767),(639,818)),
                ((639,818),(613,845),(513,850),(546,878)),
                ((546,878),(583,908),(669,865),(640,919)),
                ((640,919),(629,952),(540,954),(579,980)),
                ((579,980),(601,998),(645,1002),(625,1027)))
        # 弹簧用静止图完全相同的路径与笔色补齐；旧图被纸边截断的接点不能硬裁后拉伸。
        self.spring=Image.new('RGBA',self.size)
        stroke_path(self.spring,spring_path,45,INK)
        stroke_path(self.spring,spring_path,24,GOLD)
        # 三窗保留原像素及原遮挡。下轮廓沿真实纸边，排除紧贴其后的旧电脑残墨和手机边。
        boundary=[(0,0),(1254,0),(1254,830),(1190,830),(1085,800),
                  (1045,817),(740,727),(717,714),(717,690),(600,677),
                  (580,674),(580,657),(215,724),(0,735)]
        self.groupmask=polygon_mask(self.size,boundary,True)
        self.group=content(self.original,self.groupmask)
        # 完整手机没有原来被弹窗盖住的缺口；手机下部继续取原像素。
        self.base=phone
        lower=rect_mask(self.size,[(0,1060,1254,1254)])
        self.base=Image.composite(self.original,self.base,lower)
    def paint(self,t):
        elapsed=t-1/3
        if elapsed<=0 or elapsed>=4.2:return self.original.copy()
        envelope=math.sin(math.pi*elapsed/4.2)
        dy=-82*math.sin(math.tau*elapsed/1.3)*envelope
        if abs(dy)<.05:return self.original.copy()
        canvas=self.base.copy()
        scale=(1027-(654+dy))/(1027-654)
        canvas.alpha_composite(affine_pose(self.spring,(625,1027),sy=scale))
        canvas.alpha_composite(affine_pose(self.group,(625,654),dy=dy))
        return canvas


PAINTERS=(Touliu,Xinxijianfang,Baiyibutie,Liulianghe,Jiaolv,Shanzhai,Liebian,Tuisong)

if __name__=='__main__':
    import sys
    if '--fix-static' in sys.argv:
        fix_static_icons();sys.argv.remove('--fix-static')
    run(PAINTERS)
