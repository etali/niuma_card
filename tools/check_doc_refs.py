#!/usr/bin/env python3
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""检查文档与源码中的 `§「完整标题」` 引用。

标题必须与目标文档一致，包括 README 标题中的数字前缀。
旧章节删除后应将引用改到相关现存章节或具体源码，不能保留空标题占位。

检查范围：
  1. 带文档名的引用只查指定文档；裸引用先查本文，再查 README / balance。
  2. 裸引用同时命中多份文档时失败，要求写明文档名。
  3. 紧随标题的第二个引号表示加粗编号条目，同时检查该条目是否存在。
  4. 裸数字等没有完整标题的旧写法视为错误。

例如 `README.md §「2.9 攻击」` 指向具体规则。
静态检查只能确认标题存在；章节改写后仍需人工检查引用上下文是否准确。
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DOCS = ('README', 'balance', 'bot')
# 只能带名字引的那些（裸引用不在这里面找，见 check_ref 的注释）
NAMED_ONLY = ('bot',)
SCAN_DIRS = ('engine', 'net', 'scenes', 'tests', 'tools', 'data')
SCAN_EXT = ('.gd', '.py', '.sh', '.json', '.md')


def parse_doc(path: Path) -> dict:
    """→ {heads: {标题: 行号}, items: {标题: {条目名}}}

    heads 收 ##/###/#### 三层，不分层级 —— 引用侧写的是名字，不需要知道深浅。
    items 收每一节里的加粗编号条目（`13. **配方消耗**：…`），归到**最近的**标题下。
    只认加粗的：引用要拿名字指它，没名字的条目本来也引不了。

    标题末尾的括注不算名字的一部分：`## 卡牌总表（共 31 种卡面…）` 既登记全名、
    也登记 `卡牌总表`，两种写法都引得到。括注里常带数字（那两个总数由
    `check_card_table.py` 盯着），数一改不该让全仓引用跟着错 —— 这正是
    换成名字要买的那个性质。
    """
    out = {'heads': {}, 'items': {}}
    cur = None
    for i, line in enumerate(path.read_text(encoding='utf-8').splitlines(), 1):
        m = re.match(r'#{2,4} (.+)', line)
        if m:
            cur = m.group(1).strip()
            out['heads'].setdefault(cur, i)
            bare = re.sub(r'（[^（）]*）$', '', cur).strip()
            if bare != cur:
                out['heads'].setdefault(bare, i)
                cur = bare          # 条目归到去括注的名字下，两边一致
            continue
        m = re.match(r'[ \t]*\d+\. ~*\*\*(.+?)\*\*', line)
        if m and cur:
            out['items'].setdefault(cur, set()).add(m.group(1).strip())
    return out


def resolve_in(d: dict, title: str, item: str) -> str:
    """在**一份**文档里查这条引用。→ 空串表示查得到，否则说错在哪"""
    if title not in d['heads']:
        return f'没有「{title}」这一节'
    if item is not None:
        have = d['items'].get(title, set())
        if item not in have:
            got = '、'.join(sorted(have)) or '（这一节没有加粗编号条目）'
            return f'「{title}」里没有条目「{item}」；有的是：{got}'
    return ''


