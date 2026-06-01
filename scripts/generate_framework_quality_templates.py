#!/usr/bin/env python3
"""Generate framework-aligned JSON app templates.

Unlike the native_quality_* CRUD samples, these templates intentionally exercise
different JSON-DSL runtime capabilities: controls, charts, maps, QR codes,
video, image picker, grids, tabs, sliders, switches, and progress widgets.
"""

from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "backend"))

from json_app_builder import (  # noqa: E402
    button,
    call,
    card,
    container,
    icon,
    native_action_icon,
    native_app_bar,
    new_app,
    save_json,
    screen,
    spacer,
    text,
)


APPIDS = {
    "smart_home": "c8ce97f0-589f-4d27-9f7b-0dbb74ab45cb",
    "ops_dashboard": "9b82a9da-af09-47e3-b7db-27e3a09acc62",
    "travel_pass": "6f79a25c-5c3f-4ed9-b42e-f1005ddc7294",
    "course_player": "e353f5db-5528-4369-a10c-5bb5be855404",
    "camera_inspection": "3b713f9d-2b4e-4f21-a6e4-38a3422824ed",
}


def _title(value: str, subtitle: str | None = None) -> dict:
    children = [
        text(value, style={"fontSize": 19, "fontWeight": "bold", "color": "#111827"}),
    ]
    if subtitle:
        children.extend(
            [
                spacer(height=4),
                text(subtitle, style={"fontSize": 13, "color": "#6B7280", "lineHeight": 1.35}),
            ]
        )
    return container(children, layout="column", margin=12)


def _metric(label: str, value: str, icon_name: str, accent: str, tint: str) -> dict:
    return card(
        [
            icon(icon_name, size=20, color=accent),
            spacer(height=10),
            text(value, style={"fontSize": 22, "fontWeight": "bold", "color": "#111827", "maxLines": 1}),
            spacer(height=4),
            text(label, style={"fontSize": 12, "color": "#6B7280"}),
        ],
        margin=6,
        padding=14,
        borderRadius=16,
        elevation=0,
        color=tint,
    )


def _metric_row(items: list[tuple[str, str, str, str, str]]) -> dict:
    children = []
    for idx, item in enumerate(items):
        if idx:
            children.append(spacer(width=8))
        children.append({"type": "expanded", "child": _metric(*item)})
    return container(children, layout="row", margin=8)


def _chip(label: str, icon_name: str, color: str) -> dict:
    return {"type": "chip", "label": label, "icon": icon_name, "color": color}


