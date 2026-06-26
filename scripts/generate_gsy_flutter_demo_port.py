#!/usr/bin/env python3
"""Generate the first-pass JSON port of CarGuo/gsy_flutter_demo.

The generated launcher mirrors the upstream demo inventory from
lib/routes/demo_routes.dart and declares each child demo as a lazy app
dependency. Child demos are independently runnable JSON apps. Unsupported
Flutter-specific demos intentionally render an "in development" page until the
JSON runtime gains enough primitives for a true 1:1 port.
"""

from __future__ import annotations

import json
import re
import sys
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
UPSTREAM = Path("/tmp/gsy_flutter_demo_upstream")
ROUTES = UPSTREAM / "lib/routes/demo_routes.dart"
CATEGORY_CONFIG = UPSTREAM / "lib/home/demo_category_config.dart"
LOCALIZER = UPSTREAM / "lib/l10n/route_title_localizer.dart"

CHILD_VERSION = "0.1.0"
LAUNCHER_VERSION = "0.1.2"
LAUNCHER_NAME = "gsy_flutter_demo_launcher"
CHILD_NAMESPACE = "gsy_flutter_demo"
UUID_NS = uuid.UUID("b7c1f247-47df-4a66-9b9e-7ad47ef57e14")
UPSTREAM_REPOSITORY = "https://github.com/CarGuo/gsy_flutter_demo"
UPSTREAM_LICENSE_NAME = "MIT License"
UPSTREAM_LICENSE_COPYRIGHT = "Copyright (c) 2019 Shuyu Guo"


CATEGORY_META = {
    "basic": {
        "zh": "基础控件",
        "en": "Basics",
        "icon": "widgets",
        "placeholderIcon": "dashboard",
        "color": "#1D7BCB",
        "soft": "#E8F2FD",
    },
    "scroll": {
        "zh": "列表滚动",
        "en": "Scrolling",
        "icon": "swap_vert",
        "placeholderIcon": "list",
        "color": "#0B8E70",
        "soft": "#E7F6F1",
    },
    "animation": {
        "zh": "动画交互",
        "en": "Animation",
        "icon": "play",
        "placeholderIcon": "play",
        "color": "#E66A00",
        "soft": "#FFF2E5",
    },
    "canvas": {
        "zh": "绘制与Shader",
        "en": "Canvas & Shader",
        "icon": "brush",
        "placeholderIcon": "palette",
        "color": "#7A57D1",
        "soft": "#F0ECFB",
    },
    "visual": {
        "zh": "3D与视觉",
        "en": "3D & Visual",
        "icon": "auto_awesome_mosaic",
        "placeholderIcon": "visibility",
        "color": "#4A74E8",
        "soft": "#EAEFFE",
    },
}

CATEGORY_ORDER = ["basic", "scroll", "animation", "canvas", "visual"]

CATEGORY_RULES = [
    (
        "scroll",
        [
            "list",
            "sliver",
            "scroll",
            "viewpager",
            "pageview",
            "列表",
            "滑动",
            "停靠",
            "联动",
            "bottomsheet",
            "chat",
            "draggable",
            "link",
        ],
    ),
    (
        "visual",
        [
            "3d",
            "box",
            "card",
            "cube",
            "juejin",
            "logo",
            "sphere",
            "spatial",
            "gallery",
            "disco",
            "mosaic",
            "二维码",
            "画廊",
            "星云",
            "黑洞",
            "太极",
            "鱼",
            "koi",
            "galaxy",
        ],
    ),
    (
        "canvas",
        [
            "canvas",
            "shader",
            "path",
            "matrix",
            "blur",
            "glass",
            "liquid",
            "radial",
            "neon",
            "wave",
            "绘制",
            "阴影",
            "路径",
            "高斯",
            "手势",
            "jaw",
        ],
    ),
    (
        "animation",
        [
            "anim",
            "animation",
            "particle",
            "boom",
            "bomb",
            "switch",
            "seekbar",
            "scan",
            "clock",
            "tip",
            "撕裂",
            "爆炸",
            "动画",
            "粒子",
            "炫酷",
            "骚气",
            "霓虹",
            "cool",
        ],
    ),
]


@dataclass(frozen=True)
class DemoEntry:
    index: int
    title_zh: str
    title_en: str
    category: str
    package: str
    slug: str
    import_path: str
    source_path: str
    alias: str
    widget_class: str


