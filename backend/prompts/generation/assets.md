# 视觉素材与 Asset Manifest

适用：游戏、角色动画、地图、背景、图标化界面、可视化玩具，以及用户明确要求图片素材的 APP。

## 总原则

- 优先使用已托管到 OSS 的 CC0 asset packs。
- 始终以线上总 manifest 为准，不要凭记忆写 URL。
- JSON 中资源 URL 必须来自本次读取的 manifest `files[].url` 原样值。
- 不要热链第三方官网，不要手拼 OSS URL。
- 暂时不要加音效，除非用户明确要求。

## 总索引

先读总 manifest：

```bash
ASSET_MANIFEST_BASE="${MINIO_PUBLIC_URL:-https://myapp-oss-endpoint.dapangyu.work}"
curl -fsSL "$ASSET_MANIFEST_BASE/json-app-assets/asset-packs/manifest.json" | jq '.packs[] | {slug, version, tags, manifestUrl}'
```

根据 `tags` 选 1 个主素材包。除非用户明确要求混搭，否则不要混用多个美术风格。

## 读取包 manifest

```bash
curl -fsSL "<manifestUrl>" | jq -r '.files[] | select((.type|startswith("image/")) and (.tags|index("player"))) | [.path,.url] | @tsv' | head
```

manifest 可能包含：

- `files[].image.width/height`
- `files[].sprite.kind/frameWidth/frameHeight/columns/rows/frames`
- `files[].atlas.entries[]`

优先使用这些结构化元数据。

## sprite / sheet 规则

- 文件名包含 `SpriteSheet`、`spritesheet`、`sheet`、`strip`、`sliced`、`tileset`，或图片明显包含多姿态，默认按多帧资源处理。
- 多帧资源必须先读 `files[].sprite` 或 `files[].atlas`，再用 `animated_sprite`、`frame_size`、`frames`、`frames_per_row` 或显式 `src` 裁剪。
- 无法确认帧网格时，换用 manifest 中明确的单帧素材。
- 单帧 PNG 的 `frame_size` 必须等于 `files[].image.width/height`。
- 如果 manifest 缺尺寸，可以临时下载候选图片到 `$AI_APP_WORKSPACE`，用脚本读取宽高；不要凭文件名猜 32/48/64。

## 透明边界校验

如果只能临时推断 sprite 网格，必须跑：

```bash
python3 backend/validate_json_app.py "$TMPFILE"
```

如果 validator 报 `declared sprite grid cuts through opaque pixels`，说明切片边界穿过角色/敌人身体，不能上传。换素材或修正 atlas。

## assets.bundles

使用素材包时，在顶层声明 bundle，方便客户端缓存：

```json
"assets": {
  "bundles": {
    "kenney_new_platformer": {
      "baseUrl": "<manifest files[].url 的公共前缀，例如 https://myapp-oss-endpoint.dapangyu.work/json-app-assets/asset-packs/kenney-new-platformer-pack/1.1/>",
      "manifest": "manifest.json",
      "license": "LICENSE",
      "startupDownload": true
    }
  }
}
```

最终上传前检查 JSON 里所有 image/sprite/icon/resource URL 都来自本次 manifest。
