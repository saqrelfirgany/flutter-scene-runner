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
      home: SmokeTestPage(),
    );
  }
}

/// Day 1 smoke test: a spinning, multi-colored 3D cube.
/// Proves flutter_scene renders through Impeller + Flutter GPU on this machine.
class SmokeTestPage extends StatefulWidget {
  const SmokeTestPage({super.key});

  @override
  State<SmokeTestPage> createState() => _SmokeTestPageState();
}

class _SmokeTestPageState extends State<SmokeTestPage>
    with SingleTickerProviderStateMixin {
  final Scene _scene = Scene();
  final ValueNotifier<double> _seconds = ValueNotifier<double>(0);
  late final Ticker _ticker;
  late final Node _cube;

  @override
  void initState() {
    super.initState();

    // A cube with per-corner debug colors so it reads clearly as 3D with no
    // lighting yet. UnlitMaterial ignores scene lights.
    _cube = Node(
      mesh: Mesh(
        CuboidGeometry(vm.Vector3(1.5, 1.5, 1.5), debugColors: true),
        UnlitMaterial()..vertexColorWeight = 1.0,
      ),
    );
    _scene.add(_cube);

    _ticker = createTicker((elapsed) {
      _seconds.value = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    })..start();
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
      backgroundColor: const Color(0xFF10131A),
      body: Stack(
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _ScenePainter(
                scene: _scene,
                cube: _cube,
                seconds: _seconds,
              ),
            ),
          ),
          const Positioned(
            left: 16,
            top: 16,
            child: Text(
              'flutter-scene-runner · Day 1',
              style: TextStyle(color: Colors.white70, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }
}

class _ScenePainter extends CustomPainter {
  _ScenePainter({
    required this.scene,
    required this.cube,
    required this.seconds,
  }) : super(repaint: seconds);

  final Scene scene;
  final Node cube;
  final ValueListenable<double> seconds;

  @override
  void paint(Canvas canvas, Size size) {
    final double t = seconds.value;

    // Spin the cube on two axes.
    final vm.Matrix4 transform = vm.Matrix4.rotationY(t * 0.9);
    transform.rotateX(t * 0.5);
    cube.localTransform = transform;

    // Camera slightly above and pulled back, looking at the origin.
    final camera = PerspectiveCamera(
      position: vm.Vector3(0, 2.5, 6),
      target: vm.Vector3(0, 0, 0),
    );

    scene.render(camera, canvas, viewport: Offset.zero & size);
  }

  @override
  bool shouldRepaint(covariant _ScenePainter oldDelegate) => false;
}
