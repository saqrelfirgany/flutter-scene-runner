import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_scene/scene.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vector_math/vector_math.dart' as vm;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Scene.initializeStaticResources();
  runApp(const RunnerApp());
}

enum Phase { menu, playing, crashed }

enum PowerKind { magnet, shield, doubleScore }

class RunnerApp extends StatelessWidget {
  const RunnerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'flutter-scene-runner',
      debugShowCheckedModeBanner: false,
      home: GamePage(),
    );
  }
}

class GamePage extends StatefulWidget {
  const GamePage({super.key});

  @override
  State<GamePage> createState() => _GamePageState();
}

class _GamePageState extends State<GamePage>
    with SingleTickerProviderStateMixin {
  // --- world tuning -------------------------------------------------------
  static const double roadWidth = 6.0;
  static const double laneWidth = 2.0;
  static const double segLen = 4.0;
  static const int tileCount = 18;
  static const double totalLen = tileCount * segLen;
  static const double zFar = -62.0;
  static const double roadTopY = -0.9;
  static const double groundY = roadTopY + 0.5;
  static const double runnerZ = 1.5;
  static const double runnerHalf = 0.5;

  // --- character (Dash) ---------------------------------------------------
  // The runner is the Flutter mascot (Dash), imported from a .glb at runtime
  // with Node.fromGlbAsset. Until it resolves, the debug cube stands in.
  static const String dashAsset = 'assets/models/dash.glb';
  static const double dashScale = 0.5; // model is ~2.95u tall -> ~1.48u here
  static const double dashYaw = math.pi; // face away from camera; flip to 0 if reversed
  static const double dashFootY = roadTopY; // feet rest on the road surface
  static const double dashTurnGain = 5.0; // yaw lean toward the entered lane
  static const double dashTurnMax = 0.45;
  static const double dashAnimBlend = 16.0; // Run/Idle/Jump crossfade speed

  // --- movement tuning ----------------------------------------------------
  static const double baseSpeed = 15.0;
  static const double maxSpeed = 32.0;
  static const double speedRampPerSec = 0.45;
  static const double laneLerp = 12.0;
  static const double gravity = 38.0;
  static const double jumpImpulse = 12.0;

  // --- obstacles ----------------------------------------------------------
  static const int obstacleCount = 10;
  static const double obHalfX = 0.6;
  static const double obHalfY = 0.5;
  static const double obHalfZ = 0.5;
  static const double obstacleCenterY = groundY;
  static const double obSpacing = 17.0;
  static const double firstSpawnDelay = 1.6;
  static const double wallChance = 0.35; // share of spawns that are 2-lane walls
  static const double wallAfter = 8.0; // seconds before walls start appearing

  // --- coins --------------------------------------------------------------
  static const int coinCount = 24;
  static const double coinY = groundY + 0.35;
  static const int coinsPerLine = 4;
  static const double coinGap = 2.5;
  static const double coinInterval = 1.7;
  static const int coinScore = 25;

  static const double spawnZ = -58.0;
  static const double despawnZ = 8.0;

  static const int postCount = 9;
  static const double postSpacing = totalLen / postCount;
  static const int dashCount = 18;
  static const double dashSpacing = totalLen / dashCount;

  // --- palette ------------------------------------------------------------
  static const Color cTeal = Color(0xFF4FD1C5);
  static const Color cGold = Color(0xFFFFC93C);
  static const Color cRed = Color(0xFFE0533D);
  static const Color cBg = Color(0xFF0E1220);

  // --- juice (Day 3B) -----------------------------------------------------
  static const int particleCount = 48;
  static const double particleGravity = 16.0;
  static const double shakeDuration = 0.4;

  // --- look: post-FX + neon glow (Improvement 4) --------------------------
  // Unlit colors sit in [0,1] linear, below bloom's HDR threshold, so accent
  // nodes are multiplied above 1.0 (see _box `glow`) to make them bloom.
  static const double coinGlow = 1.6;
  static const double postGlow = 2.2;
  static const double obstacleGlow = 1.6;
  static const double particleGlow = 2.0;
  static const double bloomThreshold = 1.0;
  static const double bloomIntensity = 0.55;
  static const double bloomScatter = 0.75;
  static const double vignetteIntensity = 0.34;
  static const int fogHex = 0xFF131A30; // tint the far road fades into
  static const double fogStart = 34.0; // world units from the camera
  static const double fogEnd = 62.0;

  // --- power-ups (Improvement 6) ------------------------------------------
  static const int powerupCount = 3; // pooled orbs (rarely >1 on screen)
  static const double powerRadius = 0.42;
  static const double powerY = groundY + 0.5;
  static const double powerFirstDelay = 7.0;
  static const double powerInterval = 13.0;
  static const double powerGlow = 2.4;
  static const double magnetDuration = 6.0;
  static const double doubleDuration = 8.0;
  static const double magnetRange = 12.0; // z-reach of the magnet
  static const double magnetPull = 9.0; // how fast coins slide to the runner
  static const int cMagnet = 0xFFB56BFF; // violet
  static const int cShield = 0xFF49B6FF; // azure
  static const int cDouble = 0xFFFF5CA8; // magenta

  final Scene _scene = Scene();
  final ValueNotifier<int> _repaint = ValueNotifier<int>(0);
  final FocusNode _focus = FocusNode();
  final math.Random _rng = math.Random();
  late final Ticker _ticker;
  Duration _last = Duration.zero;

  // --- live game state ----------------------------------------------------
  Phase _phase = Phase.menu;
  double _elapsed = 0;
  double _scrollZ = 0;
  int _lane = 0;
  double _runnerX = 0;
  double _prevRunnerX = 0;
  double _jumpY = 0;
  double _jumpV = 0;
  bool _grounded = true;
  double _obSpawnTimer = firstSpawnDelay;
  double _coinSpawnTimer = 2.0;
  double _score = 0;
  int _coinsCollected = 0;
  int _best = 0;
  double _shakeT = 0;
  double _swipeDx = 0;
  double _swipeDy = 0;

  // --- leaderboard (in-memory for now) ------------------------------------
  final List<_Score> _scores = <_Score>[];
  bool _enteringName = false;
  final TextEditingController _nameCtrl = TextEditingController();
  final FocusNode _nameFocus = FocusNode();

  double get _curSpeed =>
      math.min(maxSpeed, baseSpeed + _elapsed * speedRampPerSec);

  // --- nodes --------------------------------------------------------------
  final List<Node> _tiles = <Node>[];
  final List<Node> _postsL = <Node>[];
  final List<Node> _postsR = <Node>[];
  final List<Node> _dashesL = <Node>[];
  final List<Node> _dashesR = <Node>[];
  final List<_Obstacle> _obstacles = <_Obstacle>[];
  final List<_Coin> _coins = <_Coin>[];
  final List<_PowerUp> _powerups = <_PowerUp>[];
  final List<_Particle> _particles = <_Particle>[];
  late final Node _runner; // debug-cube placeholder, shown until Dash loads
  Node? _dash; // the Flutter Dash model; null until fromGlbAsset resolves
  // Blended locomotion clips + their eased weights: Idle on the menu, Run
  // while playing, Jump one-shot in the air. AnimationClip is unambiguous
  // (unlike Animation, Flutter has no class by that name).
  AnimationClip? _clipRun;
  AnimationClip? _clipIdle;
  AnimationClip? _clipJump;
  double _wRun = 0;
  double _wIdle = 1;
  double _wJump = 0;

  // power-up run state
  double _powerSpawnTimer = powerFirstDelay;
  double _magnetT = 0; // seconds of magnet remaining
  double _doubleT = 0; // seconds of ×2 remaining
  bool _shield = false; // one-hit shield charge

  // audio: one player per SFX, plus a 3-step volume the user cycles + persists.
  final _Audio _audio = _Audio();
  static const List<double> volumes = <double>[0.0, 0.45, 0.9];
  int _volLevel = 2; // index into volumes; 0 = muted

  static double _laneX(int lane) => -lane * laneWidth;

  @override
  void initState() {
    super.initState();
    _buildWorld();
    _setupSceneLook();
    _loadDash();
    _ticker = createTicker(_onTick)..start();
    _loadScores();
    _audio.init();
    _loadVolume();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  void _onTick(Duration elapsed) {
    double dt = _last == Duration.zero
        ? 0
        : (elapsed - _last).inMicroseconds / Duration.microsecondsPerSecond;
    _last = elapsed;
    if (dt > 0.05) dt = 0.05;
    if (_shakeT > 0) _shakeT = math.max(0, _shakeT - dt);
    _updateParticles(dt);
    _update(dt);
    _updateDashAnim(dt);
    _repaint.value++;
  }

  void _update(double dt) {
    if (_phase == Phase.crashed) return;

    if (_phase == Phase.menu) {
      // Attract mode: the road drifts, the runner idles. No spawns / scoring.
      _scrollZ += baseSpeed * dt;
      _elapsed += dt;
      return;
    }

    // --- playing ---
    final double v = _curSpeed;
    _elapsed += dt;
    _scrollZ += v * dt;
    _score += v * dt * 0.7 * (_doubleT > 0 ? 2.0 : 1.0);

    if (_magnetT > 0) _magnetT = math.max(0, _magnetT - dt);
    if (_doubleT > 0) _doubleT = math.max(0, _doubleT - dt);

    _prevRunnerX = _runnerX;
    final double targetX = _laneX(_lane);
    _runnerX += (targetX - _runnerX) * (1 - math.exp(-laneLerp * dt));

    if (!_grounded) {
      _jumpY += _jumpV * dt;
      _jumpV -= gravity * dt;
      if (_jumpY <= 0) {
        _jumpY = 0;
        _jumpV = 0;
        _grounded = true;
      }
    }

    _obSpawnTimer -= dt;
    if (_obSpawnTimer <= 0) {
      _spawnObstacle();
      _obSpawnTimer = obSpacing / v;
    }

    _coinSpawnTimer -= dt;
    if (_coinSpawnTimer <= 0) {
      _spawnCoinLine();
      _coinSpawnTimer = coinInterval;
    }

    _powerSpawnTimer -= dt;
    if (_powerSpawnTimer <= 0) {
      _spawnPowerUp();
      _powerSpawnTimer = powerInterval;
    }

    for (final _Obstacle o in _obstacles) {
      if (!o.active) continue;
      o.z += v * dt;
      if (o.z > despawnZ) {
        o.active = false;
        continue;
      }
      if (_hitsObstacle(o)) {
        if (_shield) {
          _shield = false; // absorb one hit and destroy the obstacle
          o.active = false;
          _spawnParticles(
              _laneX(o.lane), obstacleCenterY, o.z, 16, cShield, 5.0, 4.0);
          _audio.power();
        } else {
          _crash();
          return;
        }
      }
    }

    for (final _Coin c in _coins) {
      if (!c.active) continue;
      c.z += v * dt;
      if (c.z > despawnZ) {
        c.active = false;
        continue;
      }
      // Magnet: slide the coin's x toward the runner once it's within reach.
      final double targetX = (_magnetT > 0 && (c.z - runnerZ).abs() < magnetRange)
          ? _runnerX
          : _laneX(c.lane);
      c.cx += (targetX - c.cx) * (1 - math.exp(-magnetPull * dt));
      if (_collectsCoin(c)) {
        c.active = false;
        _coinsCollected++;
        _score += coinScore * (_doubleT > 0 ? 2 : 1);
        _spawnParticles(c.cx, coinY, c.z, 7, 0xFFFFC93C, 3.5, 3.0);
        _audio.coin();
      }
    }

    for (final _PowerUp p in _powerups) {
      if (!p.active) continue;
      p.z += v * dt;
      if (p.z > despawnZ) {
        p.active = false;
        continue;
      }
      if (_collectsPower(p)) {
        p.active = false;
        _activatePower(p.kind);
        _spawnParticles(
            _laneX(p.lane), powerY, p.z, 18, _powerColor(p.kind), 5.5, 4.5);
        _audio.power();
      }
    }
  }

  void _spawnObstacle() {
    // After the opening seconds, some spawns are two-lane walls with a single
    // open lane, forcing a deliberate lane change. One lane is always left free.
    if (_elapsed > wallAfter && _rng.nextDouble() < wallChance) {
      final int openLane = _rng.nextInt(3) - 1;
      for (int lane = -1; lane <= 1; lane++) {
        if (lane != openLane) _placeObstacle(lane);
      }
    } else {
      _placeObstacle(_rng.nextInt(3) - 1);
    }
  }

  void _placeObstacle(int lane) {
    for (final _Obstacle o in _obstacles) {
      if (!o.active) {
        o.active = true;
        o.lane = lane;
        o.z = spawnZ;
        return;
      }
    }
  }

  void _spawnCoinLine() {
    final int lane = _rng.nextInt(3) - 1;
    int placed = 0;
    for (final _Coin c in _coins) {
      if (placed >= coinsPerLine) break;
      if (!c.active) {
        c.active = true;
        c.lane = lane;
        c.cx = _laneX(lane);
        c.z = spawnZ - placed * coinGap;
        placed++;
      }
    }
  }

  bool _hitsObstacle(_Obstacle o) {
    final double runnerY = groundY + _jumpY;
    final double dx = (_runnerX - _laneX(o.lane)).abs();
    final double dy = (runnerY - obstacleCenterY).abs();
    final double dz = (runnerZ - o.z).abs();
    return dx < (runnerHalf + obHalfX) &&
        dy < (runnerHalf + obHalfY) &&
        dz < (runnerHalf + obHalfZ);
  }

  bool _collectsCoin(_Coin c) {
    final double runnerY = groundY + _jumpY;
    final double dx = (_runnerX - c.cx).abs();
    final double dy = (runnerY - coinY).abs();
    final double dz = (runnerZ - c.z).abs();
    return dx < 1.0 && dy < 1.8 && dz < 0.9;
  }

  void _spawnPowerUp() {
    for (final _PowerUp p in _powerups) {
      if (!p.active) {
        p.active = true;
        p.kind = PowerKind.values[_rng.nextInt(PowerKind.values.length)];
        p.lane = _rng.nextInt(3) - 1;
        p.z = spawnZ;
        p.material.baseColorFactor = _glowFromHex(_powerColor(p.kind), powerGlow);
        return;
      }
    }
  }

  bool _collectsPower(_PowerUp p) {
    final double runnerY = groundY + _jumpY;
    final double dx = (_runnerX - _laneX(p.lane)).abs();
    final double dy = (runnerY - powerY).abs();
    final double dz = (runnerZ - p.z).abs();
    return dx < 1.1 && dy < 1.8 && dz < 1.0;
  }

  void _activatePower(PowerKind k) {
    switch (k) {
      case PowerKind.magnet:
        _magnetT = magnetDuration;
        break;
      case PowerKind.shield:
        _shield = true;
        break;
      case PowerKind.doubleScore:
        _doubleT = doubleDuration;
        break;
    }
  }

  static int _powerColor(PowerKind k) {
    switch (k) {
      case PowerKind.magnet:
        return cMagnet;
      case PowerKind.shield:
        return cShield;
      case PowerKind.doubleScore:
        return cDouble;
    }
  }

  void _spawnParticles(double x, double y, double z, int count, int colorHex,
      double spread, double lift) {
    for (int n = 0; n < count; n++) {
      final _Particle? p = _freeParticle();
      if (p == null) return;
      p.active = true;
      p.pos.setValues(x, y, z);
      final double ang = _rng.nextDouble() * math.pi * 2;
      final double sp = spread * (0.4 + _rng.nextDouble());
      p.vel.setValues(math.cos(ang) * sp, lift * (0.6 + _rng.nextDouble()),
          math.sin(ang) * sp);
      p.maxLife = 0.5 + _rng.nextDouble() * 0.35;
      p.life = p.maxLife;
      p.material.baseColorFactor = _glowFromHex(colorHex, particleGlow);
    }
  }

  _Particle? _freeParticle() {
    for (final _Particle p in _particles) {
      if (!p.active) return p;
    }
    return null;
  }

  void _updateParticles(double dt) {
    for (final _Particle p in _particles) {
      if (!p.active) continue;
      p.life -= dt;
      if (p.life <= 0) {
        p.active = false;
        continue;
      }
      p.vel.y -= particleGravity * dt;
      p.pos.x += p.vel.x * dt;
      p.pos.y += p.vel.y * dt;
      p.pos.z += p.vel.z * dt;
    }
  }

  bool _isHighScore(int s) =>
      s > 0 && (_scores.length < 5 || s > _scores.last.score);

  void _crash() {
    if (_phase != Phase.playing) return;
    final int s = _score.round();
    _best = math.max(_best, s);
    _shakeT = shakeDuration;
    _spawnParticles(_runnerX, groundY + _jumpY, runnerZ, 22, 0xFFE0533D, 5.0, 5.0);
    _audio.crash();
    final bool high = _isHighScore(s);
    setState(() {
      _phase = Phase.crashed;
      _enteringName = high;
      _nameCtrl.text = '';
    });
    if (high) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _nameFocus.requestFocus();
      });
    }
  }

  void _submitName() {
    final String raw = _nameCtrl.text.trim().replaceAll('|', ' ');
    final String name =
        raw.isEmpty ? 'YOU' : (raw.length > 12 ? raw.substring(0, 12) : raw);
    _scores.add(_Score(name, _score.round()));
    _scores.sort((a, b) => b.score.compareTo(a.score));
    if (_scores.length > 5) _scores.removeRange(5, _scores.length);
    _saveScores();
    setState(() => _enteringName = false);
    _focus.requestFocus();
  }

  Future<void> _loadScores() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final List<String> raw =
          prefs.getStringList('leaderboard.v1') ?? <String>[];
      final List<_Score> loaded = <_Score>[];
      for (final String e in raw) {
        final int idx = e.indexOf('|');
        if (idx <= 0) continue;
        final int? sc = int.tryParse(e.substring(0, idx));
        if (sc == null) continue;
        loaded.add(_Score(e.substring(idx + 1), sc));
      }
      loaded.sort((a, b) => b.score.compareTo(a.score));
      if (!mounted) return;
      setState(() {
        _scores
          ..clear()
          ..addAll(loaded.take(5));
      });
    } catch (_) {
      // ignore load errors — start with an empty board
    }
  }

  Future<void> _saveScores() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        'leaderboard.v1',
        _scores.map((_Score s) => '${s.score}|${s.name}').toList(),
      );
    } catch (_) {}
  }

  void _resetRun() {
    _elapsed = 0;
    _scrollZ = 0;
    _lane = 0;
    _runnerX = 0;
    _prevRunnerX = 0;
    _jumpY = 0;
    _jumpV = 0;
    _grounded = true;
    _obSpawnTimer = firstSpawnDelay;
    _coinSpawnTimer = 2.0;
    _score = 0;
    _coinsCollected = 0;
    for (final _Obstacle o in _obstacles) {
      o.active = false;
    }
    for (final _Coin c in _coins) {
      c.active = false;
    }
    for (final _PowerUp p in _powerups) {
      p.active = false;
    }
    for (final _Particle p in _particles) {
      p.active = false;
    }
    _powerSpawnTimer = powerFirstDelay;
    _magnetT = 0;
    _doubleT = 0;
    _shield = false;
    _shakeT = 0;
  }

  void _startGame() {
    _resetRun();
    setState(() {
      _phase = Phase.playing;
      _enteringName = false;
    });
    _focus.requestFocus();
  }

  void _goMenu() {
    _resetRun();
    setState(() {
      _phase = Phase.menu;
      _enteringName = false;
    });
    _focus.requestFocus();
  }

  KeyEventResult _onKey(KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final LogicalKeyboardKey k = e.logicalKey;

    if (_phase == Phase.menu) {
      if (k == LogicalKeyboardKey.space || k == LogicalKeyboardKey.enter) {
        _startGame();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    if (_phase == Phase.crashed) {
      if (_enteringName) return KeyEventResult.ignored; // TextField owns keys
      if (k == LogicalKeyboardKey.space || k == LogicalKeyboardKey.enter) {
        _startGame();
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.keyM || k == LogicalKeyboardKey.escape) {
        _goMenu();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    // playing
    if (k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.keyA) {
      _moveLane(-1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowRight || k == LogicalKeyboardKey.keyD) {
      _moveLane(1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.space ||
        k == LogicalKeyboardKey.arrowUp ||
        k == LogicalKeyboardKey.keyW) {
      _jump();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _moveLane(int dir) {
    if (_phase != Phase.playing) return;
    _lane = dir > 0 ? math.min(1, _lane + 1) : math.max(-1, _lane - 1);
  }

  void _jump() {
    if (_phase != Phase.playing) return;
    if (_grounded) {
      _grounded = false;
      _jumpV = jumpImpulse;
      _clipJump?.replay(); // restart the jump one-shot from frame 0
      _audio.jump();
    }
  }

  void _handleSwipe() {
    if (_phase != Phase.playing) return;
    if (_swipeDx.abs() > _swipeDy.abs() && _swipeDx.abs() > 18) {
      _moveLane(_swipeDx > 0 ? 1 : -1);
    } else if (_swipeDy < -18) {
      _jump();
    }
  }

  void _buildWorld() {
    const int shadeA = 0xFF232A3A;
    const int shadeB = 0xFF2E3750;
    for (int i = 0; i < tileCount; i++) {
      final Node node = _box(vm.Vector3(roadWidth, 0.2, segLen * 0.96),
          colorHex: i.isEven ? shadeA : shadeB);
      _tiles.add(node);
      _scene.add(node);
    }
    const int dashColor = 0xFFE7C24B;
    for (int k = 0; k < dashCount; k++) {
      final Node l = _box(vm.Vector3(0.14, 0.06, 1.4), colorHex: dashColor);
      final Node r = _box(vm.Vector3(0.14, 0.06, 1.4), colorHex: dashColor);
      _dashesL.add(l);
      _dashesR.add(r);
      _scene.add(l);
      _scene.add(r);
    }
    const int postColor = 0xFF4FD1C5;
    for (int j = 0; j < postCount; j++) {
      final Node l =
          _box(vm.Vector3(0.3, 1.4, 0.3), colorHex: postColor, glow: postGlow);
      final Node r =
          _box(vm.Vector3(0.3, 1.4, 0.3), colorHex: postColor, glow: postGlow);
      _postsL.add(l);
      _postsR.add(r);
      _scene.add(l);
      _scene.add(r);
    }
    const int obstacleColor = 0xFFE0533D;
    for (int i = 0; i < obstacleCount; i++) {
      final Node n = _box(vm.Vector3(obHalfX * 2, obHalfY * 2, obHalfZ * 2),
          colorHex: obstacleColor, glow: obstacleGlow);
      _obstacles.add(_Obstacle(n));
      _scene.add(n);
    }
    const int coinColor = 0xFFFFC93C;
    for (int i = 0; i < coinCount; i++) {
      final Node n =
          _box(vm.Vector3(0.5, 0.5, 0.12), colorHex: coinColor, glow: coinGlow);
      _coins.add(_Coin(n));
      _scene.add(n);
    }
    for (int i = 0; i < powerupCount; i++) {
      final UnlitMaterial mat = UnlitMaterial()
        ..baseColorFactor = _glowFromHex(cMagnet, powerGlow);
      final Node n = Node(
          mesh: Mesh(
              IcosphereGeometry(radius: powerRadius, subdivisions: 2), mat));
      _powerups.add(_PowerUp(n, mat));
      _scene.add(n);
    }
    for (int i = 0; i < particleCount; i++) {
      final UnlitMaterial mat = UnlitMaterial()
        ..baseColorFactor = _linearFromHex(0xFFFFC93C);
      final Node n =
          Node(mesh: Mesh(CuboidGeometry(vm.Vector3(0.18, 0.18, 0.18)), mat));
      _particles.add(_Particle(n, mat));
      _scene.add(n);
    }

    _runner = _box(vm.Vector3(1.0, 1.0, 1.0), debug: true);
    _scene.add(_runner);
  }

  /// One-time scene look: distance fog (far objects dissolve into the
  /// background instead of popping in), neon bloom on the boosted accents, a
  /// gentle grade, and a soft vignette. Tone mapping (pbrNeutral) and exposure
  /// (1.0) keep their defaults, which already suit the imported Dash.
  void _setupSceneLook() {
    final vm.Vector4 f = _linearFromHex(fogHex);
    _scene.fog
      ..enabled = true
      ..mode = FogMode.linear
      ..color = vm.Vector3(f.r, f.g, f.b)
      ..start = fogStart
      ..end = fogEnd;

    _scene.postProcess.bloom
      ..enabled = true
      ..threshold = bloomThreshold
      ..intensity = bloomIntensity
      ..scatter = bloomScatter;

    _scene.postProcess.colorGrading
      ..enabled = true
      ..contrast = 1.06
      ..saturation = 1.14;

    _scene.postProcess.vignette
      ..enabled = true
      ..intensity = vignetteIntensity
      ..radius = 0.82
      ..smoothness = 0.5;
  }

  /// Imports the Dash model at runtime and wires up its locomotion clips.
  /// The heavy glTF decode happens once, on the menu, so a brief hitch is
  /// fine; if it throws we simply keep the placeholder cube and play on.
  Future<void> _loadDash() async {
    try {
      final Node dash = await Node.fromGlbAsset(dashAsset);
      if (!mounted) return;
      // Run and Idle loop continuously; the blend weights (set every frame in
      // _updateDashAnim) decide which one is visible. Jump is a one-shot,
      // re-triggered from frame 0 by _jump().
      final runClip =
          _makeClip(dash, const <String>['Run', 'Walk'], loop: true);
      if (runClip != null) {
        runClip.weight = 0;
        runClip.play();
      }
      _clipRun = runClip;
      final idleClip =
          _makeClip(dash, const <String>['Idle', 'Default'], loop: true);
      if (idleClip != null) {
        idleClip.weight = 1;
        idleClip.play();
      }
      _clipIdle = idleClip;
      final jumpClip =
          _makeClip(dash, const <String>['Jump', 'JumpStart'], loop: false);
      jumpClip?.weight = 0;
      _clipJump = jumpClip;
      _scene.add(dash);
      _dash = dash; // the ticker repaints every frame, so paint() picks it up
    } catch (e) {
      debugPrint('Dash model failed to load; keeping placeholder cube: $e');
    }
  }

  /// Creates a clip for the first animation in [names] that the model has,
  /// falling back to the model's first animation. Returns null if the model
  /// carries no animations at all.
  AnimationClip? _makeClip(Node node, List<String> names, {required bool loop}) {
    for (final String n in names) {
      final anim = node.findAnimationByName(n);
      if (anim != null) return node.createAnimationClip(anim)..loop = loop;
    }
    if (node.parsedAnimations.isNotEmpty) {
      return node.createAnimationClip(node.parsedAnimations.first)..loop = loop;
    }
    return null;
  }

  /// Eases the three locomotion weights toward the pose the current game
  /// state calls for. Runs every frame in all phases (the crashed early-out
  /// in _update doesn't reach here), so Dash settles back to Idle on the menu
  /// and after a crash.
  void _updateDashAnim(double dt) {
    if (_dash == null) return;
    final bool playing = _phase == Phase.playing;
    final double idleT = playing ? 0.0 : 1.0;
    final double jumpT = (playing && !_grounded) ? 1.0 : 0.0;
    final double runT = (playing && _grounded) ? 1.0 : 0.0;
    final double k = dt <= 0 ? 1.0 : (1 - math.exp(-dashAnimBlend * dt));
    _wIdle += (idleT - _wIdle) * k;
    _wRun += (runT - _wRun) * k;
    _wJump += (jumpT - _wJump) * k;
    _clipIdle?.weight = _wIdle;
    _clipRun?.weight = _wRun;
    _clipJump?.weight = _wJump;
  }

  Node _box(vm.Vector3 size,
      {int? colorHex, bool debug = false, double glow = 1.0}) {
    final UnlitMaterial material = UnlitMaterial();
    if (debug) material.vertexColorWeight = 1.0;
    if (colorHex != null) {
      material.baseColorFactor = _glowFromHex(colorHex, glow);
    }
    return Node(mesh: Mesh(CuboidGeometry(size, debugColors: debug), material));
  }

  @override
  void dispose() {
    _ticker.dispose();
    _repaint.dispose();
    _focus.dispose();
    _nameFocus.dispose();
    _nameCtrl.dispose();
    _audio.dispose();
    super.dispose();
  }

  Future<void> _loadVolume() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final int lvl = prefs.getInt('volume.v1') ?? 2;
      if (!mounted) return;
      setState(() => _volLevel = lvl.clamp(0, volumes.length - 1));
      _applyVolume();
    } catch (_) {}
  }

  void _applyVolume() => _audio.volume = volumes[_volLevel];

  void _cycleVolume() {
    setState(() => _volLevel = (_volLevel + 1) % volumes.length);
    _applyVolume();
    _focus.requestFocus();
    _saveVolume();
  }

  Future<void> _saveVolume() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setInt('volume.v1', _volLevel);
    } catch (_) {}
  }

  // --- UI -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: cBg,
      body: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: (FocusNode node, KeyEvent e) => _onKey(e),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            if (_enteringName) return;
            _focus.requestFocus();
            if (_phase == Phase.menu) _startGame();
          },
          onPanStart: (DragStartDetails d) {
            _swipeDx = 0;
            _swipeDy = 0;
          },
          onPanUpdate: (DragUpdateDetails d) {
            _swipeDx += d.delta.dx;
            _swipeDy += d.delta.dy;
          },
          onPanEnd: (DragEndDetails d) => _handleSwipe(),
          child: Stack(
            children: <Widget>[
              const Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: <Color>[Color(0xFF1B2340), Color(0xFF0B0E18)],
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                child: CustomPaint(
                  painter: _GamePainter(state: this, repaint: _repaint),
                ),
              ),
              const Positioned(
                left: 16,
                top: 14,
                child: Text(
                  'flutter-scene-runner',
                  style: TextStyle(color: Colors.white38, fontSize: 13),
                ),
              ),
              Positioned(
                right: 6,
                top: 6,
                child: IconButton(
                  onPressed: _cycleVolume,
                  tooltip: 'volume',
                  icon: Icon(
                    _volLevel == 0
                        ? Icons.volume_off_rounded
                        : _volLevel == 1
                            ? Icons.volume_down_rounded
                            : Icons.volume_up_rounded,
                    color: _volLevel == 0 ? Colors.white38 : cTeal,
                    size: 22,
                  ),
                ),
              ),
              if (_phase == Phase.playing) _hud(),
              if (_phase == Phase.playing)
                const Positioned(
                  left: 16,
                  right: 16,
                  bottom: 14,
                  child: Text(
                    'swipe or arrows to move  ·  swipe up / Space to jump',
                    style: TextStyle(color: Colors.white38, fontSize: 13),
                  ),
                ),
              if (_phase == Phase.menu) _menuOverlay(),
              if (_phase == Phase.crashed) _crashedOverlay(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _hud() {
    return Positioned(
      top: 12,
      left: 0,
      right: 0,
      child: IgnorePointer(
        child: ValueListenableBuilder<int>(
          valueListenable: _repaint,
          builder: (BuildContext context, int _, Widget? __) {
            return Column(
              children: <Widget>[
                Text(
                  '${_score.round()}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 42,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '●  $_coinsCollected      ${(_curSpeed * 5).round()} km/h',
                  style: const TextStyle(
                    color: cGold,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                _powerChips(),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _powerChips() {
    final List<Widget> chips = <Widget>[];
    if (_magnetT > 0) {
      chips.add(_powerChip('MAGNET  ${_magnetT.ceil()}', const Color(cMagnet)));
    }
    if (_doubleT > 0) {
      chips.add(_powerChip('×2  ${_doubleT.ceil()}', const Color(cDouble)));
    }
    if (_shield) chips.add(_powerChip('SHIELD', const Color(cShield)));
    if (chips.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(mainAxisSize: MainAxisSize.min, children: chips),
    );
  }

  Widget _powerChip(String label, Color color) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 4),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.85)),
      ),
      child: Text(
        label,
        style:
            TextStyle(color: color, fontSize: 13, fontWeight: FontWeight.w700),
      ),
    );
  }

  Widget _menuOverlay() {
    return Positioned.fill(
      child: Container(
        color: Colors.black54,
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Text(
              'flutter-scene-runner',
              style: TextStyle(
                color: Colors.white,
                fontSize: 34,
                fontWeight: FontWeight.w800,
                letterSpacing: 1,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              '3D endless runner · built on Flutter GPU',
              style: TextStyle(color: Colors.white54, fontSize: 14),
            ),
            const SizedBox(height: 26),
            _leaderboard(),
            const SizedBox(height: 22),
            _primaryButton('PLAY', _startGame),
            const SizedBox(height: 10),
            const Text(
              'tap  or  Space  to play',
              style: TextStyle(color: Colors.white38, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }

  Widget _leaderboard() {
    return Container(
      width: math.min(320.0, MediaQuery.sizeOf(context).width - 32),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0x14FFFFFF),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0x26FFFFFF)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const Text(
            'BEST SCORES',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: cTeal,
              fontSize: 13,
              fontWeight: FontWeight.w700,
              letterSpacing: 2,
            ),
          ),
          const SizedBox(height: 12),
          if (_scores.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 6),
              child: Text(
                'no scores yet — be the first!',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white38, fontSize: 14),
              ),
            )
          else
            ...List<Widget>.generate(_scores.length, (int i) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: <Widget>[
                    SizedBox(
                      width: 22,
                      child: Text(
                        '${i + 1}',
                        style: const TextStyle(
                            color: Colors.white38, fontSize: 15),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        _scores[i].name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 15),
                      ),
                    ),
                    Text(
                      '${_scores[i].score}',
                      style: const TextStyle(
                        color: cGold,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }

  Widget _crashedOverlay() {
    return Positioned.fill(
      child: Container(
        color: Colors.black54,
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Text(
              'CRASHED',
              style: TextStyle(
                color: cRed,
                fontSize: 52,
                fontWeight: FontWeight.w800,
                letterSpacing: 2,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Score  ${_score.round()}      Best  $_best',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 20),
            if (_enteringName) ..._nameEntry() else ..._crashButtons(),
          ],
        ),
      ),
    );
  }

  List<Widget> _nameEntry() {
    return <Widget>[
      const Text(
        'new best score — enter your name',
        style: TextStyle(color: cGold, fontSize: 15),
      ),
      const SizedBox(height: 10),
      SizedBox(
        width: 260,
        child: TextField(
          controller: _nameCtrl,
          focusNode: _nameFocus,
          autofocus: true,
          textAlign: TextAlign.center,
          maxLength: 12,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _submitName(),
          style: const TextStyle(color: Colors.white, fontSize: 18),
          decoration: const InputDecoration(
            counterText: '',
            hintText: 'YOU',
            hintStyle: TextStyle(color: Colors.white24),
            filled: true,
            fillColor: Color(0x14FFFFFF),
            border: OutlineInputBorder(borderSide: BorderSide.none),
          ),
        ),
      ),
      const SizedBox(height: 12),
      _primaryButton('SAVE', _submitName),
    ];
  }

  List<Widget> _crashButtons() {
    return <Widget>[
      Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _primaryButton('PLAY AGAIN', _startGame),
          const SizedBox(width: 12),
          OutlinedButton(
            onPressed: _goMenu,
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white,
              side: const BorderSide(color: Color(0x40FFFFFF)),
              padding:
                  const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text('MENU'),
          ),
        ],
      ),
      const SizedBox(height: 10),
      const Text(
        'Space  play again    ·    M  menu',
        style: TextStyle(color: Colors.white38, fontSize: 13),
      ),
    ];
  }

  Widget _primaryButton(String label, VoidCallback onTap) {
    return ElevatedButton(
      onPressed: onTap,
      style: ElevatedButton.styleFrom(
        backgroundColor: cTeal,
        foregroundColor: cBg,
        padding: const EdgeInsets.symmetric(horizontal: 34, vertical: 14),
        textStyle: const TextStyle(
            fontSize: 17, fontWeight: FontWeight.w800, letterSpacing: 1),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      child: Text(label),
    );
  }
}

class _GamePainter extends CustomPainter {
  _GamePainter({required this.state, required Listenable repaint})
      : super(repaint: repaint);

  final _GamePageState state;

  @override
  void paint(Canvas canvas, Size size) {
    final double scroll = state._scrollZ;
    final double t = state._elapsed;

    double wrapZ(double phase) =>
        _GamePageState.zFar + ((phase + scroll) % _GamePageState.totalLen);

    for (int i = 0; i < state._tiles.length; i++) {
      final double z = wrapZ(i * _GamePageState.segLen);
      state._tiles[i].localTransform =
          vm.Matrix4.translationValues(0, _GamePageState.roadTopY - 0.1, z);
    }

    for (int k = 0; k < state._dashesL.length; k++) {
      final double z = wrapZ(k * _GamePageState.dashSpacing);
      state._dashesL[k].localTransform = vm.Matrix4.translationValues(
          -_GamePageState.laneWidth / 2, _GamePageState.roadTopY + 0.02, z);
      state._dashesR[k].localTransform = vm.Matrix4.translationValues(
          _GamePageState.laneWidth / 2, _GamePageState.roadTopY + 0.02, z);
    }

    const double postX = _GamePageState.roadWidth / 2 + 0.6;
    for (int j = 0; j < state._postsL.length; j++) {
      final double z = wrapZ(j * _GamePageState.postSpacing);
      state._postsL[j].localTransform = vm.Matrix4.translationValues(
          -postX, _GamePageState.roadTopY + 0.5, z);
      state._postsR[j].localTransform = vm.Matrix4.translationValues(
          postX, _GamePageState.roadTopY + 0.5, z);
    }

    for (final _Obstacle o in state._obstacles) {
      if (o.active) {
        o.node.localTransform = vm.Matrix4.translationValues(
            _GamePageState._laneX(o.lane), _GamePageState.obstacleCenterY, o.z);
      } else {
        o.node.localTransform = vm.Matrix4.translationValues(0, -1000, 0);
      }
    }

    for (final _Coin c in state._coins) {
      if (c.active) {
        final vm.Matrix4 m =
            vm.Matrix4.translationValues(c.cx, _GamePageState.coinY, c.z);
        m.rotateY(t * 4.0);
        c.node.localTransform = m;
      } else {
        c.node.localTransform = vm.Matrix4.translationValues(0, -1000, 0);
      }
    }

    for (final _PowerUp p in state._powerups) {
      if (p.active) {
        final vm.Matrix4 m = vm.Matrix4.translationValues(
            _GamePageState._laneX(p.lane), _GamePageState.powerY, p.z);
        m.rotateY(t * 2.5);
        p.node.localTransform = m;
      } else {
        p.node.localTransform = vm.Matrix4.translationValues(0, -1000, 0);
      }
    }

    final double lateralV = state._runnerX - state._prevRunnerX;
    final Node? dash = state._dash;
    if (dash != null) {
      // Dash is loaded: feet on the road, facing forward, with a small yaw
      // lean toward the lane it's entering. The Run clip supplies the bob.
      final double turn = (lateralV * _GamePageState.dashTurnGain)
          .clamp(-_GamePageState.dashTurnMax, _GamePageState.dashTurnMax);
      final vm.Matrix4 dm = vm.Matrix4.translationValues(
        state._runnerX,
        _GamePageState.dashFootY + state._jumpY,
        _GamePageState.runnerZ,
      );
      dm.rotateY(_GamePageState.dashYaw + turn);
      dm.scale(_GamePageState.dashScale);
      dash.localTransform = dm;
      // Park the placeholder cube out of view.
      state._runner.localTransform =
          vm.Matrix4.translationValues(0, -1000, 0);
    } else {
      // Placeholder cube until the model finishes importing.
      final double lean = (lateralV * 6.0).clamp(-0.35, 0.35);
      final double idleBob =
          state._grounded ? math.sin(t * 3.0) * 0.06 : 0.0;
      final vm.Matrix4 rt = vm.Matrix4.translationValues(
        state._runnerX,
        _GamePageState.groundY + state._jumpY + idleBob,
        _GamePageState.runnerZ,
      );
      rt.rotateZ(-lean);
      rt.rotateY(t * 0.6);
      state._runner.localTransform = rt;
    }

    for (final _Particle p in state._particles) {
      if (p.active) {
        final double s = (p.life / p.maxLife).clamp(0.0, 1.0);
        final vm.Matrix4 pm =
            vm.Matrix4.translationValues(p.pos.x, p.pos.y, p.pos.z);
        pm.scale(0.25 + 0.75 * s);
        pm.rotateY(t * 6.0);
        p.node.localTransform = pm;
      } else {
        p.node.localTransform = vm.Matrix4.translationValues(0, -1000, 0);
      }
    }

    double shx = 0;
    double shy = 0;
    if (state._shakeT > 0) {
      final double amp = 0.4 * (state._shakeT / _GamePageState.shakeDuration);
      shx = math.sin(t * 80.0) * amp;
      shy = math.cos(t * 67.0) * amp;
    }

    final double camX = state._runnerX * 0.35;
    final PerspectiveCamera camera = PerspectiveCamera(
      position: vm.Vector3(camX + shx, 2.6 + shy, 9.0),
      target: vm.Vector3(state._runnerX * 0.5, -1.4, -15.0),
    );

    state._scene.render(camera, canvas, viewport: Offset.zero & size);
  }

  @override
  bool shouldRepaint(covariant _GamePainter oldDelegate) => false;
}

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
