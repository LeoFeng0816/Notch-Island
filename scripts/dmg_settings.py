# Finder layout written by dmgbuild without controlling Finder.
format = "UDZO"
files = [defines["app"]]
symlinks = {"Applications": "/Applications"}
background = defines["background"]
# Volume icon: the same simplified Notch Island logo as the app.
if "icon" in defines:
    icon = defines["icon"]
default_view = "icon-view"
window_rect = ((120, 110), (620, 360))
show_toolbar = False
show_status_bar = False
show_sidebar = False
show_pathbar = False
icon_size = 112
text_size = 14
icon_locations = {
    "Notch Island.app": (158, 223),
    "Applications": (462, 223),
}
