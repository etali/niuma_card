#!/usr/bin/env python3
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
"""八张攻击/增益牌；在唯一原 PNG 局部绘制并导出完整原生帧。"""
import math
import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageChops
from render_hover_common import (NativePainter, ROOT, FPS, path, polygon_mask, rect_mask,
    ellipse_mask, content, affine_pose, gradient_fill, painted_polygon, stroke_path, dilate_disk,
    cubic, ease, run)

INK=(29,23,19,255)
CREAM=(255,248,227,255)


def union(*masks):
    out=masks[0].copy()
    for mask in masks[1:]:out=ImageChops.lighter(out,mask)
    return out


def clear(canvas,mask):
    canvas.paste((0,0,0,0),(0,0,*canvas.size),mask)


def closed(canvas,points,fill,ink=INK,width=16):
    painted_polygon(canvas,points,fill,ink,width)


def sample_silhouette(source,points,sample_box,width=16,ink=INK):
    mask=polygon_mask(source.size,points,True)
    canvas=Image.new('RGBA',source.size)
    fill=gradient_fill(source,mask,sample_box)
    canvas.paste(fill,(0,0),mask)
    stroke_path(canvas,points+[points[0]],width,ink)
    return canvas


def ellipse_shape(size,box,fill,ink=INK,width=16):
    out=Image.new('RGBA',size)
    mask=ellipse_mask(size,box)
    out.paste(fill,(0,0,*size),mask)
    x0,y0,x1,y1=box;cx=(x0+x1)/2;cy=(y0+y1)/2
    points=[(cx+(x1-x0)/2*math.cos(k*math.tau/160),cy+(y1-y0)/2*math.sin(k*math.tau/160))for k in range(161)]
    stroke_path(out,points,width,ink)
    return out


def fit_background(source,mask,sample_box,predicate=None):
    return gradient_fill(source,mask,sample_box,predicate)


def alpha_component(source,seed):
    binary=source.getchannel('A').point(lambda a:255 if a>8 else 0)
    if binary.getpixel(seed)!=255:raise ValueError(f'坏的连通种子 {seed}')
    ImageDraw.floodfill(binary,seed,128)
    return binary.point(lambda a:255 if a==128 else 0).filter(ImageFilter.MaxFilter(3))


def filled_region(source,seed,kind='cream',limit=None):
    a=np.asarray(source)
    if kind=='cream':valid=(a[:,:,0]>220)&(a[:,:,1]>190)&(a[:,:,2]>145)&(a[:,:,3]>220)
    else:valid=(a[:,:,0]>230)&(a[:,:,1]>170)&(a[:,:,2]<175)&(a[:,:,3]>220)
    if limit is not None:valid &= np.asarray(limit)>0
    binary=Image.fromarray(valid.astype('uint8')*255).copy()
    if binary.getpixel(seed)!=255:raise ValueError(f'种子不在原底色内 {seed} {a[seed[1],seed[0]]}')
    ImageDraw.floodfill(binary,seed,128)
    interior=binary.point(lambda a:255 if a==128 else 0)
    outside=ImageChops.invert(interior);ImageDraw.floodfill(outside,(0,0),128)
    filled=outside.point(lambda a:0 if a==128 else 255)
    return dilate_disk(filled,26).point(lambda a:255 if a else 0)


def gray_fill(source,mask,sample_box):
    """只拟合原灰色屏幕，避免通用纸色采样拒绝暗灰像素而补成透明。"""
    a=np.asarray(source).copy();x0,y0,x1,y1=sample_box
    sample=a[y0:y1:3,x0:x1:3];yy,xx=np.mgrid[y0:y1:3,x0:x1:3]
    valid=(sample[:,:,3]>240)&(sample[:,:,:3].min(2)>42)&(sample[:,:,:3].max(2)<145)
    x=(xx[valid]-x0)/max(x1-x0,1);y=(yy[valid]-y0)/max(y1-y0,1)
    basis=np.stack([np.ones_like(x),x,y,x*y,x*x,y*y],1)
    fit=np.linalg.lstsq(basis,sample[valid,:3].astype(float),rcond=None)[0]
    py,px=np.nonzero(np.asarray(mask)>0);x=(px-x0)/max(x1-x0,1);y=(py-y0)/max(y1-y0,1)
    values=np.stack([np.ones_like(x),x,y,x*y,x*x,y*y],1)@fit
    a[py,px,:3]=np.clip(np.rint(values),0,255).astype('uint8');a[py,px,3]=255
    return Image.fromarray(a)


class Butie(NativePainter):
    card='butie';count=49;mode='once';boxes=((350,520,931,1153),)
    notes='桶与口内现金固定；现有下方两枚先后落入真实钱包口，追加四枚从两侧桶口相继落下，钱口承接且原钱包前壁遮挡。'
    def __init__(self):
        super().__init__()
        lm=filled_region(self.original,(501,754),'gold');rm=filled_region(self.original,(678,752),'gold')
        self.left_coin=content(self.original,lm);self.right_coin=content(self.original,rm)
        self.oldcoins=union(lm,rm)
        # 活动域含金币完整轮廓和发币起点；桶及口前已有大金币是固定遮挡。
        bucketmask=ImageChops.subtract(rect_mask(self.size,((0,0,1254,745),)),self.oldcoins)
        self.bucketfront=content(self.original,bucketmask)
        self.base=self.original.copy();clear(self.base,self.oldcoins)
        self.mouth=path(((465,831),(491,760),(664,765),(770,791)),((770,791),(813,807),(818,849),(815,879)),((815,879),(704,899),(560,888),(465,857)),((465,857),(455,849),(455,839),(465,831)))
        self.mouthmask=polygon_mask(self.size,self.mouth,True)
        mouthfill=gradient_fill(self.original,self.mouthmask,(445,904,706,1074))
        self.base.paste(mouthfill,(0,0),self.mouthmask)
        stroke_path(self.base,self.mouth+[self.mouth[0]],19,INK)
        # 原钱袋内已装的钱保留，不用落币动作清空它们。
        inside=union(ellipse_mask(self.size,(548,797,695,902)),ellipse_mask(self.size,(682,831,798,903)))
        self.base.alpha_composite(content(self.original,inside))
        self.front=content(self.original,rect_mask(self.size,((425,877,887,1152),)))
        self.brow=rect_mask(self.size,((475,943,650,1057),))
        self.front_face=gradient_fill(self.original,self.brow,(444,908,672,1080))
    def paint(self,t):
        out=self.base.copy()
        # 前两枚是原图里已在下落的金币；后四枚从现有桶口的下缘连续接上。
        streams=[(self.left_coin,.25,0,0,94,116),(self.right_coin,.65,0,0,-68,124),
                 (self.left_coin,1.25,-82,-146,94,116),(self.right_coin,1.5,116,-137,-68,124),
                 (self.left_coin,2.10,-82,-146,94,116),(self.right_coin,2.34,116,-137,-68,124)]
        for coin,start,dx0,dy0,dx1,dy1 in streams:
            p=ease((t-start)/.72)
            if t<start:
                if start<1:out.alpha_composite(coin)
                continue
            if p<1:
                moved=affine_pose(coin,(0,0),dx=dx0+(dx1-dx0)*p,dy=dy0+(dy1-dy0)*p)
                # 钱包口在前景盖住金币底缘，币不会突然被缩小。
                moved.putalpha(ImageChops.multiply(moved.getchannel('A'),rect_mask(self.size,((0,0,1254,892),))))
                out.alpha_composite(moved)
        out.alpha_composite(self.bucketfront)
        fill=ease((t-.6)/2.55)
        front=self.front.copy()
        front.paste(self.front_face,(0,0),self.brow)
        stroke_path(front,[(491,952),(521,972),(486,992)],14,INK)
        stroke_path(front,[(631,956),(602,975),(632,991)],14,INK)
        stroke_path(front,path(((490,1037),(509,1000-10*fill),(525,1075),(540,1032)),((540,1032),(559,1010-8*fill),(575,1076),(598,1038))),14,INK)
        # 钱包逐渐被撑开，底边和中心保持，桶与其他原物不动。
        front=affine_pose(front,(642,1140),sx=1+.04*fill,sy=1+.015*fill)
        out.alpha_composite(front)
        return out