def text(value: Any, *, style: dict[str, Any] | None = None, **props: Any) -> dict[str, Any]:
    out: dict[str, Any] = {"type": "text", "value": value}
    if style:
        out["style"] = style
    out.update(props)
    return out


def icon(name: str, *, size: int = 20, color: str = "#6B7280", **props: Any) -> dict[str, Any]:
    out: dict[str, Any] = {"type": "icon", "name": name, "size": size, "color": color}
    out.update(props)
    return out


def spacer(*, height: int | None = None, width: int | None = None) -> dict[str, Any]:
    out: dict[str, Any] = {"type": "spacer"}
    if height is not None:
        out["height"] = height
    if width is not None:
        out["width"] = width
    return out


def container(children: list[dict[str, Any]], *, layout: str = "column", **props: Any) -> dict[str, Any]:
    out: dict[str, Any] = {"type": "container", "layout": layout, "children": children}
    out.update(props)
    return out


def card(children: list[dict[str, Any]], *, layout: str = "column", **props: Any) -> dict[str, Any]:
    out: dict[str, Any] = {
        "type": "card",
        "layout": layout,
        "children": children,
        "padding": 14,
        "margin": 4,
        "elevation": 0,
        "borderRadius": 14,
        "color": "#FFFFFF",
    }
    out.update(props)
    return out


def button(label: str, *, action: dict[str, Any], icon_name: str | None = None, **props: Any) -> dict[str, Any]:
    out: dict[str, Any] = {"type": "button", "label": label, "action": action}
    if icon_name:
        out["icon"] = icon_name
    out.update(props)
    return out


def action(call: str, args: dict[str, Any] | None = None) -> dict[str, Any]:
    return {"call": call, "args": args or {}}


def screen(
    screen_id: str,
    *,
    title: str | dict[str, str],
    children: list[dict[str, Any]],
    **props: Any,
) -> dict[str, Any]:
    out: dict[str, Any] = {
        "id": screen_id,
        "title": title,
        "layout": "column",
        "children": children,
    }
    out.update(props)
    return out


def new_app(
    *,
    name: str,
    version: str,
    appid: str,
    display_name: dict[str, str],
    description: str,
    dependencies: dict[str, Any] | None,
    variables: dict[str, Any],
    functions: dict[str, Any] | None,
    i18n: dict[str, Any] | None = None,
    screens: list[dict[str, Any]],
) -> dict[str, Any]:
    global_config: dict[str, Any] = {
        "variables": variables,
        "functions": functions or {},
    }
    if i18n:
        global_config["i18n"] = i18n
    return {
        "dsl": "3.3",
        "appid": appid,
        "meta": {
            "name": name,
            "version": version,
            "type": "app",
            "displayName": display_name,
            "description": description,
            "author": "fish",
        },
        "dependencies": dependencies or {},
        "global": global_config,
        "steps": [],
        "ui": {"screens": screens},
    }


def deterministic_uuid(name: str) -> str:
    return str(uuid.uuid5(UUID_NS, name))


def pascal_to_kebab(value: str) -> str:
    value = re.sub(r"([a-z0-9])([A-Z])", r"\1-\2", value)
    value = re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1-\2", value)
    value = value.replace("_", "-").lower()
    value = re.sub(r"[^a-z0-9-]+", "-", value)
    value = re.sub(r"-+", "-", value).strip("-")
    return value or "demo"


def categorize(title: str) -> str:
    value = title.lower()
    for category, keywords in CATEGORY_RULES:
        if any(keyword in value for keyword in keywords):
            return category
    return "basic"


def demo_key(entry: DemoEntry) -> str:
    return f"d{entry.index:03d}"


def load_title_localizer() -> list[tuple[str, str]]:
    text_src = LOCALIZER.read_text(encoding="utf-8")
    return re.findall(r"_Pair\('([^']*)', '([^']*)'\)", text_src)


def localize_title(title: str, pairs: list[tuple[str, str]]) -> str:
    if all(ord(ch) <= 127 for ch in title):
        return title
    value = title
    for zh, en in pairs:
        value = value.replace(zh, en)
    value = value.replace("（", "(").replace("）", ")").replace("，", ", ").replace("。", ".")
    return re.sub(r"\s+", " ", value).strip()