def build_smart_home_template() -> dict:
    room_tiles = [
        {"name": "客厅", "device": "灯光 · 空调 · 窗帘", "icon": "home", "accent": "#2563EB", "tint": "#EAF1FF"},
        {"name": "卧室", "device": "睡眠模式 · 加湿器", "icon": "dark_mode", "accent": "#7C3AED", "tint": "#F1EAFF"},
        {"name": "厨房", "device": "烟感 · 净水器", "icon": "warning", "accent": "#D97706", "tint": "#FFF4DE"},
        {"name": "门厅", "device": "门锁 · 摄像头", "icon": "lock", "accent": "#059669", "tint": "#E8F7F0"},
    ]
    app = new_app(
        name="framework-quality-smart-home",
        appid=APPIDS["smart_home"],
        display_name="Framework Smart Home",
        description="框架能力模板：智能家居控制台，展示 switch、slider、grid、progress、chip。",
        variables={
            "awayMode": False,
            "livingLight": True,
            "nightMode": False,
            "brightness": 68,
            "temperature": 24,
            "airQuality": 0.82,
            "roomTiles": room_tiles,
        },
        functions={
            "sync": {"params": [], "logic": [{"call": "@show_toast", "args": {"message": "已同步 12 台设备"}}]},
            "scene": {"params": [], "logic": [{"call": "@show_toast", "args": {"message": "场景已下发"}}]},
        },
    )
    home = screen(
        "home",
        title="全屋控制",
        backgroundColor="#F5F7FA",
        appBar=native_app_bar("全屋控制", actions=[native_action_icon("sync", action=call("@global.sync"), color="#2563EB")]),
        children=[
            _title("晚上好，客厅已进入舒适区", "温度、灯光和安防在同一页完成控制，不需要进入列表详情。"),
            _metric_row(
                [
                    ("在线设备", "12", "wifi", "#2563EB", "#FFFFFF"),
                    ("室温", "{{ global.temperature }}°", "light_mode", "#D97706", "#FFFFFF"),
                    ("空气质量", "82%", "check_circle", "#059669", "#FFFFFF"),
                ]
            ),
            card(
                [
                    container(
                        [
                            text("场景", style={"fontSize": 17, "fontWeight": "bold", "color": "#111827"}),
                            button("一键离家", icon_name="lock", variant="filled", action=call("@global.scene"), style={"backgroundColor": "#111827", "textColor": "#FFFFFF", "borderRadius": 16}),
                        ],
                        layout="row",
                        mainAxisAlignment="spaceBetween",
                        crossAxisAlignment="center",
                    ),
                    spacer(height=10),
                    {"type": "wrap", "spacing": 8, "runSpacing": 8, "children": [_chip("回家", "home", "#EAF1FF"), _chip("观影", "video", "#F1EAFF"), _chip("睡眠", "dark_mode", "#EEF2FF"), _chip("清洁", "refresh", "#E8F7F0")]},
                    spacer(height=14),
                    {"type": "switch", "label": "离家模式", "bind": "global.awayMode"},
                    {"type": "switch", "label": "客厅主灯", "bind": "global.livingLight"},
                    {"type": "switch", "label": "夜间勿扰", "bind": "global.nightMode"},
                    spacer(height=8),
                    text("灯光亮度 {{ global.brightness }}%", style={"fontSize": 14, "color": "#4B5563"}),
                    {"type": "slider", "bind": "global.brightness", "min": 0, "max": 100, "divisions": 20, "color": "#2563EB"},
                    text("目标温度 {{ global.temperature }}°C", style={"fontSize": 14, "color": "#4B5563"}),
                    {"type": "slider", "bind": "global.temperature", "min": 18, "max": 30, "divisions": 12, "color": "#D97706"},
                ],
                margin=12,
                padding=16,
                borderRadius=18,
                elevation=0,
            ),
            card(
                [
                    text("房间状态", style={"fontSize": 17, "fontWeight": "bold", "color": "#111827"}),
                    spacer(height=12),
                    {
                        "type": "grid",
                        "source": "{{ global.roomTiles }}",
                        "crossAxisCount": 2,
                        "spacing": 10,
                        "childAspectRatio": 1.55,
                        "shrinkWrap": True,
                        "item_template": container(
                            [
                                icon("{{ loop.item.icon }}", size=22, color="{{ loop.item.accent }}"),
                                spacer(height=8),
                                text("{{ loop.item.name }}", style={"fontSize": 15, "fontWeight": "bold", "color": "#111827"}),
                                spacer(height=4),
                                text("{{ loop.item.device }}", style={"fontSize": 12, "color": "#6B7280", "maxLines": 1, "overflow": "ellipsis"}),
                            ],
                            layout="column",
                            padding=12,
                            color="{{ loop.item.tint }}",
                            borderRadius=16,
                        ),
                    },
                ],
                margin=12,
                padding=16,
                borderRadius=18,
                elevation=0,
            ),
        ],
    )
    app["ui"]["screens"] = [home]
    return app


