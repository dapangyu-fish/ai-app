#!/usr/bin/env python3
"""未注册的 widget 类型必须在校验阶段被 ERROR 拦下。

渲染端 lib/json_ui/widget_builder.dart 的 _builders 是唯一真相源；不在其中的 type
客户端会渲染成"未知类型"错误框。这里确保 validator 用同一份集合把 AI 自造的控件
类型（row/column/flex/text_input ...）在生成阶段就拦下，触发自动修复，而不是靠客户端
加别名兜底。
"""

from __future__ import annotations

from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))

import validate_json_app as V  # noqa: E402


def _widget_type_errors(app: dict) -> list:
    validator = V.Validator(app, V.load_builtin_calls())
    validator.validate()
    return [
        f for f in validator.findings
        if f.level == "ERROR" and "unknown widget type" in f.message
    ]


def _app(children: list) -> dict:
    return {
        "dsl": "3.3",
        "meta": {"name": "t", "version": "1.0.0", "type": "app"},
        "global": {"variables": {}, "functions": {}},
        "ui": {
            "initialScreen": "home",
            "screens": [
                {"id": "home", "title": "t", "layout": "column", "children": children}
            ],
        },
    }


def test_registry_extracted_from_builders() -> None:
    types = V.load_registered_widget_types()
    assert types, "should extract widget types from widget_builder.dart _builders"
    for ok in ("container", "input", "button", "text", "list", "expanded", "card", "ref"):
        assert ok in types, ok
    for bad in ("row", "column", "flex", "text_input"):
        assert bad not in types, bad


def test_unregistered_types_error() -> None:
    errs = _widget_type_errors(_app([
        {"type": "text", "text": "ok"},
        {"type": "row", "children": [{"type": "button", "label": "b"}]},
        {"type": "column", "children": []},
        {"type": "flex", "children": []},
        {"type": "text_input", "hint": "x"},
    ]))
    flagged = sorted({e.message.split("'")[1] for e in errs})
    assert flagged == ["column", "flex", "row", "text_input"], flagged


def test_registered_types_ok() -> None:
    errs = _widget_type_errors(_app([
        {"type": "text", "text": "ok"},
        {"type": "container", "layout": "row", "children": [
            {"type": "input", "hint": "x"}, {"type": "button", "label": "b"}]},
        {"type": "card", "child": {"type": "text", "text": "c"}},
        {"type": "expanded", "child": {"type": "list"}},
    ]))
    assert errs == [], [e.message for e in errs]


def test_position_and_action_type_not_flagged() -> None:
    # position:{type:flex}（定位指令）和 action:{type:call}（动作）不是 widget，不能误报
    errs = _widget_type_errors(_app([
        {
            "type": "button", "label": "b",
            "position": {"type": "flex", "flex": 2},
            "action": {"type": "call", "call": "@global.x", "args": {}},
        },
    ]))
    assert errs == [], [e.message for e in errs]


def test_jsonlogic_custom_ops_no_drift() -> None:
    # 框架 jl.add 注册的自定义算子必须全部被识别（曾与硬编码集漂移、漏 14 个）。
    ops = V.load_jsonlogic_custom_ops()
    assert ops, "should derive custom jsonlogic ops from source/manifest"
    for op in ("clamp", "sqrt", "lerp", "atan2", "str_split", "str_len", "pow"):
        assert op in ops, op
        assert op in V.JSONLOGIC_SINGLE_KEYS, op


def test_capabilities_manifest_consumed() -> None:
    # 清单是权威 floor：lint 的能力集必须 ⊇ 清单（实时解析 ∪ 清单）。
    man = V.load_capabilities_manifest()
    assert man.get("widget_types"), "manifest must ship widget_types"
    assert set(man["widget_types"]).issubset(V.load_registered_widget_types())
    assert set(man.get("icons", [])).issubset(V.load_allowed_icon_names())
    assert set(man.get("jsonlogic_custom_ops", [])).issubset(V.JSONLOGIC_SINGLE_KEYS)


def test_unknown_type_in_tab_content_error() -> None:
    # 渲染惰性把非当前 tab 藏起来（实测 initial=0），静态全树遍历必须抓到。
    errs = _widget_type_errors(_app([
        {"type": "tab_view", "height": 300, "tabs": [
            {"label": "T1", "content": {"type": "text", "value": "x"}},
            {"label": "T2", "content": {"type": "mystery_tab_widget"}},
        ]},
    ]))
    assert any("mystery_tab_widget" in e.message for e in errs), [e.message for e in errs]


def test_unknown_type_in_item_template_error() -> None:
    errs = _widget_type_errors(_app([
        {"type": "list", "source": "{{ global.xs }}",
         "item_template": {"type": "mystery_row_widget"}},
    ]))
    assert any("mystery_row_widget" in e.message for e in errs), [e.message for e in errs]


def test_tolerant_fields_are_warn_not_error() -> None:
    # 框架忽略/容忍的字段降 WARN，绝不误拦合法 app（漂移也只剩无害 WARN）。
    validator = V.Validator(_app([
        {"type": "container", "layout": "column", "marginTop": 8, "children": [
            {"type": "text", "value": "x", "width": "100px"},
            {"type": "text", "value": {"+": [1, 2]}},
        ]},
    ]), V.load_builtin_calls())
    validator.validate()
    errs = [f for f in validator.findings if f.level == "ERROR"]
    warns = " | ".join(f.message for f in validator.findings if f.level == "WARN")
    assert errs == [], [e.message for e in errs]
    assert "CSS-like" in warns and "should be a number" in warns and "presentation text" in warns


if __name__ == "__main__":
    test_registry_extracted_from_builders()
    test_unregistered_types_error()
    test_registered_types_ok()
    test_position_and_action_type_not_flagged()
    test_jsonlogic_custom_ops_no_drift()
    test_capabilities_manifest_consumed()
    test_unknown_type_in_tab_content_error()
    test_unknown_type_in_item_template_error()
    test_tolerant_fields_are_warn_not_error()
    print("ok: widget type validation")
