#!/bin/bash
# 设置App头像脚本

SOURCE_IMAGE="$HOME/Downloads/openart-gpt-image-2-1_1777191356223_c57b4f72.png"
TARGET_DIR="$HOME/ai-app/assets"
TARGET_IMAGE="$TARGET_DIR/app_icon.png"

# 检查源文件是否存在
if [ ! -f "$SOURCE_IMAGE" ]; then
    echo "错误: 源图片不存在: $SOURCE_IMAGE"
    exit 1
fi

# 检查目标目录是否存在
if [ ! -d "$TARGET_DIR" ]; then
    echo "错误: 目标目录不存在: $TARGET_DIR"
    exit 1
fi

# 复制图片
echo "正在复制图片..."
cp "$SOURCE_IMAGE" "$TARGET_IMAGE"

if [ $? -eq 0 ]; then
    echo "✅ 成功！图片已复制到: $TARGET_IMAGE"
    echo "文件大小: $(ls -lh "$TARGET_IMAGE" | awk '{print $5}')"
else
    echo "❌ 复制失败，请检查权限"
    exit 1
fi
