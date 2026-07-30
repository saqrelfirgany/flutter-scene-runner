/// Procedurally generated surface textures for flutter-scene-runner.
///
/// Every function here returns raw **RGBA8888 sRGB** pixels for
/// `Texture2D.fromPixels`. Nothing is loaded from disk and nothing is
/// downloaded: the textures are generated arithmetically at startup, which
/// keeps them original work with no third-party licensing attached — the same
/// reasoning behind synthesizing the SFX rather than sourcing them.
///
/// ## Why not `flutter_scene`'s own noise?
///
/// The package ships `FastNoiseLite` and `bakeNoiseTexture`, which would be the
/// obvious choice — but its own docs rule them out for us: *"the Dart
/// [FastNoiseLite] relies on 32-bit integer arithmetic that overflows on the
/// web, where Dart `int` is a JavaScript double (exact only to 53 bits), so the
/// hash loses its low bits."* This game ships to GitHub Pages, so the web is a
/// first-class target and the Dart-side noise is unusable. Everything below is
/// therefore pure `double` math, which behaves identically on both backends.
///
/// ## Tiling
///
/// `CuboidGeometry` gives each face a 0..1 UV, so one texture covers one face.
/// Adjacent road tiles show the *same* texture, so any large feature would read
/// as an obvious repeat — the road generator stays high-frequency for that
/// reason, and its low-frequency layer is lattice-wrapped so it is genuinely
/// seamless rather than merely subtle.
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// Deterministic hash of a lattice point to [0, 1).
///
/// The classic `fract(sin(dot(p, k)) * m)` shader hash. Chosen over an integer
/// hash purely because it is double math and so survives the web (see the
/// library doc). [seed] shifts the lattice to decorrelate layers.
double hash2(int x, int y, [int seed = 0]) {
  final double s =
      math.sin(x * 12.9898 + y * 78.233 + seed * 37.719) * 43758.5453123;
  return s - s.floorToDouble();
}

/// Value noise sampled at ([x], [y]) on a lattice of [period] cells, wrapping
/// so the result tiles seamlessly over that period.
///
/// Smoothstep interpolation rather than linear: linear interpolation leaves
/// visible lattice creases that read as a grid once the texture is stretched.
double tileableValueNoise(double x, double y, int period, [int seed = 0]) {
  final int x0 = x.floor();
  final int y0 = y.floor();
  final double fx = x - x0;
  final double fy = y - y0;

  // Wrap into [0, period) so the far edge samples the same lattice as 0.
  int wrap(int v) => ((v % period) + period) % period;
  final int xa = wrap(x0);
  final int ya = wrap(y0);
  final int xb = wrap(x0 + 1);
  final int yb = wrap(y0 + 1);

  double smooth(double t) => t * t * (3 - 2 * t);
  final double sx = smooth(fx);
  final double sy = smooth(fy);

  final double n00 = hash2(xa, ya, seed);
  final double n10 = hash2(xb, ya, seed);
  final double n01 = hash2(xa, yb, seed);
  final double n11 = hash2(xb, yb, seed);

  final double top = n00 + (n10 - n00) * sx;
  final double bot = n01 + (n11 - n01) * sx;
  return top + (bot - top) * sy;
}

/// Sums [octaves] of [tileableValueNoise], each double the frequency and half
/// the amplitude, normalised to [0, 1]. Every octave wraps on the same period,
/// so the sum still tiles.
double tileableFbm(double x, double y, int period, int octaves, [int seed = 0]) {
  double total = 0;
  double amp = 1;
  double norm = 0;
  int freq = 1;
  for (int o = 0; o < octaves; o++) {
    total +=
        tileableValueNoise(x * freq, y * freq, period * freq, seed + o) * amp;
    norm += amp;
    amp *= 0.5;
    freq *= 2;
  }
  return total / norm;
}

