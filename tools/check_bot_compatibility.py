#!/usr/bin/env python3
"""对比 BOT 2.4 修改前冻结的逐字段指纹；只忽略新增参数元数据与版本号。"""
import argparse
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
NEW_KEYS = set('resale_mode resale_budget attack_mode attack_depth financing_mode allocation_mode formation_mode candidate_dedup reply_mode rollout_capabilities tactical_extension economic_mode generation_budget financing_choices financing_beam allocation_budget rollout_buy_beam rollout_build_beam rollout_plans'.split())


def normalized(value):
    if isinstance(value, list):
        return [normalized(v) for v in value]
    if isinstance(value, dict):
        return {k: normalized(v) for k, v in value.items() if k not in NEW_KEYS | {'profile_version'}}
    return value


def fingerprint(value):
    data = json.dumps(normalized(value), ensure_ascii=False, sort_keys=True, separators=(',', ':'))
    return hashlib.sha256(data.encode()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('cases', type=Path)
    parser.add_argument('games', type=Path)
    args = parser.parse_args()
    expected = json.loads((ROOT / 'tests/fixtures/bot_24_fingerprints.json').read_text())
    checked = 0
    for kind, path in [('cases', args.cases), ('games', args.games)]:
        report = json.loads(path.read_text())
        assert not report['failures'], report['failures']
        assert report['cards_sha256'] == expected['cards_sha256'], '卡表已变：不能和旧卡表基线比较'
        assert len(report['payload']) == len(expected[kind]), '用例数量不同'
        for index, (row, reference) in enumerate(zip(report['payload'], expected[kind])):
            assert fingerprint(row) == reference, f'{kind}[{index}] {row.get("name", "")} 行为改变'
            checked += 1
    print(f'{checked} 组冻结指纹一致：候选、浮点评分原始位、意图、选靶及状态轨迹。')


if __name__ == '__main__':
    main()
