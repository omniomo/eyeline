# dmgbuild 的设置：打开 dmg 时 Finder 窗口的样子。
# 左边 Eyeline，右边「应用程序」，中间一串蓝点画的箭头（在背景图里）。
# 用法见 scripts/release.sh：dmgbuild -s tools/dmg/settings.py -D app=... -D background=... Eyeline out.dmg
import os

app = defines["app"]
files = [app]
symlinks = {"Applications": "/Applications"}
# Keep the app bundle unmodified after code signing.

format = "UDZO"
background = defines["background"]   # background.png + background@2x.png 合成的 tiff

# 窗口：640 × 360 的内容区，图标 128 点，位置和背景图里的光晕、箭头对齐
window_rect = ((200, 160), (640, 388))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 128
text_size = 13
icon_locations = {
    os.path.basename(app): (160, 170),
    "Applications": (480, 170),
}
