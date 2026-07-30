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

/// A pooled coin. Carries **no `Node`** — coins are one `InstancedMesh`, and a
/// coin's position in `_coins` is its instance index.
class _Coin {
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

/// One roadside tree, as instance bookkeeping rather than a node tree.
///
/// A tree's parts live in different `InstancedMesh`es depending on its type
/// (pine vs round) and its foliage colour, because a batch binds one material.
/// [slot] is this tree's index **inside its foliage group's** meshes, which is
/// not its index in `_trees`; [trunkSlot] is its index in the single shared
/// trunk mesh.
class _Tree {
  _Tree({
    required this.x,
    required this.phaseZ,
    required this.scale,
    required this.pine,
    required this.foliage,
    required this.slot,
    required this.trunkSlot,
  });

  final double x;
  final double phaseZ;
  final double scale;
  final bool pine;
  final _TreeFoliage foliage;
  final int slot;
  final int trunkSlot;
}

/// The instanced meshes for one foliage colour.
///
/// Pines and round trees never share a mesh even at the same colour — their
/// geometries differ — so a colour that both types use carries both lists.
/// Empty lists are normal: a colour only reachable by round trees has no pine
/// tiers, and unused meshes are never added to the scene.
class _TreeFoliage {
  _TreeFoliage(this.colorHex);

  final int colorHex;

  /// Three stacked cone tiers, widest first.
  final List<InstancedMesh> pineTiers = <InstancedMesh>[];

  /// Crown spheres by radius: 0.64 centre, 0.42 side blob, 0.40 top blob.
  /// The 0.42 mesh carries **two** instances per tree (see `_Tree.slot`).
  final List<InstancedMesh> roundBlobs = <InstancedMesh>[];

  int pineCount = 0;
  int roundCount = 0;
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

/// A pooled particle. Like [_Coin] it carries no `Node`: particles are
/// instanced, and a particle's index within its pool is its instance index.
class _Particle {
  bool active = false;
  final vm.Vector3 pos = vm.Vector3.zero();
  final vm.Vector3 vel = vm.Vector3.zero();
  double life = 0;
  double maxLife = 1;
}

/// One instanced set of particles, all sharing a colour.
///
/// Instancing binds a single material for the whole batch, so recolouring a
/// particle at spawn — which is what the old per-particle `UnlitMaterial` did
/// — is impossible. Splitting the fixed set of burst colours into their own
/// pools buys the draw-call win back without losing the colour coding: a
/// burst just picks the pool matching its colour.
class _ParticlePool {
  _ParticlePool(this.colorHex, this.mesh, int count) {
    for (int i = 0; i < count; i++) {
      parts.add(_Particle());
      mesh.addInstance(vm.Matrix4.identity());
    }
  }

  final int colorHex;
  final InstancedMesh mesh;
  final List<_Particle> parts = <_Particle>[];

  /// First inactive particle, or null when the pool is exhausted (a burst
  /// then simply emits fewer than it asked for, which is invisible in play).
  _Particle? free() {
    for (final _Particle p in parts) {
      if (!p.active) return p;
    }
    return null;
  }
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
