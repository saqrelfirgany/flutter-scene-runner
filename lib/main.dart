import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // flutter_scene loads its material shader bundle + static GPU resources here.
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
  static const double laneWidth = 2.0; // 3 lanes across roadWidth
  static const double segLen = 4.0;
  static const int tileCount = 18;
  static const double totalLen = tileCount * segLen; // 72
  static const double zFar = -62.0; // far end; near end = zFar + totalLen = 10
  static const double roadTopY = -0.9;
  static const double speed = 15.0; // world units / second -> forward feel

  static const int postCount = 9; // per side
  static const double postSpacing = totalLen / postCount; // 8
  static const int dashCount = 18; // per lane divider
  static const double dashSpacing = totalLen / dashCount; // 4

  final Scene _scene = Scene();
  final ValueNotifier<double> _seconds = ValueNotifier<double>(0);
  late final Ticker _ticker;

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
    _ticker = createTicker((elapsed) {
      _seconds.value = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    })..start();
  }

  void _buildWorld() {
    // Road tiles: alternating shades so the surface visibly scrolls.
    const int shadeA = 0xFF232A3A;
    const int shadeB = 0xFF2E3750;
    for (int i = 0; i < tileCount; i++) {
      final Node node = _box(
        vm.Vector3(roadWidth, 0.2, segLen * 0.96),
        colorHex: i.isEven ? shadeA : shadeB,
      );
      _tiles.add(node);
      _scene.add(node);
    }

    // Dashed lane dividers at the two inner lane boundaries (x = +/- laneWidth/2).
    const int dashColor = 0xFFE7C24B;
    for (int k = 0; k < dashCount; k++) {
      final Node l = _box(vm.Vector3(0.14, 0.06, 1.4), colorHex: dashColor);
      final Node r = _box(vm.Vector3(0.14, 0.06, 1.4), colorHex: dashColor);
      _dashesL.add(l);
      _dashesR.add(r);
      _scene.add(l);
      _scene.add(r);
    }

    // Side posts that whoosh past to sell forward motion.
    const int postColor = 0xFF4FD1C5;
    for (int j = 0; j < postCount; j++) {
      final Node l = _box(vm.Vector3(0.3, 1.4, 0.3), colorHex: postColor);
      final Node r = _box(vm.Vector3(0.3, 1.4, 0.3), colorHex: postColor);
      _postsL.add(l);
      _postsR.add(r);
      _scene.add(l);
      _scene.add(r);
    }

    // Runner placeholder: multi-colored cube hovering just above the road.
    _runner = _box(vm.Vector3(0.9, 0.9, 0.9), debug: true);
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
    _seconds.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0E1220),
      body: Stack(
        children: <Widget>[
          Positioned.fill(
            child: CustomPaint(
              painter: _RoadPainter(state: this, seconds: _seconds),
            ),
          ),
          const Positioned(
            left: 16,
            top: 14,
            child: Text(
              'flutter-scene-runner · Day 1 — endless road',
              style: TextStyle(color: Colors.white70, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }
}

class _RoadPainter extends CustomPainter {
  _RoadPainter({required this.state, required this.seconds})
      : super(repaint: seconds);

  final _GamePageState state;
  final ValueListenable<double> seconds;

  @override
  void paint(Canvas canvas, Size size) {
    final double t = seconds.value;
    final double scroll = _GamePageState.speed * t;

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
      state._postsL[j].localTransform =
          vm.Matrix4.translationValues(-postX, _GamePageState.roadTopY + 0.5, z);
      state._postsR[j].localTransform =
          vm.Matrix4.translationValues(postX, _GamePageState.roadTopY + 0.5, z);
    }

    // Runner: gentle hover-bob + slow yaw, held near the camera.
    final double bob =
        _GamePageState.roadTopY + 0.5 + math.sin(t * 3.0) * 0.12;
    state._runner.localTransform =
        vm.Matrix4.translationValues(0, bob, 3.0)..rotateY(t * 0.7);

    // Third-person camera: above and behind, looking down the road.
    final PerspectiveCamera camera = PerspectiveCamera(
      position: vm.Vector3(0, 3.6, 9.0),
      target: vm.Vector3(0, 0.0, -14.0),
    );

    state._scene.render(camera, canvas, viewport: Offset.zero & size);
  }

  @override
  bool shouldRepaint(covariant _RoadPainter oldDelegate) => false;
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
