#!/usr/bin/env python3
"""Render the reproducible HugoInk app icon and vector mark."""

from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image, ImageDraw


CANVAS_SIZE = 1024
RENDER_SCALE = 4

INK_NAVY = "#061838"
CORAL = "#FF4261"
CYAN = "#20C4D5"
CREAM = "#FFF1D0"


def scaled_points(points: list[tuple[int, int]]) -> list[tuple[int, int]]:
    return [(x * RENDER_SCALE, y * RENDER_SCALE) for x, y in points]


def scaled_box(box: tuple[int, int, int, int]) -> tuple[int, int, int, int]:
    return tuple(value * RENDER_SCALE for value in box)


def render_png(path: Path) -> None:
    size = CANVAS_SIZE * RENDER_SCALE
    image = Image.new("RGB", (size, size), INK_NAVY)
    draw = ImageDraw.Draw(image)

    outer_hexagon = [(512, 60), (904, 286), (904, 738), (512, 964), (120, 738), (120, 286)]
    inner_hexagon = [(512, 148), (828, 330), (828, 694), (512, 876), (196, 694), (196, 330)]
    draw.polygon(scaled_points(outer_hexagon), fill=CORAL)
    draw.polygon(scaled_points(inner_hexagon), fill=INK_NAVY)

    # The primary H remains readable even when the icon is reduced to 32 points.
    draw.rectangle(scaled_box((280, 340, 380, 790)), fill=CORAL)
    draw.rectangle(scaled_box((644, 340, 744, 790)), fill=CORAL)
    draw.rectangle(scaled_box((380, 478, 644, 578)), fill=CORAL)

    # Markdown document with a folded corner in the upper counter of the H.
    document = [(408, 230), (576, 230), (632, 286), (632, 442), (408, 442)]
    draw.polygon(scaled_points(document), fill=CREAM)
    fold = [(576, 230), (576, 286), (632, 286)]
    draw.polygon(scaled_points(fold), fill=INK_NAVY)

    # Three Git nodes sit in the lower counter of the H.
    top_node = (512, 632)
    left_node = (424, 758)
    right_node = (600, 758)
    line_width = 30 * RENDER_SCALE
    draw.line(scaled_points([(512, 604), top_node]), fill=CYAN, width=line_width)
    draw.line(scaled_points([top_node, left_node]), fill=CYAN, width=line_width)
    draw.line(scaled_points([top_node, right_node]), fill=CYAN, width=line_width)

    for x, y in (top_node, left_node, right_node):
        outer = scaled_box((x - 48, y - 48, x + 48, y + 48))
        inner = scaled_box((x - 28, y - 28, x + 28, y + 28))
        draw.ellipse(outer, fill=CYAN)
        draw.ellipse(inner, fill=CREAM)

    image = image.resize((CANVAS_SIZE, CANVAS_SIZE), Image.Resampling.LANCZOS)
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, format="PNG", optimize=True)


def render_svg(path: Path) -> None:
    svg = f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" role="img" aria-labelledby="title desc">
  <title id="title">HugoInk logo mark</title>
  <desc id="desc">A coral H inside a hexagon with a Markdown document and three Git nodes.</desc>
  <rect width="1024" height="1024" fill="{INK_NAVY}"/>
  <path fill="{CORAL}" fill-rule="evenodd" d="M512 60 904 286v452L512 964 120 738V286Zm0 88L196 330v364l316 182 316-182V330Z"/>
  <path fill="{CORAL}" d="M280 340h100v450H280zm364 0h100v450H644zM380 478h264v100H380z"/>
  <path fill="{CREAM}" d="M408 230h168l56 56v156H408Z"/>
  <path fill="{INK_NAVY}" d="m576 230 56 56h-56Z"/>
  <path fill="none" stroke="{CYAN}" stroke-width="30" stroke-linecap="square" stroke-linejoin="miter" d="M512 604v28l-88 126m88-126 88 126"/>
  <g fill="{CYAN}">
    <circle cx="512" cy="632" r="48"/><circle cx="424" cy="758" r="48"/><circle cx="600" cy="758" r="48"/>
  </g>
  <g fill="{CREAM}">
    <circle cx="512" cy="632" r="28"/><circle cx="424" cy="758" r="28"/><circle cx="600" cy="758" r="28"/>
  </g>
</svg>
'''
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(svg, encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--png", type=Path, required=True)
    parser.add_argument("--svg", type=Path)
    args = parser.parse_args()

    render_png(args.png)
    if args.svg:
        render_svg(args.svg)


if __name__ == "__main__":
    main()
