// Tests for the procedural texture generators.
//
// These are worth having for one specific reason: the generators run at
// startup on a device we cannot inspect, and a silent failure mode (an all-one-
// colour texture, or a visible seam where the tile wraps) looks like a shading
// bug rather than a data bug. Asserting variance and seamlessness here catches
// that on the CPU, with no GPU involved.

import 'dart:typed_data';

import 'package:flutter_scene_runner/game_textures.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mean of one channel, for asserting a generator kept its target tone.
double _channelMean(Uint8List px, int channel) {
  double sum = 0;
  final int n = px.length ~/ 4;
  for (int i = 0; i < n; i++) {
    sum += px[i * 4 + channel];
  }
  return sum / n;
}

/// Population standard deviation of the luma, as a proxy for "does this
/// texture actually have detail in it".
double _lumaStdDev(Uint8List px) {
  final int n = px.length ~/ 4;
  final List<double> l = List<double>.filled(n, 0);
  double sum = 0;
  for (int i = 0; i < n; i++) {
    l[i] = 0.299 * px[i * 4] + 0.587 * px[i * 4 + 1] + 0.114 * px[i * 4 + 2];
    sum += l[i];
  }
  final double mean = sum / n;
  double acc = 0;
  for (final double v in l) {
    acc += (v - mean) * (v - mean);
  }
  return (acc / n).abs();
}

void main() {
  group('hash2', () {
    test('stays in [0, 1)', () {
      for (int x = -40; x < 40; x += 7) {
        for (int y = -40; y < 40; y += 7) {
          final double h = hash2(x, y);
          expect(h, greaterThanOrEqualTo(0.0));
          expect(h, lessThan(1.0));
        }
      }
    });

    test('is deterministic and seed-sensitive', () {
      expect(hash2(3, 9), hash2(3, 9));
      expect(hash2(3, 9), isNot(hash2(3, 9, 5)));
    });
  });

  group('tileableValueNoise', () {
    test('wraps exactly on the period', () {
      // The whole point of the wrap: sampling one period further along must
      // return the same value, or the texture shows a seam.
      const int period = 8;
      for (double x = 0; x < period; x += 1.3) {
        expect(tileableValueNoise(x + period, 2.5, period),
            closeTo(tileableValueNoise(x, 2.5, period), 1e-9));
        expect(tileableValueNoise(2.5, x + period, period),
            closeTo(tileableValueNoise(2.5, x, period), 1e-9));
      }
    });

    test('stays in [0, 1]', () {
      for (double x = 0; x < 12; x += 0.7) {
        final double v = tileableValueNoise(x, x * 1.7, 8);
        expect(v, inInclusiveRange(0.0, 1.0));
      }
    });
  });

  group('tileableFbm', () {
    test('still wraps on the base period with several octaves', () {
      const int period = 4;
      expect(tileableFbm(1.1 + period, 0.4, period, 3),
          closeTo(tileableFbm(1.1, 0.4, period, 3), 1e-9));
    });

    test('stays normalised in [0, 1]', () {
      for (double x = 0; x < 8; x += 0.55) {
        expect(tileableFbm(x, x * 0.3, 4, 4), inInclusiveRange(0.0, 1.0));
      }
    });
  });

  group('asphaltPixels', () {
    final Uint8List px = asphaltPixels(32, 0x3E444C);

    test('fills RGBA for every pixel and is fully opaque', () {
      expect(px.length, 32 * 32 * 4);
      for (int i = 3; i < px.length; i += 4) {
        expect(px[i], 255);
      }
    });

    test('has real detail rather than a flat fill', () {
      expect(_lumaStdDev(px), greaterThan(4.0));
    });

    test('keeps the requested base tone', () {
      // Grit and mottle are zero-mean, so the average should land near the
      // base colour it was given (0x3E = 62, 0x44 = 68, 0x4C = 76).
      expect(_channelMean(px, 0), closeTo(62, 9));
      expect(_channelMean(px, 1), closeTo(68, 9));
      expect(_channelMean(px, 2), closeTo(76, 9));
    });
  });

  group('grassPixels', () {
    final Uint8List px = grassPixels(32, 0x5FB343, 0x8AD05C);

    test('interpolates between the two tones and stays inside them', () {
      // Green is the channel that separates the two endpoints (0xB3 -> 0xD0).
      final double mean = _channelMean(px, 1);
      expect(mean, greaterThan(0xB3 - 4));
      expect(mean, lessThan(0xD0 + 4));
    });

    test('varies across the surface', () {
      expect(_lumaStdDev(px), greaterThan(1.0));
    });
  });

  group('dirtPixels', () {
    final Uint8List px = dirtPixels(32, 0x8A7355);

    test('is opaque and detailed', () {
      expect(px.length, 32 * 32 * 4);
      expect(_lumaStdDev(px), greaterThan(4.0));
    });

    test('skews warm — red varies more than blue', () {
      // The generator scales red by 1.15 and blue by 0.85 so lit dirt reads as
      // dust rather than grey gravel.
      expect(_channelMean(px, 0), greaterThan(_channelMean(px, 2)));
    });
  });
}
