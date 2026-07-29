/// Pure, GPU-free gameplay math for flutter-scene-runner.
///
/// Everything here is a plain function over numbers — no Flutter, no
/// `flutter_scene`, no state, no I/O. That is the whole point of the file.
///
/// The game itself cannot be unit-tested: `_GamePageState` builds a `Scene()`
/// in a *field initializer*, so it runs the instant `GamePage` mounts and
/// needs a GPU context that headless `flutter_test` does not have. Pumping the
/// app throws before any assertion runs (see CLAUDE.md). Pulling the
/// arithmetic out here is what makes any of it reachable from a test at all.
///
/// Rules for this file:
/// * Never import `flutter_scene`, `flutter/material.dart`, or anything that
///   touches a GPU, a binding, or the filesystem. `vector_math` is fine — it
///   is plain math.
/// * Keep every function total and side-effect free, so a test is a table of
///   inputs and expected outputs.
/// * `test/game_math_test.dart` is the counterpart; add cases there when you
///   add a function here.
library;

import 'dart:math' as math;

import 'package:vector_math/vector_math.dart' as vm;

/// World x of a lane index.
///
/// **The sign is inverted relative to intuition**: lane `1` sits at *negative*
/// x. This trips everyone up, which is exactly why the mapping lives in one
/// named place instead of being written inline at each call site.
double laneX(int lane, double laneWidth) => -lane * laneWidth;

/// Maps a fixed phase offset into the visible span `[zFar, zFar + totalLen)`.
///
/// This is the endless-scroll illusion: nothing ever travels the length of the
/// world and the camera never moves forward. A node keeps one constant phase
/// for its whole life, and the scroll amount slides every phase through the
/// same window. Negative z is far, positive z is near.
double wrapZ(double phase, double scroll, double zFar, double totalLen) =>
    zFar + ((phase + scroll) % totalLen);

/// Frame-rate-independent smoothing factor for an exponential approach.
///
/// Use `value += (target - value) * smoothing(rate, dt)` rather than a raw
/// lerp constant: a raw factor makes the approach speed depend on the frame
/// rate, so the same code feels different at 30 and 120 fps.
double smoothing(double rate, double dt) => 1 - math.exp(-rate * dt);

/// Whether two centres on one axis are closer than the sum of their half
/// extents — one axis of a symmetric AABB test. All three axes must overlap
/// for a real hit.
bool overlaps1D(double centreA, double centreB, double halfSum) =>
    (centreA - centreB).abs() < halfSum;

/// Difficulty ramp: speed rises linearly with elapsed time and then holds.
double speedAt(
  double elapsed, {
  required double base,
  required double max,
  required double rampPerSec,
}) =>
    math.min(max, base + elapsed * rampPerSec);

/// Clamps a frame delta so a hitch (a GC pause, a window resize, the tab
/// coming back from the background) cannot teleport the runner through an
/// obstacle. Bounding dt is cheaper and far more predictable than running a
/// sub-stepped integrator.
double clampDt(double dt, double maxDt) => dt > maxDt ? maxDt : dt;

/// Converts a `0xAARRGGBB` sRGB value to linear-space RGBA.
///
/// **Required for any `material.baseColorFactor`.** The renderer works in
/// linear space; handing it a raw hex-derived value gives visibly wrong
/// (washed-out) colour. The 2.2 exponent is the standard sRGB approximation.
vm.Vector4 linearFromHex(int hex) {
  double lin(int c) => math.pow(c / 255.0, 2.2).toDouble();
  final double a = ((hex >> 24) & 0xFF) / 255.0;
  final double r = lin((hex >> 16) & 0xFF);
  final double g = lin((hex >> 8) & 0xFF);
  final double b = lin(hex & 0xFF);
  return vm.Vector4(r, g, b, a);
}

/// Like [linearFromHex] but scales RGB by [glow] to push bright accents past
/// the bloom threshold. Alpha is preserved, and `glow == 1.0` is a no-op.
vm.Vector4 glowFromHex(int hex, double glow) {
  final vm.Vector4 c = linearFromHex(hex);
  if (glow == 1.0) return c;
  return vm.Vector4(c.r * glow, c.g * glow, c.b * glow, c.a);
}

/// English ordinal for a leaderboard position: 1 -> `1st`, 12 -> `12th`.
///
/// The 11-13 special case cannot be reached by the current top-5 board, but
/// the rule is cheap to state correctly and the board size is a constant that
/// could move.
String ordinal(int n) {
  if (n % 100 >= 11 && n % 100 <= 13) return '${n}th';
  switch (n % 10) {
    case 1:
      return '${n}st';
    case 2:
      return '${n}nd';
    case 3:
      return '${n}rd';
    default:
      return '${n}th';
  }
}