class Heigongguan(NativePainter):
    card='heigongguan';count=49;mode='once';boxes=((465,210,1254,1230),)
    notes='原完整主黑云从第一秒起明显向右喷出；二十八批相互重叠的原生烟团从同一出口接续并上下分流，喇叭后景补完整，两人真实交替迈步逃开。'
    def __init__(self):
        super().__init__()
        self.people=[]
        masks=[]
        for seed,legbox,hip,destination,sweat in [((925,883),(811,989,1001,1077),(924,989),(31,103),((980,828),(1012,858))),((1124,956),(1024,1050,1214,1129),(1124,1054),(7,82),((1194,901),(1220,937)))]:
            mask=alpha_component(self.original,seed)
            for mark in sweat:
                try: mask=union(mask,alpha_component(self.original,mark))
                except ValueError: pass
            full=content(self.original,mask)
            upper=full.copy();clear(upper,rect_mask(self.size,(legbox,)))
            self.people.append((full,upper,hip,destination));masks.append(mask)
        self.base=self.original.copy();clear(self.base,union(*masks))
        puffmask=alpha_component(self.original,(680,490))
        self.puff=content(self.original,puffmask).crop(puffmask.getbbox())
        cloudoutline=[(479,650),(507,607),(547,625),(578,614),(613,632),(661,590),(689,544),(768,509),
            (775,457),(807,430),(818,386),(873,345),(927,342),(978,368),(1003,438),(1038,451),
            (1073,480),(1088,495),(1135,509),(1166,547),(1179,590),(1148,639),(1171,669),
            (1155,726),(1115,760),(1061,785),(995,766),(960,803),(917,783),(892,813),(853,837),
            (821,818),(772,834),(741,806),(701,803),(663,765),(620,742),(589,755),(548,789),(506,785),(482,745)]
        a=np.asarray(self.original)
        dark=Image.fromarray(((a[:,:,:3].max(2)<100)&(a[:,:,3]>0)).astype('uint8')*255)
        region=polygon_mask(self.size,cloudoutline,True).filter(ImageFilter.MaxFilter(45))
        # 喇叭墨边和烟同色。原主团只取 x690 右侧及精确的口部烟颈，
        # 绝不能把喇叭的弧线随主团带走成为悬空墨线。
        root=polygon_mask(self.size,[(478,646),(505,607),(548,626),(579,614),(614,634),
            (690,586),(705,735),(664,765),(620,742),(589,755),(548,789),(506,785),(480,745)],True)
        body=ImageChops.multiply(region,rect_mask(self.size,((690,210,1254,850),)))
        moving=ImageChops.multiply(dark,body)
        eraseregion=union(region,root)
        for seed in ((680,490),(741,461),(1125,388),(1200,693)):
            part=alpha_component(self.original,seed)
            moving=union(moving,part);eraseregion=union(eraseregion,part)
        moving=ImageChops.subtract(moving,union(*masks))
        # 两枚空心汗滴的中心是透明的，不能把中心当连通种子。
        # 从实际不透明边缘找小连通形，避免把原汗滴随烟带成悬空圆环。
        sweat=ImageChops.multiply(self.original.getchannel('A').point(lambda a:255 if a>8 else 0),
                                  rect_mask(self.size,((950,780,1060,876),)))
        while sweat.getbbox():
            arr=np.asarray(sweat);yy,xx=np.argwhere(arr>0)[0];part=alpha_component(self.original,(int(xx),int(yy)))
            b=part.getbbox()
            if b[2]-b[0]<100 and b[3]-b[1]<100:
                moving=ImageChops.subtract(moving,part)
            sweat=ImageChops.subtract(sweat,part)
        self.cloud=content(self.original,moving)
        # 烟颈与喇叭内弧在原稿中连成同一黑区。用原独立烟团接成圆润烟颈，
        # 不把弧线带走，也不让矩形取样边变成三角烟片。
        for cx,cy,diameter in ((558,702,154),(617,682,164),(681,679,194)):
            puff=self.puff.resize((diameter,diameter),Image.Resampling.BICUBIC)
            self.cloud.alpha_composite(puff,(round(cx-diameter/2),round(cy-diameter/2)))
        eraseregion=eraseregion.point(lambda a:255 if a else 0)
        clear(self.base,eraseregion)
        # 用完整口部补底，再恢复原来确实可见的金色和墨边。擦域含旧烟 AA，
        # 不能只擦深黑色而在金色口内残留半透明的旧烟轮廓。
        mouth=path(((515,421),(558,413),(600,482),(621,560)),
                   ((621,560),(649,635),(676,741),(661,822)),
                   ((659,822),(655,875),(641,906),(612,914)),
                   ((612,914),(571,939),(506,847),(473,771)),
                   ((473,771),(436,680),(423,565),(447,485)),
                   ((447,485),(462,444),(483,414),(515,421)))
        repair=sample_silhouette(self.original,mouth,(500,490,581,590),width=20)
        goldmask=polygon_mask(self.size,mouth,True)
        gold=gradient_fill(self.original,goldmask,(445,430,660,900),
             lambda a:(a[:,:,0]>230)&(a[:,:,1]>185)&(a[:,:,2]<205))
        repair.paste(gold,(0,0),goldmask)
        stroke_path(repair,mouth+[mouth[0]],20,INK)
        inner=path(((550,461),(502,420),(462,489),(475,594)),
                   ((475,594),(473,680),(506,781),(551,843)),
                   ((551,843),(567,866),(582,878),(588,880)))
        stroke_path(repair,inner,13,INK)
        # 只补真实旧烟遮挡域；矩形替换会在口沿产生横向裁断和透明缺口。
        self.base.alpha_composite(content(repair,eraseregion))
        # 被旧烟遮住的口沿和内弧整段接续，不在遮罩底边留下原/新边线台阶。
        seams=Image.new('RGBA',self.size)
        stroke_path(seams,path(((621,560),(649,635),(676,741),(661,822)),
                               ((661,822),(655,875),(641,906),(612,914))),43,(255,255,255,255))
        stroke_path(seams,inner,29,(255,255,255,255))
        seam_mask=seams.getchannel('A').point(lambda a:255 if a else 0)
        clear(self.base,seam_mask);self.base.alpha_composite(content(repair,seam_mask))
        # 下方原口沿本来完整可见，连续衔接后渐接回原像素；不能把补底截在
        # 某一条水平线上，也不能改写原来圆润的喇叭底缘。
        nativeblend=Image.new('L',self.size)
        d=ImageDraw.Draw(nativeblend)
        for y in range(790,self.size[1]):
            d.line([(0,y),(self.size[0],y)],fill=round(255*ease((y-790)/45)))
        nativeblend=ImageChops.multiply(nativeblend,seam_mask)
        self.base=Image.composite(self.original,self.base,nativeblend)
    def paint(self,t):
        t=min(t,3.75)
        out=self.base.copy()
        old=ease((t-.25)/1.8)
        out.alpha_composite(affine_pose(self.cloud,(0,0),dx=510*old,dy=-35*old))
        # 旧主团已经前推，后续完整小团从原口接上、长大并分向上下，首秒即可见喷流。
        for i in range(28):
            start=.25+i*.12
            if t<=start:continue
            u=ease((t-start)/1.3)
            cx=600+650*u
            side=(-1 if i%2 else 1)
            cy=680+side*(60+15*(i%3))*math.sin(math.pi*u*.70)
            scale=1.8+1.9*u
            puff=self.puff.resize((round(self.puff.width*scale),round(self.puff.height*scale)),Image.Resampling.BICUBIC)
            out.alpha_composite(puff,(round(cx-puff.width/2),round(cy-puff.height/2)))
        progress=ease((t-.75)/1.7)
        moving=(.75<t<2.45)
        for k,(full,upper,(hx,hy),(dx,dy)) in enumerate(self.people):
            actor=upper.copy()
            phase=(t-.75)*math.tau*2.3+k*1.1
            stride=math.sin(phase)*20 if moving else 0
            lift=max(0,math.cos(phase))*12 if moving else 0
            # 两腿由同一髋点出发，交替弯膝；跑停后落地。
            stroke_path(actor,path(((hx-10,hy-2),(hx-32,hy+29),(hx-55-stride,hy+43-lift),(hx-74-stride,hy+28-lift))),13,INK)
            stroke_path(actor,path(((hx+6,hy),(hx+29,hy+19),(hx+34+stride,hy+55),(hx+55+stride,hy+39))),13,INK)
            out.alpha_composite(affine_pose(actor,(hx,hy),dx=dx*progress,dy=dy*progress))
        return out


