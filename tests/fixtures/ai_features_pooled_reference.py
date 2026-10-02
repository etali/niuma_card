#!/usr/bin/env python3
# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""Audit pooled-upgrade golden values with exhaustive count-vector allocation.

This independent oracle does not import Godot or use the production convolution
DP. Only option, total, and score may be updated; all other frozen Float64 bits
remain the original pre-optimization observations. Run with --update to refresh
these three fields deliberately after reviewing a rule change.
"""
from collections import Counter
from functools import lru_cache
from itertools import product
from pathlib import Path
import argparse
import json
import math
import struct

FIXTURE = Path(__file__).with_name("ai_features_frozen.json")


def unpack(bits):
    return struct.unpack("<d", bytes.fromhex(bits))[0]


def pack(value):
    return struct.pack("<d", value).hex()


def upgrade_option(fixture, inventory, game):
    cards, rules = fixture["cards"], fixture["upgrade"]

    @lru_cache(None)
    def pawn(card_id):
        card = cards[card_id]
        if "pawn" in card:
            return int(card["pawn"])
        if card["kind"] == "unit":
            return int(game["pawn_user"]) if card["res"] == "user" else 0
        if card.get("price", -1) > 0:
            return max(1, math.floor(card["price"] / game["pawn_rate"] + 0.5))
        source = card.get("upgrade_from")
        if source in cards:
            return max(1, math.floor(pawn(source) * max(2, card.get("upgrade_dup_n", 2)) / game["pawn_rate"] + 0.5))
        return 0

    def target(ids):
        if len(ids) < 2:
            return None
        source = cards[ids[0]]
        tier = source.get("tier")
        if tier not in (1, 2) or any(cards[x]["kind"] != "product" or cards[x].get("tier") != tier for x in ids):
            return None
        same = len(set(ids)) == 1
        for route in rules["routes"]:
            if any(key in route and route[key] != source.get(key) for key in ("kind", "tier")):
                continue
            if route["key"] == "dup_key":
                from_id, kind = rules["dup_key"], "legend"
            elif route["key"] == "self" and same and tier == 1:
                from_id, kind = ids[0], "product"
            else:
                continue
            per = int(route.get("per", 1))
            if per <= 0 or len(ids) % per:
                continue
            for name, card in cards.items():
                if card["kind"] != kind or (kind == "product" and card.get("tier") != 2):
                    continue
                if card.get("upgrade_from") == from_id and card.get("upgrade_dup_n") == len(ids) // per:
                    return name
        return None

    total = 0
    # Separate tier pools are rule constraints, not a T1:T2 exchange rate.
    for tier in (1, 2):
        names = tuple(x for x in inventory if cards[x]["kind"] == "product" and cards[x].get("tier") == tier)
        counts = tuple(inventory[x] for x in names)
        choices = []
        for use in product(*(range(c + 1) for c in counts)):
            if sum(use) < 2:
                continue
            ids = [name for name, n in zip(names, use) for _ in range(n)]
            result = target(ids)
            if result:
                gain = pawn(result) - sum(pawn(x) for x in ids)
                if gain > 0:
                    choices.append((use, gain))

        @lru_cache(None)
        def best(remaining):
            value = 0
            for use, gain in choices:
                if all(a <= b for a, b in zip(use, remaining)):
                    value = max(value, gain + best(tuple(b - a for a, b in zip(use, remaining))))
            return value

        total += best(counts)
    return float(total)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--update", action="store_true")
    args = parser.parse_args()
    fixture = json.loads(FIXTURE.read_text())
    changed = []
    for case in fixture["cases"]:
        game = fixture["game"] | case.get("game_overrides", {})
        expected = case["expected_bits"]
        updates = {}
        for who in ("player", "ai"):
            option = upgrade_option(fixture, Counter(case["cards"][who]), game)
            frozen = expected[who]
            p = case["parameters"]
            total = unpack(frozen["asset"]) + p["engine_horizon"] * unpack(frozen["engine"]) + p["upgrade_weight"] * option - p["risk_weight"] * unpack(frozen["risk"])
            updates[who] = {"option": option, "total": total}
        for who, other in (("player", "ai"), ("ai", "player")):
            score = max(-100.0, min(100.0, (updates[who]["total"] - updates[other]["total"]) / max(1, game["win_cash"])))
            if case.get("winner"):
                score = 1000000.0 if case["winner"] == who else -1000000.0
            updates[who]["score"] = score
            for key, value in updates[who].items():
                if expected[who][key] != pack(value):
                    changed.append(f"{case['name']}/{who}/{key}: {unpack(expected[who][key])} -> {value}")
                    expected[who][key] = pack(value)
    if args.update:
        fixture["upgrade_reference"] = "Same-tier mixed materials, disjoint one-step groups; independently enumerated by ai_features_pooled_reference.py. Only option/total/score updated; all other frozen bits retained."
        FIXTURE.write_text(json.dumps(fixture, ensure_ascii=False, indent=2) + "\n")
    elif changed:
        raise SystemExit("Golden differs from independent reference:\n" + "\n".join(changed))
    print("\n".join(changed) if changed else "All pooled upgrade golden values match the independent count-vector oracle.")


if __name__ == "__main__":
    main()