def parse_upstream() -> list[DemoEntry]:
    if not ROUTES.exists():
        raise SystemExit(f"missing upstream routes: {ROUTES}")

    source = ROUTES.read_text(encoding="utf-8")
    imports = {
        alias: path
        for path, alias in re.findall(
            r"import\s+'package:gsy_flutter_demo/([^']+)'\s+deferred\s+as\s+(\w+);",
            source,
            re.S,
        )
    }

    route_matches = list(
        re.finditer(r'^[ \t]*"([^"]+)"\s*:\s*\(context\)\s*\{', source, re.M)
    )
    pairs = load_title_localizer()
    entries: list[DemoEntry] = []

    used_slugs: set[str] = set()
    for i, match in enumerate(route_matches, start=1):
        title = match.group(1)
        end = route_matches[i].start() if i < len(route_matches) else source.find("\n};", match.end())
        block = source[match.end() : end]
        alias_match = re.search(r"ContainerAsyncRouterPage\(\s*(\w+)\.loadLibrary", block)
        alias = alias_match.group(1) if alias_match else ""
        widget_matches = re.findall(r"return\s+(\w+)\s*\.\s*([A-Za-z0-9_]+)\s*\(", block)
        widget_class = ""
        for widget_alias, cls in widget_matches:
            if not alias or widget_alias == alias:
                widget_class = cls
                break
        if not widget_class and widget_matches:
            widget_class = widget_matches[-1][1]

        import_path = imports.get(alias, "")
        source_path = f"lib/{import_path}" if import_path else ""
        base_slug = pascal_to_kebab(widget_class or alias or title)
        slug = f"{i:03d}-{base_slug}"
        while slug in used_slugs:
            slug = f"{slug}-x"
        used_slugs.add(slug)

        package = f"{CHILD_NAMESPACE}/{slug}"
        entries.append(
            DemoEntry(
                index=i,
                title_zh=title,
                title_en=localize_title(title, pairs),
                category=categorize(title),
                package=package,
                slug=slug,
                import_path=import_path,
                source_path=source_path,
                alias=alias,
                widget_class=widget_class or "UnknownWidget",
            )
        )

    return entries


def demo_row(entry: DemoEntry) -> dict[str, Any]:
    meta = CATEGORY_META[entry.category]
    return card(
        [
            container(
                [
                    container(
                        [
                            text(
                                f"{entry.index:03d}",
                                style={
                                    "fontSize": 11,
                                    "fontWeight": "700",
                                    "color": meta["color"],
                                },
                            )
                        ],
                        layout="column",
                        width=42,
                        height=42,
                        color=meta["soft"],
                        borderRadius=11,
                        mainAxisAlignment="center",
                        crossAxisAlignment="center",
                    ),
                    spacer(width=10),
                    container(
                        [
                            text(
                                "{{ t('demos." + demo_key(entry) + "') }}",
                                style={
                                    "fontSize": 14,
                                    "fontWeight": "600",
                                    "color": "#1B2B46",
                                },
                                maxLines=2,
                            ),
                            spacer(height=4),
                            text(
                                f"{entry.widget_class} · {entry.slug}",
                                style={"fontSize": 11, "color": "#6B7280"},
                                maxLines=1,
                            ),
                        ],
                        layout="column",
                        position={"type": "flex", "flex": 1},
                        crossAxisAlignment="start",
                    ),
                    spacer(width=8),
                    icon("chevron_right", size=22, color=meta["color"]),
                ],
                layout="row",
                crossAxisAlignment="center",
            )
        ],
        onTap=action("@launch_app", {"kind": "dependency", "name": entry.package}),
    )


def category_section(category: str, entries: list[DemoEntry]) -> dict[str, Any]:
    meta = CATEGORY_META[category]
    rows = [demo_row(entry) for entry in entries]
    return container(
        [
            container(
                [
                    container(
                        [icon(meta["icon"], size=17, color=meta["color"])],
                        layout="column",
                        width=32,
                        height=32,
                        color=meta["soft"],
                        borderRadius=10,
                        mainAxisAlignment="center",
                        crossAxisAlignment="center",
                    ),
                    spacer(width=8),
                    text(
                        "{{ t('categories." + category + "') }}",
                        style={
                            "fontSize": 16,
                            "fontWeight": "700",
                            "color": "#1B2B46",
                        },
                    ),
                    spacer(width=8),
                    text(
                        str(len(entries)),
                        style={
                            "fontSize": 13,
                            "fontWeight": "700",
                            "color": "#5F6E85",
                        },
                    ),
                ],
                layout="row",
                crossAxisAlignment="center",
            ),
            spacer(height=8),
            *rows,
        ],
        layout="column",
        padding=12,
        margin=10,
        color="#FFFFFF",
        borderRadius=18,
        border={"color": "#E5ECF7", "width": 1},
        visible={
            "or": [
                {"==": [{"var": "global.selectedCategory"}, None]},
                {"==": [{"var": "global.selectedCategory"}, category]},
            ]
        },
    )


