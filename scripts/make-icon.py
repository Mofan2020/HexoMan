#!/usr/bin/env python3
"""生成 HexoMan 应用图标。

macOS 图标遵循「squircle + 留白」规范：1024 画布，内容占中间约 82%，
四周留出透明边距让系统在 Dock 里自动加阴影。

用法：python3 scripts/make-icon.py
输出：HexoMan/Resources/Assets.xcassets/AppIcon.appiconset/icon_1024.png
"""

import os
from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
CONTENT = 840          # 内容边长
RADIUS = int(CONTENT * 0.2237)  # 苹果 squircle 比例
OUTPUT = os.path.join(
    os.path.dirname(__file__), "..", "HexoMan",
    "Resources", "Assets.xcassets", "AppIcon.appiconset", "icon_1024.png",
)

# 靛蓝到青色的对角渐变，取 hexo 主题的冷色系
START = (79, 70, 229)
END = (6, 182, 212)


def lerp(a, b, t):
    return tuple(round(x + (y - x) * t) for x, y in zip(a, b))


def make_gradient(size):
    """逐像素画对角线性渐变。"""
    image = Image.new("RGB", (size, size))
    pixels = image.load()
    for y in range(size):
        for x in range(size):
            t = (x + y) / (2 * (size - 1))
            pixels[x, y] = lerp(START, END, t)
    return image


def draw_glyph(draw, offset):
    """中间的字形：一个由方块构成的 H，加一道「代码」斜杠，呼应 hexo。"""
    s = offset
    w = CONTENT
    unit = w / 10

    bar_w = unit * 1.6
    bar_h = w * 0.46
    top = s + (w - bar_h) / 2

    white = (255, 255, 255, 255)
    soft = (255, 255, 255, 210)

    # H 的两根竖
    draw.rounded_rectangle(
        [s + unit * 1.6, top, s + unit * 1.6 + bar_w, top + bar_h],
        radius=bar_w * 0.42, fill=white,
    )
    draw.rounded_rectangle(
        [s + w - unit * 1.6 - bar_w, top, s + w - unit * 1.6, top + bar_h],
        radius=bar_w * 0.42, fill=white,
    )
    # H 的横
    draw.rounded_rectangle(
        [s + unit * 1.6, top + bar_h / 2 - bar_w / 2,
         s + w - unit * 1.6, top + bar_h / 2 + bar_w / 2],
        radius=bar_w * 0.42, fill=soft,
    )


def main():
    canvas = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))

    # squircle 遮罩
    mask = Image.new("L", (CONTENT, CONTENT), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        [0, 0, CONTENT - 1, CONTENT - 1], radius=RADIUS, fill=255,
    )

    body = make_gradient(CONTENT).convert("RGBA")
    body.putalpha(mask)

    # 顶部柔光。必须模糊后再叠，否则椭圆边缘会在图标上割出一道可见的硬接缝。
    gloss = Image.new("RGBA", (CONTENT, CONTENT), (0, 0, 0, 0))
    ImageDraw.Draw(gloss).ellipse(
        [-CONTENT * 0.30, -CONTENT * 0.95, CONTENT * 1.30, CONTENT * 0.25],
        fill=(255, 255, 255, 46),
    )
    gloss = gloss.filter(ImageFilter.GaussianBlur(CONTENT * 0.09))
    body = Image.alpha_composite(body, gloss)

    glyph = Image.new("RGBA", (CONTENT, CONTENT), (0, 0, 0, 0))
    draw_glyph(ImageDraw.Draw(glyph), 0)
    body = Image.alpha_composite(body, glyph)

    offset = (SIZE - CONTENT) // 2
    canvas.paste(body, (offset, offset), body)

    os.makedirs(os.path.dirname(OUTPUT), exist_ok=True)
    canvas.save(OUTPUT, "PNG")
    print(f"icon written: {os.path.abspath(OUTPUT)}  {canvas.size[0]}x{canvas.size[1]}")


if __name__ == "__main__":
    main()