def build_ops_dashboard_template() -> dict:
    app = new_app(
        name="framework-quality-ops-dashboard",
        appid=APPIDS["ops_dashboard"],
        display_name="Framework Ops Dashboard",
        description="框架能力模板：运营数据看板，展示 chart、tab_view、dropdown、progress。",
        variables={
            "range": "本周",
            "lineData": [{"x": i, "y": v} for i, v in enumerate([12, 18, 16, 24, 28, 31, 36])],
            "barData": [{"label": label, "value": value} for label, value in [("Mon", 18), ("Tue", 24), ("Wed", 21), ("Thu", 33), ("Fri", 29)]],
            "pieData": [
                {"label": "搜索", "value": 42, "color": "#2563EB"},
                {"label": "推荐", "value": 31, "color": "#059669"},
                {"label": "分享", "value": 18, "color": "#D97706"},
                {"label": "其它", "value": 9, "color": "#7C3AED"},
            ],
        },
        functions={
            "refresh": {"params": [], "logic": [{"call": "@show_toast", "args": {"message": "数据已刷新"}}]},
        },
    )
    home = screen(
        "home",
        title="运营看板",
        backgroundColor="#F6F7FB",
        appBar=native_app_bar("运营看板", actions=[native_action_icon("refresh", action=call("@global.refresh"), color="#2563EB")]),
        children=[
            _title("实时增长概览", "图表和筛选直接使用框架控件，不再伪装成记录列表。"),
            card(
                [
                    text("今日活跃", style={"fontSize": 13, "color": "#6B7280"}),
                    spacer(height=5),
                    text("42,860", style={"fontSize": 32, "fontWeight": "bold", "color": "#111827"}),
                    spacer(height=8),
                    {"type": "dropdown", "bind": "global.range", "options": ["今天", "本周", "本月"], "label": "时间范围", "prefixIcon": "calendar", "color": "#2563EB"},
                    spacer(height=6),
                    {"type": "chart", "kind": "line", "data": "{{ global.lineData }}", "height": 190, "color": "#2563EB"},
                ],
                margin=12,
                padding=16,
                borderRadius=18,
                elevation=0,
            ),
            _metric_row(
                [
                    ("转化率", "12.8%", "analytics", "#059669", "#FFFFFF"),
                    ("客单价", "¥186", "payment", "#D97706", "#FFFFFF"),
                    ("风险工单", "7", "warning", "#DC2626", "#FFFFFF"),
                ]
            ),
            card(
                [
                    {
                        "type": "tab_view",
                        "height": 330,
                        "color": "#2563EB",
                        "tabs": [
                            {
                                "label": "渠道",
                                "icon": "analytics",
                                "content": container(
                                    [
                                        {"type": "chart", "kind": "bar", "data": "{{ global.barData }}", "height": 220, "color": "#2563EB"},
                                        text("周四投放带来峰值，搜索渠道仍是主力。", style={"fontSize": 13, "color": "#6B7280"}),
                                    ],
                                    layout="column",
                                ),
                            },
                            {
                                "label": "来源",
                                "icon": "share",
                                "content": container(
                                    [
                                        {"type": "chart", "kind": "pie", "data": "{{ global.pieData }}", "height": 230},
                                        text("推荐流量质量更稳定，适合加码复购入口。", style={"fontSize": 13, "color": "#6B7280"}),
                                    ],
                                    layout="column",
                                ),
                            },
                        ],
                    }
                ],
                margin=12,
                padding=12,
                borderRadius=18,
                elevation=0,
            ),
        ],
    )
    app["ui"]["screens"] = [home]
    return app


