#!/bin/bash
# vdinga G1's protected app-icon gate (chain/installer-rework-20261002). No worker may edit this file;
# the broker reverts any attempt.
#
# Exit 0 only if:
#   - Contents/Info.plist has CFBundleIconFile;
#   - Contents/Resources/<that>.icns exists and `iconutil -c iconset` accepts it;
#   - its 512px representation has a near-white, opaque pixel at the centre (the mic glyph) and a
#     mid-gray, opaque (not white, not transparent) pixel inset ~20% from a corner (the rounded-square
#     background).
#
# Pixel colour is read with a tiny inline Swift script (AppKit's NSBitmapImageRep), not `sips`: sips can
# report an image's dimensions and format but has no way to print a pixel's colour as text.
#
# Usage: scripts/gates/app-icon.sh <path-to-.app>
set -euo pipefail

APP="${1:-}"
if [ -z "$APP" ]; then
  echo "[app-icon] FAIL: usage: scripts/gates/app-icon.sh <path-to-.app>"
  exit 1
fi
if [ ! -d "$APP" ]; then
  echo "[app-icon] FAIL: no such app bundle: $APP"
  exit 1
fi

INFO_PLIST="$APP/Contents/Info.plist"
if [ ! -f "$INFO_PLIST" ]; then
  echo "[app-icon] FAIL: no Info.plist at $INFO_PLIST"
  exit 1
fi

ICON_NAME=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIconFile" "$INFO_PLIST" 2>/dev/null || true)
if [ -z "$ICON_NAME" ]; then
  echo "[app-icon] FAIL: $INFO_PLIST has no CFBundleIconFile"
  exit 1
fi

case "$ICON_NAME" in
  *.icns) ICNS_PATH="$APP/Contents/Resources/$ICON_NAME" ;;
  *) ICNS_PATH="$APP/Contents/Resources/$ICON_NAME.icns" ;;
esac

if [ ! -f "$ICNS_PATH" ]; then
  echo "[app-icon] FAIL: CFBundleIconFile names \"$ICON_NAME\" but $ICNS_PATH does not exist"
  exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

ICONSET="$WORKDIR/out.iconset"
if ! iconutil -c iconset "$ICNS_PATH" -o "$ICONSET" 2>"$WORKDIR/iconutil.err"; then
  echo "[app-icon] FAIL: iconutil rejected $ICNS_PATH:"
  cat "$WORKDIR/iconutil.err"
  exit 1
fi

REP=""
for candidate in icon_512x512.png icon_256x256@2x.png; do
  if [ -f "$ICONSET/$candidate" ]; then
    REP="$ICONSET/$candidate"
    break
  fi
done
if [ -z "$REP" ]; then
  echo "[app-icon] FAIL: no 512px representation (icon_512x512.png or icon_256x256@2x.png) in the iconset"
  ls "$ICONSET" || true
  exit 1
fi

PIXEL_SWIFT="$WORKDIR/pixel.swift"
cat > "$PIXEL_SWIFT" <<'SWIFT'
import AppKit

let path = CommandLine.arguments[1]
guard let x = Int(CommandLine.arguments[2]), let y = Int(CommandLine.arguments[3]) else {
    print("ERROR: bad coordinates")
    exit(1)
}
guard let image = NSImage(contentsOfFile: path),
      let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff) else {
    print("ERROR: could not decode \(path)")
    exit(1)
}
guard let color = rep.colorAt(x: x, y: y) else {
    print("ERROR: no pixel at \(x),\(y)")
    exit(1)
}
let converted = color.usingColorSpace(.deviceRGB) ?? color
print("\(converted.redComponent) \(converted.greenComponent) \(converted.blueComponent) \(converted.alphaComponent)")
SWIFT

pixel_at() {
  swift "$PIXEL_SWIFT" "$REP" "$1" "$2"
}

SIZE=$(sips -g pixelWidth "$REP" 2>/dev/null | awk '/pixelWidth/{print $2}')
if [ -z "${SIZE:-}" ]; then
  echo "[app-icon] FAIL: could not read $REP's pixel size"
  exit 1
fi

CENTER=$((SIZE / 2))
INSET=$((SIZE / 5))

CENTER_RGBA=$(pixel_at "$CENTER" "$CENTER") || { echo "[app-icon] FAIL: could not read the centre pixel"; exit 1; }
CORNER_RGBA=$(pixel_at "$INSET" "$INSET") || { echo "[app-icon] FAIL: could not read the corner-inset pixel"; exit 1; }

case "$CENTER_RGBA" in ERROR*)
  echo "[app-icon] FAIL: centre pixel read failed: $CENTER_RGBA"; exit 1 ;;
esac
case "$CORNER_RGBA" in ERROR*)
  echo "[app-icon] FAIL: corner-inset pixel read failed: $CORNER_RGBA"; exit 1 ;;
esac

read -r CR CG CB CA <<<"$CENTER_RGBA"
read -r KR KG KB KA <<<"$CORNER_RGBA"

CENTER_OK=$(awk -v r="$CR" -v g="$CG" -v b="$CB" -v a="$CA" \
  'BEGIN{print (r>0.85 && g>0.85 && b>0.85 && a>0.9) ? 1 : 0}')
CORNER_OK=$(awk -v r="$KR" -v g="$KG" -v b="$KB" -v a="$KA" \
  'BEGIN{grey=(r+g+b)/3; print (a>0.9 && grey>0.25 && grey<0.75) ? 1 : 0}')

if [ "$CENTER_OK" != "1" ]; then
  echo "[app-icon] FAIL: the centre pixel is not a near-white, opaque glyph (rgba=$CENTER_RGBA)"
  exit 1
fi
if [ "$CORNER_OK" != "1" ]; then
  echo "[app-icon] FAIL: the corner-inset pixel is not a mid-gray, opaque background (rgba=$CORNER_RGBA)"
  exit 1
fi

echo "[app-icon] PASS: $ICNS_PATH - centre(white) rgba=$CENTER_RGBA, corner(gray) rgba=$CORNER_RGBA"
exit 0