class Zuokong(NativePainter):
    card='zuokong';count=43;mode='once';boxes=((68,399,1060,1254),)
    notes='沿原下降折线强调后，原六枚中的五枚依次保持完整大小滚落桌外，只留右下原币；原报告完整补底且固定。'
    def __init__(self):
        super().__init__()
        source=np.asarray(self.original)
        def goldseed(center):
            cx,cy=center;patch=source[cy-40:cy+41,cx-40:cx+41]
            valid=(patch[:,:,0]>230)&(patch[:,:,1]>170)&(patch[:,:,2]<175)&(patch[:,:,3]>220)
            yy,xx=np.nonzero(valid);i=np.argmin((xx-40)**2+(yy-40)**2)
            return (int(cx-40+xx[i]),int(cy-40+yy[i]))
        seeds=tuple(goldseed(center)for center in ((322,662),(206,863),(480,819),(503,932),(482,1015)))
        # ¥ 将币面分成几块不相连的金色。孤立币按完整 alpha 连通轮廓
        # 擦除，不能只擦某一块金色而把原币外圈留成中空圆环。
        masks=[alpha_component(self.original,seed) if i<2 else filled_region(self.original,seed,'gold')
               for i,seed in enumerate(seeds)]
        self.base=self.original.copy();erase=union(*masks);clear(self.base,erase)
        # 完整报告的真实左边在金币后面，五枚拿走后不留透明洞或旧币墨线。
        paperpoly=[(448,341),(941,193),(1154,917),(650,1036)]
        pm=polygon_mask(self.size,paperpoly,True)
        paper=Image.new('RGBA',self.size)
        paper.paste(gradient_fill(self.original,pm,(470,215,1136,1008),lambda a:(a[:,:,0]>235)&(a[:,:,1]>220)&(a[:,:,2]>185)),(0,0),pm)
        stroke_path(paper,paperpoly+[paperpoly[0]],20,INK)
        self.base.alpha_composite(content(paper,erase))
        # 白色冲击角在钱堆后方也补成完整形状，不能滚开金币就露一段断纸边。
        # 原爆炸短线补成闭合短纸角。上角只补到原币后 y790，
        # 不发明 y897 的长三角；全部使用报告的同一纸色，不能采入金币黄。
        for points in ([(480,699),(535,748),(549,707),(577,787),(513,790)],):
            mask=polygon_mask(self.size,points,True)
            burst=Image.new('RGBA',self.size)
            fill=gradient_fill(self.original,mask,(470,215,1136,1008),
                 lambda a:(a[:,:,0]>235)&(a[:,:,1]>220)&(a[:,:,2]>185))
            burst.paste(fill,(0,0),mask);stroke_path(burst,points+[points[0]],15,INK)
            self.base.alpha_composite(burst)
        lowerwhite=Image.fromarray(((source[:,:,:3].min(2)>220)&(source[:,:,3]>220)).astype('uint8')*255)
        lowerwhite=ImageChops.multiply(lowerwhite,rect_mask(self.size,((605,895,800,1050),)))
        self.base.paste(self.original,(0,0),ImageChops.multiply(lowerwhite,erase))
        # 两枚孤立圆币使用全部原始像素，钱堆的遮挡下半补成完整椭圆再动。
        self.coins=[]
        for seed,center in zip(seeds[:2],((322,662),(206,863))):
            self.coins.append((content(self.original,alpha_component(self.original,seed)),center))
        # 只复用完整 ¥ 的原像素，不把旧金币遮挡边/爆炸纸角采进活动币面。
        inkvalid=(source[:,:,:3].max(2)<100)&(source[:,:,3]>220)
        symbol=Image.fromarray(inkvalid.astype('uint8')*255).copy()
        ImageDraw.floodfill(symbol,(526,840),128)
        symbol=symbol.point(lambda a:255 if a==128 else 0).filter(ImageFilter.MaxFilter(5))
        symbol=content(self.original,symbol)
        for center,w,h,angle,nativebox in [((526,840),187,119,.28,(452,793,600,881)),
              ((511,934),211,121,.08,(434,910,590,980)),((488,1008),211,120,.04,(405,997,575,1055))]:
            cx,cy=center;points=[]
            for i in range(161):
                a=i*math.tau/160;x=w/2*math.cos(a);y=h/2*math.sin(a)
                points.append((cx+x*math.cos(angle)-y*math.sin(angle),cy+x*math.sin(angle)+y*math.cos(angle)))
            m=polygon_mask(self.size,points,True)
            coin=Image.new('RGBA',self.size)
            gold=gradient_fill(self.original,m,(398,780,617,1064),lambda a:(a[:,:,0]>230)&(a[:,:,1]>170)&(a[:,:,2]<175))
            coin.paste(gold,(0,0),m);stroke_path(coin,points,17,INK)
            coin.alpha_composite(affine_pose(symbol,(526,840),dx=cx-526,dy=cy-840))
            self.coins.append((coin,center))
        # 留下的原右下现金始终固定，处在原冲击角前面。
        self.keepmask=filled_region(self.original,goldseed((710,1045)),'gold')
        self.keep=content(self.original,self.keepmask)
        self.base.paste(self.original,(0,0),self.keepmask)
        # 独立的旧动势线不应在现金离开后悬空；只移除它们，不动报告两侧墨迹。
        pending=self.original.getchannel('A').point(lambda a:255 if a>8 else 0)
        while pending.getbbox():
            a=np.asarray(pending);y,x=np.argwhere(a==255)[0]
            ImageDraw.floodfill(pending,(int(x),int(y)),128)
            part=pending.point(lambda a:255 if a==128 else 0);b=part.getbbox();n=part.histogram()[255]
            if n<6000 and b[2]-b[0]<120 and b[3]-b[1]<160 and ((b[1]>500 and b[2]<435)or(b[1]>1030 and b[2]<650)):
                clear(self.base,dilate_disk(part,3))
            pending=pending.point(lambda a:0 if a==128 else a)
        self.line=[(557,446),(602,568),(641,551),(684,607),(724,581),(798,725),(852,702),(969,872)]
    def paint(self,t):
        out=self.base.copy()
        p=min(1,max(0,(t-.25)/.75));segments=len(self.line)-1;at=p*segments
        if t<1.0:
            j=min(segments-1,int(at));q=at-j
            x0,y0=self.line[j];x1,y1=self.line[j+1];x=x0+(x1-x0)*q;y=y0+(y1-y0)*q
            stroke_path(out,[(x-7,y-9),(x+7,y+9)],11,(221,174,79,255))
        for i,((coin,center),dx,dy)in enumerate(zip(self.coins,(-150,-110,-180,-150,-90),(780,620,680,560,460))):
            q=ease((t-(.95+i*.16))/.95)
            fall=q*q
            out.alpha_composite(affine_pose(coin,center,angle=(-1 if i%2 else 1)*q*2.1,dx=dx*q,
                               dy=dy*fall-35*math.sin(math.pi*q)))
        out.paste(self.original,(0,0),self.keepmask)
        return out


