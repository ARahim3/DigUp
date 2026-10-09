# DigUp's icon: "One space"

Four tiles, for what DigUp searches (text, pictures, sound, video), around an amber D with the find glowing in it.
Moss palette.

- `appicon.svg`: the app icon (1024 × 1024, macOS icon grid). `../AppIcon.icns` holds it at 64 px and up.
- `appicon-small.svg`: the same without the glyphs inside the tiles, which turn to noise when small. `../AppIcon.icns`
  holds it at 16 and 32 px.
- `AppIcon.icon`: the same design as layers for macOS 26 and later (an Icon Composer document: a #13201A fill, the
  tiles, the D). `build.sh` compiles it into `Assets.car` with `actool`; `Info.plist`'s `CFBundleIconName` points at
  it. Without it macOS 26 draws the `.icns` shrunk inside a gray square. Older macOS uses the `.icns`
  (`CFBundleIconFile`; untested there).
- `menubar.svg`: the menubar mark, a boxed D. The app draws it in code from the same geometry
  (`StatusIcon` in `Sources/DigUpApp/StatusMenu.swift`), with the indexing ring in place of the box.

To rebuild `AppIcon.icns` after editing a source: render both SVGs to an iconset (`icon_16x16.png` and
`icon_16x16@2x.png`/`icon_32x32.png` from `appicon-small.svg` at 16 and 32 px; the other eight sizes, 64 to 1024 px,
from `appicon.svg`) with a renderer that draws SVG blur filters (a browser or WebKit; macOS's own SVG renderer drops
the soft shadows), then `iconutil -c icns AppIcon.iconset -o ../AppIcon.icns`.

Colors: tile #13201A; tiles #D5E6BB, #A2C78E, #64976B, #356652; the D #FFD166 → #F2A22A with a #13201A outline; the
find #FFF6DA.
