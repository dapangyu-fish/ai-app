#!/usr/bin/env python3
"""
生成 app 图标的 Python 脚本
使用 PIL/Pillow 库生成各种尺寸的图标
"""

from PIL import Image, ImageDraw
import os

def create_icon(size):
    """创建指定尺寸的图标"""
    # 创建图像 - 使用深灰色背景
    img = Image.new('RGBA', (size, size), color=(0, 0, 0, 0))

    # 计算缩放比例
    scale = size / 1024

    # 绘制圆角矩形背景（深灰色渐变效果）
    mask = Image.new('L', (size, size), 0)
    mask_draw = ImageDraw.Draw(mask)
    corner_radius = int(180 * scale)
    mask_draw.rounded_rectangle([(0, 0), (size, size)], corner_radius, fill=255)

    # 创建深灰色背景
    bg = Image.new('RGB', (size, size), color='#1a1a1a')
    bg.putalpha(mask)

    # 创建渐变效果（从深灰到稍浅的灰）
    for y in range(size):
        gray_value = int(26 + (y / size) * 30)  # 从 #1a1a1a 到 #383838
        for x in range(size):
            if mask.getpixel((x, y)) > 0:
                bg.putpixel((x, y), (gray_value, gray_value, gray_value, 255))

    output = bg
    draw = ImageDraw.Draw(output)

    # 绘制左大括号（浅灰色）
    left_bracket_points = [
        (int(320 * scale), int(256 * scale)),
        (int(280 * scale), int(256 * scale)),
        (int(280 * scale), int(296 * scale)),
        (int(280 * scale), int(456 * scale)),
        (int(240 * scale), int(496 * scale)),
        (int(280 * scale), int(536 * scale)),
        (int(280 * scale), int(696 * scale)),
        (int(280 * scale), int(736 * scale)),
        (int(320 * scale), int(736 * scale)),
    ]
    draw.line(left_bracket_points, fill='#e5e5e5', width=int(48 * scale), joint='curve')

    # 绘制右大括号（浅灰色）
    right_bracket_points = [
        (int(704 * scale), int(256 * scale)),
        (int(744 * scale), int(256 * scale)),
        (int(744 * scale), int(296 * scale)),
        (int(744 * scale), int(456 * scale)),
        (int(784 * scale), int(496 * scale)),
        (int(744 * scale), int(536 * scale)),
        (int(744 * scale), int(696 * scale)),
        (int(744 * scale), int(736 * scale)),
        (int(704 * scale), int(736 * scale)),
    ]
    draw.line(right_bracket_points, fill='#e5e5e5', width=int(48 * scale), joint='curve')

    # 绘制中间的圆点（白色）
    for y in [380, 496, 612]:
        draw.ellipse([
            (int((512 - 24) * scale), int((y - 24) * scale)),
            (int((512 + 24) * scale), int((y + 24) * scale))
        ], fill='#f5f5f5')

    # 绘制装饰性的小方块（中灰色）
    positions = [
        (420, 368), (572, 368),
        (420, 484), (572, 484),
        (420, 600), (572, 600),
    ]
    for x, y in positions:
        draw.rounded_rectangle([
            (int(x * scale), int(y * scale)),
            (int((x + 32) * scale), int((y + 32) * scale))
        ], int(6 * scale), fill='#cccccc')

    return output

def main():
    """生成所有需要的图标尺寸"""
    # iOS 需要的尺寸
    ios_sizes = [
        (20, 1), (20, 2), (20, 3),
        (29, 1), (29, 2), (29, 3),
        (40, 1), (40, 2), (40, 3),
        (60, 2), (60, 3),
        (76, 1), (76, 2),
        (83.5, 2),
        (1024, 1),
    ]

    # 标准尺寸
    standard_sizes = [16, 32, 64, 128, 192, 256, 512, 1024]

    # 创建输出目录
    output_dir = os.path.join(os.path.dirname(__file__), '..', 'assets', 'icons')
    os.makedirs(output_dir, exist_ok=True)

    print("正在生成图标...")

    # 生成标准尺寸
    for size in standard_sizes:
        icon = create_icon(size)
        output_path = os.path.join(output_dir, f'icon_{size}.png')
        icon.save(output_path, 'PNG')
        print(f"✓ 生成 {size}x{size} 图标")

    # 生成 iOS 尺寸
    for base_size, scale in ios_sizes:
        size = int(base_size * scale)
        icon = create_icon(size)
        output_path = os.path.join(output_dir, f'Icon-App-{base_size}x{base_size}@{scale}x.png')
        icon.save(output_path, 'PNG')
        print(f"✓ 生成 iOS {base_size}x{base_size}@{scale}x 图标")

    print(f"\n所有图标已生成到: {output_dir}")
    print("\n你可以将这些图标复制到:")
    print("  - iOS: ios/Runner/Assets.xcassets/AppIcon.appiconset/")
    print("  - macOS: macos/Runner/Assets.xcassets/AppIcon.appiconset/")
    print("  - Web: web/icons/")

if __name__ == '__main__':
    main()
