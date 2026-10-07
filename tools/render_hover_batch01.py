#!/usr/bin/env python3
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""第一批五张牌：在唯一原 PNG 的固定坐标内绘制姿势，输出原生完整帧。

使用工作区附带 Python（Pillow、NumPy）。默认只写 build 下的制作与检查记录；
--install 才接入 data/ui.json。所有采样始终来自原稿，没有运行时部件或累计变换。
"""
import argparse
import hashlib
import json
import math
import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

from render_cloud_hover import cubic, ease, stroke_path
from hover_source_art import native_icon_path, uses_compact_art

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/art_generation/batch01_local_canvas"
FPS = 12
# 起始原图仍停留 0.25 秒；只压缩动作时间，在 12 fps 下重新求出每帧姿势。
ACTION_SPEED = 1.5
CARDS = ("baoyue", "pinshaoshao", "shuabuting", "ditui", "waimai")
HASHES = {
    "baoyue": "e8f4027a9afe1421030e7c9c2a8d64197234c89b4b426db384e79f0ea4a85c62",
    "pinshaoshao": "941cb1e160714a13f65855bd8c9955080b9ab57bb50475a3366df9761e0fd82a",
    "shuabuting": "814b2c5d866c1117ba89024c1fbc68a546f66c29bf8629716486103d3c86c55d",
    "ditui": "c3432d3f7f3d0252f825b04a8f4139c1c0983bfc2a904d6fe59d6914a9cd72b9",
    "waimai": "70c941e67ab4e37aaa17f033a35a5ade9c739582e35b3fd3cec72649c2c8a50b",
}


def path(*segments):
    return [p for seg in segments for p in cubic(seg)]


def polygon_mask(size, points, aa=False):
    scale = 4 if aa else 1
    im = Image.new("L", (size[0]*scale, size[1]*scale))
    ImageDraw.Draw(im).polygon([(round(x*scale), round(y*scale)) for x, y in points], fill=255)
    return im.resize(size, Image.Resampling.LANCZOS) if aa else im


def rect_mask(size, boxes):
    im = Image.new("L", size)
    d = ImageDraw.Draw(im)
    for x0, y0, x1, y1 in boxes:
        d.rectangle((x0,y0,x1-1,y1-1),fill=255)
    return im


def ellipse_mask(size,box):
    im=Image.new('L',size)
    ImageDraw.Draw(im).ellipse(box,fill=255)
    return im


def isolated_marks(source, seeds):
    """取出原图中指定的独立墨迹，不能用矩形连同后面的旧主体一起贴回。"""
    binary=source.getchannel('A').point(lambda a:255 if a>8 else 0)
    result=Image.new('L',source.size)
    for seed in seeds:
        flood=binary.copy()
        if flood.getpixel(seed)!=255:
            raise ValueError(f'独立墨迹种子不在墨迹中：{seed}')
        ImageDraw.floodfill(flood,seed,128)
        selected=flood.point(lambda a:255 if a==128 else 0)
        box=selected.getbbox()
        if box[2]-box[0]>180 or box[3]-box[1]>180:
            raise ValueError(f'独立墨迹与主体连通，需要重新标注：{seed} {box}')
        result=Image.fromarray(np.maximum(np.asarray(result),np.asarray(selected)))
    return result.filter(ImageFilter.MaxFilter(3))


def detached_marks(source):
    """保留原稿中全部独立汗滴、碎片和动势线；排除连通的主图。"""
    pending=source.getchannel('A').point(lambda a:255 if a>8 else 0)
    result=Image.new('L',source.size)
    while pending.getbbox():
        arr=np.asarray(pending)
        y,x=np.argwhere(arr==255)[0]
        ImageDraw.floodfill(pending,(int(x),int(y)),128)
        selected=pending.point(lambda a:255 if a==128 else 0)
        bounds=selected.getbbox()
        # PNG 的孤立低 alpha 残点不是汗滴或碎片，不能覆盖新姿势挖出方孔。
        if bounds[2]-bounds[0]<180 and bounds[3]-bounds[1]<180 and selected.histogram()[255]>40:
            result=Image.fromarray(np.maximum(np.asarray(result),np.asarray(selected))).copy()
        pending=pending.point(lambda a:0 if a==128 else a)
    return result.filter(ImageFilter.MaxFilter(3))


def dilate_disk(mask,radius):
    """圆形笔触扩展实际轮廓；方形膨胀的角会误采相邻纸边或另一片刀刃。"""
    bounds=mask.getbbox()
    if bounds is None:
        return mask.copy()
    x0,y0,x1,y1=bounds
    box=(max(0,x0-radius),max(0,y0-radius),min(mask.width,x1+radius),min(mask.height,y1+radius))
    src=np.asarray(mask.crop(box));dst=src.copy();h,w=src.shape
    for dy in range(-radius,radius+1):
        span=int(math.sqrt(radius*radius-dy*dy))
        for dx in range(-span,span+1):
            sy0,sy1=max(0,-dy),min(h,h-dy);sx0,sx1=max(0,-dx),min(w,w-dx)
            view=dst[sy0+dy:sy1+dy,sx0+dx:sx1+dx]
            np.maximum(view,src[sy0:sy1,sx0:sx1],out=view)
    result=Image.new('L',mask.size);result.paste(Image.fromarray(dst),box[:2]);return result


def content(source, mask):
    im = source.copy()
    a = np.asarray(source.getchannel("A"),dtype=np.uint16)
    a = ((a*np.asarray(mask,dtype=np.uint16)+127)//255).astype(np.uint8)
    im.putalpha(Image.fromarray(a))
    return im


def affine_pose(source, pivot, angle=0, sx=1, sy=1, dx=0, dy=0):
    """一次从唯一原稿取样；不能对上一帧再变换。"""
    if abs(angle)<1e-12 and sx==sy==1:
        result = Image.new("RGBA",source.size)
        result.paste(source,(round(dx),round(dy)))
        return result
    c,s = math.cos(angle),math.sin(angle)
    px,py = pivot
    # 前向先缩紧再绕原连接点旋转，Pillow 使用逆映射。
    a,b,d,e = c/sx,s/sx,-s/sy,c/sy
    x,y = px+dx,py+dy
    return source.transform(source.size,Image.Transform.AFFINE,
                            (a,b,px-a*x-b*y,d,e,py-d*x-e*y),
                            resample=Image.Resampling.BICUBIC)


def gradient_fill(source, mask, sample_box, predicate=None):
    """只在需补出的底色区拟合原稿底色，保留其余像素；不调色整张原画。"""
    arr = np.asarray(source).copy()
    x0,y0,x1,y1 = sample_box
    sample = arr[y0:y1:3,x0:x1:3]
    yy,xx = np.mgrid[y0:y1:3,x0:x1:3]
    valid = (sample[:,:,3]>245)&(sample[:,:,0]>140)
    if predicate is not None:
        valid &= predicate(sample)
    xs,ys = (xx[valid]-x0)/max(x1-x0,1),(yy[valid]-y0)/max(y1-y0,1)
    mat = np.stack([np.ones_like(xs),xs,ys,xs*ys,xs*xs,ys*ys],axis=1)
    fit = np.linalg.lstsq(mat,sample[valid].astype(float),rcond=None)[0]
    ty,tx = np.nonzero(np.asarray(mask)>0)
    xs,ys = (tx-x0)/max(x1-x0,1),(ty-y0)/max(y1-y0,1)
    mat = np.stack([np.ones_like(xs),xs,ys,xs*ys,xs*xs,ys*ys],axis=1)
    arr[ty,tx] = np.clip(np.rint(mat@fit),0,255).astype(np.uint8)
    return Image.fromarray(arr)


def painted_polygon(canvas, points, fill, ink, width=14):
    mask = polygon_mask(canvas.size,points,True)
    canvas.paste(fill,(0,0,canvas.width,canvas.height),mask)
    stroke_path(canvas,points+[points[0]],width,ink)


class Painter:
    card = ""
    count = 36
    mode = "loop"
    boxes = ()

    def __init__(self):
        self.original = Image.open(native_icon_path(self.card)).convert("RGBA")
        if hashlib.sha256(self.original.tobytes()).hexdigest()!=HASHES[self.card]:
            raise ValueError(f"{self.card} 原稿改变，须重新核对坐标与接触关系")
        self.size = self.original.size
        self.allowed = rect_mask(self.size,self.boxes)

    def frame(self,index):
        if index<=3 or (self.mode=="loop" and index==self.count-1):
            return self.original.copy()
        seconds = .25 + (index/FPS-.25)*ACTION_SPEED
        canvas = self.paint(seconds)
        return Image.composite(canvas,self.original,self.allowed)


class Scissors:
    """拼少少：闭合的握柄、孔、细颈与刀面；每半把剪刀绕同一铆钉运动。"""
    def __init__(self,source,pivot):
        self.pivot=pivot
        size=source.size
        ink=(25,22,18,255)
        if pivot==(336,679):
            self.contact=(414,625)
            blades=(path(((330,663),(353,640),(397,603),(414,588)),
                         ((414,588),(396,635),(375,669),(345,695)),
                         ((345,695),(328,697),(320,680),(330,663))),
                    path(((325,668),(351,663),(400,644),(422,640)),
                         ((422,640),(414,656),(374,681),(348,696)),
                         ((348,696),(328,705),(310,690),(325,668))))
            top=path(((333,666),(314,667),(296,659),(289,640)),
                     ((289,640),(278,608),(247,599),(223,607)),
                     ((223,607),(187,618),(183,651),(201,677)),
                     ((201,677),(220,704),(246,712),(268,696)),
                     ((268,696),(289,680),(308,680),(333,693)),
                     ((333,693),(339,683),(339,674),(333,666)))
            bottom=path(((334,678),(344,688),(326,713),(309,738)),
                        ((309,738),(326,764),(316,788),(293,798)),
                        ((293,798),(263,812),(232,789),(240,762)),
                        ((240,762),(245,735),(271,721),(293,706)),
                        ((293,706),(315,690),(326,681),(334,678)))
            top_hole=path(((225,631),(245,622),(267,634),(268,646)),
                          ((268,646),(268,666),(239,671),(219,657)),
                          ((219,657),(210,648),(214,636),(225,631)))
            bottom_hole=path(((270,746),(282,733),(298,739),(298,751)),
                             ((298,751),(298,767),(287,779),(272,779)),
                             ((272,779),(255,776),(258,759),(270,746)))
            gold_sample=(199,610,315,799)
            metal_sample=(322,600,411,693)
        elif pivot==(955,883):
            self.contact=(878,832)
            blades=(path(((958,870),(928,844),(895,815),(877,801)),
                         ((877,801),(897,845),(921,876),(948,896)),
                         ((948,896),(970,903),(978,884),(958,870))),
                    path(((964,870),(930,863),(883,840),(865,829)),
                         ((865,829),(876,858),(919,893),(946,900)),
                         ((946,900),(969,907),(984,885),(964,870))))
            top=path(((956,862),(976,858),(991,850),(1001,836)),
                     ((1001,836),(1024,810),(1051,815),(1068,830)),
                     ((1068,830),(1098,853),(1088,884),(1067,895)),
                     ((1067,895),(1047,909),(1028,893),(1010,883)),
                     ((1010,883),(992,871),(978,876),(960,891)),
                     ((960,891),(952,882),(951,869),(956,862)))
            bottom=path(((955,880),(974,891),(992,912),(1010,929)),
                        ((1010,929),(1035,946),(1045,969),(1024,985)),
                        ((1024,985),(1005,1006),(972,985),(963,965)),
                        ((963,965),(950,944),(970,926),(967,913)),
                        ((967,913),(960,899),(951,891),(955,880)))
            top_hole=path(((1026,847),(1047,838),(1068,851),(1068,863)),
                          ((1068,863),(1069,881),(1040,883),(1026,869)),
                          ((1026,869),(1017,861),(1017,853),(1026,847)))
            bottom_hole=path(((982,939),(994,931),(1015,948),(1020,961)),
                             ((1020,961),(1026,976),(1007,983),(994,970)),
                             ((994,970),(981,960),(972,947),(982,939)))
            gold_sample=(958,819,1086,991)
            metal_sample=(874,809,970,896)
        else:
            raise ValueError(f'未核对的剪刀坐标：{pivot}')
        self.halves=[]
        # 上刀刃连接下握柄，下刀刃连接上握柄；不从零散颜色蒙版裁取细颈。
        for blade,handle,hole in ((blades[0],bottom,bottom_hole),
                                 (blades[1],top,top_hole)):
            part=Image.new('RGBA',size)
            hm=polygon_mask(size,handle,True)
            gold=gradient_fill(source,hm,gold_sample,
                lambda p:(p[:,:,0]>220)&(p[:,:,1]>190)&(p[:,:,2]<230))
            part.paste(gold,mask=hm)
            stroke_path(part,handle+[handle[0]],12,ink)
            part.paste((0,0,0,0),mask=polygon_mask(size,hole,True))
            stroke_path(part,hole+[hole[0]],11,ink)
            bm=polygon_mask(size,blade,True)
            metal=gradient_fill(source,bm,metal_sample,
                lambda p:np.min(p[:,:,:3],axis=2)>230)
            part.paste(metal,mask=bm)
            stroke_path(part,blade+[blade[0]],12,ink)
            self.halves.append(part)
        # 手掌和手臂画成完整闭合轮廓，不能把原握柄颈或旧刀线取进前景手掌。
        self.hand=Image.new('RGBA',size)
        if pivot==(336,679):
            arm=path(((212,699),(222,696),(238,707),(234,718)),
                     ((234,718),(214,735),(191,758),(172,768)),
                     ((172,768),(166,773),(151,767),(143,758)),
                     ((143,758),(157,742),(185,716),(212,699)))
            cx,cy,rx,ry=234,692,31,30
        else:
            arm=path(((1074,911),(1090,923),(1120,946),(1131,956)),
                     ((1131,956),(1134,962),(1124,973),(1116,975)),
                     ((1116,975),(1094,959),(1078,943),(1063,930)),
                     ((1063,930),(1062,922),(1067,916),(1074,911)))
            cx,cy,rx,ry=1054,906,29,29
        palm=[(cx+rx*math.cos(i*math.tau/128),cy+ry*math.sin(i*math.tau/128))
              for i in range(128)]
        # 手的原底色为暖奶油色（蓝通道约 198）；不能用 >220 的白色筛选，
        # 否则只剩抗锯齿亮点，二次曲面拟合会向手臂外推成荧光色。
        cream=source.getpixel((cx,cy))[:3]+(255,)
        for contour in (arm,palm):
            painted_polygon(self.hand,contour,cream,ink,13)
        # 铆钉仅保留圆盘本身，不取周围旧刀刃的肩部。
        self.joint=Image.new('RGBA',size)
        rivet=[(pivot[0]+8.5*math.cos(i*math.tau/64),
                pivot[1]+8.5*math.sin(i*math.tau/64)) for i in range(64)]
        painted_polygon(self.joint,rivet,ink,ink,1)

    def paint(self,canvas,closure,sign=1,dx=0,dy=0,scale=1):
        # 放大以刀尖接触区为锚点，刀尖仍在牌边；握柄向外扩展而非盖住价格牌。
        px,py=self.pivot;cx,cy=self.contact
        shift=(dx+(px-cx)*(scale-1),dy+(py-cy)*(scale-1))
        for i,part in enumerate(self.halves):
            angle=sign*closure*(1 if i==0 else -1)
            canvas.alpha_composite(affine_pose(part,self.pivot,angle,sx=scale,sy=scale,
                                               dx=shift[0],dy=shift[1]))
        for part in (self.joint,self.hand):
            canvas.alpha_composite(affine_pose(part,self.pivot,sx=scale,sy=scale,
                                               dx=shift[0],dy=shift[1]))


class SubscriptionScissors:
    """完整闭合刀面与握柄同绕原铆钉转动，不采入旧刀痕或箭头像素。"""
    def __init__(self,source):
        self.pivot=(1072,678)
        size=source.size
        # 两片刀刃交叉连接相反侧握柄。隐藏处在原坐标画完整，不留下蒙版断口。
        upper=path(((989,571),(1015,577),(1051,605),(1080,635)),
                   ((1080,635),(1091,647),(1099,660),(1103,676)),
                   ((1103,676),(1091,686),(1083,695),(1074,701)),
                   ((1074,701),(1040,662),(1014,611),(989,571)))
        lower=path(((976,645),(1008,646),(1047,655),(1082,661)),
                   ((1082,661),(1091,660),(1095,655),(1098,654)),
                   ((1098,654),(1103,667),(1106,681),(1107,689)),
                   ((1107,689),(1092,695),(1080,703),(1067,698)),
                   ((1067,698),(1031,688),(1004,674),(982,663)),
                   ((982,663),(979,656),(977,651),(976,645)))
        top_handle=polygon_mask(size,[(1095,645),(1115,625),(1144,613),(1180,617),
            (1203,640),(1215,683),(1203,706),(1173,718),(1137,714),(1094,699)])
        # 取样只保留握柄。金属刀面全部由闭合路径绘制，不能夹带被另一片遮住的旧线。
        top_handle=top_handle.filter(ImageFilter.MaxFilter(9))
        top_handle.paste(0,(0,0,1100,source.height))
        # 沿原握柄下沿分界，排除另一侧连接颈的旧边线，不能切进金色填充。
        top_handle.paste(0,mask=polygon_mask(size,[(1100,695),(1126,704),
                         (1126,source.height),(1100,source.height)]))
        # 下握柄沿实际填充的连通区域取样，保留完整细颈和原描边，避免矩形切口。
        arr=np.asarray(source)
        gold=((arr[:,:,0]>180)&(arr[:,:,1]>160)&(arr[:,:,2]<220)&
              (arr[:,:,0]-arr[:,:,2].astype(int)>22)&(arr[:,:,3]>240))
        selected=Image.fromarray(gold.astype('uint8')*255).copy()
        if selected.getpixel((1092,720))!=255:
            raise ValueError('连续包月下握柄取样点不在原金色填充内')
        ImageDraw.floodfill(selected,(1092,720),128)
        selected=selected.point(lambda a:255 if a==128 else 0)
        bounds=selected.getbbox()
        if not bounds or bounds[2]-bounds[0]>100 or bounds[3]-bounds[1]>120:
            raise ValueError(f'连续包月下握柄轮廓不完整或连到其他对象：{bounds}')
        bottom_handle=selected.filter(ImageFilter.MaxFilter(31))
        # 只移除细颈上方的旧金属片；金色填充从 y=702 开始，不被裁切。
        bottom_handle.paste(0,(0,0,source.width,700))
        self.halves=[]
        for points,mask in ((upper,bottom_handle),(lower,top_handle)):
            part=Image.new('RGBA',size)
            part.alpha_composite(content(source,mask))
            blade_mask=polygon_mask(size,points,True)
            white=gradient_fill(source,blade_mask,(992,588,1101,701),
                                lambda p:np.min(p[:,:,:3],axis=2)>220)
            part.paste(white,mask=blade_mask)
            stroke_path(part,points+[points[0]],13,(25,22,18,254))
            self.halves.append(part)
        # 固定件仅为铆钉圆盘，不能把圆盘旁边的旧刀刃一起贴回。
        self.joint=content(source,ellipse_mask(size,(1059,666,1083,690)))

    def paint(self,canvas,closure,sign=-1):
        for i,part in enumerate(self.halves):
            angle=sign*closure*(1 if i==0 else -1)
            canvas.alpha_composite(affine_pose(part,self.pivot,angle))
        canvas.alpha_composite(self.joint)


class Baoyue(Painter):
    card="baoyue"
    count=34
    boxes=((200,170,1240,985),)

    def __init__(self):
        super().__init__()
        # 原环和钱包的重叠在原稿坐标内补全，剪刀不参加环的转动。
        walletmask=polygon_mask(self.size,[(386,496),(402,474),(460,443),(697,390),
            (739,399),(757,458),(789,463),(810,534),(835,543),(853,574),
            (852,644),(836,661),(847,735),(826,772),(630,811),(503,810),(427,729),(397,673)])
        # 钱包背面缺失处不是透明洞：恢复环的内侧空白，补出环的完整线条。
        # 完整圆环底稿先补出原来被钱包、剪刀遮住的环带。旋转时不能转出缺口。
        ring=Image.new('RGBA',self.size)
        outer=ellipse_mask(self.size,(248,203,1032,959))
        inner=ellipse_mask(self.size,(373,308,911,843))
        annulus=Image.fromarray(np.maximum(np.asarray(outer,dtype=int)-np.asarray(inner,dtype=int),0).astype('uint8'))
        gold=gradient_fill(self.original,annulus,(252,218,1025,942),
                           lambda p:(p[:,:,0]>240)&(p[:,:,1]>200)&(p[:,:,2]>140)&(p[:,:,2]<215))
        ring.paste(gold,mask=annulus)
        for cx,cy,rx,ry in ((640,581,385,372),(642,575,268,266)):
            stroke_path(ring,[(cx+rx*math.cos(i*math.tau/240),cy+ry*math.sin(i*math.tau/240))
                              for i in range(241)],14,(25,22,16,255))
        # 原箭头的形状和金色保留，完整环只用于接续被遮住的底稿。
        heads=rect_mask(self.size,())
        for pts in ([(748,414),(782,374),(861,290),(901,248),(916,265),(976,456),(969,474)],
                    [(359,704),(379,704),(612,753),(610,774),(555,809),(443,885),(402,922),(383,906)]):
            h=polygon_mask(self.size,pts).filter(ImageFilter.MaxFilter(7))
            heads=Image.fromarray(np.maximum(np.asarray(heads),np.asarray(h)))
        # 独立动势墨迹留在画布上，不随圆环旋转。
        self.marks=isolated_marks(self.original,[(749,180),(216,452),(238,465),(1014,449),
            (1038,464),(516,960),(317,752),(1178,564),(1208,604)])
        ring.alpha_composite(content(self.original,heads))
        self.ring=ring
        # 被前景箭头遮住的钱包左下角补画到原外轮廓，不另画新钱包。
        wallet=content(self.original,walletmask)
        corner=polygon_mask(self.size,[(420,675),(515,716),(630,745),(587,799),(485,800),(429,719)])
        repaired=gradient_fill(self.original,corner,(445,540,803,738),
                                lambda p:(p[:,:,0]<220)&(p[:,:,1]<180)&(p[:,:,2]<145))
        wallet.paste(repaired,mask=corner)
        stroke_path(wallet,path(((420,675),(429,726),(437,763),(485,789)),
                                ((485,789),(533,810),(580,805),(620,797))),14,(28,22,17,255))
        self.wallet=wallet
        self.wallet_no_face=gradient_fill(wallet,rect_mask(self.size,((470,590,627,711),)),
            (440,549,659,738),lambda p:(p[:,:,2]<p[:,:,1]*.85)&(p[:,:,1]<185))
        self.scissors=SubscriptionScissors(self.original)

    def paint(self,t):
        canvas=self.original.copy()
        canvas.paste((0,0,0,0),mask=rect_mask(self.size,((244,195,1040,966),(945,540,1235,817))))
        # 全圈推进；前后帧从原环采样，中心不漂移。
        phase=ease((t-.25)/3.25)
        ring=affine_pose(self.ring,(639,578),math.tau*phase)
        canvas.alpha_composite(ring)
        pain=ease((t-1.0)/.6)*(1-ease((t-2.9)/.55))
        wallet=self.wallet.copy()
        if pain:
            # 在原底色上画紧挤的眼与加深的苦嘴，保持原墨线宽。
            face=self.wallet_no_face.copy()
            stroke_path(face,[(481,619),(503-12*pain,632),(483,649)],10,(25,22,18,255))
            stroke_path(face,[(584,602),(559+12*pain,624),(596,632)],10,(25,22,18,255))
            mouth=path(((509,697),(528,662-12*pain),(537,702),(552,676-10*pain)),
                       ((552,676-10*pain),(566,651-10*pain),(567,701),(584,673-10*pain)),
                       ((584,673-10*pain),(597,653-10*pain),(607,674),(620,674)))
            stroke_path(face,mouth,10,(25,22,18,255))
            wallet=face
        canvas.alpha_composite(affine_pose(wallet,(616,603),sx=1-.065*pain,sy=1-.025*pain))
        # 剪刀先略张开，再闭合一次，环不会被剪断。
        closure=.24*ease((t-.8)/.55)*(1-ease((t-2.35)/.55))-.08*ease((t-.3)/.35)*(1-ease((t-.8)/.3))
        self.scissors.paint(canvas,closure,sign=-1)
        # 原汗滴和动势线不被删除。
        canvas.paste(self.original,mask=self.marks)
        return canvas


class Pinshaoshao(Painter):
    card="pinshaoshao"
    mode="once"
    count=34
    boxes=((65,169,1225,1081),)

    def __init__(self):
        super().__init__()
        tagmask=polygon_mask(self.size,[(306,175),(395,171),(470,250),(559,235),(623,303),
            (646,294),(681,336),(665,386),(739,395),(800,536),(760,586),
            (778,624),(830,625),(861,693),(836,737),(882,774),(884,804),
            (867,837),(901,917),(888,943),(861,929),(836,980),(779,960),
            (730,1016),(649,990),(623,1038),(589,1020),(560,1061),
            (510,986),(530,947),(485,914),(526,828),(458,815),(432,770),
            (480,699),(425,677),(414,636),(371,584),(399,519),(374,505),
            (402,464),(347,437),(401,299),(314,257)]).filter(ImageFilter.MaxFilter(17))
        self.shards=detached_marks(self.original)
        # 松散取样会把牌旁独立的碎片和剪切动势线一起带走，缩紧后留下两份旧线。
        tagmask=Image.fromarray(np.minimum(np.asarray(tagmask),255-np.asarray(self.shards)))
        self.tag=content(self.original,tagmask)
        # 两把剪刀遮住的牌边先在原画布补好，再画后续的切口。
        cover=rect_mask(self.size,((351,568,452,693),))
        repaired=gradient_fill(self.original,cover,(407,412,744,819),lambda p:p[:,:,1]>180)
        self.tag.paste((0,0,0,0),mask=cover)
        edge=polygon_mask(self.size,[(371,584),(399,519),(452,531),(452,688),(429,674),(414,634)])
        self.tag.paste(repaired,mask=Image.fromarray(np.minimum(np.asarray(cover),np.asarray(edge))))
        stroke_path(self.tag,[(371,584),(414,634),(429,674),(477,697)],14,(25,22,16,255))
        cover=rect_mask(self.size,((846,779,920,949),))
        repaired=gradient_fill(self.original,cover,(657,714,871,945),lambda p:p[:,:,1]>180)
        self.tag.paste((0,0,0,0),mask=cover)
        edge=polygon_mask(self.size,[(846,779),(877,779),(876,814),(886,855),
            (900,905),(889,937),(853,925),(846,949)])
        self.tag.paste(repaired,mask=edge)
        stroke_path(self.tag,[(875,779),(876,814),(886,855),(900,905),(889,937),(853,925)],14,(25,22,16,255))
        self.face_mask=rect_mask(self.size,((418,471,711,666),))
        self.tag_no_face=gradient_fill(self.tag,self.face_mask,(405,434,747,794),lambda p:p[:,:,1]>190)
        self.left=Scissors(self.original,(336,679))
        self.right=Scissors(self.original,(955,883))
        self.tag_mask=tagmask

    def paint(self,t):
        fear=ease((t-.6)/1.6)
        sx,sy=1-.035*fear,1-.025*fear
        canvas=self.original.copy()
        # 只移除牌身和剪刀；原有碎片、汗滴仍在静止构图中。
        canvas.paste((0,0,0,0),mask=self.allowed)
        tag=self.tag_no_face.copy()
        stroke_path(tag,[(500,540),(554-18*fear,556),(520,592-6*fear)],12,(25,22,17,255))
        stroke_path(tag,[(683,480),(642+18*fear,526),(695,532-5*fear)],12,(25,22,17,255))
        mouth=path(((556,650),(579,610-12*fear),(598,624),(615,622-7*fear)),
                   ((615,622-7*fear),(641,628),(635,598-12*fear),(661,608)),
                   ((661,608),(677,592-8*fear),(678,580-7*fear),(702,599)))
        stroke_path(tag,mouth,12,(25,22,17,255))
        # 闭合之后新缺口和碎片才出现，已有锯齿从第 0 帧保留。
        cut1=ease((t-1.30)/.15)
        cut2=ease((t-2.65)/.15)
        for cut,tri in ((cut1,[(401,625),(432,646),(418,674)]),
                        (cut2,[(869,834),(893,858),(883,890)])):
            if cut:
                tag.paste((0,0,0,0),mask=polygon_mask(self.size,tri))
                stroke_path(tag,[tri[0],tri[1],tri[2]],13,(25,22,17,255))
        canvas.alpha_composite(affine_pose(tag,(612,631),sx=sx,sy=sy))
        left=.28*ease((t-.45)/.85)*(1-ease((t-1.5)/.5))
        right=.13*ease((t-1.8)/.85)*(1-ease((t-2.9)/.5))
        # 原图起始停留后，连续增大 20%；持剪刀的手同样跟随，不能切出握柄缺口。
        scissor_scale=1+.20*ease((t-.25)/.65)
        self.left.paint(canvas,left,sign=1,dx=8*fear,dy=-2*fear,scale=scissor_scale)
        self.right.paint(canvas,right,sign=-1,dx=-9*fear,dy=-8*fear,scale=scissor_scale)
        # 恢复墨迹只叠有颜色的原像素；透明边缘不能把新握柄和刀面挖出孔。
        canvas.alpha_composite(content(self.original,self.shards))
        for cut,start,points,direction in (
            (cut1,1.45,[(401,625),(432,646),(418,674)],-1),
            (cut2,2.80,[(869,834),(893,858),(883,890)],1)):
            if cut:
                piece=Image.new("RGBA",self.size)
                painted_polygon(piece,points,(255,239,194,255),(25,22,17,255),11)
                fall=ease((t-start)/.8)
                canvas.alpha_composite(affine_pose(piece,points[1],angle=direction*.38*fall,
                                                  dx=direction*52*fall,dy=84*fall))
        return canvas


class Shuabuting(Painter):
    card="shuabuting"
    count=34
    boxes=((400,302,883,1109),(927,380,1234,958),(156,936,532,1205))

    def __init__(self):
        super().__init__()
        # 纸带只使用原画四格的印刷纹理；先补齐被人物和卷边遮住的末格。
        self.left=np.array([(607,311),(556,499),(512,697),(477,876),(438,1016)],float)
        self.right=np.array([(856,348),(817,538),(782,740),(727,922),(651,1058)],float)
        yy,xx=np.mgrid[0:self.size[1],0:self.size[0]]
        v=(yy-311)/190
        for _ in range(10):
            k=np.clip(v.astype(int),0,3);q=v-k
            l=self.left[k]*(1-q[...,None])+self.left[k+1]*q[...,None]
            r=self.right[k]*(1-q[...,None])+self.right[k+1]*q[...,None]
            u=(xx-l[...,0])/(r[...,0]-l[...,0])
            error=yy-(l[...,1]+u*(r[...,1]-l[...,1]))
            v=v+error/185
        self.u,self.v=u,v
        # 包括旧圆角的整个墨边，而不是仅替换框内像素、留下旧圆角细线。
        region=polygon_mask(self.size,[(587,294),(876,328),(840,538),(806,741),
            (751,924),(701,1005),(656,1080),(632,1089),(509,1072),(465,1020),
            (410,957),(454,875),(492,697),(535,497)])
        self.print_area=(u>-.075)&(u<1.075)&(v>=-.08)&(v<4.26)&(np.asarray(region)>0)
        # 原生印刷纹理在统一坐标中展开，尺寸大于原稿采样密度。
        self.tex_width,self.tex_height=400,1200
        ty,tx=np.mgrid[:self.tex_height,:self.tex_width]
        tv=ty/300.;tu=tx/(self.tex_width-1)*1.08-.04
        k=tv.astype(int);f=tv-k
        l=self.left[k]*(1-f[...,None])+self.left[k+1]*f[...,None]
        r=self.right[k]*(1-f[...,None])+self.right[k+1]*f[...,None]
        sx=l[...,0]+tu*(r[...,0]-l[...,0]);sy=l[...,1]+tu*(r[...,1]-l[...,1])
        # 末格下方在原稿被头、手和卷边遮住：补的是打印纸和完整元数据，不采入人物墨线。
        lower=tv>=3.70
        rv=tv-3
        l0=self.left[0]*(1-rv[...,None])+self.left[1]*rv[...,None]
        r0=self.right[0]*(1-rv[...,None])+self.right[1]*rv[...,None]
        sx[lower]=(l0[...,0]+tu*(r0[...,0]-l0[...,0]))[lower]
        sy[lower]=(l0[...,1]+tu*(r0[...,1]-l0[...,1]))[lower]
        self.texture=self.sample(np.asarray(self.original),sx,sy)
        # 四格墨边完整闭合后再滚动，旧圆角不能作为独立的线条残留在手机里。
        original_rgba=np.asarray(self.original)
        ink=(np.max(original_rgba[:,:,:3],axis=2)<45)&(original_rgba[:,:,3]>240)
        printed_frame=Image.fromarray(ink.astype('uint8')*255).copy()
        if printed_frame.getpixel((620,310))!=255:
            raise ValueError('刷不停的印刷边框取样点不在原墨线内')
        ImageDraw.floodfill(printed_frame,(620,310),128)
        printed_frame=printed_frame.point(lambda a:255 if a==128 else 0).filter(ImageFilter.MaxFilter(9))
        px=np.clip(np.rint(sx).astype(int),0,self.size[0]-1)
        py=np.clip(np.rint(sy).astype(int),0,self.size[1]-1)
        # 只擦印刷框连通的墨线；不能按“靠近边缘且较黑”误擦头像和山峰。
        border=(np.asarray(printed_frame)[py,px]>0)|(tu<-.035)|(tu>1.035)
        border_mask=Image.fromarray(border.astype('uint8')*255)
        clean=gradient_fill(Image.fromarray(self.texture),border_mask,(20,0,380,1200),
                            lambda p:(p[:,:,1]>223)&(p[:,:,2]>185))
        texture=Image.fromarray(self.texture)
        texture.paste(clean,mask=border_mask)
        d=ImageDraw.Draw(texture)
        for row in range(4):
            d.rounded_rectangle((6,row*300-9,393,row*300+309),radius=43,
                                outline=(25,22,18,255),width=18)
        self.texture=np.asarray(texture).copy()
        # 头和抓纸的手按完整轮廓保留，不能用宽矩形把旧纸边也贴回。
        hand=path(((450,1084),(463,1078),(464,1051),(489,1047)),
                  ((489,1047),(517,1042),(530,1075),(511,1091)),
                  ((511,1091),(496,1104),(470,1091),(449,1105)))
        rgba=np.asarray(self.original)
        cream=(rgba[:,:,0]>225)&(rgba[:,:,1]>205)&(rgba[:,:,2]>165)&(rgba[:,:,3]>240)
        face_fill=Image.fromarray(cream.astype('uint8')*255).copy()
        ImageDraw.floodfill(face_fill,(378,990),128)
        face_fill=face_fill.point(lambda a:255 if a==128 else 0)
        bounds=face_fill.getbbox()
        if not bounds or bounds[2]-bounds[0]>160 or bounds[3]-bounds[1]>150:
            raise ValueError(f'刷不停的头部取样连到了纸带：{bounds}')
        self.foreground=Image.fromarray(np.maximum(np.asarray(dilate_disk(face_fill,16)),
                                                    np.asarray(polygon_mask(self.size,hand,True))))
        # 纸的外沿与卷边始终固定；只保留这些完整边线，不把旧内容文字贴回。
        edge=Image.new('RGBA',self.size)
        stroke_path(edge,path(((510,1073),(550,1080),(600,1092),(643,1090)),
            ((643,1090),(623,1085),(623,1051),(640,1033)),
            ((640,1033),(653,1021),(665,1040),(655,1054)),
            ((655,1054),(683,1024),(708,988),(727,943))),24,(255,255,255,255))
        self.foreground=Image.fromarray(np.maximum(np.asarray(self.foreground),
                                                   np.asarray(edge.getchannel('A'))))
        curl=polygon_mask(self.size,[(620,1083),(617,1057),(629,1031),(648,1024),
            (669,1046),(656,1064),(683,1029),(708,982),(723,937),(738,943),
            (719,1010),(689,1066),(659,1099)])
        self.foreground=Image.fromarray(np.maximum(np.asarray(self.foreground),np.asarray(curl)))
        self.legs_mask=rect_mask(self.size,((190,1086,388,1205),))
        self.leg_marks=content(self.original,Image.fromarray(np.minimum(
            np.asarray(detached_marks(self.original)),np.asarray(self.legs_mask))))
        self.legs=content(self.original,self.legs_mask)
        self.legs.paste((0,0,0,0),mask=self.leg_marks.getchannel('A'))
        self.sun=content(self.original,isolated_marks(self.original,
            [(1045,525),(1040,459),(994,482),(979,536),(1000,580),(1053,592),(1093,566),(1111,522),(1095,474)]))
        self.moon=content(self.original,isolated_marks(self.original,[(1127,746)]))
        orbit_arrows=content(self.original,isolated_marks(self.original,[(1152,630),(992,741)]))
        self.orbit_mask=Image.fromarray(np.maximum.reduce([
            np.asarray(part.getchannel('A')) for part in (self.sun,self.moon,orbit_arrows)]))
        self.orbit_mask=self.orbit_mask.point(lambda a:255 if a>0 else 0).filter(ImageFilter.MaxFilter(3))
        # 原始箭头的曲线点；两支与日月共用一个椭圆轨道和同一推进相位。
        self.arrow_paths=(path(((1129,563),(1156,586),(1175,626),(1157,663))),
                          path(((1027,755),(994,746),(976,720),(979,696))))
        self.arrow_heads=(((1140,646),(1157,665),(1174,656)),
                          ((963,716),(978,696),(995,706)))

    def orbital(self,p,angle):
        cx,cy,rx,ry=1078,637,46,100
        x,y=(p[0]-cx)/rx,(p[1]-cy)/ry
        c,s=math.cos(angle),math.sin(angle)
        return (cx+rx*(c*x-s*y),cy+ry*(s*x+c*y))

    @staticmethod
    def sample(arr,x,y):
        # 只采样唯一原稿/原稿印刷纹理。双线性采样没有混合相邻动画帧。
        x=np.clip(x,0,arr.shape[1]-1.001);y=np.clip(y,0,arr.shape[0]-1.001)
        x0=x.astype(int);y0=y.astype(int);fx=(x-x0)[...,None];fy=(y-y0)[...,None]
        rgba=arr.astype(float)
        value=(rgba[y0,x0]*(1-fx)*(1-fy)+rgba[y0,x0+1]*fx*(1-fy)+
               rgba[y0+1,x0]*(1-fx)*fy+rgba[y0+1,x0+1]*fx*fy)
        return np.clip(np.rint(value),0,255).astype('uint8')

    def paint(self,t):
        canvas=self.original.copy()
        q=ease((t-.25)/3.5)
        sv=np.mod(self.v-4*q,4)
        tx=(self.u+.04)/1.08*(self.tex_width-1)
        ty=sv*300
        sampled=self.sample(self.texture,tx,ty)
        out=np.asarray(self.original).copy()
        out[self.print_area]=sampled[self.print_area]
        canvas=Image.fromarray(out)
        # 同方向转一圈并回到第 0 帧，日月保持自身形状、箭头墨线宽恒定。
        angle=math.tau*q
        canvas.paste((0,0,0,0),mask=self.orbit_mask)
        for part,center in ((self.sun,(1046,525)),(self.moon,(1110,746))):
            dest=self.orbital(center,angle)
            canvas.alpha_composite(affine_pose(part,center,dx=dest[0]-center[0],dy=dest[1]-center[1]))
        for points,head in zip(self.arrow_paths,self.arrow_heads):
            stroke_path(canvas,[self.orbital(p,angle) for p in points],14,(25,21,16,255))
            stroke_path(canvas,[self.orbital(p,angle) for p in head],14,(25,21,16,255))
        # 抓纸的手与头身不漂移，腿从原臀部小幅挣扎后回位。
        stride=.07*math.sin(8*math.pi*q)*math.sin(math.pi*q)
        canvas.paste((0,0,0,0),mask=self.legs_mask)
        canvas.alpha_composite(affine_pose(self.legs,(303,1124),angle=stride))
        canvas.alpha_composite(self.leg_marks)
        canvas.paste(self.original,mask=self.foreground)
        return canvas


class Ditui(Painter):
    card="ditui"
    count=42
    # Complete shell can rise above the old visible egg and return behind the tray.
    boxes=((424,355,1008,1100),(457,767,656,888))

    def __init__(self):
        super().__init__()
        rgba=np.asarray(self.original)
        cream_pixels=(rgba[:,:,0]>220)&(rgba[:,:,1]>215)&(rgba[:,:,2]>185)&(rgba[:,:,3]>240)
        visible=Image.fromarray(cream_pixels.astype('uint8')*255).copy()
        ImageDraw.floodfill(visible,(800,800),128)
        visible=visible.point(lambda a:255 if a==128 else 0)
        if visible.getbbox()!=(615,594,969,971):
            raise ValueError(f'原图前排鸡蛋内部范围改变：{visible.getbbox()}')
        # The old V-shaped lower edge is the tray occlusion, not an egg bottom.
        # Continue both sides down into one rounded, complete egg silhouette.
        lower_path=path(((973,895),(960,977),(885,1048),(790,1048)),
                        ((790,1048),(690,1048),(623,977),(609,895)))
        inner=polygon_mask(self.size,lower_path+[(973,895)],True)
        fill=gradient_fill(self.original,inner,(640,620,955,888),
                           lambda p:(p[:,:,0]>225)&(p[:,:,1]>215)&(p[:,:,2]>185))
        self.egg=content(fill,inner)
        stroke_path(self.egg,lower_path,20,(24,20,15,255))
        # Native upper shell remains the actual original silhouette; its two
        # side contours meet the new rounded underside at (609,895)/(973,895).
        native_upper=dilate_disk(visible,20)
        native_upper.paste(0,(0,896,self.size[0],self.size[1]))
        self.egg.alpha_composite(content(self.original,native_upper))
        native_cream=visible.filter(ImageFilter.MinFilter(17)).filter(ImageFilter.GaussianBlur(2))
        self.egg.alpha_composite(content(self.original,native_cream))

        # Remove the real old front shell only, rather than a looser polygon that
        # cuts into the right rear egg's original upper contour.
        self.egg_mask=dilate_disk(visible,32)
        upper_removal=dilate_disk(visible,20)
        self.egg_mask.paste(upper_removal.crop((0,0,self.size[0],630)),(0,0))
        self.egg_mask=Image.fromarray(np.maximum.reduce([np.asarray(self.egg_mask),
            np.asarray(ellipse_mask(self.size,(573,887,631,944))),
            np.asarray(ellipse_mask(self.size,(966,884,1007,946)))]))
        bg=gradient_fill(self.original,self.egg_mask,(449,880,1188,1040),
                         lambda p:(p[:,:,0]>225)&(p[:,:,1]>160)&(p[:,:,2]<185))
        ink=(24,20,15,255)
        back_paths=(path(((647,465),(702,464),(756,513),(790,578)),
                         ((790,578),(826,664),(836,755),(795,802)),
                         ((795,802),(718,823),(613,841),(547,889)),
                         ((547,889),(495,869),(449,854),(442,829)),
                         ((442,829),(433,710),(519,466),(647,465))),
                    path(((1044,486),(1151,473),(1201,659),(1192,792)),
                         ((1192,792),(1191,824),(1181,846),(1170,849)),
                         ((1170,849),(1124,870),(1083,886),(1045,890)),
                         ((1045,890),(1007,878),(882,834),(847,814)),
                         ((847,814),(821,770),(848,645),(874,590)),
                         ((874,590),(922,522),(1000,481),(1044,486))))
        for points in back_paths:
            m=polygon_mask(self.size,points,True)
            fill=gradient_fill(self.original,m,(507,510,1179,891),
                               lambda p:(p[:,:,0]>225)&(p[:,:,1]>215)&(p[:,:,2]>185))
            bg.paste(fill,mask=m)
            stroke_path(bg,points+[points[0]],20,ink)
        # 原可见孔前沿为左(605,918)→前(790,979)→右(979,908)。
        # 接续同一透视的后两边，保持原孔约 374×132 的投影尺寸；不能缩成圆槽。
        opening=path(((605,918),(664,896),(735,867),(794,847)),
                     ((794,847),(850,866),(920,890),(979,908)),
                     ((979,908),(966,930),(870,959),(790,979)),
                     ((790,979),(730,966),(652,943),(605,918)))
        opening_mask=polygon_mask(self.size,opening,True)
        # 孔内仅用原蛋托的暖金色加深，表达凹陷，不改变容器外壁的颜色。
        gold=self.original.getpixel((790,995))[:3]
        recessed=tuple(round(v*.86) for v in gold)+(255,)
        bg.paste(recessed,(0,0,self.size[0],self.size[1]),opening_mask)
        stroke_path(bg,opening+[opening[0]],16,ink)
        # 原孔沿两端完整接到新露出的方孔；不能把旧蛋侧边一起取来成为空线。
        stroke_path(bg,path(((606,923),(596,921),(584,915),(585,902))),16,ink)
        stroke_path(bg,path(((970,923),(985,920),(996,916),(992,906))),16,ink)
        self.background=Image.composite(bg,self.original,self.egg_mask)
        self.front_layer=self.original.copy()
        self.front_layer.paste(self.background,mask=self.egg_mask)

        self.arm_mask=polygon_mask(self.size,[(464,848),(526,798),(526,779),
            (550,774),(552,790),(569,786),(579,805),(556,821),(485,872),
            (464,878)]).filter(ImageFilter.MaxFilter(13))
        self.arm_mask.paste(0,(0,0,458,self.size[1]))
        arm_back=gradient_fill(self.background,self.arm_mask,(488,694,582,839),
                                lambda p:(p[:,:,0]>225)&(p[:,:,1]>215))
        self.background.paste(arm_back,mask=self.arm_mask)
        self.head_mask=ellipse_mask(self.size,(287,718,491,902))

        # 前孔沿与固定托盘前壁共同遮挡落回的鸡蛋；不添加与方孔脱开的 U 形线。
        # The occluder is the actual original tray in front of the slot, following
        # the V-shaped front rim. It includes the upper rim and the full front wall.
        # Sampling only the gold front wall leaves the hidden shell on the platform.
        front_curve=path(((590,918),(645,946),(747,979),(790,979)),
                         ((790,979),(834,979),(937,931),(994,908)))
        foreground_domain=polygon_mask(self.size,front_curve+[(1008,1138),(575,1138)],True).filter(ImageFilter.MaxFilter(21))
        gold=(rgba[:,:,0]>220)&(rgba[:,:,1]>150)&(rgba[:,:,2]<200)&(rgba[:,:,3]>240)
        tray=Image.new('L',self.size)
        for seed in ((781,1060),(790,995)):
            region=Image.fromarray(gold.astype('uint8')*255).copy()
            if region.getpixel(seed)!=255:
                raise ValueError(f'蛋托前景取样点改变：{seed}')
            ImageDraw.floodfill(region,seed,128)
            region=region.point(lambda a:255 if a==128 else 0)
            tray=Image.fromarray(np.maximum(np.asarray(tray),np.asarray(region)))
            if seed==(781,1060):
                # 旧蛋擦除的右侧范围不能吞掉真实前壁的墨边，例如 (990,940)。
                # 先恢复完整原前壁，再由前景域决定其遮挡；不取旧蛋下沿。
                self.front_layer.paste(self.original,mask=region.filter(ImageFilter.MaxFilter(33)))
        tray=tray.filter(ImageFilter.MaxFilter(37))
        self.front_mask=Image.fromarray(np.minimum(np.asarray(tray),np.asarray(foreground_domain)))
        # All pre-existing tray pixels below the slot remain the fixed front layer.
        self.front_mask=Image.fromarray(np.maximum(np.asarray(self.front_mask),
             np.asarray(rect_mask(self.size,((575,1025,1008,1138),)))))

    def paint(self,t):
        if t<.75:
            canvas=self.original.copy()
            delta=8*math.sin(math.pi*ease((t-.25)/.5))
            canvas.paste(self.background,mask=self.arm_mask)
            stroke_path(canvas,[(464,865),(514,822),(550,797-delta)],21,(26,22,17,255))
            stroke_path(canvas,[(550,797-delta),(539,784-delta)],18,(26,22,17,255))
            canvas.paste(self.original,mask=self.head_mask)
            return canvas
        reach=ease((t-.75)/.6)
        lift=ease((t-1.4)/.8)*(1-ease((t-3.1)/.95))
        dx,dy=-80*lift,-210*lift
        if lift<=1e-8:
            # 手伸过去之前、鸡蛋落稳之后使用原槽内完整静止画面，
            # 不能等到手撤回才补回接触下沿，让轮廓在无动作时跳变。
            canvas=self.original.copy()
            canvas.paste(self.background,mask=self.arm_mask)
        else:
            canvas=self.background.copy()
            canvas.alpha_composite(affine_pose(self.egg,(790,790),dx=dx,dy=dy))
        contact=(614+dx,839+dy)
        hand=(550+(contact[0]-550)*reach,797+(contact[1]-797)*reach)
        release=ease((t-4.10)/.55)
        hand=(hand[0]*(1-release)+550*release,hand[1]*(1-release)+797*release)
        stroke_path(canvas,path(((464,865),(482,855),(499,842),hand)),21,(26,22,17,255))
        stroke_path(canvas,[(hand[0]-6,hand[1]+6),hand,(hand[0]+9,hand[1]-8)],18,(26,22,17,255))
        if lift>1e-8:
            canvas.paste(self.front_layer,mask=self.front_mask)
        canvas.paste(self.original,mask=self.head_mask)
        if t>=4.7:
            return self.original.copy()
        return canvas

class Waimai(Painter):
    card="waimai"
    count=34
    boxes=((146,358,1187,1103),)

    def __init__(self):
        super().__init__()
        # 车箱、底盘和车轮从同一原稿整体取样，避免在挡泥板和车轮之间切出空线。
        self.vehicle_mask=rect_mask(self.size,((160,358,1090,1103),))
        self.vehicle=content(self.original,self.vehicle_mask)
        self.steam_mask=Image.new('L',self.size)
        for seed in ((479,250),(404,320),(580,327)):
            flood=self.original.getchannel('A').point(lambda a:255 if a>8 else 0)
            if flood.getpixel(seed)!=255:
                raise ValueError(f'外卖蒸汽的取样点不在原图轮廓内：{seed}')
            ImageDraw.floodfill(flood,seed,128)
            steam=flood.point(lambda a:255 if a==128 else 0)
            bounds=steam.getbbox()
            if not bounds or bounds[3]-bounds[1]>230 or bounds[2]-bounds[0]>120:
                raise ValueError(f'外卖蒸汽取样连到了箱体：{bounds}')
            self.steam_mask=Image.fromarray(np.maximum(np.asarray(self.steam_mask),np.asarray(steam))).copy()
        self.steam_mask=self.steam_mask.filter(ImageFilter.MaxFilter(5))
        self.vehicle.paste((0,0,0,0),mask=self.steam_mask)
        self.pendant_area=rect_mask(self.size,((925,518,1187,830),))
        self.vehicle.paste((0,0,0,0),mask=self.pendant_area)
        self.speed_area=rect_mask(self.size,((146,897,354,993),))
        self.vehicle.paste((0,0,0,0),mask=self.speed_area)
        self.pendant=content(self.original,rect_mask(self.size,((925,643,1187,830),)))
        self.drive_area=rect_mask(self.size,self.boxes)
        self.body_face=gradient_fill(self.vehicle,rect_mask(self.size,((532,677,679,790),)),
                                     (464,639,699,791),lambda p:p[:,:,1]>190)
        arr=np.asarray(self.original)
        gray=(np.max(arr[:,:,:3],axis=2)<100)&(np.min(arr[:,:,:3],axis=2)>32)&(arr[:,:,3]>245)
        self.tyre_masks=[]
        for x,y in ((470,995),(795,1017)):
            yy,xx=np.mgrid[:self.size[1],:self.size[0]]
            radius=np.hypot(xx-x,yy-y)
            # 只有原轮胎内部灰色纹理参与转动；轮毂、外缘和遮住轮子的车壳保留原稿。
            mask=gray&(radius>38)&(radius<57)
            self.tyre_masks.append(((x,y),Image.fromarray(mask.astype('uint8')*255)))

    def paint(self,t):
        drive=ease((t-.25)/.55)*(1-ease((t-3.0)/.55))
        q=ease((t-.25)/3.3)
        canvas=self.original.copy()
        canvas.paste((0,0,0,0),mask=self.drive_area)
        # 原生画布的 ±2 像素缩到卡面后几乎看不到；完整车身统一颠簸 ±10 像素。
        bounce=round(10*math.sin(12*math.pi*q)*drive)
        vehicle=self.body_face.copy() if drive else self.vehicle.copy()
        if drive:
            stroke_path(vehicle,[(551,687),(573-8*drive,705),(540,720)],10,(24,20,15,255))
            stroke_path(vehicle,[(661,689),(637+7*drive,707),(665,724)],10,(24,20,15,255))
            mouth=path(((548,772),(566,746-8*drive),(575,773),(588,758-5*drive)),
                       ((588,758-5*drive),(603,746-8*drive),(608,781),(622,764-5*drive)),
                       ((622,764-5*drive),(634,750-8*drive),(635,777),(640,775)))
            stroke_path(vehicle,mouth,10,(24,20,15,255))
        for (x,y),mask in self.tyre_masks:
            tread=Image.new('RGBA',self.size)
            angle=4*math.pi*q
            points=[(x+r*math.cos(angle),y+r*math.sin(angle)) for r in (39,55)]
            stroke_path(tread,points,8,(30,28,25,255))
            vehicle.alpha_composite(content(tread,mask))
        # 绳子从杆端完整画到吊坠；不能把一段原吊杆随吊坠旋转，也不能保留旧绳。
        angle=.13*drive+.018*math.sin(8*math.pi*q)*drive
        anchor=(1038,510)
        cord=Image.new('RGBA',self.size)
        end=(1039,656)
        dest=(anchor[0]+math.cos(angle)*(end[0]-anchor[0])-math.sin(angle)*(end[1]-anchor[1]),
              anchor[1]+math.sin(angle)*(end[0]-anchor[0])+math.cos(angle)*(end[1]-anchor[1]))
        stroke_path(cord,[anchor,dest],14,self.original.getpixel((1039,574)))
        vehicle.alpha_composite(cord)
        vehicle.alpha_composite(affine_pose(self.pendant,anchor,angle=angle))
        canvas.alpha_composite(affine_pose(vehicle,(635,799),dy=bounce))
        canvas.paste(self.original,mask=self.steam_mask)
        # 短速度线完整掠过，长度随进出变化；不在矩形边界硬切出黑点或半根线。
        for row,origin,length,width in ((915,263,80,12),(959,232,81,14),(986,312,38,10)):
            progress=(q*3+(origin-232)/208)%1
            center=330-150*progress
            shown=length*math.sin(math.pi*progress)*drive
            if shown>3:
                stroke_path(canvas,[(center-shown/2,row),(center+shown/2,row+3)],width,(24,21,17,255))
        return canvas


PAINTERS=(Baoyue,Pinshaoshao,Shuabuting,Ditui,Waimai)


def preview(frames,directory):
    bg=(230,226,211,255)
    displayed=[]
    for frame in frames:
        canvas=Image.new("RGBA",frame.size,bg)
        canvas.alpha_composite(frame)
        displayed.append(canvas)
    # 原生尺寸、无损、不降低帧率。WebP 仅为检查，不参与游戏。
    displayed[0].save(directory/"preview.webp",save_all=True,append_images=displayed[1:],
                      lossless=True,duration=[round((i+1)*1000/FPS)-round(i*1000/FPS)
                                              for i in range(len(frames))],
                      loop=0 if directory.name!="pinshaoshao" else 1)
    indices=[0,len(frames)//4,len(frames)//2,3*len(frames)//4,len(frames)-1]
    sheet=Image.new("RGB",(400*5,425),bg[:3])
    draw=ImageDraw.Draw(sheet)
    for k,i in enumerate(indices):
        im=displayed[i].copy();im.thumbnail((390,390),Image.Resampling.LANCZOS)
        sheet.paste(im,(400*k+(400-im.width)//2,20))
        draw.text((400*k+12,407),f"{i:02d} / {i/FPS:.2f}s",fill=(32,27,20))
    sheet.save(directory/"keyframes.png")


def install(card,frames,report,directory,config):
    if uses_compact_art(config):
        install_compact(card, frames, report, directory, config)
        return
    target=ROOT/f"assets/art/icon/hover/{card}"
    target.mkdir(exist_ok=True)
    paths=[]
    known={hashlib.sha256(frames[0].tobytes()).hexdigest():f"icon/icon_{card}.png"}
    for i,(frame,sha) in enumerate(zip(frames,report['rgba_sha256'])):
        if sha not in known:
            filename=f"{i:03d}.png"
            shutil.copy2(directory/"frames"/filename,target/filename)
            # 同原 icon 的无损、颜色、透明边缘和 mipmap 设置，从首次导入就一致。
            source_path=f'res://assets/art/icon/hover/{card}/{filename}'
            imported=f'res://.godot/imported/{filename}-{hashlib.md5(source_path.encode()).hexdigest()}.ctex'
            params=(ROOT/f'assets/art/icon/icon_{card}.png.import').read_text().split('[params]',1)[1]
            preset=('[remap]\n\nimporter="texture"\ntype="CompressedTexture2D"\n'
                    f'path="{imported}"\nmetadata={{\n"vram_texture": false\n}}\n\n'
                    f'[deps]\n\nsource_file="{source_path}"\ndest_files=["{imported}"]\n\n'
                    '[params]'+params)
            (target/(filename+'.import')).write_text(preset)
            known[sha]=f"icon/hover/{card}/{filename}"
        paths.append(known[sha])
    config['art']['hover']['cards'][card]={"files":paths,"frames":len(frames),
                    "frame_size":list(frames[0].size),"play_mode":report['play_mode'],"loop_pause":.65}
    used={Path(p).name for p in paths if p.startswith(f'icon/hover/{card}/')}
    for old_frame in target.glob('*.png'):
        if old_frame.name not in used:
            old_frame.unlink()
            old_frame.with_suffix('.png.import').unlink(missing_ok=True)
    # 被替换的旧图集只归档 build，不保留两套正式素材。
    archive=OUT/"replaced_atlases";archive.mkdir(parents=True,exist_ok=True)
    for suffix in (".png",".png.import"):
        old=ROOT/f"assets/art/icon/hover/{card}{suffix}"
        if old.exists():
            shutil.move(str(old),archive/old.name)


def install_compact(card, frames, report, directory, config):
    """高清完整帧仅写 build；正式更新统一经过 384 缩放和无损差分打包。"""
    if len(frames) != len(report['rgba_sha256']) or not frames:
        raise ValueError(f'{card} 帧数与制作记录不一致')
    original_path = native_icon_path(card)
    with Image.open(original_path) as image:
        original = image.convert('RGBA')
    if any(frame.size != original.size for frame in frames) or frames[0].tobytes() != original.tobytes():
        raise ValueError(f'{card} 必须以同尺寸高清静止原稿作为第一帧')
    stage = directory / 'runtime_source'
    if not stage.resolve().is_relative_to((ROOT / 'build').resolve()):
        raise ValueError('高清制作与检查中间文件必须位于 build 下')
    art = stage / 'art'
    static = art / f'icon/icon_{card}.png'
    static.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(original_path, static)
    source_import = Path(str(original_path) + '.import')
    if source_import.exists():
        shutil.copy2(source_import, Path(str(static) + '.import'))
    paths = []
    known = {hashlib.sha256(frames[0].tobytes()).hexdigest(): f'icon/icon_{card}.png'}
    for index, (frame, expected_hash) in enumerate(zip(frames, report['rgba_sha256'])):
        actual_hash = hashlib.sha256(frame.tobytes()).hexdigest()
        if actual_hash != expected_hash:
            raise ValueError(f'{card} 第 {index} 帧与制作记录不一致')
        if actual_hash not in known:
            relative = f'icon/hover/{card}/{index:03d}.png'
            target = art / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            frame.save(target)
            if source_import.exists():
                shutil.copy2(source_import, Path(str(target) + '.import'))
            known[actual_hash] = relative
        paths.append(known[actual_hash])
    source_config = json.loads(json.dumps(config))
    source_config['art']['hover']['cards'] = {card: {
        'files': paths, 'frames': len(frames), 'frame_size': list(original.size),
        'play_mode': report['play_mode'], 'loop_pause': .65}}
    source_config['art']['hover'].pop('max_dimension', None)
    source_ui = stage / 'ui.json'
    source_ui.write_text(json.dumps(source_config, ensure_ascii=False, indent=2) + '\n')
    subprocess.run([sys.executable, str(ROOT / 'tools/pack_hover_animations.py'),
                    '--source-ui', str(source_ui.resolve()), '--source-art', str(art.resolve()),
                    '--limit', str(config['art']['hover'].get('max_dimension', 384)), '--install'],
                   cwd=ROOT, check=True)
    # 调用者随后仍会写 config；必须同步正式登记，不能把旧 files 覆盖回去。
    config.clear()
    config.update(json.loads((ROOT / 'data/ui.json').read_text()))


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--card',choices=CARDS)
    parser.add_argument('--install',action='store_true')
    args=parser.parse_args()
    config=json.loads((ROOT/'data/ui.json').read_text())
    for cls in PAINTERS:
        if args.card and cls.card!=args.card:
            continue
        painter=cls()
        directory=OUT/painter.card;folder=directory/"frames";folder.mkdir(parents=True,exist_ok=True)
        frames=[];hashes=[];fixed_changes=[]
        old=np.asarray(painter.original)
        fixed=np.asarray(painter.allowed)==0
        for i in range(painter.count):
            frame=painter.frame(i);frame.save(folder/f"{i:03d}.png")
            frames.append(frame);hashes.append(hashlib.sha256(frame.tobytes()).hexdigest())
            fixed_changes.append(int(np.count_nonzero(np.any(np.asarray(frame)!=old,axis=2)&fixed)))
        report={"card":painter.card,"method":"original PNG canvas, local pose drawing",
                "frames":painter.count,"fps":FPS,"action_speed":ACTION_SPEED,
                "size":painter.size,"edit_boxes":painter.boxes,
                "play_mode":painter.mode,"source_rgba_sha256":HASHES[painter.card],
                "rgba_sha256":hashes,"fixed_changed_pixels":fixed_changes,"user_review":"pending"}
        (directory/'drawing.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
        preview(frames,directory)
        if args.install:
            install(painter.card,frames,report,directory,config)
        print(f"{painter.card}: {painter.count} native complete frames, {len(set(hashes))} poses, fixed pixels {max(fixed_changes)}",flush=True)
    if args.install:
        (ROOT/'data/ui.json').write_text(json.dumps(config,ensure_ascii=False,indent=2)+'\n')


if __name__=='__main__':
    main()
