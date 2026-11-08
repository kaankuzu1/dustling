# dmgbuild settings for Dustling.dmg (https://dmgbuild.readthedocs.io).
#
# scripts/build-dmg.sh runs:
#   dmgbuild -s App/DMG/dmg-settings.py -D app=<Dustling.app> -D icon=<AppIcon.icns> \
#            -D background=App/DMG/background.png Dustling <out.dmg>
#
# The window shows background.png (640 x 400, with background@2x.png next to it for Retina),
# Dustling on the left and an Applications link on the right, at 128 pt, with no toolbar,
# sidebar, path bar or status bar. The disk itself shows the app icon.
#
# The icon centers below must match the trail drawn in background.html.

import os.path

app = defines["app"]  # noqa: F821  (dmgbuild provides `defines`)
app_name = os.path.basename(app)

# Disk image
format = "UDZO"
compression_level = 9
filesystem = "HFS+"
files = [app]
symlinks = {"Applications": "/Applications"}
icon = defines["icon"]  # noqa: F821

# Window
background = defines["background"]  # noqa: F821
# Finder counts the title bar in the window's height (28 to 32 pt depending on macOS), so the window
# is 32 pt taller than the 400 pt picture. The picture ends in white, which hides the difference.
window_rect = ((200, 120), (640, 432))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False
include_icon_view_settings = True

# Icons
arrange_by = None
icon_size = 128
text_size = 13
label_pos = "bottom"
icon_locations = {
    app_name: (180, 188),
    "Applications": (460, 188),
}