class Eryouxuan(NativePainter):
    card='eryouxuan';count=37;mode='once';boxes=((663,518,1149,1090),(577,867,652,929))
    notes='左店/左路固定，右路从第一帧即断开；原接触点剪刀两半连柄开合，断端退开后小人目光望左。'
    def __init__(self):
        super().__init__()
        self.pivot=(878,713)
        # 完整闭合半剪刀：上握柄连接下刀刃，下握柄连接上刀刃。
        upper=path(((823,667),(772,690),(683,660),(683,593)),((683,593),(684,538),(745,510),(790,537)),((790,537),(826,557),(843,616),(838,655)),((838,655),(881,696),(959,769),(1028,879)),((1028,879),(968,865),(926,803),(866,753)),((866,753),(837,711),(821,686),(823,667)))
        lower=path(((834,717),(778,700),(707,714),(686,751)),((686,751),(661,801),(704,835),(753,831)),((753,831),(805,826),(817,775),(839,749)),((839,749),(866,738),(973,785),(1080,803)),((1080,803),(1039,757),(957,725),(881,703)),((881,703),(854,693),(846,706),(834,717)))
        topgrip=filled_region(self.original,(704,592),'gold')
        bottomgrip=filled_region(self.original,(760,723),'gold')
        downblade=filled_region(self.original,(924,769),limit=polygon_mask(self.size,[(852,709),(906,740),(1048,903),(949,858),(860,755)]))
        upblade=filled_region(self.original,(942,744),limit=polygon_mask(self.size,[(842,677),(916,701),(1095,820),(987,801),(857,750)]))
        upperneck=polygon_mask(self.size,[(793,636),(834,653),(889,700),(903,737),(875,753),(835,726),(796,681)],True)
        lowerneck=polygon_mask(self.size,[(791,753),(823,728),(860,704),(878,691),(902,717),(875,755),(838,782)],True)
        topmask=union(topgrip,downblade,upperneck)
        bottommask=union(bottomgrip,upblade,lowerneck)
        self.upper=self.half(upper,(718,565,798,638),(697,563,729,629))
        self.lower=self.half(lower,(706,742,791,807),(735,717,774,738))
        # 握柄孔里可见的店铺基线属于固定后景，不跟着剪刀转。
        hole=polygon_mask(self.size,[(742,565),(766,569),(788,590),(790,616),(776,630),(748,631),(726,617),(723,590)],True)
        # 孔为已闭合的握柄内孔，由 half 同步绘出；店铺基线留在后景。
        self.joint=content(self.original,ellipse_mask(self.size,(854,689,903,739)))
        fullmask=union(topmask,bottommask).filter(ImageFilter.MaxFilter(7)).point(lambda a:255 if a else 0)
        self.base=self.original.copy();clear(self.base,fullmask)
        # 握柄挪开后露出的店墙、左竖边与门框必须完整，孔中看见的是这一固定后景。
        shop=Image.new('RGBA',self.size)
        shopshape=polygon_mask(self.size,[(768,371),(1128,371),(1128,598),(768,598)],True)
        shopfill=gradient_fill(self.original,shopshape,(850,418,1100,583))
        shop.paste(shopfill,(0,0),shopshape)
        stroke_path(shop,[(768,373),(768,598)],17,INK)
        stroke_path(shop,[(1128,373),(1128,598)],17,INK)
        stroke_path(shop,path(((829,598),(826,553),(826,441),(829,421)),((829,421),(846,407),(1008,407),(1043,415)),((1043,415),(1055,433),(1049,548),(1049,597))),17,INK)
        stroke_path(shop,[(935,417),(935,597)],17,INK)
        self.base.alpha_composite(content(shop,fullmask))
        # 把剪刀遮住的右店底沿和已断上段完整补出，连接真实店门。
        road=path(((906,601),(934,655),(874,744),(846,793)),((846,793),(830,828),(820,869),(821,914)),((821,914),(838,902),(850,918),(860,918)),((860,918),(879,899),(890,936),(908,922)),((908,922),(926,909),(941,949),(957,929)),((957,929),(973,918),(977,938),(987,934)),((987,934),(969,861),(961,838),(979,782)),((979,782),(1004,708),(1017,652),(996,599)))
        canvas=sample_silhouette(self.original,road,(918,623,978,696),width=15)
        self.base.alpha_composite(content(canvas,fullmask))
        stroke_path(self.base,[(741,597),(1132,597)],15,INK)
        self.lowerroad=content(self.original,rect_mask(self.size,((783,936,1018,1048),)))
        clear(self.base,rect_mask(self.size,((783,936,1018,1050),)))
        self.face_mask=rect_mask(self.size,((580,866,650,929),))
        self.face_bg=gradient_fill(self.original,self.face_mask,(557,841,651,909))
    def half(self,points,hole,sample):
        out=Image.new('RGBA',self.size);closed(out,points,(252,217,129,255),width=15)
        # 刀面为原奶油纸色，握柄保留原金色；窄颈也有实体填色。
        blade=polygon_mask(self.size,[(839,654),(876,695),(1037,876),(944,831),(827,699)],True) if hole[1]<600 else polygon_mask(self.size,[(834,713),(877,695),(1081,803),(953,788),(835,750)],True)
        out.paste(CREAM,(0,0,*self.size),ImageChops.multiply(blade,out.getchannel('A')))
        stroke_path(out,points+[points[0]],15,INK)
        clear(out,ellipse_mask(self.size,hole))
        x0,y0,x1,y1=hole;cx=(x0+x1)/2;cy=(y0+y1)/2
        stroke_path(out,[(cx+(x1-x0)/2*math.cos(k*math.tau/96),cy+(y1-y0)/2*math.sin(k*math.tau/96))for k in range(97)],15,INK)
        return out
    def paint(self,t):
        out=self.base.copy();close=ease((t-.35)/.65)*(1-ease((t-1.1)/.55))
        out.alpha_composite(affine_pose(self.lower,self.pivot,angle=.12*close))
        out.alpha_composite(affine_pose(self.upper,self.pivot,angle=-.12*close))
        out.alpha_composite(self.joint)
        retreat=ease((t-.95)/.7)
        out.alpha_composite(affine_pose(self.lowerroad,(0,0),dy=32*retreat))
        worry=ease((t-1.3)/.5)
        if worry>0:
            out.paste(self.face_bg,(0,0),self.face_mask)
            for x,y in[(593-4*worry,878),(638-4*worry,870)]:out.alpha_composite(ellipse_shape(self.size,(x-7,y-7,x+7,y+7),INK,width=0))
            stroke_path(out,path(((598,916),(608,896),(629,891),(640,907))),12,INK)
        return out