def build_travel_pass_template() -> dict:
    checkpoints = [
        {"time": "08:20", "title": "值机完成", "desc": "2 号航站楼 · B 区安检"},
        {"time": "09:15", "title": "登机口开放", "desc": "Gate 23 · 预计步行 8 分钟"},
        {"time": "10:05", "title": "起飞", "desc": "MU 5107 · 靠窗 12A"},
    ]
    app = new_app(
        name="framework-quality-travel-pass",
        appid=APPIDS["travel_pass"],
        display_name="Framework Travel Pass",
        description="框架能力模板：旅行票证和地图，展示 qr_code、map、timeline 式信息卡。",
        variables={
            "checkpoints": checkpoints,
            "markers": [
                {"latitude": 31.1443, "longitude": 121.8083, "label": "PVG"},
                {"latitude": 31.2304, "longitude": 121.4737, "label": "Hotel"},
            ],
        },
        functions={
            "share": {"params": [], "logic": [{"call": "@show_toast", "args": {"message": "行程卡已准备分享"}}]},
        },
    )
    home = screen(
        "home",
        title="行程卡",
        backgroundColor="#F7F8FA",
        appBar=native_app_bar("行程卡", actions=[native_action_icon("share", action=call("@global.share"), color="#111827")]),
        children=[
            card(
                [
                    container(
                        [
                            container(
                                [
                                    text("上海 PVG", style={"fontSize": 13, "color": "#6B7280"}),
                                    spacer(height=6),
                                    text("10:05", style={"fontSize": 34, "fontWeight": "bold", "color": "#111827"}),
                                    spacer(height=6),
                                    text("MU 5107 · 12A", style={"fontSize": 14, "fontWeight": "600", "color": "#2563EB"}),
                                ],
                                layout="column",
                                position={"type": "flex", "flex": 1},
                            ),
                            container(
                                [{"type": "qr_code", "data": "travel-pass:MU5107:2026-06-02:12A", "size": 116, "color": "#111827"}],
                                width=124,
                                height=124,
                                color="#FFFFFF",
                                borderRadius=16,
                                mainAxisAlignment="center",
                                crossAxisAlignment="center",
                            ),
                        ],
                        layout="row",
                        crossAxisAlignment="center",
                    ),
                    spacer(height=18),
                    {"type": "progress", "value": 0.62, "color": "#2563EB", "backgroundColor": "#E5E7EB", "height": 8},
                    spacer(height=8),
                    text("距登机还有 46 分钟", style={"fontSize": 13, "color": "#6B7280"}),
                ],
                margin=12,
                padding=18,
                borderRadius=24,
                elevation=0,
                color="#FFFFFF",
            ),
            card(
                [
                    text("机场与酒店", style={"fontSize": 17, "fontWeight": "bold", "color": "#111827"}),
                    spacer(height=10),
                    {"type": "map", "latitude": 31.18, "longitude": 121.64, "zoom": 10, "height": 210, "borderRadius": 18, "markers": "{{ global.markers }}"},
                ],
                margin=12,
                padding=14,
                borderRadius=20,
                elevation=0,
            ),
            card(
                [
                    text("时间线", style={"fontSize": 17, "fontWeight": "bold", "color": "#111827"}),
                    spacer(height=10),
                    {
                        "type": "grid",
                        "source": "{{ global.checkpoints }}",
                        "crossAxisCount": 1,
                        "childAspectRatio": 4.2,
                        "spacing": 8,
                        "shrinkWrap": True,
                        "item_template": container(
                            [
                                container([text("{{ loop.item.time }}", style={"fontSize": 13, "fontWeight": "bold", "color": "#2563EB"})], width=54, height=42, color="#EAF1FF", borderRadius=14, mainAxisAlignment="center", crossAxisAlignment="center"),
                                spacer(width=10),
                                container(
                                    [
                                        text("{{ loop.item.title }}", style={"fontSize": 15, "fontWeight": "bold", "color": "#111827"}),
                                        spacer(height=4),
                                        text("{{ loop.item.desc }}", style={"fontSize": 12, "color": "#6B7280"}),
                                    ],
                                    layout="column",
                                    position={"type": "flex", "flex": 1},
                                ),
                            ],
                            layout="row",
                            padding=10,
                            color="#F8FAFC",
                            borderRadius=16,
                        ),
                    },
                ],
                margin=12,
                padding=16,
                borderRadius=20,
                elevation=0,
            ),
        ],
    )
    app["ui"]["screens"] = [home]
    return app


