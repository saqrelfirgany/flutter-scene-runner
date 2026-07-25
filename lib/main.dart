import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Scene.initializeStaticResources();
  runApp(const RunnerApp());
}

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
  static const double laneWidth = 2.0; // lane spacing; lanes at x = -2, 0, +2
  static const double segLen = 4.0;
  static const int tileCount = 18;
  static const double totalLen = tileCount * segLen; // 72
  static const double zFar = -62.0; // far end; near end = 10
  static const double roadTopY = -0.9;
  static const double groundY = roadTopY + 0.5; // runner / obstacle rest height
  static const double runnerZ = 1.5;
  static const double runnerHalf = 0.5; // runner is a 1.0 cube

  // --- movement tuning ----------------------------------------------------
  static const double baseSpeed = 15.0; // starting forward speed (units / s)
  static const double maxSpeed = 32.0; // speed ramp ceiling
  static const double speedRampPerSec = 0.45; // how fast difficulty rises
  static const double laneLerp = 12.0; // lane snap responsiveness
  static const double gravity = 38.0; // jump gravity (units / second^2)
  static const double jumpImpulse = 12.0; // initial jump velocity (apex ~1.9)

  // --- obstacles ----------------------------------------------------------
  static const int obstacleCount = 10; // pool size
  static const double obHalfX = 0.6;
  static const double obHalfY = 0.5; // 1.0 tall -> clearable near jump apex
  static const double obHalfZ = 0.5;
  static const double obstacleCenterY = groundY;
  static const double obSpacing = 17.0; // distance kept between obstacles
  static const double firstSpawnDelay = 1.6;

  // --- coins --------------------------------------------------------------
  static const int coinCount = 24; // pool size
  static const double coinY = groundY + 0.35; // floats just above the road
  static const int coinsPerLine = 4;
  static const double coinGap = 2.5;
  static const double coinInterval = 1.7;
  static const int coinScore = 25;

  static const double spawnZ = -58.0; // where obstacles / coins appear
  static const double despawnZ = 8.0; // recycled once past the runner

  static const int postCount = 9;
  static const double postSpacing = totalLen / postCount; // 8
  static const int dashCount = 18;
  static const double dashSpacing = totalLen / dashCount; // 4

  final Scene _scene = Scene();
  final ValueNotifier<int> _repaint = ValueNotifier<int>(0);
  final FocusNode _focus = FocusNode();
  final math.Random _rng = math.Random();
  late final Ticker _ticker;
  Duration _last = Duration.zero;

  // --- live game state ----------------------------------------------------
  double _elapsed = 0; // seconds since (re)start -> drives the speed ramp
  double _scrollZ = 0; // accumulated forward scroll
  int _lane = 0; // -1, 0, 1
  double _runnerX = 0; // smoothed lateral position
  double _prevRunnerX = 0; // for lean
  double _jumpY = 0; // height above ground
  double _jumpV = 0; // vertical velocity
  bool _grounded = true;
  bool _crashed = false;
  double _obSpawnTimer = firstSpawnDelay;
  double _coinSpawnTimer = 2.0;
  double _score = 0;
  int _coinsCollected = 0;
  int _best = 0;

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
  late final Node _runner;

  static double _laneX(int lane) => -lane * laneWidth; // matches runner mapping

  @override
  void initState() {
    super.initState();
    _buildWorld();
    _ticker = createTicker(_onTick)..start();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  void _onTick(Duration elapsed) {
    double dt = _last == Duration.zero
        ? 0
        : (elapsed - _last).inMicroseconds / Duration.microsecondsPerSecond;
    _last = elapsed;
    if (dt > 0.05) dt = 0.05; // clamp big hitches (e.g. after a stall)
    _update(dt);
    _repaint.value++;
  }

  void _update(double dt) {
    if (_crashed) return; // world is frozen after a crash
    final double v = _curSpeed;
    _elapsed += dt;
    _scrollZ += v * dt;
    _score += v * dt * 0.7; // distance-based score

    // Lane movement: frame-rate-independent smoothing toward the target lane.
    _prevRunnerX = _runnerX;
    final double targetX = _laneX(_lane);
    _runnerX += (targetX - _runnerX) * (1 - math.exp(-laneLerp * dt));

    // Jump physics.
    if (!_grounded) {
      _jumpY += _jumpV * dt;
      _jumpV -= gravity * dt;
      if (_jumpY <= 0) {
        _jumpY = 0;
        _jumpV = 0;
        _grounded = true;
      }
    }

    // Spawn obstacles keeping a roughly constant distance (harder as v rises).
    _obSpawnTimer -= dt;
    if (_obSpawnTimer <= 0) {
      _spawnObstacle();
      _obSpawnTimer = obSpacing / v;
    }

    // Spawn coin lines on a timer.
    _coinSpawnTimer -= dt;
    if (_coinSpawnTimer <= 0) {
      _spawnCoinLine();
      _coinSpawnTimer = coinInterval;
    }

    // Move obstacles; recycle; detect collision.
    for (final _Obstacle o in _obstacles) {
      if (!o.active) continue;
      o.z += v * dt;
      if (o.z > despawnZ) {
        o.active = false;
        continue;
      }
      if (_hitsObstacle(o)) {
        _crash();
        return;
      }
    }

    // Move coins; recycle; collect on overlap.
    for (final _Coin c in _coins) {
      if (!c.active) continue;
      c.z += v * dt;
      if (c.z > despawnZ) {
        c.active = false;
        continue;
      }
      if (_collectsCoin(c)) {
        c.active = false;
        _coinsCollected++;
        _score += coinScore;
      }
    }
  }

  void _spawnObstacle() {
    for (final _Obstacle o in _obstacles) {
      if (!o.active) {
        o.active = true;
        o.lane = _rng.nextInt(3) - 1; // -1, 0, 1
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
    final double dx = (_runnerX - _laneX(c.lane)).abs();
    final double dy = (runnerY - coinY).abs();
    final double dz = (runnerZ - c.z).abs();
    return dx < 1.0 && dy < 1.8 && dz < 0.9; // generous -> feels good
  }

  void _crash() {
    if (_crashed) return;
    _best = math.max(_best, _score.round());
    setState(() => _crashed = true);
  }

  void _restart() {
    setState(() {
      _crashed = false;
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
    });
  }

  KeyEventResult _onKey(KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final LogicalKeyboardKey k = e.logicalKey;

    if (_crashed) {
      if (k == LogicalKeyboardKey.space || k == LogicalKeyboardKey.enter) {
        _restart();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    if (k == LogicalKeyboardKey.arrowLeft || k == LogicalKeyboardKey.keyA) {
      _lane = math.max(-1, _lane - 1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowRight || k == LogicalKeyboardKey.keyD) {
      _lane = math.min(1, _lane + 1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.space ||
        k == LogicalKeyboardKey.arrowUp ||
        k == LogicalKeyboardKey.keyW) {
      if (_grounded) {
        _grounded = false;
        _jumpV = jumpImpulse;
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
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
      final Node l = _box(vm.Vector3(0.3, 1.4, 0.3), colorHex: postColor);
      final Node r = _box(vm.Vector3(0.3, 1.4, 0.3), colorHex: postColor);
      _postsL.add(l);
      _postsR.add(r);
      _scene.add(l);
      _scene.add(r);
    }

    const int obstacleColor = 0xFFE0533D;
    for (int i = 0; i < obstacleCount; i++) {
      final Node n = _box(vm.Vector3(obHalfX * 2, obHalfY * 2, obHalfZ * 2),
          colorHex: obstacleColor);
      _obstacles.add(_Obstacle(n));
      _scene.add(n);
    }

    const int coinColor = 0xFFFFC93C;
    for (int i = 0; i < coinCount; i++) {
      final Node n = _box(vm.Vector3(0.5, 0.5, 0.12), colorHex: coinColor);
      _coins.add(_Coin(n));
      _scene.add(n);
    }

    _runner = _box(vm.Vector3(1.0, 1.0, 1.0), debug: true);
    _scene.add(_runner);
  }

  Node _box(vm.Vector3 size, {int? colorHex, bool debug = false}) {
    final UnlitMaterial material = UnlitMaterial();
    if (debug) material.vertexColorWeight = 1.0;
    if (colorHex != null) material.baseColorFactor = _linearFromHex(colorHex);
    return Node(mesh: Mesh(CuboidGeometry(size, debugColors: debug), material));
  }

  @override
  void dispose() {
    _ticker.dispose();
    _repaint.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0E1220),
      body: Focus(
        focusNode: _focus,
        autofocus: true,
        onKeyEvent: (FocusNode node, KeyEvent e) => _onKey(e),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => _focus.requestFocus(),
          child: Stack(
            children: <Widget>[
              Positioned.fill(
                child: CustomPaint(
                  painter: _GamePainter(state: this, repaint: _repaint),
                ),
              ),
              // Score / coins / speed HUD (rebuilds every frame via _repaint).
              Positioned(
                top: 12,
                left: 0,
                right: 0,
                child: IgnorePointer(
                  child: ValueListenableBuilder<int>(
                    valueListenable: _repaint,
                    builder: (BuildContext context, int _, Widget? _) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.center,
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
                              color: Color(0xFFFFC93C),
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ),
              const Positioned(
                left: 16,
                top: 14,
                child: Text(
                  'flutter-scene-runner · Day 2',
                  style: TextStyle(color: Colors.white38, fontSize: 13),
                ),
              ),
              const Positioned(
                left: 16,
                bottom: 14,
                child: Text(
                  'A / D  or  ← / →  : change lane        Space / ↑ : jump',
                  style: TextStyle(color: Colors.white38, fontSize: 13),
                ),
              ),
              if (_crashed)
                Positioned.fill(
                  child: Container(
                    color: Colors.black54,
                    alignment: Alignment.center,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        const Text(
                          'CRASHED',
                          style: TextStyle(
                            color: Color(0xFFE0533D),
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
                        const SizedBox(height: 16),
                        const Text(
                          'Press  Space  to restart',
                          style: TextStyle(color: Colors.white70, fontSize: 18),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
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
        final vm.Matrix4 m = vm.Matrix4.translationValues(
            _GamePageState._laneX(c.lane), _GamePageState.coinY, c.z);
        m.rotateY(t * 4.0); // spin
        c.node.localTransform = m;
      } else {
        c.node.localTransform = vm.Matrix4.translationValues(0, -1000, 0);
      }
    }

    final double lateralV = state._runnerX - state._prevRunnerX;
    final double lean = (lateralV * 6.0).clamp(-0.35, 0.35);
    final double idleBob = state._grounded ? math.sin(t * 3.0) * 0.06 : 0.0;
    final vm.Matrix4 rt = vm.Matrix4.translationValues(
      state._runnerX,
      _GamePageState.groundY + state._jumpY + idleBob,
      _GamePageState.runnerZ,
    );
    rt.rotateZ(-lean);
    rt.rotateY(t * 0.6);
    state._runner.localTransform = rt;

    final double camX = state._runnerX * 0.35;
    final PerspectiveCamera camera = PerspectiveCamera(
      position: vm.Vector3(camX, 2.6, 9.0),
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