/// Writes one RGBA pixel, clamping each channel.
void _put(Uint8List out, int i, double r, double g, double b) {
  out[i] = r.clamp(0, 255).round();
  out[i + 1] = g.clamp(0, 255).round();
  out[i + 2] = b.clamp(0, 255).round();
  out[i + 3] = 255;
}

/// Asphalt: fine aggregate speckle over a broad tonal mottle.
///
/// [baseHex] is a `0xRRGGBB` sRGB tone — pass the flat colour the surface used
/// to be so the textured road keeps its established value. The speckle is
/// per-pixel (never a readable pattern however often the tile repeats) while
/// the mottle is low-frequency and lattice-wrapped, which is what stops a road
/// of identical tiles from looking like a tiled floor.
Uint8List asphaltPixels(int size, int baseHex, {int seed = 11}) {
  final Uint8List out = Uint8List(size * size * 4);
  final double br = ((baseHex >> 16) & 0xFF).toDouble();
  final double bg = ((baseHex >> 8) & 0xFF).toDouble();
  final double bb = (baseHex & 0xFF).toDouble();

  for (int y = 0; y < size; y++) {
    for (int x = 0; x < size; x++) {
      // Broad wear patches: ±9 of tone across the tile.
      final double mottle =
          tileableFbm(x / size * 4, y / size * 4, 4, 3, seed) - 0.5;
      // Aggregate grit: a hard per-pixel value, the thing that actually reads
      // as "asphalt" rather than "grey plastic".
      final double grit = hash2(x, y, seed + 91) - 0.5;
      // A few brighter stones scattered through the mix.
      final double stone = hash2(x, y, seed + 57) > 0.985 ? 26.0 : 0.0;

      final double d = mottle * 18.0 + grit * 21.0 + stone;
      _put(out, (y * size + x) * 4, br + d, bg + d, bb + d);
    }
  }
  return out;
}

/// Grass ground: soft colour variation between two tones.
///
/// Deliberately low-frequency. The ground slabs are ~280 units long with a
/// single 0..1 UV, so any fine detail would be stretched into mush; broad
/// patches instead read as natural variation in the turf at that scale.
Uint8List grassPixels(int size, int darkHex, int lightHex, {int seed = 23}) {
  final Uint8List out = Uint8List(size * size * 4);
  final double dr = ((darkHex >> 16) & 0xFF).toDouble();
  final double dg = ((darkHex >> 8) & 0xFF).toDouble();
  final double db = (darkHex & 0xFF).toDouble();
  final double lr = ((lightHex >> 16) & 0xFF).toDouble();
  final double lg = ((lightHex >> 8) & 0xFF).toDouble();
  final double lb = (lightHex & 0xFF).toDouble();

  for (int y = 0; y < size; y++) {
    for (int x = 0; x < size; x++) {
      final double t =
          tileableFbm(x / size * 3, y / size * 3, 3, 3, seed).clamp(0.0, 1.0);
      _put(out, (y * size + x) * 4, dr + (lr - dr) * t, dg + (lg - dg) * t,
          db + (lb - db) * t);
    }
  }
  return out;
}

/// Packed dirt for the road shoulder: grainier and higher contrast than
/// [grassPixels], since the shoulder is narrow and read at a glancing angle.
Uint8List dirtPixels(int size, int baseHex, {int seed = 41}) {
  final Uint8List out = Uint8List(size * size * 4);
  final double br = ((baseHex >> 16) & 0xFF).toDouble();
  final double bg = ((baseHex >> 8) & 0xFF).toDouble();
  final double bb = (baseHex & 0xFF).toDouble();

  for (int y = 0; y < size; y++) {
    for (int x = 0; x < size; x++) {
      final double patch =
          tileableFbm(x / size * 6, y / size * 6, 6, 3, seed) - 0.5;
      final double grain = hash2(x, y, seed + 13) - 0.5;
      final double d = patch * 24.0 + grain * 16.0;
      // Warm the highlights slightly so lit dirt reads as dust, not grey.
      _put(out, (y * size + x) * 4, br + d * 1.15, bg + d, bb + d * 0.85);
    }
  }
  return out;
}