def category_chip(category: str, count: int) -> dict[str, Any]:
    meta = CATEGORY_META[category]
    return {
        "type": "chip",
        "variant": "choice",
        "bind": "global.selectedCategory",
        "value": category,
        "label": "{{ t('categories." + category + "') }} · " + str(count),
        "icon": meta["icon"],
        "color": meta["color"],
    }


def launcher_i18n(entries: list[DemoEntry]) -> dict[str, Any]:
    return {
        "zh": {
            "appTitle": "GSY Flutter Demo",
            "noticeTitle": "开源仓库与许可声明",
            "noticeIntro": "这个 JSON-APP 启动器是对 GSY Flutter Demo 的 JSON 层移植与索引展示。原 Flutter 项目、示例思想和源代码归上游作者所有。",
            "noticeRepoLabel": "上游仓库",
            "noticeLicenseLabel": "许可",
            "noticeLicense": f"{UPSTREAM_LICENSE_NAME}，{UPSTREAM_LICENSE_COPYRIGHT}。许可信息请以上游仓库根目录 LICENSE 文件为准。",
            "noticeConfirm": "点击进入表示你已阅读该声明。",
            "openRepository": "查看 GitHub",
            "enterLauncher": "进入启动器",
            "homeSubtitle": "分组浏览、快速检索，一键进入示例。",
            "allExamples": "全部示例",
            "currentShown": "当前显示",
            "searchHint": "搜索示例名称（中英文均可）",
            "language": "语言",
            "categories": {
                key: meta["zh"] for key, meta in CATEGORY_META.items()
            },
            "demos": {demo_key(entry): entry.title_zh for entry in entries},
        },
        "en": {
            "appTitle": "GSY Flutter Demo",
            "noticeTitle": "Repository and License Notice",
            "noticeIntro": "This JSON-APP launcher is a JSON-layer port and index for GSY Flutter Demo. The original Flutter project, demo ideas, and source code belong to the upstream author.",
            "noticeRepoLabel": "Upstream repository",
            "noticeLicenseLabel": "License",
            "noticeLicense": f"{UPSTREAM_LICENSE_NAME}, {UPSTREAM_LICENSE_COPYRIGHT}. Please treat the upstream LICENSE file as authoritative.",
            "noticeConfirm": "Continue only after reading this notice.",
            "openRepository": "Open GitHub",
            "enterLauncher": "Enter launcher",
            "homeSubtitle": "Browse by category, search quickly, and open examples in one tap.",
            "allExamples": "All examples",
            "currentShown": "Shown",
            "searchHint": "Search examples",
            "language": "Language",
            "categories": {
                key: meta["en"] for key, meta in CATEGORY_META.items()
            },
            "demos": {demo_key(entry): entry.title_en for entry in entries},
        },
    }


