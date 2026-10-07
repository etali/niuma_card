#!/usr/bin/env python3
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""对 test_image/ 的生成稿做尺寸归一化和线稿后处理，输出到 assets/art/。

    python3 tools/build_art.py            # 生成素材
    python3 tools/build_art.py --dry-run  # 只报告不写文件

三条流水线：
  图标   主体外接框归一化到长边 1024 → 不透明像素改写纯白 → icon_<def_id>.png
         （命名用 cards.json 的 def_id，引擎可直接按卡牌 id 取图，不需要映射表）
  其余   按 MISC_MAP 中各类素材的目标尺寸缩放
  应用图标  assets/art/app_icon.png → assets/app_icon.png（透明补方 + 缩到 1024）
         桌宠原图保持原样，导出图由 Git 管理；两者共用同一角色。

底板不由本脚本产出：卡面由 shaders/ 下的着色器及共享 include 程序化绘制，
不依赖 plate_master.png；颜色来自 data/ui.json 的 palette 段。
换色和卡框几何修改由 shader 实现，素材和 shader/include/UID 均由 Git 管理。

素材登记写入 data/ui.json 的 art 段，保留其他展示配置。
"""
import argparse
import colorsys
import json
import os
import sys
from collections import Counter

from PIL import Image, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.normpath(os.path.join(HERE, ".."))
SRC = os.path.join(ROOT, "test_image")
OUT = os.path.join(ROOT, "assets", "art")

# 桌宠源图和标准应用图标均由 Git 管理；导出统一使用标准方图。
APP_ICON_SRC = os.path.join(OUT, "app_icon.png")
APP_ICON_REF = os.path.join(ROOT, "ref_image", "app_icon.png")
APP_ICON_EXPORT = os.path.join(ROOT, "assets", "app_icon.png")

# 九张按槽位烘色的底板和透明母版都不在本脚本的构建清单中。
# 卡框由 shaders/ 代码绘制；test_image/底板/ 中的历史源图保留，不在这里清理。

# 其余素材：源相对路径 → (输出子目录, 输出名, 目标尺寸)
MISC_MAP = {
    "典当行.png": ("table", "pawnshop", (1200, 1600)),
    "卡背.png": ("table", "card_back", (1200, 1600)),
    "资源徽章底.png": ("table", "badge_base", (1024, 1024)),
    "覆盖标记/护盾角标.png": ("overlay", "overlay_shield", (1024, 1024)),
    # 保留历史源文件名和 overlay_void_stamp 输出名，避免改变已有资源路径。
    "覆盖标记/配方失效盖章.png": ("overlay", "overlay_void_stamp", (1024, 1024)),
}

ICON_SIZE = 1024
PLATE_SIZE = (1200, 1600)

# 应用图标边长。macOS 的 .icns 最大档位就是 1024，Web 那边 Godot 自己缩到
# 16/32/144/180/512，源图给足 1024 就不会有哪一档是放大来的
APP_ICON_SIZE = 1024
INK_DARK = (0x22, 0x22, 0x22)
INK_LIGHT = (0xF5, 0xF5, 0xF5)

# 图标上屏的实际边长：卡宽约 90px（货架）~113px（手牌），ICON_FRAC=0.6 → 54~68px。
# 取 60 做后处理时的判据尺寸
DISP_SIZE = 60

# 墨迹在上屏尺寸上的目标平均 alpha（0~255）：只解决「发灰」，不解决「细」。
# 实测未处理时中位只有 126，墨迹半透明所以发灰。160 是本来就够浓的三张
# （现金 160 / 拼少少 156 / 独角兽 155）的档位，即「照最浓的原稿看齐」
TARGET_ALPHA = 160

# 目标墨占比：这一条才是「粗细」。
# 上一版只盯 TARGET_ALPHA，结果 alpha 全部达标而线还是发丝——
# 热搜包年膨胀完 alpha 162 但墨只占 16%，屏上就是一根 2px 的细线，看着毫无变化。
# 「看着粗」= 单位面积里的墨够多，所以判据必须是占比。
# 0.30 取自原稿里本来就显粗的那几张（独角兽 0.29 / 现金 0.31）
TARGET_COVER = 0.30

# 膨胀的两条闸门：上屏墨占比不许超过 COVER_CAP，迭代不许超过 MAX_DILATE。
# 密集线稿（如百亿补贴，未膨胀已占 34%）继续膨胀会连成一块黑斑，
# 那是原稿在 60px 上太密，只能重画，后处理救不了
COVER_CAP = 0.46
MAX_DILATE = 14


def hexof(c):
    return "#%02X%02X%02X" % tuple(c[:3])


def relative_luminance(c):
    out = []
    for v in c[:3]:
        v /= 255.0
        out.append(v / 12.92 if v <= 0.03928 else ((v + 0.055) / 1.055) ** 2.4)
    return 0.2126 * out[0] + 0.7152 * out[1] + 0.0722 * out[2]


def contrast(c1, c2):
    l1, l2 = relative_luminance(c1), relative_luminance(c2)
    if l1 < l2:
        l1, l2 = l2, l1
    return (l1 + 0.05) / (l2 + 0.05)


def dominant(im, box, step=2):
    """区域内出现最多的颜色。量化到 8 级，避开粉笔颗粒噪声。"""
    crop = im.crop(box).convert("RGB")
    px = crop.load()
    w, h = crop.size
    c = Counter()
    for y in range(0, h, step):
        for x in range(0, w, step):
            r, g, b = px[x, y]
            c[(r // 8 * 8, g // 8 * 8, b // 8 * 8)] += 1
    return c.most_common(1)[0][0]


def load_name_to_id():
    """cards.json 的 name → def_id。图标文件名用的是中文卡名。"""
    with open(os.path.join(ROOT, "data", "cards.json"), encoding="utf-8") as f:
        data = json.load(f)
    return {v["name"]: k for k, v in data.items()
            if not k.startswith("_") and isinstance(v, dict) and "name" in v}


def stroke_width(alpha, step=4):
    """线稿笔画粗细：逐行取不透明段长，返回段长中位数。

    横向段长在斜笔画上会偏大，但线稿以竖笔为主，用来做「够不够粗」的相对判断足够；
    只关心中位数，个别横笔的长段不影响结论。
    """
    px = alpha.load()
    w, h = alpha.size
    runs = []
    for y in range(0, h, step):
        run = 0
        for x in range(w):
            if px[x, y] > 128:
                run += 1
            else:
                if run >= 2:
                    runs.append(run)
                run = 0
        if run >= 2:
            runs.append(run)
    if not runs:
        return 0
    runs.sort()
    return runs[len(runs) // 2]


def ink_stats(alpha):
    """在真实上屏尺寸上量线稿：(墨占比, 墨像素平均 alpha)。

    「笔画细」的实质就是缩到 DISP_SIZE 后 alpha 被平均掉：
    实测未膨胀时平均 alpha 中位只有 126/255，也就是墨迹只有半透明，所以发灰看不清。
    """
    a = alpha.resize((DISP_SIZE, DISP_SIZE), Image.LANCZOS)
    px = [v for v in a.getdata() if v > 8]
    if not px:
        return 0.0, 0.0
    return len(px) / float(DISP_SIZE * DISP_SIZE), sum(px) / float(len(px))


def thicken(alpha):
    """逐步膨胀线稿 alpha，直到墨迹在上屏尺寸上够浓且够粗——但不许糊成一团。

    两个判据都要过：平均 alpha ≥ TARGET_ALPHA（不发灰）
    且墨占比 ≥ TARGET_COVER（真的粗）。
    只卡 alpha 是上一版的错：热搜包年 alpha 到 162 就停手，墨才占 16%，
    屏上仍是一根 2px 发丝，肉眼看不出任何变化——alpha 管浓淡，占比才管粗细。

    都不用 1024 空间的笔画宽度换算：膨胀会让相邻笔画并成一条，
    「加粗 1px」实际涨的宽度远大于 1px（实测补贴从 9px 一路涨到 57px），
    按宽度预测会一直不达标而空转。

    每次 3×3 MaxFilter 每侧长 1px，不用大核一步到位——大核会把笔画间的空隙整片吃掉。
    三个停止条件：两项都达标 / 上屏墨占比超过 COVER_CAP / 到 MAX_DILATE 上限。
    被墨占比拦住的图标说明原稿在 60px 上本来就太密，得重画，不是后处理能救的。
    """
    cover0, am = ink_stats(alpha)
    cover = cover0
    steps, stop = 0, "达标"
    while steps < MAX_DILATE:
        if am >= TARGET_ALPHA and cover >= TARGET_COVER:
            break
        nxt = alpha.filter(ImageFilter.MaxFilter(3))
        cover_next, am_next = ink_stats(nxt)
        if cover_next > COVER_CAP:
            stop = "墨占比"
            break
        alpha, steps, am, cover = nxt, steps + 1, am_next, cover_next
    else:
        stop = "次数上限"
    return alpha, steps, stop, cover0


def normalize_icon(path):
    """抠好绿幕的线稿 → 外接框长边顶满 1024 → 不透明像素改纯白。

    额外按上屏平均 alpha 与墨占比膨胀线稿，避免缩到卡面尺寸后笔画过细、发灰。
    """
    im = Image.open(path).convert("RGBA")
    alpha = im.split()[-1]
    bbox = alpha.point(lambda v: 255 if v > 16 else 0).getbbox()
    if bbox is None:
        raise ValueError("整张全透明")
    sub = im.crop(bbox)
    bw, bh = sub.size
    scale = ICON_SIZE / max(bw, bh)
    nw, nh = max(1, round(bw * scale)), max(1, round(bh * scale))
    sub = sub.resize((nw, nh), Image.LANCZOS)

    canvas = Image.new("RGBA", (ICON_SIZE, ICON_SIZE), (255, 255, 255, 0))
    canvas.paste(sub, ((ICON_SIZE - nw) // 2, (ICON_SIZE - nh) // 2))

    # 线稿改写为纯白：保留 alpha 做形状，引擎用 modulate 着成底板墨色
    r, g, b, a = canvas.split()
    sw0 = stroke_width(a)
    a, steps, stop, cover0 = thicken(a)
    cover, alpha_mean = ink_stats(a)
    white = Image.new("L", canvas.size, 255)
    return (Image.merge("RGBA", (white, white, white, a)), (bw, bh), {
        "stroke_src": sw0,
        "stroke": stroke_width(a) if steps else sw0,
        "dilate": steps,
        "stop": stop,
        "cover": round(cover, 3),
        "cover_src": round(cover0, 3),
        "alpha_mean": round(alpha_mean),
    })


def measure_band(im, band_rgb):
    """实测标题带的上下边界，返回 (中心 y, 高) 两个占卡高的比例。

    定位表给的是 46..296，实测这批底板画到 45..265（分隔线另占 266..295），
    差 16px 会把卡名压到分隔线上。所以按画面实测，重画底板后重跑即自动跟上。
    """
    w, h = im.size
    px = im.convert("RGB").load()
    x = w // 2

    def near(y):
        r, g, b = px[x, y]
        return (abs(r - band_rgb[0]) + abs(g - band_rgb[1]) + abs(b - band_rgb[2])) <= 36

    seed = None
    for y in range(int(h * 0.03), int(h * 0.20)):
        if near(y):
            seed = y
            break
    if seed is None:
        return None
    top = seed
    while top > 0 and near(top - 1):
        top -= 1
    bot = seed
    while bot < h - 1 and near(bot + 1):
        bot += 1
    if bot - top < h * 0.05:          # 没连成一条带，交给引擎用定位表兜底
        return None
    return round((top + bot) / 2.0 / h, 6), round((bot - top + 1) / float(h), 6)


def measure_plate(im):
    """实测卡面色 / 标题带色 / 标题带位置，按 2.2~2.3 节规律推出墨色与强调色。"""
    w, h = im.size
    face = dominant(im, (int(w * 0.30), int(h * 0.28), int(w * 0.70), int(h * 0.42)))
    band = dominant(im, (int(w * 0.25), int(h * 0.08), int(w * 0.75), int(h * 0.13)))
    # 墨色：在暗墨 / 米白之间取对比度更高的那个（2.2 节的浅色卡暗墨、深色卡米白）
    ink = INK_DARK if contrast(face, INK_DARK) >= contrast(face, INK_LIGHT) else INK_LIGHT
    # 强调色：2.2 节实测「高光圆 ≈ 标题带，只再亮 1~2 点」，据此由标题带提亮得到
    hh, ss, vv = colorsys.rgb_to_hsv(*[c / 255 for c in band])
    accent = tuple(round(c * 255) for c in colorsys.hsv_to_rgb(hh, ss, min(1.0, vv + 0.02)))
    info = {
        "face": hexof(face),
        "band": hexof(band),
        "accent": hexof(accent),
        "ink": hexof(ink),
        "name_contrast": round(contrast(face, ink), 2),
    }
    geo = measure_band(im, band)
    if geo:
        info["band_cy"], info["band_frac"] = geo
    return info


def save(im, subdir, name, dry, log):
    d = os.path.join(OUT, subdir)
    p = os.path.join(d, name + ".png")
    if not dry:
        os.makedirs(d, exist_ok=True)
        im.save(p, "PNG", optimize=True)
    log.append(f"  {os.path.relpath(p, ROOT):<44} {im.size[0]}x{im.size[1]}")
    return p


def normalize_app_icon(source, target_size=APP_ICON_SIZE):
    """透明等距补方再采样；不裁角色、不变形、不改源图。"""
    im = source.convert("RGBA")
    side = max(im.size)
    square = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    square.paste(im, ((side - im.width) // 2, (side - im.height) // 2))
    return square.resize((target_size, target_size), Image.Resampling.LANCZOS)


def build_app_icon(dry, log):
    """桌宠原图 → assets/app_icon.png；原始 assets/art/app_icon.png 从不覆盖。"""
    source = APP_ICON_SRC if os.path.exists(APP_ICON_SRC) else APP_ICON_REF
    if not os.path.exists(source):
        return None
    with Image.open(source) as image:
        normalized = normalize_app_icon(image)
    if not dry:
        os.makedirs(os.path.dirname(APP_ICON_EXPORT), exist_ok=True)
        # 字节一致时保留 mtime，避免每次构建都触发无意义的 Godot 图标重导入。
        import io
        encoded = io.BytesIO()
        normalized.save(encoded, "PNG", optimize=True)
        contents = encoded.getvalue()
        current = open(APP_ICON_EXPORT, "rb").read() if os.path.isfile(APP_ICON_EXPORT) else b""
        if current != contents:
            with open(APP_ICON_EXPORT, "wb") as output:
                output.write(contents)
    log.append(f"  {os.path.relpath(APP_ICON_EXPORT, ROOT):<44} {APP_ICON_SIZE}x{APP_ICON_SIZE}（源图保持原样）")
    return APP_ICON_EXPORT


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true", help="只报告，不写文件")
    args = ap.parse_args()
    dry = args.dry_run

    # 应用图标先做：它的源在 ref_image/ 而不是 test_image/，
    # 所以放在下面那道 SRC 闸门前面 —— 只有卡面素材缺失时也能单独出图标
    print("应用图标 →")
    log = []
    if build_app_icon(dry, log):
        print("\n".join(log))
    else:
        print(f"  缺 {os.path.relpath(APP_ICON_SRC, ROOT)}，"
              f"无法生成标准应用图标")

    if not os.path.isdir(SRC):
        print(f"找不到素材目录 {os.path.relpath(SRC, ROOT)}", file=sys.stderr)
        return 1

    name_to_id = load_name_to_id()
    manifest = {"icons": {}, "misc": {}}
    # 新版插画直接覆盖 icon 目录，旧素材构建不得把它们还原成旧线稿。
    ui_path = os.path.join(ROOT, "data", "ui.json")
    with open(ui_path, encoding="utf-8") as existing:
        ui = json.load(existing)
    existing_manifest = ui.get("art", {})
    manifest.update(existing_manifest)
    warnings = []

    # ---------- 图标 ----------
    print("图标 → assets/art/icon/")
    log = []
    icon_dir = os.path.join(SRC, "图标")
    if os.path.isdir(icon_dir):
        for fn in sorted(os.listdir(icon_dir)):
            if not fn.endswith(".png"):
                continue
            zh = os.path.splitext(fn)[0]
            def_id = name_to_id.get(zh)
            if def_id is None:
                warnings.append(f"图标 {fn} 在 cards.json 里找不到同名卡牌，已跳过")
                continue
            current_icon = f"icon/icon_{def_id}.png"
            if (def_id in ("cash", "user") or def_id in manifest.get("illustrations", {})) \
                    and os.path.isfile(os.path.join(OUT, current_icon)):
                continue
            im, bbox, sw = normalize_icon(os.path.join(icon_dir, fn))
            save(im, "icon", f"icon_{def_id}", dry, log)
            manifest["icons"][def_id] = dict(
                sw, file=f"icon/icon_{def_id}.png", zh=zh,
                src_bbox=f"{bbox[0]}x{bbox[1]}")
            if sw["stop"] == "墨占比":
                warnings.append(
                    f"图标 {zh} 线条太密：上屏墨占比已 {sw['cover']:.0%}（上限 "
                    f"{COVER_CAP:.0%}），再加粗就连成黑斑，故只到平均 alpha "
                    f"{sw['alpha_mean']}/{TARGET_ALPHA}。缩到 {DISP_SIZE}px 仍偏灰，"
                    f"建议重画得更简")
            elif sw["cover"] < TARGET_COVER:
                warnings.append(
                    f"图标 {zh} 膨胀到上限仍偏细：上屏墨占比 {sw['cover']:.0%}"
                    f"（目标 {TARGET_COVER:.0%}），原稿线条过于纤细，建议加粗重画")
    print("\n".join(log))
    missing_icons = [i for i in name_to_id.values() if i not in manifest["icons"]]
    if missing_icons:
        warnings.append(f"以下卡牌没有图标：{', '.join(sorted(missing_icons))}")

    # ---------- 其余素材 ----------
    print("\n其余素材 →")
    log = []
    for rel, (subdir, name, size) in sorted(MISC_MAP.items(), key=lambda kv: kv[1][1]):
        current = existing_manifest.get("misc", {}).get(name, {})
        if current.get("hand_drawn") and os.path.isfile(os.path.join(OUT, current.get("file", ""))):
            manifest["misc"][name] = current
            continue
        p = os.path.join(SRC, rel)
        if not os.path.exists(p):
            warnings.append(f"缺 {rel} → {subdir}/{name}.png（引擎回退程序化）")
            continue
        im = Image.open(p).convert("RGBA")
        info = {"file": f"{subdir}/{name}.png"}
        # 典当行是整卡素材（同一张底板母版画的），一样要实测色板和标题带位置，
        # 否则牌名还是按定位表摆，压在分隔线上
        if size == PLATE_SIZE and name not in ("card_back", "pawnshop"):
            info.update(measure_plate(im))
        if im.size != size:
            im = im.resize(size, Image.LANCZOS)
        save(im, subdir, name, dry, log)
        manifest["misc"][name] = info
    print("\n".join(log))

    # ---------- manifest ----------
    mp = ui_path
    if not dry:
        os.makedirs(OUT, exist_ok=True)
        with open(mp, "w", encoding="utf-8") as f:
            ui["art"] = manifest
            json.dump(ui, f, ensure_ascii=False, indent=2)
            f.write("\n")
    print(f"\n色板实测（写入 {os.path.relpath(mp, ROOT)}）：")
    print(f"  {'整卡素材':<18} {'卡面':>9} {'标题带':>9} {'强调':>9} {'墨色':>9}  卡名对比度")
    for name, v in sorted(manifest["misc"].items()):
        if "name_contrast" not in v:
            continue
        flag = "" if v["name_contrast"] >= 4.5 else "  ← 低于 WCAG AA 4.5"
        print(f"  {name:<18} {v['face']:>9} {v['band']:>9} {v['accent']:>9} "
              f"{v['ink']:>9}  {v['name_contrast']:>6}{flag}")

    print(f"\n合计 图标 {len(manifest['icons'])} / 其余 {len(manifest['misc'])}"
          + ("   [dry-run 未写文件]" if dry else ""))
    if warnings:
        print("\n提醒：")
        for w in warnings:
            print(f"  - {w}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
