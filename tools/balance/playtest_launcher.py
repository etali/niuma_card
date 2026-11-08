# SPDX-License-Identifier: AGPL-3.0-only
"""Shared runtime selection for interactive workbench playtests."""
import os
from pathlib import Path
import plistlib
import sys
from xml.parsers.expat import ExpatError


def macos_executable(root):
    """Use the same exported application as ordinary desktop play."""
    app = Path(root) / "build" / "牛马牌.app"
    try:
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        name = info.get("CFBundleExecutable")
        if not isinstance(name, str) or not name or Path(name).name != name:
            raise ValueError("App 执行文件声明无效")
        binary = app / "Contents/MacOS" / name
        if not binary.is_file() or not binary.stat().st_size or not os.access(binary, os.X_OK):
            raise ValueError("App 执行文件缺失或不可执行")
        packs = list((app / "Contents/Resources").glob("*.pck"))
        if len(packs) != 1 or not packs[0].is_file() or not packs[0].stat().st_size:
            raise ValueError("App 游戏资源包缺失或不唯一")
    except (OSError, ValueError, TypeError, AttributeError, plistlib.InvalidFileException, ExpatError) as error:
        raise ValueError("请先构建游戏：运行“构建游戏.command”生成完整的 build/牛马牌.app，再启动试玩。") from error
    return binary.resolve()


def playtest_command(root, engine, cards_path, *, off_work=False):
    root = Path(root).resolve()
    snapshot = Path(cards_path)
    if not snapshot.is_absolute():
        snapshot = root / snapshot
    flags = (["--off-work-playtest"] if off_work else []) + ["--cards-config=" + str(snapshot.resolve())]
    if sys.platform == "darwin":
        # The release template discovers its own bundled PCK. Its path override
        # options are disabled, so do not pass --path, --main-pack or --script.
        return [str(macos_executable(root)), "--", *flags]
    return [str(engine), "--path", str(root), "--", *flags]
