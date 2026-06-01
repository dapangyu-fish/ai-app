# 当前应用分析与修复

适用：用户说“当前应用 / 这个应用 / 我的应用 / 修改这个 APP / 修复这个问题 / 看看为什么按钮点不动”等。

## 先取得 JSON

如果用户没有提供 `[json_app_url]...[/json_app_url]` 或直接 JSON URL，先回复：

```text
我需要先查看当前应用的配置代码。[request_action]upload_current_app[/request_action]
```

不要猜当前 APP 的内容。用户可能已经切换 APP。

## 下载

用户提供 URL 后，用 `curl` 下载到本轮工作目录：

```bash
WORKDIR="${AI_APP_WORKSPACE:-$(mktemp -d /tmp/ai-workspaces/current.XXXXXX)}"
mkdir -p "$WORKDIR"
TARGET="$WORKDIR/current_app.json"
echo "WORKDIR=$WORKDIR"
echo "DOWNLOAD_TO=$TARGET"
curl -sS --max-time 30 -o "$TARGET" "<完整URL，从 [json_app_url]…[/json_app_url] 标签里取出>"
python3 -m json.tool "$TARGET" > /dev/null
```

严格禁止：

- 不要用 `WebFetch` 读取签名 OSS URL。
- 不要用 `wget`。
- 不要写死 `/tmp/current_app.json`。
- 不要拆开 URL；`?` 和 `&` 必须保留，整个 URL 用双引号包裹。

## 分析方式

- 先读下载的 JSON。
- 按用户报告的问题定位对应 screen/function/action/global variable。
- 只查必要源码或模板，不要重新全仓库探索。
- 修复后另存为 `$AI_APP_WORKSPACE/app.json`，不要覆盖原始下载文件，除非只是临时测试。

## 修改后

必须走通用校验和上传：

```bash
TMPFILE="$AI_APP_WORKSPACE/app.json"
python3 -m json.tool "$TMPFILE" > /dev/null
python3 backend/repair_json_app.py "$TMPFILE"
python3 backend/validate_json_app.py "$TMPFILE"
bash backend/upload_with_signature.sh "$TMPFILE"
```

返回 `[json_app_url]完整URL[/json_app_url]`。
