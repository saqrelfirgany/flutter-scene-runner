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

/// Convert a 0xAARRGGBB sRGB value to a linear-space RGBA for baseColorFactor.
vm.Vector4 _linearFromHex(int hex) {
  double lin(int c) => math.pow(c / 255.0, 2.2).toDouble();
  final double a = ((hex >> 24) & 0xFF) / 255.0;
  final double r = lin((hex >> 16) & 0xFF);
  final double g = lin((hex >> 8) & 0xFF);
  final double b = lin(hex & 0xFF);
  return vm.Vector4(r, g, b, a);
}

/// Like [_linearFromHex] but scales RGB by [glow] to push bright accents past
/// the bloom threshold (alpha preserved). `glow == 1.0` returns it unchanged.
vm.Vector4 _glowFromHex(int hex, double glow) {
  final vm.Vector4 c = _linearFromHex(hex);
  if (glow == 1.0) return c;
  return vm.Vector4(c.r * glow, c.g * glow, c.b * glow, c.a);
}

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
