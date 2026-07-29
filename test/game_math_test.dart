// The project's first tests.
//
// These deliberately cover `lib/game_math.dart` only. The game widget cannot
// be pumped: `_GamePageState` constructs a `Scene()` in a field initializer,
// which needs Impeller/Flutter GPU, and `flutter_test` is headless — pumping
// `RunnerApp` throws before any expectation runs. So the testable surface is
// exactly the pure math, which is why it was extracted.
//
// Run: `fvm flutter test`  (or `fvm flutter test test/game_math_test.dart`)

import 'dart:math' as math;

import 'package:flutter_scene_runner/game_math.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;

void main() {
  group('laneX', () {
    test('inverts the sign — lane 1 is at negative x', () {
      expect(laneX(1, 2.0), -2.0);
      expect(laneX(-1, 2.0), 2.0);
      expect(laneX(0, 2.0), 0.0);
    });

    test('scales with lane width', () {
      expect(laneX(1, 3.5), -3.5);
    });
  });

  group('wrapZ', () {
    const double zFar = -62.0;
    const double totalLen = 72.0;

    test('lands inside [zFar, zFar + totalLen) for any scroll', () {
      for (double scroll = 0; scroll < 500; scroll += 7.3) {
        final double z = wrapZ(12.0, scroll, zFar, totalLen);
        expect(z, greaterThanOrEqualTo(zFar));
        expect(z, lessThan(zFar + totalLen));
      }
    });

    test('is periodic in scroll with period totalLen', () {
      final double a = wrapZ(5.0, 3.0, zFar, totalLen);
      final double b = wrapZ(5.0, 3.0 + totalLen, zFar, totalLen);
      expect(b, closeTo(a, 1e-9));
    });

    test('advancing scroll moves a node toward the camera (+z)', () {
      // Negative z is far, positive z is near, so z must increase until it
      // wraps. Chosen to stay well inside one period.
      final double before = wrapZ(0.0, 1.0, zFar, totalLen);
      final double after = wrapZ(0.0, 2.0, zFar, totalLen);
      expect(after, greaterThan(before));
    });
  });

  group('smoothing', () {
    test('is 0 at dt 0 and approaches 1 for a long frame', () {
      expect(smoothing(12.0, 0.0), 0.0);
      expect(smoothing(12.0, 10.0), closeTo(1.0, 1e-6));
    });

    test('two half-steps land where one full step does (frame-rate safe)', () {
      // The property that a raw lerp factor does NOT have.
      const double rate = 12.0;
      const double dt = 1 / 30;
      double single = 0.0;
      single += (1.0 - single) * smoothing(rate, dt);

      double split = 0.0;
      split += (1.0 - split) * smoothing(rate, dt / 2);
      split += (1.0 - split) * smoothing(rate, dt / 2);

      expect(split, closeTo(single, 1e-12));
    });
  });

  group('overlaps1D', () {
    test('touching exactly is not an overlap', () {
      expect(overlaps1D(0.0, 1.0, 1.0), isFalse);
    });

    test('closer than the half sum overlaps, farther does not', () {
      expect(overlaps1D(0.0, 0.9, 1.0), isTrue);
      expect(overlaps1D(0.0, 1.1, 1.0), isFalse);
    });

    test('is symmetric', () {
      expect(overlaps1D(3.0, 1.0, 2.5), overlaps1D(1.0, 3.0, 2.5));
    });
  });

  group('speedAt', () {
    test('starts at base and ramps linearly', () {
      expect(speedAt(0, base: 15, max: 32, rampPerSec: 0.45), 15.0);
      expect(speedAt(10, base: 15, max: 32, rampPerSec: 0.45),
          closeTo(19.5, 1e-9));
    });

    test('never exceeds max, however long the run', () {
      expect(speedAt(100000, base: 15, max: 32, rampPerSec: 0.45), 32.0);
    });
  });

  group('clampDt', () {
    test('passes normal frames through untouched', () {
      expect(clampDt(1 / 60, 0.05), closeTo(1 / 60, 1e-12));
    });

    test('caps a hitch so nothing tunnels through an obstacle', () {
      expect(clampDt(2.5, 0.05), 0.05);
    });
  });

  // NOTE for anyone adding cases below: `vm.Vector4` stores its components as
  // **float32**, not double. Comparing a component against a double computed
  // in Dart needs a float32-sized tolerance (~1e-6); 1e-9 can never pass, no
  // matter how correct the function is.
  group('linearFromHex', () {
    const double f32 = 1e-6;

    test('keeps alpha linear and black/white at the ends', () {
      final vm.Vector4 black = linearFromHex(0xFF000000);
      expect(black.r, 0.0);
      expect(black.a, 1.0);

      final vm.Vector4 white = linearFromHex(0xFFFFFFFF);
      expect(white.r, closeTo(1.0, f32));
      expect(white.a, 1.0);
    });

    test('applies the 2.2 gamma, i.e. mid grey darkens', () {
      final vm.Vector4 grey = linearFromHex(0xFF808080);
      expect(grey.r, closeTo(math.pow(128 / 255, 2.2).toDouble(), f32));
      // The whole point: linear mid-grey is well below sRGB 0.5.
      expect(grey.r, lessThan(0.25));
    });

    test('unpacks channels in ARGB order', () {
      final vm.Vector4 c = linearFromHex(0xFFFF0000);
      expect(c.r, closeTo(1.0, f32));
      expect(c.g, 0.0);
      expect(c.b, 0.0);
    });
  });

  group('glowFromHex', () {
    test('glow of 1.0 is exactly linearFromHex', () {
      final vm.Vector4 plain = linearFromHex(0xFFFFC93C);
      final vm.Vector4 glowed = glowFromHex(0xFFFFC93C, 1.0);
      expect(glowed.r, plain.r);
      expect(glowed.g, plain.g);
      expect(glowed.b, plain.b);
    });

    test('scales rgb past 1.0 but leaves alpha alone', () {
      final vm.Vector4 c = glowFromHex(0xFFFFFFFF, 2.4);
      expect(c.r, closeTo(2.4, 1e-6)); // float32 storage — see note above
      expect(c.a, 1.0);
    });
  });

  group('ordinal', () {
    test('covers the board positions actually reachable', () {
      expect(ordinal(1), '1st');
      expect(ordinal(2), '2nd');
      expect(ordinal(3), '3rd');
      expect(ordinal(4), '4th');
      expect(ordinal(5), '5th');
    });

    test('handles the 11-13 exception', () {
      expect(ordinal(11), '11th');
      expect(ordinal(12), '12th');
      expect(ordinal(13), '13th');
      expect(ordinal(21), '21st');
    });
  });
}
