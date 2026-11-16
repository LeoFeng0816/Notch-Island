# Finder layout written by dmgbuild without controlling Finder.
format = "UDZO"
files = [defines["app"]]
symlinks = {"Applications": "/Applications"}
background = defines["background"]
# Volume icon: the same simplified Notch Island logo as the app.
if "icon" in defines:
    icon = defines["icon"]
default_view = "icon-view"
# Window bounds include Finder's title bar; the 620 x 380 background keeps all
# text above the bottom 56 pt (see maxTitleBar in scripts/render_artwork.swift).
window_rect = ((120, 110), (620, 380))
show_toolbar = False
show_status_bar = False
show_sidebar = False
show_pathbar = False
icon_size = 112
text_size = 14
# Centre row 165 pt from the top (no header since 0.1.1); keep in sync with
# installerIconRow in scripts/render_artwork.swift and the check in make_dmg.sh.
icon_locations = {
    "Notch Island.app": (158, 165),
    "Applications": (462, 165),
}
