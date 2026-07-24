import 'dart:math' as math;

import 'package:flutter/foundation.dart';
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
  static const double groundY = roadTopY + 0.5; // runner resting height
  static const double runnerZ = 1.5;

  // --- movement tuning ----------------------------------------------------
  static const double speed = 15.0; // forward speed (units / second)
  static const double laneLerp = 12.0; // lane snap responsiveness
  static const double gravity = 38.0; // jump gravity (units / second^2)
  static const double jumpImpulse = 12.0; // initial jump velocity

  static const int postCount = 9;
  static const double postSpacing = totalLen / postCount; // 8
  static const int dashCount = 18;
  static const double dashSpacing = totalLen / dashCount; // 4

  final Scene _scene = Scene();
  final ValueNotifier<int> _repaint = ValueNotifier<int>(0);
  final FocusNode _focus = FocusNode();
  late final Ticker _ticker;
  Duration _last = Duration.zero;

  // --- live game state ----------------------------------------------------
  double _elapsed = 0; // seconds
  double _scrollZ = 0; // accumulated forward scroll
  int _lane = 0; // -1, 0, 1
  double _runnerX = 0; // smoothed lateral position
  double _prevRunnerX = 0; // for lean
  double _jumpY = 0; // height above ground
  double _jumpV = 0; // vertical velocity
  bool _grounded = true;

  // --- nodes --------------------------------------------------------------
  final List<Node> _tiles = <Node>[];
  final List<Node> _postsL = <Node>[];
  final List<Node> _postsR = <Node>[];
  final List<Node> _dashesL = <Node>[];
  final List<Node> _dashesR = <Node>[];
  late final Node _runner;

  @override
  void initState() {
    super.initState();
    _buildWorld();
    _ticker = createTicker(_onTick)..start();
    // Make sure we hold keyboard focus once the first frame is up.
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
    _elapsed += dt;
    _scrollZ += speed * dt;

    // Lane movement: frame-rate-independent smoothing toward the target lane.
    _prevRunnerX = _runnerX;
    // flutter_scene renders +X toward screen-left, so negate: lane +1 (D / →) = screen-right.
    final double targetX = -_lane * laneWidth;
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
  }

  KeyEventResult _onKey(KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final LogicalKeyboardKey k = e.logicalKey;
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

    // Runner placeholder: multi-colored cube.
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
          onTap: () => _focus.requestFocus(), // click window to (re)grab keys
          child: Stack(
            children: <Widget>[
              Positioned.fill(
                child: CustomPaint(
                  painter: _GamePainter(state: this, repaint: _repaint),
                ),
              ),
              const Positioned(
                left: 16,
                top: 14,
                child: Text(
                  'flutter-scene-runner · Day 2',
                  style: TextStyle(color: Colors.white70, fontSize: 14),
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

    // Road tiles.
    for (int i = 0; i < state._tiles.length; i++) {
      final double z = wrapZ(i * _GamePageState.segLen);
      state._tiles[i].localTransform =
          vm.Matrix4.translationValues(0, _GamePageState.roadTopY - 0.1, z);
    }

    // Lane-divider dashes.
    for (int k = 0; k < state._dashesL.length; k++) {
      final double z = wrapZ(k * _GamePageState.dashSpacing);
      state._dashesL[k].localTransform = vm.Matrix4.translationValues(
          -_GamePageState.laneWidth / 2, _GamePageState.roadTopY + 0.02, z);
      state._dashesR[k].localTransform = vm.Matrix4.translationValues(
          _GamePageState.laneWidth / 2, _GamePageState.roadTopY + 0.02, z);
    }

    // Side posts.
    const double postX = _GamePageState.roadWidth / 2 + 0.6;
    for (int j = 0; j < state._postsL.length; j++) {
      final double z = wrapZ(j * _GamePageState.postSpacing);
      state._postsL[j].localTransform = vm.Matrix4.translationValues(
          -postX, _GamePageState.roadTopY + 0.5, z);
      state._postsR[j].localTransform = vm.Matrix4.translationValues(
          postX, _GamePageState.roadTopY + 0.5, z);
    }

    // Runner: lane position + jump height + a little lean when moving sideways.
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

    // Third-person camera: behind + slightly above, angled down at the road so
    // the runner sits clearly in the lower third. Follows the lane a little.
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

/// Convert a 0xAARRGGBB sRGB value to a linear-space RGBA for baseColorFactor.
vm.Vector4 _linearFromHex(int hex) {
  double lin(int c) => math.pow(c / 255.0, 2.2).toDouble();
  final double a = ((hex >> 24) & 0xFF) / 255.0;
  final double r = lin((hex >> 16) & 0xFF);
  final double g = lin((hex >> 8) & 0xFF);
  final double b = lin(hex & 0xFF);
  return vm.Vector4(r, g, b, a);
}