class Chaping(NativePainter):
    card='chaping';count=25;mode='once';boxes=((35,101,1240,1140),)
    notes='三次完整差评气泡在约1.1秒内连续冲撞手机；位移加倍，接触后新增裂纹，手机嘴更委屈，底板完整不透明。'
    def __init__(self):
        super().__init__()
        polys=[[(81,451),(139,371),(96,301),(185,280),(200,192),(276,214),(333,144),(386,182),(470,132),(497,202),(595,183),(569,272),(630,318),(596,373),(619,438),(579,456),(602,522),(553,514),(583,657),(432,565),(388,608),(331,579),(280,610),(209,574),(118,579),(142,492)],
               [(818,434),(847,370),(829,293),(891,283),(904,220),(962,244),(998,215),(1036,270),(1108,248),(1101,329),(1171,348),(1135,388),(1170,450),(1124,470),(1130,532),(1042,515),(1021,566),(943,512),(899,540),(857,505),(811,559),(836,456)],
               [(727,880),(801,882),(773,798),(816,812),(784,758),(834,785),(893,747),(948,783),(1053,751),(1079,818),(1137,838),(1111,887),(1171,947),(1122,989),(1132,1020),(1041,1037),(982,1084),(906,1027),(868,1048),(846,994),(789,985),(811,926)]]
        # 擦除域和活动泡取样域分开：旧尾巴/AA 全擦净，新泡不带走后面的手机切片。
        self.masks=[union(polygon_mask(self.size,p,True).filter(ImageFilter.MaxFilter(39)),
                          ImageChops.multiply(filled_region(self.original,seed),
                            ImageChops.multiply(rect_mask(self.size,(limit,)),
                                                polygon_mask(self.size,p,True).filter(ImageFilter.MaxFilter(129)))))
                    for p,seed,limit in zip(polys,((355,216),(997,270),(1040,809)),
                                           ((55,100,660,678),(785,180,1204,586),(700,720,1210,1125)))]
        tailfragment=polygon_mask(self.size,[(430,589),(525,627),(509,663),(444,661)],True).filter(ImageFilter.MaxFilter(13))
        self.masks[0]=union(self.masks[0],tailfragment)
        self.masks=[m.point(lambda a:255 if a else 0)for m in self.masks]
        self.bubbles=[]
        for poly,sample in zip(polys,((141,192,591,571),(858,243,1120,519),(815,778,1112,1021))):
            shape=polygon_mask(self.size,poly,True)
            bubble=Image.new('RGBA',self.size)
            fill=gradient_fill(self.original,shape,sample,lambda a:(a[:,:,0]>235)&(a[:,:,1]>220)&(a[:,:,2]>185))
            bubble.paste(fill,(0,0),shape)
            stroke_path(bubble,poly+[poly[0]],20,INK)
            # 内部拇指、星级及尾内黑划仍是原稿像素；完整边用闭合形状保证不夹手机。
            inner=shape.filter(ImageFilter.MinFilter(43))
            symbolboxes=(((243,232,500,439),(183,425,547,536)),
                         ((893,294,1110,501),),
                         ((850,816,1115,1021),))[len(self.bubbles)]
            native=ImageChops.multiply(inner,rect_mask(self.size,symbolboxes))
            bubble.alpha_composite(content(self.original,native))
            if not self.bubbles:
                # 完整纸尾内只有这一根原黑划，不采入尾巴后面的手机断角。
                stroke_path(bubble,[(483,535),(528,607)],11,INK)
            self.bubbles.append(bubble)
        self.base=self.original.copy();clear(self.base,union(*self.masks))
        # 完整手机后景仅补在原气泡遮挡域，原可见壳、屏、裂纹都保留。
        hidden=union(*self.masks)
        phone=sample_silhouette(self.original,[(559,432),(897,528),(891,575),(754,1047),(723,1086),(396,1013),(380,978)],(500,957,710,1000),width=17)
        phonebody=polygon_mask(self.size,[(559,432),(897,528),(891,575),(754,1047),(723,1086),(396,1013),(380,978)],True)
        white=gradient_fill(self.original,phonebody,(385,450,900,1070),lambda a:(a[:,:,0]>235)&(a[:,:,1]>220)&(a[:,:,2]>185))
        phone.paste(white,(0,0),phonebody)
        stroke_path(phone,[(559,432),(897,528),(891,575),(754,1047),(723,1086),(396,1013),(380,978),(559,432)],17,INK)
        screenpoints=[(568,502),(861,565),(730,999),(433,925)]
        screenmask=polygon_mask(self.size,screenpoints,True)
        screen=Image.new('RGBA',self.size)
        screen.paste(gray_fill(self.original,screenmask,(573,639,746,902)),(0,0),screenmask)
        stroke_path(screen,screenpoints+[screenpoints[0]],12,INK)
        phone.alpha_composite(screen)
        self.screenmask=screenmask
        self.face_mask=rect_mask(self.size,((553,766,723,845),))
        self.face_bg=gray_fill(self.original,self.face_mask,(573,639,746,902))
        self.base.alpha_composite(content(phone,hidden))
        # 旧泡尾遮住手机边线时，补底不能在擦除域的矩形下沿截成台阶。
        # 四条直边按同一完整线段连续补齐，端点都藏在原泡/底部圆角之前。
        borders=Image.new('RGBA',self.size)
        for pts,width in (([(559,432),(383,970)],43),
                          ([(568,502),(433,925)],31),
                          ([(891,575),(759,1030)],43),
                          ([(861,565),(730,999)],31)):
            stroke_path(borders,pts,width,(255,255,255,255))
        border_mask=borders.getchannel('A').point(lambda a:255 if a else 0)
        clear(self.base,border_mask)
        self.base.alpha_composite(content(phone,border_mask))
        # 新裂纹仍是表面墨迹；原裂纹和手机表情留着。
        self.cracks=[[(564,595),(584,618),(568,641),(601,654)],[(808,577),(787,611),(807,627),(787,650)],[(738,854),(711,872),(731,891),(704,916)]]
    def paint(self,t):
        out=self.base.copy()
        hurt=ease((t-.55)/.7)
        if hurt>0:
            out.paste(self.face_bg,(0,0),self.face_mask)
            stroke_path(out,path(((568,805),(590,765-12*hurt),(609,812+7*hurt),(627,792)),
                                ((627,792),(647,763-10*hurt),(671,826+10*hurt),(697,830+8*hurt))),17,INK)
        for k,start in enumerate((.25,.55,.85)):
            if t>=start+.23:
                n=ease((t-start-.23)/.10)
                pts=self.cracks[k];step=max(2,round(n*(len(pts)-1))+1)
                newcrack=Image.new('RGBA',self.size)
                stroke_path(newcrack,pts[:step],10,(243,235,217,255))
                out.alpha_composite(content(newcrack,self.screenmask))
        # 气泡为完整前景，始终盖住后景裂纹；裂纹不能穿进白泡纸面。
        for bubble,start,dx,dy in zip(self.bubbles,(.25,.55,.85),(72,-74,-65),(50,49,-62)):
            hit=ease((t-start)/.23);bounce=ease((t-start-.25)/.20)
            p=hit-.42*bounce
            out.alpha_composite(affine_pose(bubble,(0,0),dx=dx*p,dy=dy*p))
        return out


