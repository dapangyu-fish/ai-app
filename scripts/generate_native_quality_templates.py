#!/usr/bin/env python3
"""Generate high-quality JSON-native app templates.

These templates are deliberately designed like compact Flutter/Material apps,
then expressed with the JSON-DSL helper primitives. They are examples for the
AI generator to copy structure from; they are not marketplace seed data.
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
    native_crud_app_shell,
    new_app,
    save_json,
    screen,
    spacer,
    text,
)

APPIDS = {
    "notes": "370e919b-c51d-4cdd-8b3d-87063c666076",
    "crm": "5ef21f4d-cffa-4b8a-bc41-66375a76ac07",
    "budget": "008b3ccc-c8f3-4382-985c-e1de89621497",
    "habits": "e1c49e4f-ddf8-411c-b7f1-3f9cd8b784e5",
    "workout": "84a2ebef-2c02-4730-afbf-4f9193d758c3",
}


def note_item_template() -> dict:
    return card(
        [
            container(
                [
                    container(
                        [icon("file", size=20, color="{{ loop.item.accent }}")],
                        layout="column",
                        width=42,
                        height=42,
                        color="{{ loop.item.tint }}",
                        borderRadius=12,
                        mainAxisAlignment="center",
                        crossAxisAlignment="center",
                    ),
                    spacer(width=12),
                    container(
                        [
                            container(
                                [
                                    text(
                                        "{{ loop.item.title }}",
                                        position={"type": "flex", "flex": 1},
                                        style={
                                            "fontSize": 16,
                                            "fontWeight": "bold",
                                            "color": "#111827",
                                            "maxLines": 1,
                                            "overflow": "ellipsis",
                                        },
                                    ),
                                    text(
                                        "{{ loop.item.date }}",
                                        style={"fontSize": 12, "color": "#9CA3AF"},
                                    ),
                                ],
                                layout="row",
                                crossAxisAlignment="center",
                            ),
                            spacer(height=6),
                            text(
                                "{{ loop.item.excerpt }}",
                                style={
                                    "fontSize": 13,
                                    "color": "#6B7280",
                                    "lineHeight": 1.35,
                                    "maxLines": 2,
                                    "overflow": "ellipsis",
                                },
                            ),
                            spacer(height=10),
                            container(
                                [
                                    container(
                                        [
                                            text(
                                                "{{ loop.item.tag }}",
                                                style={
                                                    "fontSize": 12,
                                                    "fontWeight": "600",
                                                    "color": "{{ loop.item.accent }}",
                                                    "paddingH": 2,
                                                    "paddingV": 0,
                                                },
                                            )
                                        ],
                                        padding=6,
                                        color="{{ loop.item.tint }}",
                                        borderRadius=12,
                                    ),
                                    spacer(width=8),
                                    icon("check_circle", size=15, color="#10B981"),
                                    spacer(width=4),
                                    text("已同步", style={"fontSize": 12, "color": "#9CA3AF"}),
                                ],
                                layout="row",
                                crossAxisAlignment="center",
                            ),
                        ],
                        layout="column",
                        position={"type": "flex", "flex": 1},
                    ),
                ],
                layout="row",
                crossAxisAlignment="start",
            )
        ],
        margin=8,
        padding=14,
        elevation=0,
        borderRadius=16,
        onTap=call(
            "@global.viewNote",
            title="{{ loop.item.title }}",
            tag="{{ loop.item.tag }}",
            date="{{ loop.item.date }}",
            content="{{ loop.item.content }}",
            accent="{{ loop.item.accent }}",
            tint="{{ loop.item.tint }}",
        ),
    )


def build_notes_template() -> dict:
    notes = [
        {
            "id": "n1",
            "title": "产品想法整理",
            "tag": "工作",
            "date": "今天 09:30",
            "excerpt": "把待验证的功能拆成三组：核心流程、付费触点、次要体验。",
            "content": "把待验证的功能拆成三组：核心流程、付费触点、次要体验。\n\n下次评审前需要补齐用户路径截图和失败状态。",
            "accent": "#2563EB",
            "tint": "#EAF1FF",
        },
        {
            "id": "n2",
            "title": "周末阅读清单",
            "tag": "生活",
            "date": "昨天",
            "excerpt": "系统设计、交互心理学、一本短篇小说。控制在 3 小时内。",
            "content": "系统设计、交互心理学、一本短篇小说。控制在 3 小时内。\n\n读完只记录能落到实践里的结论。",
            "accent": "#059669",
            "tint": "#E8F7F0",
        },
        {
            "id": "n3",
            "title": "旅行备忘",
            "tag": "灵感",
            "date": "5月28日",
            "excerpt": "证件、充电器、降噪耳机、备用银行卡。出发前一天再检查。",
            "content": "证件、充电器、降噪耳机、备用银行卡。出发前一天再检查。\n\n酒店确认邮件和路线截图都放到同一个文件夹。",
            "accent": "#D97706",
            "tint": "#FFF4DE",
        },
    ]
    app = new_app(
        name="native-quality-notes",
        appid=APPIDS["notes"],
        display_name="Native Notes Template",
        description="高质量原生记录类 APP JSON 模板：摘要、搜索、筛选、列表、详情、表单。",
        dependencies={},
        variables={
            "searchQuery": "",
            "selectedTag": "全部",
            "notes": notes,
            "currentTitle": "",
            "currentTag": "",
            "currentDate": "",
            "currentContent": "",
            "currentAccent": "#2563EB",
            "currentTint": "#EAF1FF",
            "formTitle": "",
            "formContent": "",
            "formTag": "工作",
        },
        functions={
            "startCreate": {
                "params": [],
                "logic": [
                    {"call": "@set", "args": {"var": "global.formTitle", "value": ""}},
                    {"call": "@set", "args": {"var": "global.formContent", "value": ""}},
                    {"call": "@navigate", "args": {"screen": "note_form"}},
                ],
            },
            "viewNote": {
                "params": ["title", "tag", "date", "content", "accent", "tint"],
                "logic": [
                    {"call": "@set", "args": {"var": "global.currentTitle", "value": "{{ params.title }}"}},
                    {"call": "@set", "args": {"var": "global.currentTag", "value": "{{ params.tag }}"}},
                    {"call": "@set", "args": {"var": "global.currentDate", "value": "{{ params.date }}"}},
                    {"call": "@set", "args": {"var": "global.currentContent", "value": "{{ params.content }}"}},
                    {"call": "@set", "args": {"var": "global.currentAccent", "value": "{{ params.accent }}"}},
                    {"call": "@set", "args": {"var": "global.currentTint", "value": "{{ params.tint }}"}},
                    {"call": "@navigate", "args": {"screen": "note_detail"}},
                ],
            },
            "saveDraft": {
                "params": [],
                "logic": [
                    {"call": "@show_toast", "args": {"message": "模板示例：这里接入保存逻辑"}},
                    {"call": "@navigate", "args": {"screen": "home"}},
                ],
            },
        },
    )

    home = native_crud_app_shell(
        screen_id="home",
        title="笔记",
        accent="#2563EB",
        list_source="{{ global.notes }}",
        item_template=note_item_template(),
        metrics=[
            {"label": "全部笔记", "value": "24", "icon": "file", "accent": "#2563EB"},
            {"label": "置顶", "value": "3", "icon": "star", "accent": "#F59E0B"},
            {"label": "本周新增", "value": "8", "icon": "calendar", "accent": "#10B981"},
        ],
        search_bind="global.searchQuery",
        search_placeholder="搜索标题、内容、标签",
        filters=[("全部", "全部"), ("工作", "工作"), ("生活", "生活"), ("灵感", "灵感")],
        filter_bind="global.selectedTag",
        primary_action=call("@global.startCreate"),
        primary_icon="add",
        primary_label="新建笔记",
        empty_text="暂无笔记，先创建第一条记录",
        background="#F4F6F8",
    )

    detail = screen(
        "note_detail",
        title="笔记详情",
        backgroundColor="#F4F6F8",
        appBar=native_app_bar(
            "笔记详情",
            actions=[native_action_icon("edit", action=call("@global.startCreate"), color="#2563EB")],
        ),
        children=[
            card(
                [
                    container(
                        [
                            container(
                                [icon("file", size=24, color="{{ global.currentAccent }}")],
                                width=48,
                                height=48,
                                color="{{ global.currentTint }}",
                                borderRadius=14,
                                mainAxisAlignment="center",
                                crossAxisAlignment="center",
                            ),
                            spacer(width=12),
                            container(
                                [
                                    text(
                                        "{{ global.currentTitle }}",
                                        style={"fontSize": 22, "fontWeight": "bold", "color": "#111827"},
                                    ),
                                    spacer(height=4),
                                    text(
                                        "{{ global.currentTag }} · {{ global.currentDate }}",
                                        style={"fontSize": 13, "color": "#6B7280"},
                                    ),
                                ],
                                position={"type": "flex", "flex": 1},
                            ),
                        ],
                        layout="row",
                        crossAxisAlignment="center",
                    ),
                    spacer(height=18),
                    text(
                        "{{ global.currentContent }}",
                        style={"fontSize": 16, "color": "#374151", "lineHeight": 1.65},
                    ),
                ],
                margin=12,
                padding=18,
                borderRadius=18,
            )
        ],
    )

    form = screen(
        "note_form",
        title="编辑笔记",
        backgroundColor="#F4F6F8",
        appBar=native_app_bar("编辑笔记"),
        children=[
            card(
                [
                    text("标题", style={"fontSize": 14, "fontWeight": "600", "color": "#374151"}),
                    spacer(height=8),
                    {"type": "input", "placeholder": "输入笔记标题", "bind": "global.formTitle"},
                    spacer(height=16),
                    text("内容", style={"fontSize": 14, "fontWeight": "600", "color": "#374151"}),
                    spacer(height=8),
                    {"type": "input", "placeholder": "记录想法、任务或灵感", "bind": "global.formContent", "maxLines": 8},
                    spacer(height=18),
                    button(
                        "保存",
                        icon_name="save",
                        action=call("@global.saveDraft"),
                        style={"backgroundColor": "#2563EB", "textColor": "#FFFFFF", "borderRadius": 14},
                    ),
                ],
                margin=12,
                padding=18,
                borderRadius=18,
            )
        ],
    )
    app["ui"]["screens"] = [home, detail, form]
    return app


def crm_item_template() -> dict:
    return card(
        [
            container(
                [
                    {"type": "avatar", "text": "{{ loop.item.initial }}", "size": 46, "color": "{{ loop.item.tint }}", "textColor": "{{ loop.item.accent }}"},
                    spacer(width=12),
                    container(
                        [
                            text(
                                "{{ loop.item.name }}",
                                style={
                                    "fontSize": 16,
                                    "fontWeight": "bold",
                                    "color": "#111827",
                                    "maxLines": 1,
                                    "overflow": "ellipsis",
                                },
                            ),
                            spacer(height=5),
                            text(
                                "{{ loop.item.status }} · {{ loop.item.company }} · {{ loop.item.phone }}",
                                style={"fontSize": 13, "color": "#6B7280", "maxLines": 1, "overflow": "ellipsis"},
                            ),
                            spacer(height=8),
                            container(
                                [
                                    icon("calendar", size=15, color="#9CA3AF"),
                                    spacer(width=5),
                                    text("{{ loop.item.nextStep }}", style={"fontSize": 13, "color": "#4B5563"}),
                                ],
                                layout="row",
                                crossAxisAlignment="center",
                            ),
                        ],
                        layout="column",
                        position={"type": "flex", "flex": 1},
                    ),
                ],
                layout="row",
                crossAxisAlignment="start",
            )
        ],
        margin=8,
        padding=14,
        borderRadius=16,
        elevation=0,
        onTap=call(
            "@global.viewCustomer",
            customerName="{{ loop.item.name }}",
            company="{{ loop.item.company }}",
            phone="{{ loop.item.phone }}",
            status="{{ loop.item.status }}",
            nextStep="{{ loop.item.nextStep }}",
            note="{{ loop.item.note }}",
            accent="{{ loop.item.accent }}",
            tint="{{ loop.item.tint }}",
        ),
    )


def build_crm_template() -> dict:
    customers = [
        {
            "id": "c1",
            "name": "林青",
            "initial": "林",
            "company": "北辰科技",
            "phone": "138 0000 1201",
            "status": "待跟进",
            "nextStep": "明天 10:00 回访预算",
            "note": "关注部署周期和售后响应，希望本周拿到报价。",
            "accent": "#2563EB",
            "tint": "#EAF1FF",
        },
        {
            "id": "c2",
            "name": "周远",
            "initial": "周",
            "company": "恒泰贸易",
            "phone": "139 0000 2302",
            "status": "洽谈中",
            "nextStep": "周五发送试用账号",
            "note": "团队 12 人，核心诉求是移动端审批和客户数据沉淀。",
            "accent": "#D97706",
            "tint": "#FFF4DE",
        },
        {
            "id": "c3",
            "name": "陈白",
            "initial": "陈",
            "company": "云谷设计",
            "phone": "137 0000 4503",
            "status": "已成交",
            "nextStep": "下月复盘续费计划",
            "note": "已完成首单，后续可能扩展到第二部门。",
            "accent": "#059669",
            "tint": "#E8F7F0",
        },
    ]
    app = new_app(
        name="native-quality-crm",
        appid=APPIDS["crm"],
        display_name="Native CRM Template",
        description="高质量 CRM/联系人类 JSON 模板：统计、搜索、状态筛选、客户列表、详情、表单。",
        dependencies={},
        variables={
            "searchQuery": "",
            "selectedStatus": "全部",
            "customers": customers,
            "currentName": "",
            "currentCompany": "",
            "currentPhone": "",
            "currentStatus": "",
            "currentNextStep": "",
            "currentNote": "",
            "currentAccent": "#2563EB",
            "currentTint": "#EAF1FF",
            "formName": "",
            "formPhone": "",
            "formCompany": "",
        },
        functions={
            "startCreate": {
                "params": [],
                "logic": [
                    {"call": "@set", "args": {"var": "global.formName", "value": ""}},
                    {"call": "@navigate", "args": {"screen": "customer_form"}},
                ],
            },
            "viewCustomer": {
                "params": ["customerName", "company", "phone", "status", "nextStep", "note", "accent", "tint"],
                "logic": [
                    {"call": "@set", "args": {"var": "global.currentName", "value": "{{ params.customerName }}"}},
                    {"call": "@set", "args": {"var": "global.currentCompany", "value": "{{ params.company }}"}},
                    {"call": "@set", "args": {"var": "global.currentPhone", "value": "{{ params.phone }}"}},
                    {"call": "@set", "args": {"var": "global.currentStatus", "value": "{{ params.status }}"}},
                    {"call": "@set", "args": {"var": "global.currentNextStep", "value": "{{ params.nextStep }}"}},
                    {"call": "@set", "args": {"var": "global.currentNote", "value": "{{ params.note }}"}},
                    {"call": "@set", "args": {"var": "global.currentAccent", "value": "{{ params.accent }}"}},
                    {"call": "@set", "args": {"var": "global.currentTint", "value": "{{ params.tint }}"}},
                    {"call": "@navigate", "args": {"screen": "customer_detail"}},
                ],
            },
            "saveCustomer": {
                "params": [],
                "logic": [
                    {"call": "@show_toast", "args": {"message": "模板示例：这里接入客户保存逻辑"}},
                    {"call": "@navigate", "args": {"screen": "home"}},
                ],
            },
        },
    )
    home = native_crud_app_shell(
        screen_id="home",
        title="客户",
        accent="#2563EB",
        list_source="{{ global.customers }}",
        item_template=crm_item_template(),
        metrics=[
            {"label": "客户总数", "value": "128", "icon": "people", "accent": "#2563EB"},
            {"label": "待跟进", "value": "18", "icon": "clock", "accent": "#D97706"},
            {"label": "已成交", "value": "42", "icon": "check_circle", "accent": "#059669"},
        ],
        search_bind="global.searchQuery",
        search_placeholder="搜索姓名、公司、电话",
        filters=[("全部", "全部"), ("待跟进", "待跟进"), ("洽谈中", "洽谈中"), ("已成交", "已成交")],
        filter_bind="global.selectedStatus",
        primary_action=call("@global.startCreate"),
        primary_icon="add",
        primary_label="新增客户",
        empty_text="暂无客户，先新增第一位客户",
        background="#F4F6F8",
    )
    detail = screen(
        "customer_detail",
        title="客户详情",
        backgroundColor="#F4F6F8",
        appBar=native_app_bar(
            "客户详情",
            actions=[native_action_icon("edit", action=call("@global.startCreate"), color="#2563EB")],
        ),
        children=[
            card(
                [
                    container(
                        [
                            {"type": "avatar", "text": "{{ global.currentName }}", "size": 56, "color": "{{ global.currentTint }}", "textColor": "{{ global.currentAccent }}"},
                            spacer(width=14),
                            container(
                                [
                                    text("{{ global.currentName }}", style={"fontSize": 23, "fontWeight": "bold", "color": "#111827"}),
                                    spacer(height=4),
                                    text("{{ global.currentCompany }}", style={"fontSize": 14, "color": "#6B7280"}),
                                ],
                                position={"type": "flex", "flex": 1},
                            ),
                        ],
                        layout="row",
                        crossAxisAlignment="center",
                    ),
                    spacer(height=18),
                    container(
                        [
                            icon("phone", size=18, color="#2563EB"),
                            spacer(width=8),
                            text("{{ global.currentPhone }}", style={"fontSize": 15, "color": "#374151"}),
                        ],
                        layout="row",
                    ),
                    spacer(height=12),
                    container(
                        [
                            icon("calendar", size=18, color="#D97706"),
                            spacer(width=8),
                            text("{{ global.currentNextStep }}", style={"fontSize": 15, "color": "#374151"}),
                        ],
                        layout="row",
                    ),
                    spacer(height=16),
                    text("{{ global.currentNote }}", style={"fontSize": 15, "color": "#4B5563", "lineHeight": 1.5}),
                ],
                margin=12,
                padding=18,
                borderRadius=18,
            )
        ],
    )
    form = screen(
        "customer_form",
        title="编辑客户",
        backgroundColor="#F4F6F8",
        appBar=native_app_bar("编辑客户"),
        children=[
            card(
                [
                    text("姓名", style={"fontSize": 14, "fontWeight": "600", "color": "#374151"}),
                    spacer(height=8),
                    {"type": "input", "placeholder": "客户姓名", "bind": "global.formName"},
                    spacer(height=16),
                    text("电话", style={"fontSize": 14, "fontWeight": "600", "color": "#374151"}),
                    spacer(height=8),
                    {"type": "input", "placeholder": "手机号或座机", "bind": "global.formPhone"},
                    spacer(height=16),
                    text("公司", style={"fontSize": 14, "fontWeight": "600", "color": "#374151"}),
                    spacer(height=8),
                    {"type": "input", "placeholder": "公司名称", "bind": "global.formCompany"},
                    spacer(height=18),
                    button(
                        "保存客户",
                        icon_name="save",
                        action=call("@global.saveCustomer"),
                        style={"backgroundColor": "#2563EB", "textColor": "#FFFFFF", "borderRadius": 14},
                    ),
                ],
                margin=12,
                padding=18,
                borderRadius=18,
            )
        ],
    )
    app["ui"]["screens"] = [home, detail, form]
    return app


def budget_item_template() -> dict:
    return card(
        [
            container(
                [
                    container(
                        [icon("receipt", size=20, color="{{ loop.item.accent }}")],
                        width=42,
                        height=42,
                        color="{{ loop.item.tint }}",
                        borderRadius=12,
                        mainAxisAlignment="center",
                        crossAxisAlignment="center",
                    ),
                    spacer(width=12),
                    container(
                        [
                            container(
                                [
                                    text(
                                        "{{ loop.item.title }}",
                                        position={"type": "flex", "flex": 1},
                                        style={
                                            "fontSize": 16,
                                            "fontWeight": "bold",
                                            "color": "#111827",
                                            "maxLines": 1,
                                            "overflow": "ellipsis",
                                        },
                                    ),
                                    text(
                                        "{{ loop.item.amount }}",
                                        style={
                                            "fontSize": 17,
                                            "fontWeight": "bold",
                                            "color": "{{ loop.item.accent }}",
                                        },
                                    ),
                                ],
                                layout="row",
                                crossAxisAlignment="center",
                            ),
                            spacer(height=5),
                            text(
                                "{{ loop.item.category }} · {{ loop.item.date }}",
                                style={"fontSize": 13, "color": "#6B7280"},
                            ),
                            spacer(height=8),
                            text(
                                "{{ loop.item.note }}",
                                style={
                                    "fontSize": 13,
                                    "color": "#9CA3AF",
                                    "maxLines": 1,
                                    "overflow": "ellipsis",
                                },
                            ),
                        ],
                        layout="column",
                        position={"type": "flex", "flex": 1},
                    ),
                ],
                layout="row",
                crossAxisAlignment="center",
            )
        ],
        margin=8,
        padding=14,
        borderRadius=16,
        onTap=call(
            "@global.viewTxn",
            txnTitle="{{ loop.item.title }}",
            amount="{{ loop.item.amount }}",
            category="{{ loop.item.category }}",
            date="{{ loop.item.date }}",
            note="{{ loop.item.note }}",
            accent="{{ loop.item.accent }}",
            tint="{{ loop.item.tint }}",
        ),
    )


def build_budget_template() -> dict:
    transactions = [
        {
            "id": "b1",
            "title": "午餐",
            "amount": "-¥42",
            "category": "餐饮",
            "date": "今天 12:35",
            "note": "工作日套餐，计入日常支出。",
            "accent": "#DC2626",
            "tint": "#FEECEC",
        },
        {
            "id": "b2",
            "title": "项目尾款",
            "amount": "+¥4,800",
            "category": "收入",
            "date": "今天 09:10",
            "note": "五月第二阶段交付完成。",
            "accent": "#059669",
            "tint": "#E8F7F0",
        },
        {
            "id": "b3",
            "title": "地铁通勤",
            "amount": "-¥8",
            "category": "交通",
            "date": "昨天",
            "note": "往返客户现场。",
            "accent": "#2563EB",
            "tint": "#EAF1FF",
        },
    ]
    app = new_app(
        name="native-quality-budget",
        appid=APPIDS["budget"],
        display_name="Native Budget Template",
        description="高质量预算/记账类 JSON UI 模板：月度摘要、分类筛选、交易列表、详情、表单。",
        variables={
            "searchQuery": "",
            "selectedType": "全部",
            "transactions": transactions,
            "currentTitle": "",
            "currentAmount": "",
            "currentCategory": "",
            "currentDate": "",
            "currentNote": "",
            "currentAccent": "#2563EB",
            "currentTint": "#EAF1FF",
            "formAmount": "",
            "formTitle": "",
        },
        functions={
            "startCreate": {"params": [], "logic": [{"call": "@navigate", "args": {"screen": "budget_form"}}]},
            "viewTxn": {
                "params": ["txnTitle", "amount", "category", "date", "note", "accent", "tint"],
                "logic": [
                    {"call": "@set", "args": {"var": "global.currentTitle", "value": "{{ params.txnTitle }}"}},
                    {"call": "@set", "args": {"var": "global.currentAmount", "value": "{{ params.amount }}"}},
                    {"call": "@set", "args": {"var": "global.currentCategory", "value": "{{ params.category }}"}},
                    {"call": "@set", "args": {"var": "global.currentDate", "value": "{{ params.date }}"}},
                    {"call": "@set", "args": {"var": "global.currentNote", "value": "{{ params.note }}"}},
                    {"call": "@set", "args": {"var": "global.currentAccent", "value": "{{ params.accent }}"}},
                    {"call": "@set", "args": {"var": "global.currentTint", "value": "{{ params.tint }}"}},
                    {"call": "@navigate", "args": {"screen": "budget_detail"}},
                ],
            },
            "saveTxn": {
                "params": [],
                "logic": [
                    {"call": "@show_toast", "args": {"message": "模板示例：这里接入交易保存逻辑"}},
                    {"call": "@navigate", "args": {"screen": "home"}},
                ],
            },
        },
    )
    home = native_crud_app_shell(
        screen_id="home",
        title="记账",
        accent="#0F766E",
        list_source="{{ global.transactions }}",
        item_template=budget_item_template(),
        metrics=[
            {"label": "本月支出", "value": "¥3,280", "icon": "receipt", "accent": "#DC2626"},
            {"label": "本月收入", "value": "¥8,900", "icon": "payment", "accent": "#059669"},
            {"label": "结余", "value": "¥5,620", "icon": "analytics", "accent": "#0F766E"},
        ],
        search_bind="global.searchQuery",
        search_placeholder="搜索备注、分类、金额",
        filters=[("全部", "全部"), ("支出", "支出"), ("收入", "收入"), ("餐饮", "餐饮")],
        filter_bind="global.selectedType",
        primary_action=call("@global.startCreate"),
        primary_icon="add",
        primary_label="记一笔",
        empty_text="暂无交易，先记录第一笔收支",
        background="#F3F7F6",
    )
    detail = screen(
        "budget_detail",
        title="交易详情",
        backgroundColor="#F3F7F6",
        appBar=native_app_bar("交易详情"),
        children=[
            card(
                [
                    container(
                        [
                            container(
                                [icon("receipt", size=24, color="{{ global.currentAccent }}")],
                                width=52,
                                height=52,
                                color="{{ global.currentTint }}",
                                borderRadius=16,
                                mainAxisAlignment="center",
                                crossAxisAlignment="center",
                            ),
                            spacer(width=14),
                            container(
                                [
                                    text("{{ global.currentAmount }}", style={"fontSize": 28, "fontWeight": "bold", "color": "{{ global.currentAccent }}"}),
                                    spacer(height=4),
                                    text("{{ global.currentTitle }} · {{ global.currentCategory }}", style={"fontSize": 14, "color": "#6B7280"}),
                                ],
                                position={"type": "flex", "flex": 1},
                            ),
                        ],
                        layout="row",
                        crossAxisAlignment="center",
                    ),
                    spacer(height=18),
                    text("{{ global.currentDate }}", style={"fontSize": 14, "color": "#6B7280"}),
                    spacer(height=10),
                    text("{{ global.currentNote }}", style={"fontSize": 15, "color": "#374151", "lineHeight": 1.5}),
                ],
                margin=12,
                padding=18,
                borderRadius=18,
            )
        ],
    )
    form = screen(
        "budget_form",
        title="记一笔",
        backgroundColor="#F3F7F6",
        appBar=native_app_bar("记一笔"),
        children=[
            card(
                [
                    text("金额", style={"fontSize": 14, "fontWeight": "600", "color": "#374151"}),
                    spacer(height=8),
                    {"type": "input", "placeholder": "0.00", "bind": "global.formAmount", "prefixIcon": "payment"},
                    spacer(height=16),
                    text("说明", style={"fontSize": 14, "fontWeight": "600", "color": "#374151"}),
                    spacer(height=8),
                    {"type": "input", "placeholder": "例如 午餐、地铁、工资", "bind": "global.formTitle"},
                    spacer(height=18),
                    button("保存", icon_name="save", action=call("@global.saveTxn"), style={"backgroundColor": "#0F766E", "textColor": "#FFFFFF", "borderRadius": 14}),
                ],
                margin=12,
                padding=18,
                borderRadius=18,
            )
        ],
    )
    app["ui"]["screens"] = [home, detail, form]
    return app


def habit_item_template() -> dict:
    return card(
        [
            container(
                [
                    container(
                        [icon("check_circle", size=20, color="{{ loop.item.accent }}")],
                        width=42,
                        height=42,
                        color="{{ loop.item.tint }}",
                        borderRadius=12,
                        mainAxisAlignment="center",
                        crossAxisAlignment="center",
                    ),
                    spacer(width=12),
                    container(
                        [
                            text("{{ loop.item.title }}", style={"fontSize": 16, "fontWeight": "bold", "color": "#111827", "maxLines": 1, "overflow": "ellipsis"}),
                            spacer(height=6),
                            text(
                                "{{ loop.item.status }} · 连续 {{ loop.item.streak }} 天 · 本周 {{ loop.item.weekDone }}/7",
                                style={"fontSize": 13, "color": "#6B7280", "maxLines": 1, "overflow": "ellipsis"},
                            ),
                            spacer(height=8),
                            {"type": "progress", "value": "{{ loop.item.progress }}", "color": "{{ loop.item.accent }}", "backgroundColor": "#E5E7EB", "height": 6},
                        ],
                        layout="column",
                        position={"type": "flex", "flex": 1},
                    ),
                ],
                layout="row",
                crossAxisAlignment="center",
            )
        ],
        margin=8,
        padding=14,
        borderRadius=16,
        onTap=call("@global.viewHabit", habitTitle="{{ loop.item.title }}", streak="{{ loop.item.streak }}", status="{{ loop.item.status }}", accent="{{ loop.item.accent }}", tint="{{ loop.item.tint }}"),
    )


def build_habits_template() -> dict:
    habits = [
        {"id": "h1", "title": "晨间拉伸", "status": "已完成", "streak": "18", "weekDone": "6", "progress": 0.86, "accent": "#059669", "tint": "#E8F7F0"},
        {"id": "h2", "title": "阅读 30 分钟", "status": "待打卡", "streak": "9", "weekDone": "4", "progress": 0.57, "accent": "#2563EB", "tint": "#EAF1FF"},
        {"id": "h3", "title": "晚上复盘", "status": "21:30", "streak": "12", "weekDone": "5", "progress": 0.71, "accent": "#7C3AED", "tint": "#F1EAFF"},
    ]
    app = new_app(
        name="native-quality-habits",
        appid=APPIDS["habits"],
        display_name="Native Habits Template",
        description="高质量习惯打卡类 JSON UI 模板：今日进度、习惯列表、详情、表单。",
        variables={"searchQuery": "", "selectedStatus": "全部", "habits": habits, "currentTitle": "", "currentStreak": "", "currentStatus": "", "currentAccent": "#059669", "currentTint": "#E8F7F0", "formTitle": ""},
        functions={
            "startCreate": {"params": [], "logic": [{"call": "@navigate", "args": {"screen": "habit_form"}}]},
            "viewHabit": {
                "params": ["habitTitle", "streak", "status", "accent", "tint"],
                "logic": [
                    {"call": "@set", "args": {"var": "global.currentTitle", "value": "{{ params.habitTitle }}"}},
                    {"call": "@set", "args": {"var": "global.currentStreak", "value": "{{ params.streak }}"}},
                    {"call": "@set", "args": {"var": "global.currentStatus", "value": "{{ params.status }}"}},
                    {"call": "@set", "args": {"var": "global.currentAccent", "value": "{{ params.accent }}"}},
                    {"call": "@set", "args": {"var": "global.currentTint", "value": "{{ params.tint }}"}},
                    {"call": "@navigate", "args": {"screen": "habit_detail"}},
                ],
            },
            "saveHabit": {"params": [], "logic": [{"call": "@show_toast", "args": {"message": "模板示例：这里接入习惯保存逻辑"}}, {"call": "@navigate", "args": {"screen": "home"}}]},
        },
    )
    home = native_crud_app_shell(
        screen_id="home",
        title="习惯",
        accent="#7C3AED",
        list_source="{{ global.habits }}",
        item_template=habit_item_template(),
        metrics=[
            {"label": "今日完成", "value": "5/7", "icon": "check_circle", "accent": "#059669"},
            {"label": "最长连续", "value": "18", "icon": "timeline", "accent": "#7C3AED"},
            {"label": "本周完成率", "value": "76%", "icon": "analytics", "accent": "#2563EB"},
        ],
        search_bind="global.searchQuery",
        search_placeholder="搜索习惯",
        filters=[("全部", "全部"), ("待打卡", "待打卡"), ("已完成", "已完成"), ("晚间", "晚间")],
        filter_bind="global.selectedStatus",
        primary_action=call("@global.startCreate"),
        primary_icon="add",
        primary_label="新增习惯",
        empty_text="暂无习惯，先创建一个可坚持的小目标",
        background="#F6F4FB",
    )
    detail = screen(
        "habit_detail",
        title="习惯详情",
        backgroundColor="#F6F4FB",
        appBar=native_app_bar("习惯详情"),
        children=[
            card(
                [
                    container([icon("check_circle", size=28, color="{{ global.currentAccent }}")], width=58, height=58, color="{{ global.currentTint }}", borderRadius=18, mainAxisAlignment="center", crossAxisAlignment="center"),
                    spacer(height=14),
                    text("{{ global.currentTitle }}", style={"fontSize": 24, "fontWeight": "bold", "color": "#111827"}),
                    spacer(height=8),
                    text("当前状态：{{ global.currentStatus }}", style={"fontSize": 14, "color": "#6B7280"}),
                    spacer(height=14),
                    text("已连续坚持 {{ global.currentStreak }} 天", style={"fontSize": 18, "fontWeight": "bold", "color": "{{ global.currentAccent }}"}),
                ],
                margin=12,
                padding=20,
                borderRadius=18,
                crossAxisAlignment="center",
            )
        ],
    )
    form = screen(
        "habit_form",
        title="编辑习惯",
        backgroundColor="#F6F4FB",
        appBar=native_app_bar("编辑习惯"),
        children=[
            card(
                [
                    text("习惯名称", style={"fontSize": 14, "fontWeight": "600", "color": "#374151"}),
                    spacer(height=8),
                    {"type": "input", "placeholder": "例如 每天步行 20 分钟", "bind": "global.formTitle"},
                    spacer(height=18),
                    button("保存习惯", icon_name="save", action=call("@global.saveHabit"), style={"backgroundColor": "#7C3AED", "textColor": "#FFFFFF", "borderRadius": 14}),
                ],
                margin=12,
                padding=18,
                borderRadius=18,
            )
        ],
    )
    app["ui"]["screens"] = [home, detail, form]
    return app


def workout_item_template() -> dict:
    return card(
        [
            container(
                [
                    container([icon("play", size=20, color="{{ loop.item.accent }}")], width=42, height=42, color="{{ loop.item.tint }}", borderRadius=12, mainAxisAlignment="center", crossAxisAlignment="center"),
                    spacer(width=12),
                    container(
                        [
                            container([
                                text("{{ loop.item.title }}", position={"type": "flex", "flex": 1}, style={"fontSize": 16, "fontWeight": "bold", "color": "#111827", "maxLines": 1, "overflow": "ellipsis"}),
                                text("{{ loop.item.duration }}", style={"fontSize": 13, "color": "#9CA3AF"}),
                            ], layout="row", crossAxisAlignment="center"),
                            spacer(height=6),
                            text("{{ loop.item.summary }}", style={"fontSize": 13, "color": "#6B7280", "maxLines": 2, "overflow": "ellipsis"}),
                            spacer(height=8),
                            container([icon("trophy", size=15, color="#F59E0B"), spacer(width=5), text("{{ loop.item.highlight }}", style={"fontSize": 12, "color": "#6B7280"})], layout="row", crossAxisAlignment="center"),
                        ],
                        layout="column",
                        position={"type": "flex", "flex": 1},
                    ),
                ],
                layout="row",
                crossAxisAlignment="center",
            )
        ],
        margin=8,
        padding=14,
        borderRadius=16,
        onTap=call("@global.viewWorkout", workoutTitle="{{ loop.item.title }}", duration="{{ loop.item.duration }}", summary="{{ loop.item.summary }}", highlight="{{ loop.item.highlight }}", accent="{{ loop.item.accent }}", tint="{{ loop.item.tint }}"),
    )


def build_workout_template() -> dict:
    workouts = [
        {"id": "w1", "title": "上肢力量 A", "duration": "48 分钟", "summary": "卧推 4 组、划船 4 组、肩推 3 组。", "highlight": "卧推 70kg x 5", "accent": "#EA580C", "tint": "#FFF1E8"},
        {"id": "w2", "title": "腿部训练", "duration": "55 分钟", "summary": "深蹲、罗马尼亚硬拉、箭步蹲，重点控制动作节奏。", "highlight": "深蹲 90kg x 3", "accent": "#2563EB", "tint": "#EAF1FF"},
        {"id": "w3", "title": "有氧恢复", "duration": "32 分钟", "summary": "椭圆机中低强度，结束后拉伸 12 分钟。", "highlight": "心率区间 2", "accent": "#059669", "tint": "#E8F7F0"},
    ]
    app = new_app(
        name="native-quality-workout",
        appid=APPIDS["workout"],
        display_name="Native Workout Template",
        description="高质量健身训练类 JSON UI 模板：本周统计、训练列表、详情、记录入口。",
        variables={"searchQuery": "", "selectedType": "全部", "workouts": workouts, "currentTitle": "", "currentDuration": "", "currentSummary": "", "currentHighlight": "", "currentAccent": "#EA580C", "currentTint": "#FFF1E8", "formTitle": ""},
        functions={
            "startCreate": {"params": [], "logic": [{"call": "@navigate", "args": {"screen": "workout_form"}}]},
            "viewWorkout": {
                "params": ["workoutTitle", "duration", "summary", "highlight", "accent", "tint"],
                "logic": [
                    {"call": "@set", "args": {"var": "global.currentTitle", "value": "{{ params.workoutTitle }}"}},
                    {"call": "@set", "args": {"var": "global.currentDuration", "value": "{{ params.duration }}"}},
                    {"call": "@set", "args": {"var": "global.currentSummary", "value": "{{ params.summary }}"}},
                    {"call": "@set", "args": {"var": "global.currentHighlight", "value": "{{ params.highlight }}"}},
                    {"call": "@set", "args": {"var": "global.currentAccent", "value": "{{ params.accent }}"}},
                    {"call": "@set", "args": {"var": "global.currentTint", "value": "{{ params.tint }}"}},
                    {"call": "@navigate", "args": {"screen": "workout_detail"}},
                ],
            },
            "saveWorkout": {"params": [], "logic": [{"call": "@show_toast", "args": {"message": "模板示例：这里接入训练保存逻辑"}}, {"call": "@navigate", "args": {"screen": "home"}}]},
        },
    )
    home = native_crud_app_shell(
        screen_id="home",
        title="训练",
        accent="#EA580C",
        list_source="{{ global.workouts }}",
        item_template=workout_item_template(),
        metrics=[
            {"label": "本周训练", "value": "4", "icon": "calendar", "accent": "#EA580C"},
            {"label": "总组数", "value": "62", "icon": "list", "accent": "#2563EB"},
            {"label": "新纪录", "value": "3", "icon": "trophy", "accent": "#F59E0B"},
        ],
        search_bind="global.searchQuery",
        search_placeholder="搜索训练、动作、重量",
        filters=[("全部", "全部"), ("力量", "力量"), ("有氧", "有氧"), ("恢复", "恢复")],
        filter_bind="global.selectedType",
        primary_action=call("@global.startCreate"),
        primary_icon="add",
        primary_label="记录训练",
        empty_text="暂无训练记录，先完成一次训练",
        background="#F8F5F2",
    )
    detail = screen(
        "workout_detail",
        title="训练详情",
        backgroundColor="#F8F5F2",
        appBar=native_app_bar("训练详情"),
        children=[
            card(
                [
                    container([icon("play", size=28, color="{{ global.currentAccent }}")], width=58, height=58, color="{{ global.currentTint }}", borderRadius=18, mainAxisAlignment="center", crossAxisAlignment="center"),
                    spacer(height=14),
                    text("{{ global.currentTitle }}", style={"fontSize": 24, "fontWeight": "bold", "color": "#111827"}),
                    spacer(height=8),
                    text("{{ global.currentDuration }}", style={"fontSize": 14, "color": "#6B7280"}),
                    spacer(height=16),
                    text("{{ global.currentSummary }}", style={"fontSize": 15, "color": "#374151", "lineHeight": 1.5}),
                    spacer(height=14),
                    container([icon("trophy", size=18, color="#F59E0B"), spacer(width=8), text("{{ global.currentHighlight }}", style={"fontSize": 15, "fontWeight": "600", "color": "#92400E"})], layout="row", crossAxisAlignment="center"),
                ],
                margin=12,
                padding=20,
                borderRadius=18,
                crossAxisAlignment="center",
            )
        ],
    )
    form = screen(
        "workout_form",
        title="记录训练",
        backgroundColor="#F8F5F2",
        appBar=native_app_bar("记录训练"),
        children=[
            card(
                [
                    text("训练名称", style={"fontSize": 14, "fontWeight": "600", "color": "#374151"}),
                    spacer(height=8),
                    {"type": "input", "placeholder": "例如 上肢力量 A", "bind": "global.formTitle"},
                    spacer(height=18),
                    button("保存训练", icon_name="save", action=call("@global.saveWorkout"), style={"backgroundColor": "#EA580C", "textColor": "#FFFFFF", "borderRadius": 14}),
                ],
                margin=12,
                padding=18,
                borderRadius=18,
            )
        ],
    )
    app["ui"]["screens"] = [home, detail, form]
    return app


def main() -> int:
    targets = {
        ROOT / "templates/native_quality_notes.json": build_notes_template(),
        ROOT / "templates/native_quality_crm.json": build_crm_template(),
        ROOT / "templates/native_quality_budget.json": build_budget_template(),
        ROOT / "templates/native_quality_habits.json": build_habits_template(),
        ROOT / "templates/native_quality_workout.json": build_workout_template(),
    }
    for path, app in targets.items():
        save_json(app, path)
        print(path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
