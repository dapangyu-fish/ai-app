#!/usr/bin/env python3
"""jsonlogic 引擎吞吐量基准：测每帧可解释执行多少逻辑步（NESd 可行性核心数据）。
负载：1=裸算术  2=AND8(按位与的算术仿真)  3=内存读写(动态寻址)  4=6502六指令切片
按钮：M1-M4 切负载并清零计数；N+/N- 倍增/减半每帧迭代数。"""
import json

V = lambda p: {"var": p}
def call(n, a=None, assign=None):
    c = {"call": n}
    if a is not None:
        c["args"] = a
    if assign:
        c["assign"] = assign
    return c
def gif(c, t, e=None):
    a = {"cond": c, "then": t}
    if e:
        a["else"] = e
    return call("@if", a)
def vset(k, v): return call("@set", {"var": k, "value": v})
def IF(c, t, e): return {"if": [c, t, e]}

# 整数除法仿真: idiv(x,d) = x/d - (x/d)%1   （无 floor 原语）
def IDIV(x, d): return {"-": [{"/": [x, d]}, {"%": [{"/": [x, d]}, 1]}]}
def BIT(v, k): return {"%": [IDIV(v, 2 ** k), 2]}
# AND8 = Σ bit_k(a)*bit_k(b)*2^k  —— 每次 AND ≈ 130 个 jsonlogic 节点
AND8 = {"+": [{"*": [BIT(V("vars.a"), k), BIT(V("vars.b"), k), 2 ** k]} for k in range(8)]}

W_RAW = [vset("vars.a", {"%": [{"+": [V("vars.a"), 1]}, 256]})]
W_AND = [vset("vars.c", AND8),
         vset("vars.a", {"%": [{"+": [V("vars.a"), 1]}, 256]}),
         vset("vars.b", {"%": [{"+": [V("vars.b"), 3]}, 256]})]
W_MEM = [vset("vars.addr", {"%": [{"+": [V("vars.addr"), 1]}, 2048]}),
         vset("vars.tmp", {"var": {"cat": ["vars.ram.", V("vars.addr")]}}),
         call("@set", {"var": "vars.ram.{{ vars.addr }}",
                       "value": {"%": [{"+": [V("vars.tmp"), 1]}, 256]}})]
# 6502 切片：程序 A9 01 / 69 03 / 85 10 / E8 / D0 F8(回跳) —— 真 fetch/decode/execute
FETCH = lambda off=0: {"var": {"cat": ["vars.ram.", {"%": [{"+": [V("vars.pc"), off]}, 2048]}]}}
W_CPU = [
    vset("vars.op", FETCH()),
    gif({"==": [V("vars.op"), 169]}, [  # LDA #imm
        vset("vars.a", FETCH(1)),
        vset("vars.z", {"==": [V("vars.a"), 0]}),
        vset("vars.pc", {"+": [V("vars.pc"), 2]})],
    [gif({"==": [V("vars.op"), 105]}, [  # ADC #imm
        vset("vars.t2", {"+": [V("vars.a"), FETCH(1), IF(V("vars.cf"), 1, 0)]}),
        vset("vars.cf", {">": [V("vars.t2"), 255]}),
        vset("vars.a", {"%": [V("vars.t2"), 256]}),
        vset("vars.z", {"==": [V("vars.a"), 0]}),
        vset("vars.pc", {"+": [V("vars.pc"), 2]})],
    [gif({"==": [V("vars.op"), 133]}, [  # STA zp
        vset("vars.t2", FETCH(1)),
        call("@set", {"var": "vars.ram.{{ vars.t2 }}", "value": V("vars.a")}),
        vset("vars.pc", {"+": [V("vars.pc"), 2]})],
    [gif({"==": [V("vars.op"), 232]}, [  # INX
        vset("vars.x", {"%": [{"+": [V("vars.x"), 1]}, 256]}),
        vset("vars.z", {"==": [V("vars.x"), 0]}),
        vset("vars.pc", {"+": [V("vars.pc"), 1]})],
    [gif({"==": [V("vars.op"), 208]}, [  # BNE rel (向后跳 -8)
        gif({"!": V("vars.z")},
            [vset("vars.pc", {"-": [{"+": [V("vars.pc"), 2]}, 8]})],
            [vset("vars.pc", {"+": [V("vars.pc"), 2]})])],
    [vset("vars.pc", 0)])])])])]),  # 未知op → reset
]
BODIES = {1: W_RAW, 2: W_AND, 3: W_MEM, 4: W_CPU}

RAM = [0] * 2048
PROG = [169, 1, 105, 3, 133, 16, 232, 208, 248]  # @0; BNE 回跳到 pc=0 区
for i, b in enumerate(PROG):
    RAM[i] = b

