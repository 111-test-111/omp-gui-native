# dmgbuild settings used to (re)bake release/dmg/installer-DS_Store.base64 (the
# baked volume's .DS_Store, base64-encoded so it lives in git as text).
# Not used at release time — see release/dmg/README.md for when and how to run it.
#
# Geometry must stay in lockstep with generate_installer_background.swift:
#   window content: 660x370 (WindowBounds adds ~28pt of titlebar)
#   Droppy Code.app at (165, 208), Applications at (495, 208), icon size 128
import os.path

# dmgbuild exec()s this file without __file__; pass -D here=<this directory>.
HERE = os.path.abspath(defines.get("here", "."))  # noqa: F821 - injected by dmgbuild

volume_name = "Droppy Code"
format = "UDZO"
filesystem = "HFS+"

# Any minimal stub named Droppy Code.app works: only the NAME is baked into .DS_Store.
files = [os.path.join(HERE, "stub", "Droppy Code.app")]
symlinks = {"Applications": "/Applications"}

# dmgbuild copies this to /.background.tiff on the volume and the baked alias
# points there; scripts/package_dmg.sh must keep staging it at that path.
background = os.path.join(HERE, "installer-background.tiff")

window_rect = ((420, 240), (660, 398))

default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False

icon_size = 128
text_size = 12
show_icon_preview = False
arrange_by = None

icon_locations = {
    "Droppy Code.app": (165, 208),
    "Applications": (495, 208),
}