class Yinqing996(NativePainter):
    card='yinqing996';count=49;mode='once';boxes=((170,324,810,969),(920,716,1226,1111))
    notes='向画面右跑：右前方落脚，承重脚沿内轮向左后蹬，离地屈膝后向右前摆；左侧轮带向上、底部向左，与承重脚接触同向。头身、设备、两张完整逐张出纸保持原位。'
    def __init__(self):
        super().__init__()
        self.base=self.original.copy()
        self.treads=[[(303,395),(485,396)],[(261,454),(395,451)],[(211,536),(346,518)],[(207,609),(333,587)],[(207,694),(324,673)],[(231,786),(275,773)],[(257,855),(302,844)],[(377,929),(526,918)],[(510,938),(670,910)]]
        # 完整的可见踏板面带，墨线只在带内推进，外围原轮圈像素保留。
        bandpoints=[(310,390),(485,388),(401,451),(353,521),(341,602),(340,695),(378,787),(443,851),(590,920),(673,907),(613,952),(504,974),(373,937),(250,863),(224,790),(197,699),(194,610),(199,533),(253,446)]
        self.bandmask=polygon_mask(self.size,bandpoints,True)
        maskcanvas=Image.new('RGBA',self.size)
        for line in self.treads:stroke_path(maskcanvas,line,24,(255,255,255,255))
        self.treadmask=ImageChops.multiply(maskcanvas.getchannel('A'),self.bandmask)
        cream=gradient_fill(self.original,self.treadmask,(214,545,316,664),lambda a:(a[:,:,0]>230)&(a[:,:,1]>205)&(a[:,:,2]>160))
        self.base.paste(cream,(0,0),self.treadmask)
        # 原双腿只有墨线，按墨线的真实连通位置擦除，不挖矩形穿破轮圈。
        legcanvas=Image.new('RGBA',self.size)
        stroke_path(legcanvas,[(449,800),(419,837),(396,846),(357,813),(335,832)],38,(255,255,255,255))
        stroke_path(legcanvas,[(527,804),(550,809),(567,830),(575,886),(609,872)],39,(255,255,255,255))
        self.legmask=legcanvas.getchannel('A')
        clear(self.base,self.legmask)
        # 原身体和手只保留其真实闭合轮廓，绝不连同背后的旧踏板一起取样。
        head=ellipse_mask(self.size,(436,545,627,728)).filter(ImageFilter.MaxFilter(4+1))
        body=polygon_mask(self.size,path(((471,708),(483,706),(552,718),(548,750)),((548,750),(530,805),(509,821),(480,819)),((480,819),(441,812),(436,791),(455,752)),((455,752),(464,731),(476,716),(471,708))),True).filter(ImageFilter.MaxFilter(23))
        armscanvas=Image.new('RGBA',self.size)
        stroke_path(armscanvas,[(474,715),(421,687),(378,727)],30,(255,255,255,255))
        stroke_path(armscanvas,[(544,736),(598,756),(646,706)],30,(255,255,255,255))
        self.upper=content(self.original,union(head,body,armscanvas.getchannel('A')))
        self.papermask=filled_region(self.original,(1077,824))
        paperoutline=path(((1008,788),(1043,778),(1092,764),(1129,755)),((1129,755),(1148,749),(1167,804),(1182,857)),((1182,857),(1198,914),(1208,939),(1215,947)),((1215,947),(1170,964),(1121,982),(1070,994)),((1070,994),(1042,986),(1026,934),(1008,873)),((1008,873),(995,830),(987,799),(1008,788)))
        self.paper=sample_silhouette(self.original,paperoutline,(1070,792,1114,928),width=17)
        inside=polygon_mask(self.size,paperoutline).filter(ImageFilter.MinFilter(27))
        self.paper.alpha_composite(content(self.original,inside))
        clear(self.base,self.papermask)
        tongue=path(((948,744),(981,729),(1024,744),(1046,766)),((1046,766),(1026,774),(1006,783),(982,784)),((982,784),(974,764),(965,755),(948,744)))
        self.base.alpha_composite(sample_silhouette(self.original,tongue,(966,746,1007,765),width=14))
        # 脚掠过的轮壁仍用原像素恢复，其他轮架/轮轴也全保持。
        inneredge=Image.new('RGBA',self.size)
        stroke_path(inneredge,path(((328,767),(339,839),(413,915),(514,941)),((514,941),(581,952),(663,910),(720,835))),23,(255,255,255,255))
        self.base.alpha_composite(content(self.original,inneredge.getchannel('A')))
        # 透明内腔的凸外界给出原内轮真实曲线；忽略腔内小人孔洞，不重画椭圆。
        blank=self.original.getchannel('A').point(lambda a:255 if a<8 else 0)
        ImageDraw.floodfill(blank,(604,474),128)
        hole=blank.point(lambda a:255 if a==128 else 0)
        points=[];ha=np.asarray(hole)
        for y in range(ha.shape[0]):
            xx=np.flatnonzero(ha[y])
            if len(xx):points.extend(((int(xx[0]),y),(int(xx[-1]),y)))
        pts=sorted(set(points))
        def cross(o,a,b):return (a[0]-o[0])*(b[1]-o[1])-(a[1]-o[1])*(b[0]-o[0])
        lower=[]
        for pt in pts:
            while len(lower)>=2 and cross(lower[-2],lower[-1],pt)<=0:lower.pop()
            lower.append(pt)
        upper=[]
        for pt in reversed(pts):
            while len(upper)>=2 and cross(upper[-2],upper[-1],pt)<=0:upper.pop()
            upper.append(pt)
        hull=polygon_mask(self.size,lower[:-1]+upper[:-1])
        # 原内腔下缘就是唯一接触面，脚底按实际轮弧采样，不能悬空踩近似椭圆。
        cavity=np.asarray(hull)>128
        self.ground_points=[]
        for x in range(350,636,5):
            bottom=[]
            for samplex in range(x-2,x+3):
                ys=np.flatnonzero(cavity[:,samplex])
                if len(ys):bottom.append(int(ys[-1]))
            self.ground_points.append((x,float(np.median(bottom))-7))
        self.contact_points=[(x,self.surface(x))for x in range(585,394,-5)]
        self.contact_distances=[0.]
        for p,q in zip(self.contact_points,self.contact_points[1:]):
            self.contact_distances.append(self.contact_distances[-1]+math.hypot(q[0]-p[0],q[1]-p[1]))
        self.contact_length=self.contact_distances[-1]
        # 旧踏板局部补色不能伸进原透明内腔；清回原腔，原固定上身/汗滴保留，旧腿除外。
        nativeinside=content(self.original,hull);clear(nativeinside,self.legmask)
        clear(self.base,hull);self.base.alpha_composite(nativeinside)
        # 内腔真实凸边界外侧的完整 18px 轮壁，先保留原深墨像素，再补连续边。
        # 不能用矩形膨胀把旧踏板端头/旧脚一起复制成前景。
        wall=ImageChops.subtract(dilate_disk(hull,18),hull)
        rimcanvas=Image.new('RGBA',self.size)
        rimcanvas.paste(INK,(0,0,*self.size),wall)
        origarr=np.asarray(self.original)
        nativeblack=Image.fromarray(((np.max(origarr[:,:,:3],axis=2)<80)&(origarr[:,:,3]>220)).astype('uint8')*255)
        rimcanvas.paste(self.original,(0,0),ImageChops.multiply(nativeblack,wall))
        # 前轮的奶油色环是原稿真正闭合且未被踏板切断的独立区域。
        # 由它的连续边缘构造干净墨边，不能复制原图边缘旁的旧踏板端头。
        frontpixels=(origarr[:,:,0]>220)&(origarr[:,:,1]>190)&(origarr[:,:,2]>145)&(origarr[:,:,3]>220)
        front=Image.fromarray(frontpixels.astype('uint8')*255).copy()
        ImageDraw.floodfill(front,(165,640),128)
        front=front.point(lambda a:255 if a==128 else 0)
        frontouter=dilate_disk(front,20)
        frontborder=ImageChops.subtract(frontouter,front)
        frontrim=Image.new('RGBA',self.size)
        frontrim.paste((24,13,7,255),(0,0,*self.size),frontborder)
        # 原奶油填色保留原像素，只有墨边的旧横条端头由闭合边界清理。
        frontrim.alpha_composite(content(self.original,front))
        rimcanvas.alpha_composite(frontrim)
        self.fixed_rim=rimcanvas
        # 完整擦域包含原横条端点；腔体、连续边和前轮环作为固定前景保护。
        expanded=union(dilate_disk(self.bandmask,20),maskcanvas.getchannel('A'),
                       polygon_mask(self.size,[(424,331),(564,336),(490,401),(355,420),(346,378)],True))
        opaque=self.original.getchannel('A').point(lambda a:255 if a>128 else 0)
        self.bandmask=ImageChops.multiply(ImageChops.subtract(expanded,union(hull,wall,frontouter)),opaque)
    def surface(self,x):
        x=max(self.ground_points[0][0],min(self.ground_points[-1][0],x))
        for p,q in zip(self.ground_points,self.ground_points[1:]):
            if p[0]<=x<=q[0]:
                u=(x-p[0])/(q[0]-p[0]);return p[1]+(q[1]-p[1])*u
        return self.ground_points[-1][1]
    def foot(self,progress):
        # 前方落脚点 x585 → 后蹬点 x395，按弧长匀速承重；回收时反向取样。
        distance=max(0,min(1,progress))*self.contact_length
        for i,(a,b)in enumerate(zip(self.contact_distances,self.contact_distances[1:])):
            if a<=distance<=b:
                p,q=self.contact_points[i:i+2];u=(distance-a)/max(b-a,1e-9)
                return tuple(x+(y-x)*u for x,y in zip(p,q))
        return self.contact_points[-1]
    def leg(self,out,hip,foot,lift,k,onset,settle):
        hx,hy=hip;fx,fy=foot
        # 膝盖向右前摆；旧版固定向左折膝会把整个跑步语义反过来。
        air=lift/76
        knee=(hx+(fx-hx)*.52+26+22*air,max(hy+16,hy+(fy-hy)*.48-25*air))
        ankle=(fx-8,fy-10)
        heel=(fx-9,fy-2)
        toe=(fx+18,self.surface(fx+18)-1-lift-10*air)
        pose=[knee,ankle,heel,toe]
        restx=447 if k==0 else 534;resty=self.surface(restx)
        rest=[((hx+restx)/2,(hy+resty)/2),(restx-8,resty-10),
              (restx-9,resty-2),(restx+18,self.surface(restx+18)-1)]
        original=[(393,846),(356,813),(356,813),(335,832)] if k==0 else [(566,824),(575,886),(575,886),(610,872)]
        points=[]
        for first,runpoint,restpoint in zip(original,pose,rest):
            current=tuple(a+(b-a)*settle for a,b in zip(runpoint,restpoint))
            points.append(tuple(a+(b-a)*onset for a,b in zip(first,current)))
        stroke_path(out,[hip]+points,17,INK)
    def paint(self,t):
        out=self.base.copy()
        # 腿从胎面上离开后仍是完整奶油色胎面，而非透明洞。
        treadfill=Image.new('RGBA',self.size,(253,242,214,255))
        out.paste(treadfill,(0,0),self.bandmask)
        clock=max(0,min(t,3.48)-.25)
        start=min(1,clock/.35)
        elapsed=clock-min(clock,.35)+.35*(start**3-.5*start**4)
        stop=max(0,min(1,(t-3.1)/.38))
        elapsed-=.38*(stop**3-.5*stop**4)
        phase=max(0,elapsed)*.9
        # 承重脚的弧长位移就是轮带推进距离；左侧向上即顺时针、轮底向左。
        shift=(phase*self.contact_length/.48)%74
        movingmarks=Image.new('RGBA',self.size)
        bandarr=np.asarray(self.bandmask)
        # 每条横板直接取原轮带真实左右端，不用近似折线留下悬空端点。
        for i in range(8):
            y=342+((i*74-shift)%600)
            row=max(0,min(self.size[1]-1,round(y)))
            xx=np.flatnonzero(bandarr[row]>128)
            intervals=np.split(xx,np.where(np.diff(xx)>1)[0]+1)
            candidates=[part for part in intervals if len(part)>20 and part[0]<715]
            if not candidates:continue
            part=max(candidates,key=len)
            xl=float(part[0]);xr=float(part[-1])
            # 同一行两个端点都伸至墨边下，前景轮壁覆盖后保持真实连接。
            stroke_path(movingmarks,[(xl-10,y),(xr+10,y)],11,INK)
        movingmarks.putalpha(ImageChops.multiply(movingmarks.getchannel('A'),self.bandmask))
        out.alpha_composite(movingmarks)
        out.alpha_composite(self.fixed_rim)
        for k in range(2):
            cycle=(phase+.48+k*.5)%1
            if cycle<.48:
                foot=self.foot(cycle/.48);lift=0.
            else:
                swing=(cycle-.48)/.52
                foot=self.foot(1-ease(swing));lift=76*math.sin(math.pi*swing)
                foot=(foot[0],foot[1]-lift)
            onset=ease((t-.25)/.45)
            self.leg(out,(453,805) if k==0 else (526,805),foot,lift,k,onset,ease(stop))
        out.alpha_composite(self.upper)
        out.paste(self.original,(0,0),rect_mask(self.size,((452,564,608,697),(726,639,827,731),(940,708,995,733))))
        first=ease((t-.35)/1.08)
        firstpaper=affine_pose(self.paper,(0,0),dx=8*first,dy=79*first)
        start=1.58;second=ease((t-start)/1.38)
        if t>=start:
            paper=affine_pose(self.paper,(0,0),dx=-60*(1-second)-15*second,dy=-170*(1-second)+8*second)
            # 真实出纸口上沿的半平面剪裁：纸前缘先出，然后完整送完。
            visible=polygon_mask(self.size,[(949,790),(1254,710),(1254,1190),(949,1190)],True)
            paper.putalpha(ImageChops.multiply(paper.getchannel('A'),visible))
            out.alpha_composite(paper)
        out.alpha_composite(firstpaper)
        return out


