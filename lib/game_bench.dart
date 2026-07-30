/// Frame-time benchmark probe.
///
/// Exists because the HUD's fps readout is unusable for comparing builds: it is
/// an exponential moving average read off a screenshot, its variance is roughly
/// ±8 fps, and a single throttled frame drags it down for seconds afterwards.
/// Trying to detect a 3 fps change with it produces noise, not measurements.
///
/// This collects raw frame deltas instead and reports the **median**, which is
/// immune to the one failure mode that ruins every other statistic here: when
/// the window stops being frontmost, the browser and macOS both stop delivering
/// frames, and the resulting handful of 500 ms deltas would swamp a mean.
///
/// Off unless the build asks for it:
/// ```
/// fvm flutter build web --release --dart-define=BENCH=true --base-href /flutter-scene-runner/
/// fvm flutter run -d macos --release --dart-define=BENCH=true --enable-flutter-gpu --enable-impeller
/// ```
/// It then prints one `BENCH` line per window to the console (readable in
/// devtools on web, or in the `flutter run` log on native). A normal build
/// compiles the whole thing out via the `const` guard.
library;

/// Whether this build collects frame timings. See the library doc for how to
/// turn it on; `const` so a normal build tree-shakes the probe away entirely.
const bool kBenchEnabled = bool.fromEnvironment('BENCH');

/// Seconds of frames per reported window.
const double _kWindowSeconds = 5.0;

/// One 60 Hz vsync interval, plus a hair of slack.
///
/// `hit60` — the share of frames landing under this — is the number that
/// actually matters here, and the reason this probe exists. The frame budget
/// sits right on the boundary: a frame that misses 16.67 ms by any margin
/// waits for the next vsync and costs 33.3 ms, so the distribution is bimodal
/// and a *mean* reads ~37 fps while half the frames are hitting a clean 60.
/// Optimising against the mean therefore hides the only thing worth moving —
/// how many frames make it under the line.
const double _kVsyncMs = 17.0;

/// Frames per reported window, whichever limit is reached first.
///
/// The time limit alone is not enough: when the window is not frontmost the
/// host stops delivering frames entirely, so `_elapsed` freezes and a
/// time-only window never closes — which reads as "the probe is broken"
/// rather than "nothing is rendering". Closing on a frame count as well means
/// a window always eventually reports, and its `dropped` count says plainly
/// whether the samples are trustworthy.
const int _kWindowFrames = 300;

/// Frames slower than this are dropped before the statistics are computed.
///
/// Nothing in this game legitimately takes a third of a second. A delta that
/// long means the window lost focus, the tab was backgrounded, or the browser
/// stalled on a resource — none of which is the thing being measured.
const double _kOutlierMs = 300.0;

/// Collects frame deltas and reports a summary line per window.
class FrameBench {
  final List<double> _ms = <double>[];
  double _elapsed = 0;
  int _window = 0;
  int _dropped = 0;

  /// Feeds one frame delta, in seconds. Call once per tick, with the **raw**
  /// delta — not the clamped one the simulation uses, or every reading below
  /// 20 fps silently reads as exactly 20.
  ///
  /// Returns a summary line when a window completes, otherwise null.
  String? addFrame(double dtSeconds) {
    if (dtSeconds <= 0) return null;
    final double ms = dtSeconds * 1000.0;
    _elapsed += dtSeconds;
    if (ms > _kOutlierMs) {
      _dropped++;
    } else {
      _ms.add(ms);
    }
    if (_elapsed < _kWindowSeconds && _ms.length + _dropped < _kWindowFrames) {
      return null;
    }

    final String line = _summarise();
    _ms.clear();
    _elapsed = 0;
    _dropped = 0;
    _window++;
    return line;
  }

  String _summarise() {
    if (_ms.length < 5) {
      return 'BENCH win=$_window n=${_ms.length} dropped=$_dropped '
          '(too few frames — was the window frontmost?)';
    }
    final List<double> s = List<double>.of(_ms)..sort();
    double sum = 0;
    int hit = 0;
    for (final double v in s) {
      sum += v;
      if (v <= _kVsyncMs) hit++;
    }
    final double mean = sum / s.length;
    final double hitPct = 100.0 * hit / s.length;
    return 'BENCH win=$_window n=${s.length} dropped=$_dropped '
        'hit60=${hitPct.toStringAsFixed(1)}% '
        'mean=${mean.toStringAsFixed(2)}ms/${_fps(mean)}fps '
        'median=${_percentile(s, 0.50).toStringAsFixed(2)}ms '
        'p95=${_percentile(s, 0.95).toStringAsFixed(2)}ms';
  }

  /// Nearest-rank percentile of an already-sorted list.
  static double _percentile(List<double> sorted, double q) {
    final int i = (q * (sorted.length - 1)).round().clamp(0, sorted.length - 1);
    return sorted[i];
  }

  static String _fps(double ms) => (1000.0 / ms).toStringAsFixed(1);
}
