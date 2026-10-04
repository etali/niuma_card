# Copyright (C) 2026 etali (https://github.com/etali)
# SPDX-License-Identifier: AGPL-3.0-only
# See LICENSE in the project root.

"""文档检查支持 GDScript 常量和只读强度曲线，并继续拒绝非法规格。"""
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import check_balance_numbers as checker


class BalanceNumbersTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = (ROOT / "engine/ai_turn_strategy.gd").read_text()

    def test_constant_values_in_targets_and_defaults(self):
        schema = checker.read_parameter_schema(self.source)
        self.assertEqual(schema["node_budget"]["strength_target"], 2500000)
        self.assertEqual(schema["node_budget"]["default"], 2500000)
        self.assertEqual(schema["compute_budget"]["defaults"], [3000000] * 3)

    def test_typed_constant_alias(self):
        source = self.source.replace(
            "const BASE_NODE_BUDGET := 2500000",
            "const NODE_LIMIT: int = 1234567 # 数值常量\nconst BASE_NODE_BUDGET := NODE_LIMIT")
        schema = checker.read_parameter_schema(source)
        self.assertEqual(schema["node_budget"]["strength_target"], 1234567)
        self.assertEqual(schema["node_budget"]["default"], 1234567)

    def test_unknown_constant_is_reported(self):
        source = self.source.replace('"node_budget": BASE_NODE_BUDGET', '"node_budget": UNKNOWN_LIMIT')
        with self.assertRaisesRegex(ValueError, "未定义的数值常量：UNKNOWN_LIMIT"):
            checker.read_parameter_schema(source)

    def test_circular_constant_is_reported(self):
        source = self.source.replace("const BASE_NODE_BUDGET := 2500000",
                                   "const BASE_NODE_BUDGET := OTHER\nconst OTHER := BASE_NODE_BUDGET")
        with self.assertRaisesRegex(ValueError, "数值常量循环引用"):
            checker.read_parameter_schema(source)

    def test_expressions_are_not_executed(self):
        source = self.source.replace("const BASE_NODE_BUDGET := 2500000",
                                   "const BASE_NODE_BUDGET := 2500000 * 2")
        with self.assertRaisesRegex(ValueError, "不支持的数值声明"):
            checker.read_parameter_schema(source)

    def test_read_only_curve_and_bounds(self):
        spec = checker.read_parameter_schema(self.source)["search_fraction"]
        self.assertTrue(spec["read_only"])
        self.assertEqual(spec["step"], 0.000001)
        self.assertEqual(len(spec["strength_points"]), 101)
        self.assertEqual(checker.document_values(spec["strength_points"], spec), [0.002, 0.12675, 1])
        self.assertIsNone(checker._value_problem(0.002000998, spec))
        self.assertIn("超出范围", checker._value_problem(1.01, spec))
        editable = checker.read_parameter_schema(self.source)["upgrade_weight"]
        self.assertIn("未对齐步长", checker._value_problem(0.651, editable))

    def test_unsupported_curve_is_reported(self):
        source = self.source.replace("minimum+(1.0-minimum)*s*s*s", "minimum+(1.0-minimum)*s*s")
        with self.assertRaisesRegex(ValueError, "不支持的参数强度曲线"):
            checker.read_parameter_schema(source)

    def test_current_documents_and_configuration(self):
        errors, references, anchors = checker.validate(ROOT)
        self.assertEqual(errors, [])
        self.assertGreater(references, 0)
        self.assertGreater(anchors, 0)


if __name__ == "__main__":
    unittest.main()