class Resou(NativePainter):
    card='resou';count=49;mode='loop';boxes=((485,12,1130,782),(505,836,651,948))
    notes='完整火焰轮廓连续大幅回收、窜高与侧摆，根部固定；钉尖和下托固定，上钉帽沿原轴压下、钉杆真实缩短后回弹。'
    def __init__(self):
        super().__init__()
        self.firemask=filled_region(self.original,(817,440),'gold')
        self.pinmask=polygon_mask(self.size,path(((655,507),(700,490),(759,527),(771,566)),((771,566),(782,594),(748,617),(715,605)),((715,605),(666,672),(691,696),(651,723)),((651,723),(622,736),(603,719),(589,707)),((589,707),(568,756),(558,761),(552,748)),((552,748),(579,701),(533,654),(558,623)),((558,623),(582,601),(600,608),(632,619)),((632,619),(656,580),(627,545),(655,507))),True).filter(ImageFilter.MaxFilter(41)).point(lambda a:255 if a else 0)
        self.base=self.original.copy();clear(self.base,union(self.firemask,self.pinmask))
        # 原手机在图钉后面是完整纸壳，补齐上沿及屏幕；可见原像素全部留在原位。
        phone=sample_silhouette(self.original,[(351,701),(381,677),(586,637),(628,652),(746,1025),(746,1084),(704,1118),(539,1150),(487,1135),(338,744)],(449,793,543,913),width=17)
        screen=sample_silhouette(self.original,[(395,731),(622,690),(719,1000),(496,1044)],(450,777,535,905),width=13)
        phone.alpha_composite(screen)
        hidden=ImageChops.multiply(self.pinmask,rect_mask(self.size,((0,620,800,783),)))
        self.base.alpha_composite(content(phone,hidden))
        self.fixedrootmask=ImageChops.subtract(ImageChops.multiply(self.firemask,rect_mask(self.size,((0,620,1254,1254),))),self.pinmask).point(lambda a:255 if a else 0)
        pinregion=rect_mask(self.size,((495,460,815,783),))
        self.pinmaterial=gradient_fill(self.original,pinregion,(550,495,780,731),
             lambda a:(a[:,:,0]>235)&(a[:,:,1]>220)&(a[:,:,2]>185))
        self.headpath=path(((660,506),(687,495),(725,507),(764,540)),((764,540),(783,564),(779,592),(756,606)),((756,606),(730,623),(693,604),(662,579)),((662,579),(638,557),(635,525),(660,506)))
        self.head=self.pin_shape(self.headpath,17)
        self.basepath=path(((576,610),(606,601),(653,627),(682,666)),((682,666),(705,693),(689,717),(660,726)),((660,726),(631,735),(584,710),(560,676)),((560,676),(542,648),(550,622),(576,610)))
        self.pinbase=self.pin_shape(self.basepath,17)
        # 钉尖独立固定在原接触处，不会跟着钉帽压入手机另一侧。
        self.point=self.pin_shape([(584,700),(610,716),(572,758),(552,750)],12)
    def pin_shape(self,points,width):
        mask=polygon_mask(self.size,points,True)
        out=content(self.pinmaterial,mask);stroke_path(out,points+[points[0]],width,INK)
        return out
    def paint(self,t):
        if t>=3.72:return self.original.copy()
        out=self.base.copy()
        env=ease((t-.25)/.35)*(1-ease((t-3.0)/.65))
        phase=(t-.25)*math.tau/.95
        def flamepoint(p):
            x,y=p
            if y>=620:return p
            weight=((620-y)/540)**1.3
            wave=math.sin(phase+(800-x)/150)
            sy=1+env*(-.18+.25*wave)
            return (x+60*env*math.sin(phase*.77+(800-x)/220)*weight,620+(y-620)*sy)
        segments=[((565,617),(510,553),(506,487),(532,424)),((532,424),(561,360),(625,325),(670,287)),
            ((670,287),(685,263),(692,235),(688,210)),((688,210),(714,209),(739,237),(743,264)),
            ((743,264),(790,223),(812,176),(801,135)),((801,135),(797,117),(797,105),(797,96)),
            ((797,96),(843,127),(888,194),(908,258)),((908,258),(929,323),(920,376),(896,420)),
            ((896,420),(931,406),(954,377),(962,342)),((962,342),(996,378),(1015,526),(1002,573)),
            ((1002,573),(984,648),(912,703),(834,717)),((834,717),(780,729),(720,720),(680,704)),
            ((680,704),(628,693),(597,657),(565,617))]
        outline=path(*[tuple(flamepoint(p)for p in seg)for seg in segments])
        m=polygon_mask(self.size,outline,True)
        fire=gradient_fill(self.original,m,(792,458,955,633),lambda a:(a[:,:,0]>230)&(a[:,:,1]>170)&(a[:,:,2]<190))
        fire=content(fire,m);stroke_path(fire,outline+[outline[0]],20,INK)
        out.alpha_composite(fire);out.paste(self.original,(0,0),self.fixedrootmask)
        pressure=env*(.50+.50*math.sin(phase-.25))
        dx=-34*pressure;dy=46*pressure
        stem=path(((642+dx,563+dy),(660+dx,576+dy),(695+dx,595+dy),(713+dx,608+dy)),
                  ((713+dx,608+dy),(694+dx*.25,632+dy*.25),(670,664),(657,677)),
                  ((657,677),(645,690),(606,668),(599,648)),
                  ((599,648),(607,626),(629+dx,583+dy),(642+dx,563+dy)))
        out.alpha_composite(self.pinbase)
        # 钉杆位于钉座之前，连续圆弧的下端就是原 U 形穿孔边，不复制被切开的旧弧。
        out.alpha_composite(self.pin_shape(stem,16))
        out.alpha_composite(affine_pose(self.head,(0,0),dx=dx,dy=dy))
        out.alpha_composite(self.point)
        # 下半个原手机和尖端下的接触短线保持原像素，不让补底改动机壳。
        out.paste(self.original,(0,0),rect_mask(self.size,((0,766,1254,1254),)))
        # 接触尖端和其下手机纸面完全固定，原 AA 边只保留一次，
        # 不把重新绘制尖端与原尖端的底缘叠成细白边。
        out.paste(self.original,(0,0),rect_mask(self.size,((540,732,635,783),)))
        return out