def launcher_app(entries: list[DemoEntry]) -> dict[str, Any]:
    by_category = {category: [] for category in CATEGORY_ORDER}
    for entry in entries:
        by_category[entry.category].append(entry)

    dependencies = {
        entry.package: {"version": f"^{CHILD_VERSION}", "type": "app", "lazy": True}
        for entry in entries
    }
    sections = [
        category_section(category, by_category[category])
        for category in CATEGORY_ORDER
        if by_category[category]
    ]
    chips = [
        category_chip(category, len(by_category[category]))
        for category in CATEGORY_ORDER
    ]

    notice_children = [
        container(
            [
                container(
                    [icon("code", size=30, color="#FFFFFF")],
                    layout="column",
                    width=58,
                    height=58,
                    color="#0B4D88",
                    borderRadius=16,
                    mainAxisAlignment="center",
                    crossAxisAlignment="center",
                ),
                spacer(height=18),
                text(
                    "{{ t('appTitle') }}",
                    style={"fontSize": 24, "fontWeight": "800", "color": "#0F172A"},
                ),
                spacer(height=8),
                text(
                    "{{ t('noticeTitle') }}",
                    style={"fontSize": 18, "fontWeight": "700", "color": "#1E3A5F"},
                ),
                spacer(height=14),
                text(
                    "{{ t('noticeIntro') }}",
                    style={"fontSize": 14, "color": "#334155", "height": 1.35},
                ),
                spacer(height=18),
                container(
                    [
                        text("{{ t('noticeRepoLabel') }}", style={"fontSize": 13, "fontWeight": "700", "color": "#475569"}),
                        spacer(height=6),
                        text(UPSTREAM_REPOSITORY, style={"fontSize": 13, "color": "#1D7BCB"}),
                    ],
                    layout="column",
                    padding=14,
                    color="#F8FAFC",
                    borderRadius=14,
                    border={"color": "#E2E8F0", "width": 1},
                    crossAxisAlignment="start",
                ),
                spacer(height=10),
                container(
                    [
                        text("{{ t('noticeLicenseLabel') }}", style={"fontSize": 13, "fontWeight": "700", "color": "#475569"}),
                        spacer(height=6),
                        text("{{ t('noticeLicense') }}", style={"fontSize": 13, "color": "#334155", "height": 1.35}),
                    ],
                    layout="column",
                    padding=14,
                    color="#F8FAFC",
                    borderRadius=14,
                    border={"color": "#E2E8F0", "width": 1},
                    crossAxisAlignment="start",
                ),
                spacer(height=16),
                text("{{ t('noticeConfirm') }}", style={"fontSize": 12, "color": "#64748B"}),
                spacer(height=18),
                button(
                    "{{ t('openRepository') }}",
                    icon_name="link",
                    variant="outlined",
                    action=action("@launch_url", {"url": UPSTREAM_REPOSITORY}),
                    style={"fontSize": 14, "borderRadius": 12},
                ),
                spacer(height=10),
                button(
                    "{{ t('enterLauncher') }}",
                    icon_name="forward",
                    variant="filled",
                    action=action("@navigate", {"screen": "home"}),
                    style={"fontSize": 15, "fontWeight": "700", "borderRadius": 12},
                ),
            ],
            layout="column",
            padding=22,
            margin=16,
            color="#FFFFFF",
            borderRadius=20,
            border={"color": "#D7E2F0", "width": 1},
            crossAxisAlignment="start",
        ),
    ]

    children = [
        container(
            [
                container(
                    [
                        container(
                            [icon("auto_awesome", size=22, color="#FFFFFF")],
                            layout="column",
                            width=44,
                            height=44,
                            color="#2D82D3",
                            borderRadius=12,
                            mainAxisAlignment="center",
                            crossAxisAlignment="center",
                        ),
                        spacer(width=12),
                        text(
                            "{{ t('appTitle') }}",
                            style={
                                "fontSize": 22,
                                "fontWeight": "700",
                                "color": "#FFFFFF",
                            },
                            position={"type": "flex", "flex": 1},
                        ),
                        container(
                            [icon("language", size=22, color="#FFFFFF")],
                            layout="column",
                            width=42,
                            height=42,
                            borderRadius=12,
                            mainAxisAlignment="center",
                            crossAxisAlignment="center",
                            onTap=action("@global.toggleLocale"),
                        ),
                    ],
                    layout="row",
                    crossAxisAlignment="center",
                ),
                spacer(height=10),
                text(
                    "{{ t('homeSubtitle') }}",
                    style={"fontSize": 14, "color": "#EAF2FF"},
                ),
                spacer(height=14),
                container(
                    [
                        text("{{ t('allExamples') }}", style={"fontSize": 12, "color": "#D9ECFF"}),
                        spacer(width=8),
                        text(str(len(entries)), style={"fontSize": 15, "fontWeight": "800", "color": "#FFFFFF"}),
                        spacer(width=16),
                        text("{{ t('currentShown') }}", style={"fontSize": 12, "color": "#D9ECFF"}),
                        spacer(width=8),
                        text(str(len(entries)), style={"fontSize": 15, "fontWeight": "800", "color": "#FFFFFF"}),
                    ],
                    layout="row",
                    crossAxisAlignment="center",
                ),
            ],
            layout="column",
            padding=18,
            margin=12,
            color="#0B4D88",
            borderRadius=20,
        ),
        container(
            [
                icon("search", size=18, color="#6B7280"),
                spacer(width=8),
                {
                    "type": "input",
                    "bind": "global.query",
                    "placeholder": "{{ t('searchHint') }}",
                    "position": {"type": "flex", "flex": 1},
                    "style": {"fontSize": 14, "borderRadius": 12},
                },
            ],
            layout="row",
            padding=10,
            margin=12,
            color="#FFFFFF",
            borderRadius=16,
            crossAxisAlignment="center",
        ),
        container(
            chips,
            layout="row",
            scrollDirection="horizontal",
            padding=8,
            margin=12,
            height=56,
            crossAxisAlignment="center",
        ),
        *sections,
        spacer(height=20),
    ]

    return new_app(
        name=LAUNCHER_NAME,
        version=LAUNCHER_VERSION,
        appid=deterministic_uuid(LAUNCHER_NAME),
        display_name={
            "zh": "GSY Flutter Demo 启动器",
            "en": "GSY Flutter Demo Launcher",
        },
        description="CarGuo/gsy_flutter_demo 的 JSON-APP 启动器，入口清单按 upstream 路由表生成。",
        dependencies=dependencies,
        variables={
            "query": "",
            "selectedCategory": None,
            "source": UPSTREAM_REPOSITORY,
            "licenseName": UPSTREAM_LICENSE_NAME,
            "licenseCopyright": UPSTREAM_LICENSE_COPYRIGHT,
            "total": len(entries),
        },
        functions={
            "toggleLocale": {
                "params": [],
                "logic": [
                    {
                        "call": "@if",
                        "args": {
                            "condition": {"==": [{"var": "global.locale"}, "en"]},
                            "then": [
                                {
                                    "call": "@set_framework_locale",
                                    "args": {"value": "zh"},
                                }
                            ],
                            "else": [
                                {
                                    "call": "@set_framework_locale",
                                    "args": {"value": "en"},
                                }
                            ],
                        },
                    }
                ],
            }
        },
        i18n=launcher_i18n(entries),
        screens=[
            screen(
                "notice",
                title="{{ t('noticeTitle') }}",
                children=notice_children,
                padding=0,
                backgroundColor="#F2F6FF",
            ),
            screen(
                "home",
                title="{{ t('appTitle') }}",
                children=children,
                padding=0,
                backgroundColor="#F2F6FF",
            )
        ],
    )