def check_ref(docs: dict, doc: str, title: str, item: str,
              own: str = None) -> str:
    """→ 空串表示这条引用查得到，否则返回错在哪

    own 是这条引用所在的文档名（`.md` 文件才有，代码传 None）。
    """
    if doc is not None:
        if doc not in docs:
            return f'没有 {doc}.md'
        err = resolve_in(docs[doc], title, item)
        return f'{doc}.md {err}' if err else ''
    # 文档内部的裸引用先在**本文档**里找：一份文档引自己的节不必写自己的名字，
    # bot.md 内部也可用裸引用；下面的「专题文档带名字」约束外部引用。
    if own in docs and not resolve_in(docs[own], title, item):
        return ''
    # 裸引用只在 README / balance 里找。外部引用 bot.md（BOT 设计）须带文档名，
    # 将它算进裸引用候选会造成歧义。
    cand = {n: d for n, d in docs.items() if n not in NAMED_ONLY}
    hits = [n for n, d in cand.items() if not resolve_in(d, title, item)]
    if not hits:
        look = dict(cand)
        if own in docs:
            look[own] = docs[own]
        why = '；'.join(f'{n}.md {resolve_in(d, title, item)}'
                       for n, d in look.items())
        return f'哪份文档都查不到（{why}）'
    if len(hits) > 1:
        names = ' / '.join(f'{n}.md' for n in hits)
        return f'{names} 都有这一节，看不出指哪份（要写成 `README §…`）'
    return ''


# `README.md §「2.9 攻击」` / `balance.md §「攻击卡」` / 标题后的加粗条目引用
# 文档名可带或不带 `.md`，也可能被反引号包着。
#
# 标题里**自带**「」的（条目名 `「装机中」标记`）：所以一个「」单元的内容写成
# 「非括号字符 或 一整对括号」，而不是 `[^」]+` —— 后者会把
# 「示例标题」「「嵌套引号」条目」不能截在第一个」上，否则会报假错。
#
# 第二个「」只在紧跟着（中间只许空格）时才当条目名。代码注释里常写
# `§「3. 文件目录结构」所述的「共享裁决路径」`，中间有字，
# 那个引号是行文而不是条目名，不该被当成条目去查
_UNIT = r'((?:[^「」]|「[^「」]*」)+)'
REF = re.compile(
    r'(?:`?(README|balance|bot)(?:\.md)?`?[ 　]*)?'
    r'§[ 　]*「' + _UNIT + r'」(?:[ 　]*「' + _UNIT + r'」)?')

# 裸 § 后面不跟「」的：漏了标题，或者还留着旧的数字写法
BARE = re.compile(r'§[ 　]*(?!「)')


def main() -> int:
    docs = {}
    for name in DOCS:
        p = ROOT / f'{name}.md'
        if p.exists():
            docs[name] = parse_doc(p)

    files = [ROOT / f'{n}.md' for n in DOCS if (ROOT / f'{n}.md').exists()]
    files.append(ROOT / 'CLAUDE.md')
    me = Path(__file__).resolve()
    for d in SCAN_DIRS:
        if not (ROOT / d).is_dir():
            continue
        for f in sorted((ROOT / d).rglob('*')):
            if f.suffix in SCAN_EXT and f.resolve() != me:
                files.append(f)

    bad, total = [], 0
    for f in files:
        if not f.exists():
            continue
        rel = f.relative_to(ROOT)
        for i, line in enumerate(
                f.read_text(encoding='utf-8').splitlines(), 1):
            own = f.stem if f.suffix == '.md' else None
            for m in REF.finditer(line):
                total += 1
                err = check_ref(docs, *m.groups(), own=own)
                if err:
                    bad.append((rel, i, m.group(0).strip(), err))
            # 把 REF 匹配掉的部分挖掉，剩下的 § 就是没带标题的。
            # `` `§` `` 这种被反引号裹起来的是在**讲这个符号本身**
            # （README 的目录树里介绍这个脚本就这么写），不是引用
            rest = REF.sub('', line).replace('`§`', '')
            for _ in BARE.finditer(rest):
                bad.append((rel, i, '§', '§ 后面没跟「标题」'
                            '（旧的数字写法这一轮全部改掉了）'))

    if not bad:
        print(f'{total} 条 § 引用全部查得到（扫了 {len(files)} 个文件）')
        return 0
    for rel, i, ref, err in bad:
        print(f'  {rel}:{i}  `{ref}`  ← {err}')
    print(f'\n{total} 条 § 引用，{len(bad)} 条有问题')
    return 1


if __name__ == '__main__':
    sys.exit(main())
