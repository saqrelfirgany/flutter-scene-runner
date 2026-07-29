// Part of the flutter-scene-runner library — see lib/main.dart.
// `part of` keeps the game one library so the sim/render split can use
// library-private access (e.g. _GamePainter reads _GamePageState fields).
part of 'main.dart';

class _Obstacle {
  _Obstacle(this.node);
  final Node node;
  bool active = false;
  int lane = 0;
  double z = 0;
}

class _Coin {
  _Coin(this.node);
  final Node node;
  bool active = false;
  int lane = 0;
  double z = 0;
  double cx = 0; // continuous x; eased toward the runner while a magnet is up
  double y = 0; // per-coin height, so a line can be laid out as a rising arc
  // Where cx settles when no magnet is pulling. Not simply the lane centre:
  // a drifting trail places each coin part-way between two lanes, and easing
  // back to the lane centre would straighten the curve out.
  double restX = 0;
}

/// A launch ramp. Additive only — it never blocks the runner, it just
/// replaces a grounded jump with a stronger one while overlapped.
class _Ramp {
  _Ramp(this.node);
  final Node node;
  bool active = false;
  int lane = 0;
  double z = 0;
}

class _PowerUp {
  _PowerUp(this.node, this.material);
  final Node node;
  final UnlitMaterial material; // recolored per kind on spawn
  bool active = false;
  PowerKind kind = PowerKind.magnet;
  int lane = 0;
  double z = 0;
}

class _Score {
  _Score(this.name, this.score);
  final String name;
  final int score;
}

class _Popup {
  _Popup(this.text, this.x, this.y);
  final String text;
  final double x; // screen x (fixed at spawn)
  double y; // screen y (rises over life)
  double age = 0;
  static const double life = 0.85;
}

class _Particle {
  _Particle(this.node, this.material);
  final Node node;
  final UnlitMaterial material;
  bool active = false;
  final vm.Vector3 pos = vm.Vector3.zero();
  final vm.Vector3 vel = vm.Vector3.zero();
  double life = 0;
  double maxLife = 1;
}

// Colour conversion lives in `game_math.dart` so it is unit-testable; these
// two are the library-private aliases the rest of the game calls, kept so the
// ~30 existing call sites read the same as before.
vm.Vector4 _linearFromHex(int hex) => gm.linearFromHex(hex);

vm.Vector4 _glowFromHex(int hex, double glow) => gm.glowFromHex(hex, glow);

/// Tiny SFX wrapper: one reusable player per sound, played from bundled WAVs.
/// [volume] `0` mutes (playback is skipped); failures are swallowed so audio
/// can never interrupt the game loop.
class _Audio {
  final AudioPlayer _coin = AudioPlayer(playerId: 'sfx_coin');
  final AudioPlayer _jump = AudioPlayer(playerId: 'sfx_jump');
  final AudioPlayer _crash = AudioPlayer(playerId: 'sfx_crash');
  final AudioPlayer _power = AudioPlayer(playerId: 'sfx_power');
  double volume = 0.9;

  Future<void> init() async {
    for (final AudioPlayer p in <AudioPlayer>[_coin, _jump, _crash, _power]) {
      try {
        await p.setReleaseMode(ReleaseMode.stop);
      } catch (_) {}
    }
  }

  void _play(AudioPlayer p, String asset) {
    if (volume <= 0) return;
    p.play(AssetSource(asset), volume: volume).catchError((Object _) {});
  }

  void coin() => _play(_coin, 'sfx/coin.wav');
  void jump() => _play(_jump, 'sfx/jump.wav');
  void crash() => _play(_crash, 'sfx/crash.wav');
  void power() => _play(_power, 'sfx/power.wav');

  void dispose() {
    for (final AudioPlayer p in <AudioPlayer>[_coin, _jump, _crash, _power]) {
      p.dispose();
    }
  }
}