def build_course_player_template() -> dict:
    lessons = [
        {"title": "01 需求拆解", "state": "已完成", "progress": 1.0},
        {"title": "02 交互草图", "state": "播放中", "progress": 0.46},
        {"title": "03 组件验收", "state": "待学习", "progress": 0.0},
    ]
    app = new_app(
        name="framework-quality-course-player",
        appid=APPIDS["course_player"],
        display_name="Framework Course Player",
        description="框架能力模板：视频课程播放器，展示 video、tab_view、checkbox、progress。",
        variables={"lessons": lessons, "notesEnabled": True, "downloadWifi": True},
        functions={
            "mark": {"params": [], "logic": [{"call": "@show_toast", "args": {"message": "已标记本节重点"}}]},
        },
    )
    home = screen(
        "home",
        title="课程",
        backgroundColor="#F5F5F7",
        appBar=native_app_bar("课程", actions=[native_action_icon("bookmark", action=call("@global.mark"), color="#EA580C")]),
        children=[
            card(
                [
                    {"type": "video", "url": "https://demo.unified-streaming.com/k8s/features/stable/video/tears-of-steel/tears-of-steel.ism/.m3u8", "aspectRatio": 1.78, "borderRadius": 16},
                    spacer(height=10),
                    text("产品原型课 · 第 2 节", style={"fontSize": 13, "color": "#6B7280"}),
                    spacer(height=4),
                    text("把交互草图变成可验证流程", style={"fontSize": 20, "fontWeight": "bold", "color": "#111827"}),
                    spacer(height=10),
                    {"type": "progress", "value": 0.46, "color": "#EA580C", "backgroundColor": "#E5E7EB", "height": 8},
                ],
                margin=12,
                padding=14,
                borderRadius=20,
                elevation=0,
            ),
            card(
                [
                    {
                        "type": "tab_view",
                        "height": 360,
                        "color": "#EA580C",
                        "tabs": [
                            {
                                "label": "目录",
                                "icon": "list",
                                "content": container(
                                    [
                                        {
                                            "type": "grid",
                                            "source": "{{ global.lessons }}",
                                            "crossAxisCount": 1,
                                            "childAspectRatio": 4.4,
                                            "spacing": 8,
                                            "shrinkWrap": True,
                                            "item_template": container(
                                                [
                                                    icon("play", size=20, color="#EA580C"),
                                                    spacer(width=10),
                                                    container(
                                                        [
                                                            text("{{ loop.item.title }}", style={"fontSize": 15, "fontWeight": "bold", "color": "#111827"}),
                                                            spacer(height=5),
                                                            text("{{ loop.item.state }}", style={"fontSize": 12, "color": "#6B7280"}),
                                                        ],
                                                        layout="column",
                                                        position={"type": "flex", "flex": 1},
                                                    ),
                                                    text("{{ loop.item.progress }}", style={"fontSize": 12, "color": "#9CA3AF"}),
                                                ],
                                                layout="row",
                                                padding=12,
                                                color="#FFF7ED",
                                                borderRadius=16,
                                                crossAxisAlignment="center",
                                            ),
                                        }
                                    ],
                                    layout="column",
                                ),
                            },
                            {
                                "label": "设置",
                                "icon": "settings",
                                "content": container(
                                    [
                                        {"type": "switch", "label": "显示随堂笔记", "bind": "global.notesEnabled"},
                                        {"type": "switch", "label": "仅 Wi-Fi 自动缓存", "bind": "global.downloadWifi"},
                                        spacer(height=10),
                                        text("本页体现视频、标签页、开关和课程进度，不依赖记录列表结构。", style={"fontSize": 14, "color": "#6B7280", "lineHeight": 1.45}),
                                        spacer(height=12),
                                        button("标记重点", icon_name="bookmark", action=call("@global.mark"), style={"backgroundColor": "#EA580C", "textColor": "#FFFFFF", "borderRadius": 16}),
                                    ],
                                    layout="column",
                                    padding=8,
                                ),
                            },
                        ],
                    }
                ],
                margin=12,
                padding=12,
                borderRadius=20,
                elevation=0,
            ),
        ],
    )
    app["ui"]["screens"] = [home]
    return app


