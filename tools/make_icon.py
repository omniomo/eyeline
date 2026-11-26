#!/usr/bin/env python3
"""生成 App 图标：Icon Composer 的 .icon（Liquid Glass）。一只眼睛：玻璃的眼白，里面一颗往上看的蓝色虹膜。

    python3 tools/make_icon.py [bg] [trans] [line] [look] [pupil] [iris] [eye]

- bg：背景，white（白，默认）、ink（深色）或 paper（米白）
- trans：眼白那层玻璃透多少（0…1，默认 0.75）
- line：眼睛下面一条线的颜色，none 是不要（默认）
- look：虹膜往上看多少（1024 的画布上的像素，默认 29）
- pupil：瞳孔的颜色，none 是不要（默认；黑瞳孔看着吓人）
- iris：虹膜的颜色（默认 #4AA8FF）
- eye：眼白的颜色（默认 #78B6FF；白底上要深一点才看得清，深色底用过 #9CCBFF）

写到 Sources/Resources/AppIcon.icon（icon.json + Assets/*.svg）。Xcode 26 编译时把它变成 Assets.car 和 AppIcon.icns；
看效果：scripts/dev/iconrender.sh 用 ictool 画成 tools/icon-1024.png。
"""
import json
import os
import shutil
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
OUT = os.path.join(ROOT, "Sources", "Resources", "AppIcon.icon")

args = sys.argv[1:] + [None] * 7
BG = args[0] or "white"
TRANS = float(args[1]) if args[1] else 0.75
LINE_COLOR = args[2] or "none"
LOOK = float(args[3]) if args[3] else 29
PUPIL = args[4] or "none"
IRIS = args[5] or "#4AA8FF"
EYE = args[6] or "#78B6FF"

BACKGROUNDS = {
    "ink": ["extended-srgb:0.20000,0.21000,0.24000,1.00000", "extended-srgb:0.04000,0.04000,0.05000,1.00000"],
    "paper": ["extended-srgb:0.99000,0.99000,0.98000,1.00000", "extended-srgb:0.90000,0.90000,0.89000,1.00000"],
    "white": ["extended-srgb:1.00000,1.00000,1.00000,1.00000", "extended-srgb:0.91000,0.92000,0.94000,1.00000"],
}

SIZE = 1024
CENTER = SIZE / 2
# 眼睛：两段圆弧围成的杏仁形，左右两个尖。
# 2026-11 加大了一点（上下原来空太多）：宽 800、上下各鼓 205（半径 492.74），虹膜半径 146、往上看 29。
EYE_LEFT, EYE_RIGHT, EYE_RADIUS = 112.0, 912.0, 492.74
IRIS_RADIUS = 146


def svg(body):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{SIZE}" height="{SIZE}" '
            f'viewBox="0 0 {SIZE} {SIZE}">{body}</svg>')


def eye_path():
    return (f'M {EYE_LEFT:.2f} {CENTER:.2f} A {EYE_RADIUS:.2f} {EYE_RADIUS:.2f} 0 0 1 {EYE_RIGHT:.2f} {CENTER:.2f} '
            f'A {EYE_RADIUS:.2f} {EYE_RADIUS:.2f} 0 0 1 {EYE_LEFT:.2f} {CENTER:.2f} Z')


def main():
    if os.path.isdir(OUT):
        shutil.rmtree(OUT)
    assets = os.path.join(OUT, "Assets")
    os.makedirs(assets)
    iris_y = CENTER - LOOK

    files = {
        "2-eye.svg": svg(f'<path d="{eye_path()}" fill="{EYE}"/>'),
        "3-iris.svg": svg(f'<circle cx="{CENTER:g}" cy="{iris_y:g}" r="{IRIS_RADIUS}" fill="{IRIS}"/>'),
    }
    iris_layers = [{"name": "Iris", "image-name": "3-iris.svg", "glass": True}]
    if PUPIL != "none":
        files["4-pupil.svg"] = svg(f'<circle cx="{CENTER:g}" cy="{iris_y:g}" r="{IRIS_RADIUS * 0.42:.0f}" fill="{PUPIL}"/>')
        iris_layers.insert(0, {"name": "Pupil", "image-name": "4-pupil.svg", "glass": True})

    groups = [
        {
            "name": "Iris",
            "layers": iris_layers,
            "lighting": "individual",
            "shadow": {"kind": "layer-color", "opacity": 0.5},
            "specular": True,
            "translucency": {"enabled": False, "value": 0.5},
        },
        {
            "name": "Eye",
            "layers": [{"name": "Eye", "image-name": "2-eye.svg", "glass": True, "opacity": 1}],
            "shadow": {"kind": "neutral", "opacity": 0.45},
            "specular": True,
            "blur-material": 0.15,
            "translucency": {"enabled": True, "value": TRANS},
        },
    ]
    if LINE_COLOR != "none":
        y = EYE_RADIUS + CENTER - 300
        files["1-line.svg"] = svg(f'<rect x="{EYE_LEFT:g}" y="{y:g}" width="{EYE_RIGHT - EYE_LEFT:g}" height="36" rx="18" fill="{LINE_COLOR}"/>')
        groups.append({"name": "Line", "layers": [{"name": "Line", "image-name": "1-line.svg", "glass": True}],
                       "shadow": {"kind": "neutral", "opacity": 0.4}, "specular": True})

    for name, content in files.items():
        with open(os.path.join(assets, name), "w") as f:
            f.write(content + "\n")
    icon = {
        "fill": {
            "linear-gradient": BACKGROUNDS.get(BG, BACKGROUNDS["white"]),
            "orientation": {"start": {"x": 0.5, "y": 0.0}, "stop": {"x": 0.5, "y": 1.0}},
        },
        "groups": groups,
        "supported-platforms": {"squares": "shared"},
    }
    with open(os.path.join(OUT, "icon.json"), "w") as f:
        json.dump(icon, f, indent=2)
    print("wrote", os.path.relpath(OUT, ROOT))


if __name__ == "__main__":
    main()
