#!/bin/bash
# Regenerates App/AppIcon.icns from the master artwork in Design/AppIcon.png.
# Usage: scripts/make-icon.sh
#
# The master is a plain 1024x1024 square. macOS draws app icons unmasked, so
# the icon shape has to be baked in: this fits the artwork to the standard
# grid — an 824x824 continuous rounded rect (radius 185.4) centred on a
# 1024x1024 canvas — before slicing the iconset.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Design/AppIcon.png"
OUT="$ROOT/App/AppIcon.icns"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/squircle.swift" <<'SWIFT'
import AppKit
import SwiftUI
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 3 else { fputs("usage: squircle <in.png> <out.png>\n", stderr); exit(2) }

let canvas: CGFloat = 1024, side: CGFloat = 824, radius: CGFloat = 185.4
let inset = (canvas - side) / 2
let box = CGRect(x: inset, y: inset, width: side, height: side)

guard let src = NSImage(contentsOfFile: args[1]),
      let cg = src.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fputs("cannot read \(args[1])\n", stderr); exit(1)
}
guard let ctx = CGContext(data: nil, width: Int(canvas), height: Int(canvas),
                          bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fputs("cannot make context\n", stderr); exit(1)
}
ctx.interpolationQuality = .high
ctx.addPath(Path(roundedRect: box, cornerRadius: radius, style: .continuous).cgPath)
ctx.clip()
ctx.draw(cg, in: box)

guard let out = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(
          URL(fileURLWithPath: args[2]) as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fputs("cannot write \(args[2])\n", stderr); exit(1) }
CGImageDestinationAddImage(dest, out, nil)
CGImageDestinationFinalize(dest)
SWIFT

swift "$WORK/squircle.swift" "$SRC" "$WORK/master.png"

SET="$WORK/AppIcon.iconset"
mkdir -p "$SET"
for PAIR in 16:icon_16x16 32:icon_16x16@2x 32:icon_32x32 64:icon_32x32@2x \
            128:icon_128x128 256:icon_128x128@2x 256:icon_256x256 \
            512:icon_256x256@2x 512:icon_512x512 1024:icon_512x512@2x; do
  sips -s format png -z "${PAIR%%:*}" "${PAIR%%:*}" \
    "$WORK/master.png" --out "$SET/${PAIR##*:}.png" >/dev/null
done

iconutil -c icns "$SET" -o "$OUT"
echo "Wrote $OUT"