def build_camera_inspection_template() -> dict:
    checks = [
        {"label": "标签清晰", "ok": True},
        {"label": "封口完整", "ok": True},
        {"label": "批次匹配", "ok": False},
    ]
    app = new_app(
        name="framework-quality-camera-inspection",
        appid=APPIDS["camera_inspection"],
        display_name="Framework Camera Inspection",
        description="框架能力模板：现场拍照检测，展示 image_picker(camera)、badge、checkbox、progress。",
        variables={"photoPath": "", "checks": checks, "autoEnhance": True, "geoTag": True, "score": 0.78},
        functions={
            "submit": {"params": [], "logic": [{"call": "@show_toast", "args": {"message": "检测报告已提交"}}]},
        },
    )
    home = screen(
        "home",
        title="现场检测",
        backgroundColor="#F3F7F6",
        appBar=native_app_bar("现场检测", actions=[native_action_icon("send", action=call("@global.submit"), color="#0F766E")]),
        children=[
            _title("包装质检", "拍照、打勾、提交，体现移动端采集类应用，而不是表单记录页。"),
            card(
                [
                    {
                        "type": "badge",
                        "label": "待提交",
                        "color": "#DC2626",
                        "textColor": "#FFFFFF",
                        "child": {"type": "image_picker", "source": "camera", "bind": "global.photoPath", "placeholder": "点击拍摄包装正面", "height": 220, "borderRadius": 18},
                    },
                    spacer(height=12),
                    container(
                        [
                            text("AI 预检分", style={"fontSize": 13, "color": "#6B7280"}),
                            text("78", style={"fontSize": 32, "fontWeight": "bold", "color": "#0F766E"}),
                            text("/100", style={"fontSize": 13, "color": "#9CA3AF"}),
                        ],
                        layout="row",
                        crossAxisAlignment="end",
                    ),
                    {"type": "progress", "value": "{{ global.score }}", "color": "#0F766E", "backgroundColor": "#DDE7E4", "height": 8},
                ],
                margin=12,
                padding=14,
                borderRadius=20,
                elevation=0,
            ),
            card(
                [
                    text("采集选项", style={"fontSize": 17, "fontWeight": "bold", "color": "#111827"}),
                    spacer(height=8),
                    {"type": "switch", "label": "自动增强图片", "bind": "global.autoEnhance"},
                    {"type": "switch", "label": "写入定位标签", "bind": "global.geoTag"},
                    spacer(height=6),
                    text("质检项", style={"fontSize": 15, "fontWeight": "bold", "color": "#111827"}),
                    spacer(height=8),
                    {
                        "type": "grid",
                        "source": "{{ global.checks }}",
                        "crossAxisCount": 1,
                        "childAspectRatio": 6.2,
                        "spacing": 8,
                        "shrinkWrap": True,
                        "item_template": container(
                            [
                                icon("check_circle", size=20, color="#0F766E"),
                                spacer(width=10),
                                text("{{ loop.item.label }}", position={"type": "flex", "flex": 1}, style={"fontSize": 15, "fontWeight": "600", "color": "#111827"}),
                                {"type": "checkbox", "bind": "loop.item.ok"},
                            ],
                            layout="row",
                            padding=10,
                            color="#EEF7F4",
                            borderRadius=14,
                            crossAxisAlignment="center",
                        ),
                    },
                    spacer(height=12),
                    button("提交检测", icon_name="send", action=call("@global.submit"), style={"backgroundColor": "#0F766E", "textColor": "#FFFFFF", "borderRadius": 16}),
                ],
                margin=12,
                padding=16,
                borderRadius=20,
                elevation=0,
            ),
        ],
    )
    app["ui"]["screens"] = [home]
    return app


def main() -> int:
    targets = {
        ROOT / "templates/framework_quality_smart_home.json": build_smart_home_template(),
        ROOT / "templates/framework_quality_ops_dashboard.json": build_ops_dashboard_template(),
        ROOT / "templates/framework_quality_travel_pass.json": build_travel_pass_template(),
        ROOT / "templates/framework_quality_course_player.json": build_course_player_template(),
        ROOT / "templates/framework_quality_camera_inspection.json": build_camera_inspection_template(),
    }
    for path, app in targets.items():
        save_json(app, path)
        print(path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