game = {
    "type": "flame_game",
    "world": {"kind": "pixel", "bg": "#101018"},
    "viewport": {"width": 392, "height": 220, "fit": "contain"},
    "overlay": {"score": False, "game_over": False, "asset_loading": False},
    "vars": {"mode": 1, "n": 100, "t": 0.0001, "frames": 0, "steps": 0,
             "a": 1, "b": 7, "c": 0, "x": 0, "z": False, "cf": False,
             "pc": 0, "op": 0, "t2": 0, "addr": 0, "tmp": 0, "ram": RAM},
    "entities": {
        "dbg": {"kind": "pixel", "priority": 10, "position": [4, 30], "size": [1, 1],
                "fixed_to_screen": True, "auto_update": False,
                "render": {"shape": "text", "value": "bench", "color": "#00FF88",
                           "fontSize": 10}},
        "dbg2": {"kind": "pixel", "priority": 10, "position": [4, 60], "size": [1, 1],
                 "fixed_to_screen": True, "auto_update": False,
                 "render": {"shape": "text", "value": "-", "color": "#FFD24A",
                            "fontSize": 10}},
    },
    "input": {
        "m1": [vset("vars.mode", 1)] + [vset(f"vars.{k}", v) for k, v in
               (("t", 0.0001), ("frames", 0), ("steps", 0), ("pc", 0))],
        "m2": [vset("vars.mode", 2)] + [vset(f"vars.{k}", v) for k, v in
               (("t", 0.0001), ("frames", 0), ("steps", 0), ("pc", 0))],
        "m3": [vset("vars.mode", 3)] + [vset(f"vars.{k}", v) for k, v in
               (("t", 0.0001), ("frames", 0), ("steps", 0), ("pc", 0))],
        "m4": [vset("vars.mode", 4)] + [vset(f"vars.{k}", v) for k, v in
               (("t", 0.0001), ("frames", 0), ("steps", 0), ("pc", 0))],
        "nup": [vset("vars.n", {"*": [V("vars.n"), 2]}),
                vset("vars.t", 0.0001), vset("vars.frames", 0), vset("vars.steps", 0)],
        "ndn": [vset("vars.n", {"max": [1, IDIV(V("vars.n"), 2)]}),
                vset("vars.t", 0.0001), vset("vars.frames", 0), vset("vars.steps", 0)],
        "tap": [vset("vars._x", 0)],
    },
    "frame": {"logic": [
        vset("vars.t", {"+": [V("vars.t"), V("event.dt")]}),
        vset("vars.frames", {"+": [V("vars.frames"), 1]}),
        call("@loop_by_num", {"count": V("vars.n"),
                              "body": [gif({"==": [V("vars.mode"), 1]}, W_RAW,
                                       [gif({"==": [V("vars.mode"), 2]}, W_AND,
                                        [gif({"==": [V("vars.mode"), 3]}, W_MEM, W_CPU)])])]}),
        vset("vars.steps", {"+": [V("vars.steps"), V("vars.n")]}),
        call("@entity.set", {"id": "dbg", "field": "render.value",
             "value": {"cat": ["mode=", V("vars.mode"), " n=", V("vars.n"),
                       " fps=", IDIV({"*": [{"/": [V("vars.frames"), V("vars.t")]}, 10]}, 10),
                       " sps=", IDIV({"/": [V("vars.steps"), V("vars.t")]}, 1)]}}),
        call("@entity.set", {"id": "dbg2", "field": "render.value",
             "value": {"cat": ["a=", V("vars.a"), " c=", V("vars.c"),
                       " x=", V("vars.x"), " pc=", V("vars.pc"),
                       " ram16=", V("vars.ram.16"), " tmp=", V("vars.tmp")]}}),
    ]},
}


def pad_btn(label, inp):
    return {"type": "gesture_detector",
            "onTapDown": {"call": "@flame_game_input", "args": {"input": inp}},
            "child": {"type": "container", "width": 56, "height": 44,
                      "borderRadius": 8, "color": "#2C3E70", "alignment": "center",
                      "children": [{"type": "text", "value": label,
                                    "style": {"fontSize": 12, "color": "#FFFFFF"}}]}}


app = {
    "dsl": "3.3", "appid": "9e0a3a44-0000-4000-8000-00000000bef1",
    "meta": {"name": "bench-jsonlogic", "version": "0.0.1", "type": "app",
             "description": "jsonlogic throughput bench"},
    "global": {"variables": {}, "functions": {}},
    "ui": {"screens": [{
        "id": "b", "title": "bench", "backgroundColor": "#000000",
        "appBar": False, "layout": "column", "padding": 0,
        "children": [
            {"type": "expanded", "child": game},
            {"type": "container", "height": 120, "color": "#141C2E", "layout": "column",
             "padding": 8, "children": [
                 {"type": "container", "layout": "row", "mainAxisAlignment": "spaceBetween",
                  "children": [pad_btn("RAW", "m1"), pad_btn("AND8", "m2"),
                               pad_btn("MEM", "m3"), pad_btn("6502", "m4")]},
                 {"type": "container", "height": 8},
                 {"type": "container", "layout": "row", "mainAxisAlignment": "spaceBetween",
                  "children": [pad_btn("N x2", "nup"), pad_btn("N /2", "ndn")]},
             ]},
        ],
    }]},
}
out = "/tmp/claude-1000/-home-fish-ai-app/209f3943-1b1c-4f10-af8e-6c6cdca97f82/scratchpad/nesd/bench_app.json"
json.dump(app, open(out, "w"), ensure_ascii=False)
print("wrote", out)