def child_app(entry: DemoEntry) -> dict[str, Any]:
    meta = CATEGORY_META[entry.category]
    children = [
        container(
            [
                container(
                    [icon(meta["placeholderIcon"], size=26, color=meta["color"])],
                    layout="column",
                    width=58,
                    height=58,
                    color=meta["soft"],
                    borderRadius=16,
                    mainAxisAlignment="center",
                    crossAxisAlignment="center",
                ),
                spacer(height=16),
                text(
                    entry.title_zh,
                    style={"fontSize": 22, "fontWeight": "800", "color": "#111827"},
                ),
                spacer(height=6),
                text(
                    entry.title_en,
                    style={"fontSize": 13, "color": "#667085"},
                ),
            ],
            layout="column",
            padding=20,
            margin=12,
            color="#FFFFFF",
            borderRadius=20,
            crossAxisAlignment="start",
        ),
        container(
            [
                text("JSON 移植状态", style={"fontSize": 16, "fontWeight": "700", "color": "#111827"}),
                spacer(height=8),
                text(
                    "正在开发中。该子 APP 已经可以独立运行，并且可以被 launcher 作为 lazy app dependency 启动；真实交互会按 upstream demo 逐项补齐。",
                    style={"fontSize": 13, "color": "#4B5563"},
                ),
                spacer(height=14),
                text(f"分类：{meta['zh']}", style={"fontSize": 13, "color": "#374151"}),
                spacer(height=6),
                text(f"Upstream：{entry.source_path}", style={"fontSize": 12, "color": "#6B7280"}),
                spacer(height=6),
                text(f"Widget：{entry.widget_class}", style={"fontSize": 12, "color": "#6B7280"}),
            ],
            layout="column",
            padding=16,
            margin=12,
            color="#FFFFFF",
            borderRadius=16,
            border={"color": "#E5E7EB", "width": 1},
            crossAxisAlignment="start",
        ),
        button(
            "返回",
            icon_name="back",
            variant="outlined",
            action=action("@back"),
            style={"fontSize": 14, "borderRadius": 12},
        ),
    ]

    app = new_app(
        name=entry.package,
        version=CHILD_VERSION,
        appid=deterministic_uuid(entry.package),
        display_name={"zh": entry.title_zh, "en": entry.title_en},
        description=f"gsy_flutter_demo JSON 移植子示例：{entry.title_zh}",
        dependencies={},
        variables={
            "upstreamTitle": entry.title_zh,
            "upstreamSource": entry.source_path,
            "upstreamWidget": entry.widget_class,
            "portStatus": "in_development",
        },
        functions={},
        screens=[
            screen(
                "home",
                title=entry.title_zh,
                children=children,
                padding=0,
                backgroundColor="#F7F8FA",
            )
        ],
    )
    app["meta"]["upstream"] = {
        "repository": "https://github.com/CarGuo/gsy_flutter_demo",
        "routeTitle": entry.title_zh,
        "sourcePath": entry.source_path,
        "deferredAlias": entry.alias,
        "widgetClass": entry.widget_class,
        "category": entry.category,
        "routeIndex": entry.index,
    }
    return app


