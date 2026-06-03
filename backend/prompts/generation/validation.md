# 生成、修复、校验、上传

本文件是所有类型都必须遵守的硬闸。不要因为赶时间跳过。

## 工作目录

后端通常已设置 `AI_APP_WORKSPACE`。如果没有，自己创建：

```bash
WORKDIR="${AI_APP_WORKSPACE:-$(mktemp -d /tmp/ai-workspaces/session.XXXXXX)}"
mkdir -p "$WORKDIR"
TMPFILE="$WORKDIR/app.json"
echo "WORKDIR=$WORKDIR"
echo "TMPFILE=$TMPFILE"
```

所有生成器、manifest、下载图片、校验日志、JSON 都放在 `$WORKDIR`。禁止固定路径 `/tmp/app.json`。

## 复杂 JSON 必须用生成器

满足任一条件时，写 `$WORKDIR/generate_app.py` 生成 `$TMPFILE`：

- 超过约 30 个 widget/entity/action。
- 有重复列表、表单字段、关卡、实体、地图、素材选择。
- `flame_game`、tiled map、关卡、sprite、asset manifest。
- 需要使用 `json_app_builder.py` helper。

标准命令：

```bash
python3 "$WORKDIR/generate_app.py" "$TMPFILE"
python3 -m json.tool "$TMPFILE" > /dev/null
python3 backend/repair_json_app.py "$TMPFILE"
python3 backend/validate_json_app.py "$TMPFILE"
```

生成器导入项目 helper 时，不要假设当前目录一定是项目根目录。统一写：

```python
import os
import sys

PROJECT_ROOT = os.environ.get("AI_APP_PROJECT_ROOT") or os.getcwd()
sys.path.insert(0, os.path.join(PROJECT_ROOT, "backend"))
```

## 必跑校验

上传前必须按顺序跑：

```bash
python3 -m json.tool "$TMPFILE" > /dev/null
python3 backend/repair_json_app.py "$TMPFILE"
python3 backend/validate_json_app.py "$TMPFILE"
```

规则：

- `json.tool` 失败：先修 JSON 语法。
- `validate_json_app.py` 出现 `ERROR`：必须按路径修复，重新从 `json.tool` 开始。
- `WARN`：新生成 APP 尽量修复；只有兼容旧 APP 的修复场景才可保留。
- 最终回复前，最后一次 validator 必须无 `ERROR`。
- 如果大量重复机械错误（`body`、`marginTop`、container `style`、padding/margin dict），写递归清理脚本或运行 `repair_json_app.py`，不要逐条手改到漏项。

## 高频禁忌字段

生成前后都要避免：

- 顶层不能用 `entry`、`pages`；页面必须在 `ui.screens`。
- screen/tab 内容必须用 `children`，不要用 Flutter/React 的 `body`。
- `children` 必须永远是数组，哪怕只有一个子控件也写 `"children": [{...}]`。不要写 `"children": {...}`；只有 `center`、`padding`、`align`、`expanded` 等单子控件 wrapper 才写 `child: {...}`。
- container 没有 `style`；样式字段直接平铺。
- 禁止 `transform`、`transition`、`shadow`、`marginTop`、`marginBottom`、`marginLeft`、`marginRight`。
- `margin`、`padding`、`height`、`width`、`fontSize`、`borderRadius`、`elevation`、`flex` 必须是数字标量，不能是 dict/string/template。
- list 的 `source` 必须是 `"{{ global.xxx }}"` 这种字符串；排序、过滤在 logic 层做完再绑定。
- 长页面必须能滚到底：普通 full-height `list`/非 `shrinkWrap` `grid` 只能作为 screen/tab 的主滚动区域直接放在 `children` 中；嵌入详情页/仪表盘的短列表、最近记录、预览网格必须写 `"shrinkWrap": true`。
- 新 button action 推荐 `{ "call": "@global.xxx", "args": {} }`，不要写冗余 `"type": "call"`。
- JsonLogic 使用标准单 key 形状，例如 `{ "if": [cond, a, b] }`、`{ "+": [1, 2] }`。不要写 `{ "op": "if", "args": [...] }`。
- `text.value`、`label`、`title`、`subtitle`、`emptyText` 等展示字段必须是字符串或 `{{ global.xxx }}` 插值。不要把 JsonLogic Map/List 直接放进去；需要动态文案时先在 action/global 函数里写入 `global.xxxLabel`，再显示 `{{ global.xxxLabel }}`。
- 模板只能作为 DSL/API 参考，不能整套换壳。IM/社交类尤其不能复用 `demo_im` 的 tab 结构、页面 id、函数名集合、通讯录静态行和视觉样式。

## action / widget 检查

如果不确定某个组件或 action 是否存在：

- action 查 `lib/json_ui/interpreter.dart` 中 `case '@xxx':`
- widget 查 `lib/json_ui/widget_builder.dart` 中 `_builders`
- widget 字段查 `lib/json_ui/widgets/` 下对应 Dart 文件
- 图标名查 `lib/json_ui/widgets/icon_registry.dart`；未知静态图标会显示红色问号并触发 validator `ERROR`。

不要自创函数、属性或控件类型。

## 上传

只有 validator 无 `ERROR` 后才能上传：

```bash
bash backend/upload_with_signature.sh "$TMPFILE"
```

脚本成功后会自动写入 `$AI_APP_WORKSPACE/client_actions.json`。在有上传密钥的环境中形状如下：

```json
{"client_actions":[{"type":"json_app_ready","url":"https://..."}]}
```

这是结构化客户端动作文件，不是聊天文本。隔离运行时没有上传密钥时，脚本会写入后端代上传动作，后端会转换成客户端可用的 `json_app_ready`。最终回答只用自然语言说明已生成/已修复，禁止输出 `[json_app_url]` 标签。

## 发布禁令

聊天生成模式下禁止自动发布到商店。不要调用：

- `publish_script.py`
- `/api/store/publish`
- 任何 publish 相关 curl

只有用户明确说“发布/上架/publish”时才处理发布。
