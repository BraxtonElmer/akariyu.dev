// One-off generator for the akariyu app icon.
//
// Renders a 1024×1024 PNG that mirrors the welcome-screen mark: a soft
// rounded square against the near-black background base, with the `>_`
// glyph in the akariyu accent red. Output is written to
// assets/icon/akariyu_icon.png; flutter_launcher_icons reads from there.
//
// Run:   dart run tool/generate_icon.dart
//
// Re-run any time the brand mark changes; commit the PNGs that
// flutter_launcher_icons produces but not this generator's bytes.

import 'dart:io';

import 'package:image/image.dart' as img;

const _backgroundBase = 0xFF0A0A0A;
const _surfaceCard = 0xFF1C1C1C;
const _borderSubtle = 0xFF262626;
const _accent = 0xFFB1271C;

void main() async {
  const size = 1024;
  const cardInset = 96; // leaves ~10% margin around the inner card
  const cardRadius = 200;

  final canvas = img.Image(width: size, height: size, numChannels: 4);
  img.fill(canvas, color: _rgba(_backgroundBase));

  // Inner card (a rounded square that matches the welcome screen mark).
  final cardRect = img.Image(
    width: size - cardInset * 2,
    height: size - cardInset * 2,
    numChannels: 4,
  );
  img.fill(cardRect, color: _rgba(_surfaceCard));
  _roundCorners(cardRect, radius: cardRadius);
  img.compositeImage(canvas, cardRect, dstX: cardInset, dstY: cardInset);

  // Subtle border.
  _drawRoundedRectBorder(
    canvas,
    x: cardInset,
    y: cardInset,
    w: size - cardInset * 2,
    h: size - cardInset * 2,
    radius: cardRadius,
    color: _rgba(_borderSubtle),
    thickness: 6,
  );

  // The `>_` glyph in red — drawn manually as stroked shapes since
  // `package:image`'s built-in bitmap fonts max out around 48px.
  _drawCaret(canvas,
      centerX: size ~/ 2 - 90,
      centerY: size ~/ 2,
      armLength: 220,
      thickness: 60,
      color: _rgba(_accent));
  _drawUnderscore(canvas,
      x: size ~/ 2 + 70,
      y: size ~/ 2 + 110,
      width: 200,
      thickness: 60,
      color: _rgba(_accent));

  final out = File('assets/icon/akariyu_icon.png');
  await out.parent.create(recursive: true);
  await out.writeAsBytes(img.encodePng(canvas));
  // Also write a 432x432 foreground for adaptive icons — same mark, no card.
  final fg = img.Image(width: 432, height: 432, numChannels: 4);
  img.fill(fg, color: img.ColorUint8.rgba(0, 0, 0, 0));
  _drawCaret(fg,
      centerX: 432 ~/ 2 - 38,
      centerY: 432 ~/ 2,
      armLength: 96,
      thickness: 28,
      color: _rgba(_accent));
  _drawUnderscore(fg,
      x: 432 ~/ 2 + 30,
      y: 432 ~/ 2 + 48,
      width: 88,
      thickness: 28,
      color: _rgba(_accent));
  await File('assets/icon/akariyu_icon_fg.png')
      .writeAsBytes(img.encodePng(fg));
  // Solid background for adaptive icons.
  final bg = img.Image(width: 432, height: 432, numChannels: 4);
  img.fill(bg, color: _rgba(_backgroundBase));
  await File('assets/icon/akariyu_icon_bg.png')
      .writeAsBytes(img.encodePng(bg));

  stdout.writeln('Wrote ${out.path}');
}

img.Color _rgba(int argb) {
  final a = (argb >> 24) & 0xFF;
  final r = (argb >> 16) & 0xFF;
  final g = (argb >> 8) & 0xFF;
  final b = argb & 0xFF;
  return img.ColorUint8.rgba(r, g, b, a);
}

/// Zero out the alpha of pixels outside a rounded rectangle so the card
/// has soft corners.
void _roundCorners(img.Image image, {required int radius}) {
  final w = image.width;
  final h = image.height;
  final transparent = img.ColorUint8.rgba(0, 0, 0, 0);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      double? dx;
      double? dy;
      if (x < radius && y < radius) {
        dx = (radius - x).toDouble();
        dy = (radius - y).toDouble();
      } else if (x >= w - radius && y < radius) {
        dx = (x - (w - radius - 1)).toDouble();
        dy = (radius - y).toDouble();
      } else if (x < radius && y >= h - radius) {
        dx = (radius - x).toDouble();
        dy = (y - (h - radius - 1)).toDouble();
      } else if (x >= w - radius && y >= h - radius) {
        dx = (x - (w - radius - 1)).toDouble();
        dy = (y - (h - radius - 1)).toDouble();
      }
      if (dx != null && dy != null) {
        final d = (dx * dx + dy * dy);
        if (d > radius * radius) {
          image.setPixel(x, y, transparent);
        }
      }
    }
  }
}

void _drawRoundedRectBorder(
  img.Image image, {
  required int x,
  required int y,
  required int w,
  required int h,
  required int radius,
  required img.Color color,
  required int thickness,
}) {
  // Approximate by drawing four thick lines + four arcs is overkill;
  // package:image's drawRect with thickness is sufficient.
  img.drawRect(image,
      x1: x, y1: y, x2: x + w - 1, y2: y + h - 1,
      color: color, thickness: thickness, radius: radius);
}

/// Filled `>` glyph: two thick lines meeting at a point on the right.
void _drawCaret(
  img.Image image, {
  required int centerX,
  required int centerY,
  required int armLength,
  required int thickness,
  required img.Color color,
}) {
  final topX = centerX - armLength;
  final topY = centerY - armLength;
  final botX = centerX - armLength;
  final botY = centerY + armLength;
  img.drawLine(image,
      x1: topX, y1: topY, x2: centerX, y2: centerY,
      color: color, thickness: thickness, antialias: true);
  img.drawLine(image,
      x1: botX, y1: botY, x2: centerX, y2: centerY,
      color: color, thickness: thickness, antialias: true);
}

/// Filled `_` glyph: a horizontal stroke under the baseline.
void _drawUnderscore(
  img.Image image, {
  required int x,
  required int y,
  required int width,
  required int thickness,
  required img.Color color,
}) {
  img.fillRect(image,
      x1: x - width ~/ 2,
      y1: y,
      x2: x + width ~/ 2,
      y2: y + thickness,
      color: color);
}