class Jiangjia(NativePainter):
    card='jiangjia';count=37;mode='loop';boxes=((418,182,1212,1000),(292,746,437,836))
    notes='价格牌刚性下移下蹲，不压扁；固定双脚，膝腿接续；原手持续承接箭头，钱包原位苦嘴加深后回位。'
    def __init__(self):
        super().__init__()
        self.arrowmask=filled_region(self.original,(1109,292),'gold')
        self.arrow=content(self.original,self.arrowmask)
        # 保留牌身完整、绳、手，腿和脚另按地面姿势绘制。
        tagmask=polygon_mask(self.size,path(((599,381),(620,371),(777,496),(814,522)),((814,522),(851,551),(888,716),(910,866)),((910,866),(881,892),(826,932),(781,951)),((781,951),(751,957),(622,915),(517,890)),((517,890),(507,828),(477,692),(453,570)),((453,570),(450,546),(477,515),(599,381))),True).filter(ImageFilter.MaxFilter(15))
        self.tagmask=union(filled_region(self.original,(740,700)),rect_mask(self.size,((417,285,649,477),)))
        self.tag=content(self.original,self.tagmask)
        # 下移牌身与原钱包交叠区域不能包含钱包旧墨或棕色。
        arr=np.asarray(self.tag).copy();orig=np.asarray(self.original)
        brown=(orig[:,:,0]>90)&(orig[:,:,0]<240)&(orig[:,:,1]<180)&(orig[:,:,2]<135)&(np.indices(orig.shape[:2])[1]<530)
        arr[brown,3]=0;self.tag=Image.fromarray(arr)
        self.base=self.original.copy();clear(self.base,union(self.arrowmask,self.tagmask,rect_mask(self.size,((523,890,979,982),))))
        # 价格牌与钱包叠在一起，钱包原像素从前景保留，不挖边。
        self.wallet_mask=polygon_mask(self.size,[(194,671),(423,617),(450,622),(470,658),(513,863),(515,895),(236,943),(212,932),(195,879),(171,859),(168,804),(183,780),(194,772)],True).filter(ImageFilter.MaxFilter(9)).point(lambda a:255 if a else 0)
        self.wallet=content(self.original,self.wallet_mask)
        self.feet=content(self.original,rect_mask(self.size,((522,949,587,978),(888,937,979,976))))
        self.wface=rect_mask(self.size,((291,756,434,836),))
        self.wfill=gradient_fill(self.original,self.wface,(284,699,436,847))
    def paint(self,t):
        if t>=2.79:return self.original.copy()
        out=self.base.copy();contact=ease((t-.25)/.38)*(1-ease((t-2.35)/.43));p=ease((t-.60)/.65)*(1-ease((t-1.85)/.65));down=22*p
        # 下蹲的脚接地，腿往外弯。牌身、绳与脸仅作刚性平移。
        stroke_path(out,[(566,917+down),(543-12*p,941),(540,958),(578,960)],15,INK)
        stroke_path(out,[(868,891+down),(902+9*p,924),(908,950),(954,949)],15,INK)
        out.alpha_composite(affine_pose(self.tag,(0,0),dy=down))
        # 原箭头朝手的方向再压 20px；手同牌身下移，接触线完整延伸。
        out.alpha_composite(affine_pose(self.arrow,(0,0),dx=-12*contact,dy=62*contact+down))
        # 接触仍位于原画右手上缘与箭头尖的方向；不加独立漂浮的手。
        wallet=self.wallet.copy()
        if p>0:
            wallet.paste(self.wfill,(0,0),self.wface)
            stroke_path(wallet,path(((340,827),(354,796-8*p),(369,839),(388,812)),((388,812),(406,796-8*p),(414,823),(431,813))),12,INK)
        out.paste(wallet,(0,0),self.wallet_mask)
        out.alpha_composite(self.feet)
        out.paste(self.original,(0,0),rect_mask(self.size,((522,949,587,978),(888,937,979,976))))
        return out


PAINTERS=(Butie,Heigongguan,Zuokong,Eryouxuan,Chaping,Yinqing996,Resou,Jiangjia)
if __name__=='__main__':run(PAINTERS)
