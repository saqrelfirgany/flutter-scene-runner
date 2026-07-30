import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_scene/scene.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vector_math/vector_math.dart' as vm;

// The pure, GPU-free half of the gameplay math. Prefixed because names like
// `wrapZ` also exist as locals in the painter, and a silent shadow there would
// be very hard to spot. Kept a real library (not a `part`) precisely so tests
// can import it without dragging in flutter_scene.
import 'game_math.dart' as gm;

// Procedural surface textures, generated at startup rather than bundled. Also
// a standalone library so the pixel generators are unit-testable without a GPU.
import 'game_textures.dart' as gt;

// Frame-time benchmark probe. Compiled out unless the build passes
// --dart-define=BENCH=true; see lib/game_bench.dart.
import 'game_bench.dart' as bench;

part 'game_state.dart';
part 'game_painter.dart';
part 'models.dart';

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