def write_json(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def write_docs(entries: list[DemoEntry]) -> None:
    by_category = {category: [] for category in CATEGORY_ORDER}
    for entry in entries:
        by_category[entry.category].append(entry)

    lines = [
        "# GSY Flutter Demo JSON Port",
        "",
        "Source repository: `https://github.com/CarGuo/gsy_flutter_demo`.",
        "",
        "This document is generated by `scripts/generate_gsy_flutter_demo_port.py` from the locally cloned upstream route table. Do not hand-edit the generated inventory; change the generator or upstream parser instead.",
        "",
        "## Current Phase",
        "",
        "- Launcher package: `gsy_flutter_demo_launcher`.",
        "- Child package namespace: `gsy_flutter_demo/*`.",
        "- Upstream route count: `{}`.".format(len(entries)),
        "- The launcher declares child demos as lazy app dependencies and opens them with `@launch_app({kind: \"dependency\"})`.",
        "- Child demos are independently runnable JSON apps. They currently show a structured development placeholder until each Flutter-specific demo is ported with matching JSON/runtime capabilities.",
        "",
        "## Category Counts",
        "",
        "| Category | Count |",
        "| --- | ---: |",
    ]
    for category in CATEGORY_ORDER:
        lines.append(f"| {CATEGORY_META[category]['zh']} | {len(by_category[category])} |")

    lines.extend(["", "## Inventory", "", "| # | Category | Title | Package | Upstream widget | Source |", "| ---: | --- | --- | --- | --- | --- |"])
    for entry in entries:
        lines.append(
            f"| {entry.index} | {CATEGORY_META[entry.category]['zh']} | {entry.title_zh} | `{entry.package}` | `{entry.widget_class}` | `{entry.source_path}` |"
        )

    path = ROOT / "docs/gsy_flutter_demo_json_port.md"
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    if not UPSTREAM.exists():
        raise SystemExit("Clone upstream first: git clone https://github.com/CarGuo/gsy_flutter_demo /tmp/gsy_flutter_demo_upstream")
    if not CATEGORY_CONFIG.exists():
        raise SystemExit(f"missing upstream category config: {CATEGORY_CONFIG}")

    entries = parse_upstream()
    if len(entries) != 126:
        raise SystemExit(f"expected 126 upstream routes, got {len(entries)}")

    launcher_path = ROOT / "templates/gsy_flutter_demo_launcher.json"
    write_json(launcher_path, launcher_app(entries))

    child_dir = ROOT / f"templates/{CHILD_NAMESPACE}"
    child_dir.mkdir(parents=True, exist_ok=True)
    for old in child_dir.glob("*.json"):
        old.unlink()
    for entry in entries:
        write_json(child_dir / f"{entry.slug}.json", child_app(entry))

    write_docs(entries)
    print(f"generated launcher: {launcher_path}")
    print(f"generated child apps: {len(entries)} in {child_dir}")
    print(f"generated docs: {ROOT / 'docs/gsy_flutter_demo_json_port.md'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
