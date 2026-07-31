// Part of the flutter-scene-runner library — see lib/main.dart.
// `part of` keeps the game one library so the sim/render split can use
// library-private access (e.g. _GamePainter reads _GamePageState fields).
part of 'main.dart';

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

  // --- camera -------------------------------------------------------------
  // Pulled in and down toward the reference framing, where Dash fills much
  // more of the frame. These four are the knobs to nudge by eye — nothing
  // else in the sim depends on them.
  // Dash filled about a quarter of the frame height at camZ 8; the reference
  // frames it at roughly half that. `PerspectiveCamera` uses a fixed vertical
  // FOV, so this framing is aspect-independent — a portrait window and a
  // landscape one crop the sides, not the top and bottom.
  static const double camY = 2.9;
  static const double camZ = 11.0;
  static const double camTargetY = -0.85;
  static const double camTargetZ = -16.0;

  // --- movement tuning ----------------------------------------------------
  static const double baseSpeed = 15.0;
  static const double maxSpeed = 32.0;
  static const double speedRampPerSec = 0.45;
  static const double laneLerp = 12.0;
  /// Frame deltas are clamped to this before any integration, so a hitch
  /// cannot teleport the runner through an obstacle.
  static const double maxFrameDt = 0.05;
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
  static const int coinCount = 36;
  static const double coinY = groundY + 0.35;
  static const int coinsPerLine = 6;
  static const double coinGap = 2.5;
  static const double coinRadius = 0.32; // upright disc, not a flat card
  // Arc height must stay under _collectsCoin's dy tolerance (1.8) or the peak
  // of an arc becomes uncollectable while running on the ground.
  static const double coinArcH = 0.85;
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
  static const int cCoin = 0xFFFFC93C; // coin gold, also its pickup sparkle
  static const int cCrash = 0xFFE0533D; // crash burst
  static const Color cBg = Color(0xFF0E1220);

  // --- juice (Day 3B) -----------------------------------------------------
  // Particles are instanced per colour (see `_ParticlePool`), so the pool set
  // is fixed at build: every colour a burst can ask for needs its own entry.
  // A colour missing from this list falls back to the first pool.
  static const List<int> particleColors = <int>[
    cCoin,
    cCrash,
    cMagnet,
    cShield,
    cDouble,
  ];
  // Sized for the largest single burst (the 22-particle crash) plus headroom.
  static const int particlesPerColor = 24;
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

  // --- daylight world (visual overhaul, Phase 1) --------------------------
  // The neon params above stay for a future "night" theme; these drive the
  // bright DashSurfers-style look: sun + shadows + grass + sky.
  static const int cSkyTop = 0xFF5AAEF5; // sky blue (screen top)
  static const int cSkyBot = 0xFFCDEBFF; // pale horizon
  static const int cGrass = 0xFF5FB343; // grass field
  static const int cAsphaltA = 0xFF3E444C; // road tile A
  static const int cAsphaltB = 0xFF474E57; // road tile B
  static const int cHedge = 0xFF4C9A3C; // roadside greenery (repurposed posts)
  static const double groundHalfW = 40.0; // grass reach each side of the road
  static const double groundLen = 280.0; // static grass length in z
  // --- shadow + render budget ---------------------------------------------
  // The real saving here is `shadowMaxDistance`: the default 150 spreads the
  // cascade set over 3.5x the range we actually shadow, so cutting it to 42
  // shrinks every cascade's footprint and sharpens the shadows for free.
  //
  // Cascade count is a *geometry* cost (every caster is re-submitted per
  // cascade) while map resolution is a memory cost. Measured on web the frame
  // is draw-call bound, not fill bound, so the win is to cut cascades — but
  // cutting them alone at 1024² halved the shadow texel density and flat
  // ground began self-shadowing into a large black blob across the near road.
  //
  // 2 cascades at 2048² carries the *same* texel density as 4 at 1024² over
  // the same 42 units (~97 texels/unit either way) while halving the geometry
  // re-submissions. Keep these two in step: raising the count or dropping the
  // resolution without the other brings the blob back.
  // One cascade, not two. Two 2048² maps is 8.4 MP of shadow rendering against
  // a ~1.1 MP screen — the shadow pass was filling seven times the visible
  // frame. Over only 24 units a single 2048² map still carries ~85 texels per
  // unit, which is plenty, and it halves both the fill and the geometry
  // re-submission. The raised bias below is what makes one cascade safe: bias
  // is the part that does not move with the camera frustum.
  static const int shadowCascades = 1;
  static const int shadowMapRes = 2048;
  // 24, not 42, and the reason is *visual* — it measured as free either way.
  // At 42 the tall roadside trees are still in shadow range and the sun angle
  // throws their shadows right across the road, which is nothing like the
  // reference's bright open asphalt. Cutting the range keeps the shadows that
  // ground things (Dash, obstacles, near props) and drops the ones that only
  // muddied the road. Fog starts at 40, so nothing visible loses a shadow it
  // would have been read as having.
  static const double shadowDistance = 24.0;

  // Fragment-cost knob: renders below native resolution and upscales on
  // composite. Independent of everything else, which makes it the safest lever
  // when a device simply cannot keep up. See `_quality` / `qualityScales`.
  // `renderScale` multiplies the *device* pixel ratio, so on a 2x display HIGH
  // is already 4x the pixels of a 1x one. That is exactly how this shipped at
  // 18 fps after measuring 45 — the measurement ran in a 1x window. Hence
  // `pixelBudget` below: the resolution has to follow the machine, not the
  // developer's machine.
  static const List<double> qualityScales = <double>[1.0, 0.85, 0.65];

  /// The most fragments the 3D scene may render per frame, whatever the window
  /// size or display density.
  ///
  /// This is the fix for the thing that actually shipped broken: `renderScale`
  /// multiplies the **device pixel ratio**, so a 1648x914 window on a 2x
  /// display is 6.0 MP at scale 1.0 — about five times what the same code
  /// renders in a 1x window, and it measured 16 fps against 47. A fixed preset
  /// is a bet on one machine.
  ///
  /// So the scale is *derived*, not guessed and not reacted to: see
  /// [_syncRenderScale]. It is deterministic, applies from the very first
  /// frame, and cannot fail quietly the way an fps-triggered step-down can.
  /// 1.1 MP is a little under the resolution this scene was measured at.
  static const double pixelBudget = 1100000.0;

  /// Never upscale past native, and never go softer than this.
  static const double minRenderScale = 0.35;
  static const List<String> qualityNames = <String>['HIGH', 'BALANCED', 'FAST'];

  // Sun down, ambient up. The roadside trees legitimately cast across the road
  // at this sun angle, and with a dark asphalt albedo a correctly-shadowed road
  // still read as near-black slabs. `shadowAmbientStrength` is already at its
  // physical 0.0 (shadow removes only the direct light), so the fix is not a
  // shadow setting at all — it is the direct/ambient ratio. This is the
  // "soft lighting over more geometry" lever from docs/VISION.md §2.1.
  static const double sunIntensity = 2.1;
  static const double envIntensity = 1.75;
  static const int cFogDay = 0xFFCDEBFF; // far road melts into the sky
  static const double fogStartDay = 40.0;
  static const double fogEndDay = 80.0;
  static const int cTrunk = 0xFF7A5233; // tree trunk
  // Tree part dimensions, shared by the builder and the painter's part-local
  // matrices. Pine tiers are [bottomRadius, height], widest first.
  static const double trunkH = 0.7;
  static const List<List<double>> _pineTierDims = <List<double>>[
    <double>[0.82, 1.2],
    <double>[0.6, 0.95],
    <double>[0.4, 0.72],
  ];
  static const List<double> _roundBlobRadii = <double>[0.64, 0.42, 0.40];
  static const int cPine = 0xFF2F7D44; // pine foliage
  static const int cLeaf = 0xFF5CB248; // round-tree foliage
  static const double treeX = roadWidth / 2 + 2.3; // trees sit out on the grass
  static const int houseCount = 5;
  static const double houseSpacing = totalLen / houseCount;
  static const double houseX = roadWidth / 2 + 8.0; // houses sit behind the trees
  static const int cWall = 0xFFEBE0CC; // house walls (cream)
  static const int cDoor = 0xFF6E4A2C; // house door
  static const int cWindow = 0xFF9BD6EC; // house window
  static const List<int> roofHexes = <int>[
    0xFFCF5140,
    0xFF4E86C6,
    0xFFE0973C,
    0xFF5AA090,
  ];
  // Part-local transforms inside a house's own (already scaled) space. The
  // painter composes `houseWorld * partLocal` each frame, which is what the
  // old `root -> body(scale) -> parts` node tree did implicitly. Constant, so
  // they are built once rather than per frame.
  static final vm.Matrix4 kHouseWall = vm.Matrix4.translationValues(0, 0.55, 0);
  static final vm.Matrix4 kHouseRoof =
      vm.Matrix4.translationValues(0, 1.55, 0)..rotateY(0.7853981633974483);
  static final vm.Matrix4 kHouseDoor =
      vm.Matrix4.translationValues(-0.32, 0.275, 0.77);
  static final vm.Matrix4 kHouseWindow =
      vm.Matrix4.translationValues(0.34, 0.62, 0.77);
  static const int cRock = 0xFF8C9198; // scattered rocks
  static const int cBush = 0xFF52A63C; // scattered bushes
  static const int decoCount = 40; // instanced rocks / bushes per type
  static const int cLeafB = 0xFF7BBF3A; // yellow-green foliage
  static const int cAutumn = 0xFFD1662E; // autumn foliage
  static const int cFlowerA = 0xFFB760D9; // purple flowers
  static const int cFlowerB = 0xFFEC5C79; // pink flowers
  // Raised from 240 toward the reference's carpet. Instancing is real hardware
  // instancing here (see CLAUDE.md), so the whole shade is 1-2 draw calls no
  // matter the count — raising this costs vertex/fragment work and overdraw,
  // not draw calls.
  static const int grassCount = 320; // instanced grass tufts per shade (dense)
  static const int cGrassA = 0xFF69B84A; // grass tuft (soft green)
  static const int cGrassB = 0xFF8AD05C; // grass tuft (light green)
  static const int cGrassC = 0xFF57A33F; // grass tuft (deep green)

  // --- road markings + shoulder (target-reference pass) -------------------
  // The reference road is read by its markings, not its colour: white dashed
  // dividers, a solid white line on each edge, and a packed-dirt shoulder
  // between asphalt and grass. Edge lines and shoulder never scroll (a solid
  // line has no phase), so they are static geometry placed once.
  static const int cLaneLine = 0xFFF4F2EA; // dashes + edge lines
  static const double edgeLineX = roadWidth / 2 - 0.22;
  static const double shoulderW = 1.0;
  static const double shoulderX = roadWidth / 2 + shoulderW / 2;
  static const int cShoulder = 0xFF8A7355; // packed dirt

  // --- distant hills ------------------------------------------------------
  // Big static mounds parked just inside the fog's far end, so they arrive as
  // hazy silhouettes on the horizon rather than as readable geometry. They do
  // not scroll — like real distant terrain, parallax at this range is nil.
  static const int hillCount = 6;
  static const int cHill = 0xFF4E9A3E;

  // --- guardrails ---------------------------------------------------------
  static const int railCount = 30; // beam segments per side
  static const int railPostCount = railCount ~/ 2; // a post every other beam
  static const double railSpacing = totalLen / railCount;
  static const double railX = roadWidth / 2 + 0.62;
  // Beam spans roadTopY+0.37..+0.67; the posts top out at +0.66, so the beam
  // reads as carried by them rather than floating above.
  static const double railY = roadTopY + 0.52;
  static const int cRail = 0xFFB9C4CE; // galvanised steel
  static const int cRailPost = 0xFF8A939B;

  // --- roadside sign posts ------------------------------------------------
  static const int signCount = 8; // per side
  static const double signSpacing = totalLen / signCount;
  static const double signX = roadWidth / 2 + 1.45;
  static const int cSignPole = 0xFFEDEDE8;
  static const int cSignBoard = 0xFFD6DBE0;

  // --- jump ramps ---------------------------------------------------------
  // Purely additive: a ramp launches the runner, it never blocks. That keeps
  // it safe to tune without making the run unfair.
  static const int rampCount = 2;
  static const double rampFirstDelay = 12.0;
  static const double rampInterval = 11.0;
  static const double rampImpulse = 15.5; // vs jumpImpulse 12
  static const double rampHalfZ = 1.5;
  static const int cRamp = 0xFF3F8FD8;
  static const int cRampEdge = 0xFF2B6DA6;

  // --- obstacle variety (DashSurfers pass) --------------------------------
  // Pooled obstacles are a mix of these three shapes; each is a composite node
  // built base-at-origin and positioned on the road surface (roadTopY) in the
  // painter. Collision stays a uniform AABB (obHalf*), so shapes read fairly.
  static const int cGiftA = 0xFFE0533D; // red present
  static const int cGiftB = 0xFFF2B33D; // gold present
  static const int cRibbon = 0xFFF7F3EA; // ribbon + bow (cream)
  static const int cBarrierA = 0xFFD84B3A; // barrier stripe (red)
  static const int cBarrierB = 0xFFF2ECDE; // barrier stripe (cream)
  static const int cBarrierLeg = 0xFF5A5F66; // barrier legs (grey)
  static const int cContainer = 0xFF3F8F57; // shipping container (green)
  static const int cContainerB = 0xFF2E6B41; // container trim + ribs (dark)
  static const int cContainerR = 0xFFB2543A; // rust container variant

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
  bool _isNewBest = false; // did the last run beat the all-time best?
  double _shakeT = 0;
  double _swipeDx = 0;
  double _swipeDy = 0;

  // --- leaderboard (in-memory for now) ------------------------------------
  final List<_Score> _scores = <_Score>[];
  bool _enteringName = false;
  final TextEditingController _nameCtrl = TextEditingController();
  final FocusNode _nameFocus = FocusNode();

  double get _curSpeed => gm.speedAt(_elapsed,
      base: baseSpeed, max: maxSpeed, rampPerSec: speedRampPerSec);

  // --- nodes --------------------------------------------------------------
  // Road surface is instanced: two sets for the alternating asphalt tones
  // (one material per set — instancing shares a material across the batch)
  // and one set covering both lane dividers. 54 draw calls become 3.
  InstancedMesh? _tilesA;
  InstancedMesh? _tilesB;
  InstancedMesh? _dashes;
  // Pooled coins share one geometry and material, so they are instanced too;
  // a coin's index in `_coins` IS its instance index.
  InstancedMesh? _coinMesh;
  // Roadside trees. All 18 are on screen at all times, which made them the
  // single largest fixed draw-call cost (4 meshes each = 72). Instanced per
  // (part geometry, foliage colour); see `_Tree` / `_TreeFoliage`.
  final List<_Tree> _trees = <_Tree>[];
  final List<_TreeFoliage> _foliages = <_TreeFoliage>[];
  InstancedMesh? _treeTrunks;

  // Procedural surface textures, uploaded once in `_buildTextures()`.
  late final Texture2D _texAsphaltA;
  late final Texture2D _texAsphaltB;
  late final Texture2D _texGrass;
  late final Texture2D _texDirt;
  // Houses are instanced per part, and the roof additionally per colour —
  // a batch binds one material, so four roof colours means four roof meshes.
  // `_houseData` is (x, phaseZ, scale, roofIndex) per house; `_houseRoofSlot`
  // is that house's instance index *inside its own roof mesh*, which is not
  // the same as its index in `_houseData`.
  InstancedMesh? _houseWalls;
  InstancedMesh? _houseDoors;
  InstancedMesh? _houseWindows;
  final List<InstancedMesh> _houseRoofs = <InstancedMesh>[];
  final List<vm.Vector4> _houseData = <vm.Vector4>[];
  final List<int> _houseRoofSlot = <int>[];
  // Instanced scenery: many rocks/bushes drawn in ONE call each. Per-instance
  // data is (x, phaseZ, scale); the painter scrolls them via setInstanceTransform.
  InstancedMesh? _rocks;
  InstancedMesh? _bushes;
  final List<vm.Vector3> _rockData = <vm.Vector3>[];
  final List<vm.Vector3> _bushData = <vm.Vector3>[];
  InstancedMesh? _flowersA;
  InstancedMesh? _flowersB;
  final List<vm.Vector3> _flowerAData = <vm.Vector3>[];
  final List<vm.Vector3> _flowerBData = <vm.Vector3>[];
  // Tall grass tufts carpeting the roadside — instanced (x, phaseZ, scale, yaw).
  InstancedMesh? _grassA;
  InstancedMesh? _grassB;
  InstancedMesh? _grassC;
  final List<vm.Vector4> _grassAData = <vm.Vector4>[];
  final List<vm.Vector4> _grassBData = <vm.Vector4>[];
  final List<vm.Vector4> _grassCData = <vm.Vector4>[];
  // Guardrails and sign posts sit on a fixed spacing, so unlike the scattered
  // scenery they need no per-instance data at all — the painter derives side
  // and z from the instance index. Instances 0..n-1 are the left side, n..2n-1
  // the right.
  InstancedMesh? _rails;
  InstancedMesh? _railPosts;
  InstancedMesh? _signPoles;
  InstancedMesh? _signBoards;
  final List<_Ramp> _ramps = <_Ramp>[];
  final List<_Obstacle> _obstacles = <_Obstacle>[];
  final List<_Coin> _coins = <_Coin>[];
  final List<_PowerUp> _powerups = <_PowerUp>[];
  final List<_ParticlePool> _particlePools = <_ParticlePool>[];
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

  // Smoothed frame rate, shown in the HUD. Instancing does not batch draw
  // calls at flutter_scene 0.19.0, so density changes have to be measured
  // rather than assumed — this is the readout for that.
  double _fps = 60;

  // Only allocated when the build asked for timings; see lib/game_bench.dart.
  final bench.FrameBench? _bench =
      bench.kBenchEnabled ? bench.FrameBench() : null;

  // power-up run state
  double _rampSpawnTimer = rampFirstDelay;
  double _powerSpawnTimer = powerFirstDelay;
  double _magnetT = 0; // seconds of magnet remaining
  double _doubleT = 0; // seconds of ×2 remaining
  bool _shield = false; // one-hit shield charge

  // audio: one player per SFX, plus a 3-step volume the user cycles + persists.
  final _Audio _audio = _Audio();
  static const List<double> volumes = <double>[0.0, 0.45, 0.9];
  int _volLevel = 2; // index into volumes; 0 = muted

  // Render-resolution preset; index into qualityScales/qualityNames. Persisted
  // like volume, because it is a device capability choice, not a run setting.
  int _quality = 0;

  // Last render scale actually pushed to the Scene. Assigning `renderScale`
  // reallocates the swapchain, so it is only written when it really changes.
  double _appliedScale = -1;

  // floating "+N" score popups (screen space, projected via the last camera)
  Camera? _lastCamera;
  Size _lastViewport = Size.zero;
  final List<_Popup> _popups = <_Popup>[];

  static double _laneX(int lane) => gm.laneX(lane, laneWidth);

  @override
  void initState() {
    super.initState();
    if (bench.kBenchEnabled) debugPrint('BENCH probe active');
    _buildWorld();
    _setupSceneLook();
    _loadDash();
    _ticker = createTicker(_onTick)..start();
    _loadScores();
    _audio.init();
    _loadVolume();
    _loadQuality();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  void _onTick(Duration elapsed) {
    double dt = _last == Duration.zero
        ? 0
        : (elapsed - _last).inMicroseconds / Duration.microsecondsPerSecond;
    _last = elapsed;
    // Smooth the RAW dt: the clamp below would floor the readout at 20 fps and
    // hide exactly the hitches worth seeing.
    if (dt > 0) _fps += (1 / dt - _fps) * 0.06;
    // Fed the RAW delta, before the clamp below — otherwise everything slower
    // than 20 fps would report as exactly 20.
    final String? benchLine = _bench?.addFrame(dt);
    if (benchLine != null) debugPrint(benchLine);
    dt = gm.clampDt(dt, maxFrameDt);
    if (_shakeT > 0) _shakeT = math.max(0, _shakeT - dt);
    _updateParticles(dt);
    _update(dt);
    _updateDashAnim(dt);
    _updatePopups(dt);
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
    _runnerX += (targetX - _runnerX) * gm.smoothing(laneLerp, dt);

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

    _rampSpawnTimer -= dt;
    if (_rampSpawnTimer <= 0) {
      _spawnRamp();
      _rampSpawnTimer = rampInterval;
    }

    for (final _Ramp r in _ramps) {
      if (!r.active) continue;
      r.z += v * dt;
      if (r.z > despawnZ) {
        r.active = false;
        continue;
      }
      // Additive only — a ramp never blocks. Overlapping one while grounded
      // replaces the normal jump with a stronger launch.
      if (_grounded &&
          (_runnerX - _laneX(r.lane)).abs() < 1.0 &&
          (runnerZ - r.z).abs() < rampHalfZ + runnerHalf) {
        _grounded = false;
        _jumpV = rampImpulse;
        _clipJump?.replay();
        _audio.jump();
      }
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
          : c.restX;
      c.cx += (targetX - c.cx) * gm.smoothing(magnetPull, dt);
      if (_collectsCoin(c)) {
        c.active = false;
        _coinsCollected++;
        _score += coinScore * (_doubleT > 0 ? 2 : 1);
        _spawnParticles(c.cx, c.y, c.z, 7, 0xFFFFC93C, 3.5, 3.0);
        _audio.coin();
        _spawnPopup(
            c.cx, c.y + 0.4, c.z, '+${coinScore * (_doubleT > 0 ? 2 : 1)}');
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

  /// Lays a run of coins in one of three shapes. The reference never uses a
  /// flat straight line — coins arrive as **rising arcs** and **lane-to-lane
  /// trails**, which is what makes them read as a path to follow rather than
  /// as loose pickups.
  void _spawnCoinLine() {
    final int pattern = _rng.nextInt(3);
    final int lane = _rng.nextInt(3) - 1;
    // The trail slides toward a neighbouring lane; from the middle either way.
    final int lane2 =
        pattern == 2 ? (lane == 0 ? (_rng.nextBool() ? 1 : -1) : 0) : lane;
    const int n = coinsPerLine;
    int placed = 0;
    for (final _Coin c in _coins) {
      if (placed >= n) break;
      if (c.active) continue;
      final double f = n > 1 ? placed / (n - 1) : 0.0; // 0..1 along the run
      c.active = true;
      c.z = spawnZ - placed * coinGap;
      switch (pattern) {
        case 1: // rising arc, peaking mid-run
          c.lane = lane;
          c.y = coinY + math.sin(f * math.pi) * coinArcH;
          c.restX = _laneX(lane);
          break;
        case 2: // trail drifting across to the next lane
          c.lane = f < 0.5 ? lane : lane2;
          c.y = coinY;
          c.restX = _laneX(lane) + (_laneX(lane2) - _laneX(lane)) * f;
          break;
        default: // flat line
          c.lane = lane;
          c.y = coinY;
          c.restX = _laneX(lane);
      }
      c.cx = c.restX;
      placed++;
    }
  }

  void _spawnRamp() {
    for (final _Ramp r in _ramps) {
      if (!r.active) {
        r.active = true;
        r.lane = _rng.nextInt(3) - 1;
        r.z = spawnZ;
        return;
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
    final double dy = (runnerY - c.y).abs();
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

  /// Emits a burst from the pool whose colour matches [colorHex]. The colour
  /// is baked into the pool's material at build time, so it selects a pool
  /// rather than recolouring anything.
  void _spawnParticles(double x, double y, double z, int count, int colorHex,
      double spread, double lift) {
    final _ParticlePool pool = _poolFor(colorHex);
    for (int n = 0; n < count; n++) {
      final _Particle? p = pool.free();
      if (p == null) return; // pool exhausted; emit what we got
      p.active = true;
      p.pos.setValues(x, y, z);
      final double ang = _rng.nextDouble() * math.pi * 2;
      final double sp = spread * (0.4 + _rng.nextDouble());
      p.vel.setValues(math.cos(ang) * sp, lift * (0.6 + _rng.nextDouble()),
          math.sin(ang) * sp);
      p.maxLife = 0.5 + _rng.nextDouble() * 0.35;
      p.life = p.maxLife;
    }
  }

  _ParticlePool _poolFor(int colorHex) {
    for (final _ParticlePool pool in _particlePools) {
      if (pool.colorHex == colorHex) return pool;
    }
    return _particlePools.first; // unlisted colour: wrong tint beats no burst
  }

  void _updateParticles(double dt) {
    for (final _ParticlePool pool in _particlePools) {
      for (final _Particle p in pool.parts) {
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
  }

  /// 1-based position [s] would take on the board, or null if it wouldn't make
  /// the top 5. `_scores` is kept sorted descending, so this counts entries
  /// that already beat it.
  int? _placeFor(int s) {
    if (s <= 0) return null;
    int place = 1;
    for (final _Score e in _scores) {
      if (s > e.score) break;
      place++;
    }
    return place <= 5 ? place : null;
  }

  static String _ordinal(int n) => gm.ordinal(n);

  bool _isHighScore(int s) =>
      s > 0 && (_scores.length < 5 || s > _scores.last.score);

  void _spawnPopup(double wx, double wy, double wz, String text) {
    final Camera? cam = _lastCamera;
    if (cam == null) return;
    final Offset? o = cam.worldToScreen(vm.Vector3(wx, wy, wz), _lastViewport);
    if (o == null) return;
    _popups.add(_Popup(text, o.dx, o.dy));
    if (_popups.length > 14) _popups.removeAt(0);
  }

  void _updatePopups(double dt) {
    for (int i = _popups.length - 1; i >= 0; i--) {
      final _Popup p = _popups[i];
      p.age += dt;
      p.y -= 46 * dt; // rise
      if (p.age >= _Popup.life) _popups.removeAt(i);
    }
  }

  void _crash() {
    if (_phase != Phase.playing) return;
    final int s = _score.round();
    _isNewBest = s > _best; // beats the all-time best
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
        _best = _scores.isNotEmpty ? _scores.first.score : 0;
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
    for (final _Ramp r in _ramps) {
      r.active = false;
    }
    for (final _ParticlePool pool in _particlePools) {
      for (final _Particle p in pool.parts) {
        p.active = false;
      }
    }
    _rampSpawnTimer = rampFirstDelay;
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
    _buildTextures();

    // Static ground: grass fields either side + a continuous road bed. They
    // never move, so they're placed once here (not in paint()) and they catch
    // the sun's shadows.
    final Node grassL = Node(
        mesh: Mesh(CuboidGeometry(vm.Vector3(groundHalfW, 0.4, groundLen)),
            _textured(_texGrass)))
      ..localTransform = vm.Matrix4.translationValues(
          -(roadWidth / 2 + groundHalfW / 2), roadTopY - 0.2, -20);
    final Node grassR = Node(
        mesh: Mesh(CuboidGeometry(vm.Vector3(groundHalfW, 0.4, groundLen)),
            _textured(_texGrass)))
      ..localTransform = vm.Matrix4.translationValues(
          roadWidth / 2 + groundHalfW / 2, roadTopY - 0.2, -20);
    final Node roadBed =
        _litBox(vm.Vector3(roadWidth + 0.1, 0.3, groundLen), cAsphaltB)
          ..localTransform =
              vm.Matrix4.translationValues(0, roadTopY - 0.26, -20);
    // These never move, so their shadow-map contribution can be baked once
    // instead of re-rendered every frame. `shadowStatic` is only safe because
    // nothing below ever changes transform, geometry or material after build —
    // a static node that *does* change keeps showing its stale shadow.
    grassL.shadowStatic = true;
    grassR.shadowStatic = true;
    roadBed.shadowStatic = true;
    _scene.add(grassL);
    _scene.add(grassR);
    _scene.add(roadBed);

    // Packed-dirt shoulders + solid white edge lines. Both are continuous, so
    // they have no phase to scroll — static geometry, placed once. Each sits a
    // hair above roadTopY so it can't z-fight the road or the grass, which
    // both top out exactly at roadTopY.
    for (final double side in <double>[-1.0, 1.0]) {
      _scene.add(Node(
          mesh: Mesh(CuboidGeometry(vm.Vector3(shoulderW, 0.08, groundLen)),
              _textured(_texDirt)))
        ..shadowStatic = true
        ..localTransform = vm.Matrix4.translationValues(
            side * shoulderX, roadTopY - 0.03, -20));
      _scene.add(_litBox(vm.Vector3(0.16, 0.06, groundLen), cLaneLine)
        ..shadowStatic = true
        ..localTransform = vm.Matrix4.translationValues(
            side * edgeLineX, roadTopY - 0.005, -20));
    }

    // Distant hills: parked just inside fogEndDay so they read as haze, and
    // sunk below roadTopY so only the crowns break the horizon.
    for (int i = 0; i < hillCount; i++) {
      final double side = i.isEven ? -1.0 : 1.0;
      // w and h are semi-axes of a unit icosphere, so the mound is 2w wide and
      // rises 0.45h above the ground plane. hx must clear w by a wide margin
      // or a "distant" hill ends up straddling the road.
      final double w = 14.0 + _rng.nextDouble() * 10.0;
      final double h = 6.0 + _rng.nextDouble() * 6.0;
      final double hx = side * (38.0 + _rng.nextDouble() * 30.0);
      // Inside fogEndDay (80 from the camera at camZ) so they read as haze
      // rather than dissolving into the sky entirely.
      final double hz = -40.0 - _rng.nextDouble() * 18.0;
      // Built as a local: a cascade after `..localTransform = …` would bind to
      // the Node, not to the matrix.
      final vm.Matrix4 hm =
          vm.Matrix4.translationValues(hx, roadTopY - h * 0.55, hz)
            ..scaleByDouble(w, h, w * 0.7, 1.0);
      _scene.add(Node(
          mesh: Mesh(IcosphereGeometry(radius: 1.0, subdivisions: 2),
              _matte(cHill)))
        ..shadowStatic = true
        ..localTransform = hm);
    }

    // Road tiles: 18 slabs in two alternating tones, instanced per tone.
    // Textured asphalt. A tile's 0..1 UV covers 6x4 units, so a 256² texture
    // lands ~43 texels/unit — enough for the aggregate grit to read at speed.
    _tilesA = InstancedMesh(
        geometry: CuboidGeometry(vm.Vector3(roadWidth, 0.2, segLen * 0.96)),
        material: _textured(_texAsphaltA, rough: 0.92));
    _tilesB = InstancedMesh(
        geometry: CuboidGeometry(vm.Vector3(roadWidth, 0.2, segLen * 0.96)),
        material: _textured(_texAsphaltB, rough: 0.92));
    for (int i = 0; i < tileCount; i++) {
      (i.isEven ? _tilesA! : _tilesB!).addInstance(vm.Matrix4.identity());
    }
    _scene.add(Node()..addComponent(InstancedMeshComponent(_tilesA!)));
    _scene.add(Node()..addComponent(InstancedMeshComponent(_tilesB!)));

    // Lane dividers: white and *lit*, not the old unlit gold. Lit means they
    // take the same sun and distance fog as the road, so they fade with it
    // instead of staying crisp all the way to the horizon. One instanced set
    // covers both lines — [0, n) left, [n, 2n) right.
    _dashes = InstancedMesh(
        geometry: CuboidGeometry(vm.Vector3(0.16, 0.06, 1.5)),
        material: _matte(cLaneLine));
    for (int k = 0; k < dashCount * 2; k++) {
      _dashes!.addInstance(vm.Matrix4.identity());
    }
    _scene.add(Node()..addComponent(InstancedMeshComponent(_dashes!)));
    _buildTrees();
    // Houses: box walls + a 4-sided pyramid roof (a cone with 4 radial
    // segments), instanced per part. 40 draw calls become 7.
    _houseWalls = InstancedMesh(
        geometry: CuboidGeometry(vm.Vector3(1.5, 1.1, 1.5)),
        material: _matte(cWall));
    _houseDoors = InstancedMesh(
        geometry: CuboidGeometry(vm.Vector3(0.34, 0.55, 0.06)),
        material: _matte(cDoor));
    _houseWindows = InstancedMesh(
        geometry: CuboidGeometry(vm.Vector3(0.32, 0.32, 0.06)),
        material: _matte(cWindow));
    for (final int hex in roofHexes) {
      _houseRoofs.add(InstancedMesh(
          geometry: CylinderGeometry(
              bottomRadius: 1.15,
              topRadius: 0.0,
              height: 0.9,
              radialSegments: 4),
          material: _matte(hex)));
    }
    for (int i = 0; i < houseCount; i++) {
      for (int s = 0; s < 2; s++) {
        final double side = s == 0 ? -1.0 : 1.0;
        // Same offset the two sides had before, so they stay staggered.
        final int roofIdx = (s == 0 ? i : i + 2) % roofHexes.length;
        _houseData.add(vm.Vector4(
          side * houseX,
          i * houseSpacing + houseSpacing / 2,
          1.1 + _rng.nextDouble() * 0.7,
          roofIdx.toDouble(),
        ));
        _houseRoofSlot.add(_houseRoofs[roofIdx].instanceCount);
        _houseRoofs[roofIdx].addInstance(vm.Matrix4.identity());
        _houseWalls!.addInstance(vm.Matrix4.identity());
        _houseDoors!.addInstance(vm.Matrix4.identity());
        _houseWindows!.addInstance(vm.Matrix4.identity());
      }
    }
    _scene.add(Node()..addComponent(InstancedMeshComponent(_houseWalls!)));
    _scene.add(Node()..addComponent(InstancedMeshComponent(_houseDoors!)));
    _scene.add(Node()..addComponent(InstancedMeshComponent(_houseWindows!)));
    for (final InstancedMesh roof in _houseRoofs) {
      _scene.add(Node()..addComponent(InstancedMeshComponent(roof)));
    }

    _rocks = InstancedMesh(
        geometry: IcosphereGeometry(radius: 0.5, subdivisions: 1),
        material: _matte(cRock));
    _bushes = InstancedMesh(
        geometry: IcosphereGeometry(radius: 0.5, subdivisions: 1),
        material: _matte(cBush));
    _scatterDeco(_rocks!, _rockData, 0.35, 0.55);
    _scatterDeco(_bushes!, _bushData, 0.5, 0.7);
    _scene.add(Node()..addComponent(InstancedMeshComponent(_rocks!)));
    _scene.add(Node()..addComponent(InstancedMeshComponent(_bushes!)));

    _flowersA = InstancedMesh(
        geometry: IcosphereGeometry(radius: 0.5, subdivisions: 1),
        material: _matte(cFlowerA));
    _flowersB = InstancedMesh(
        geometry: IcosphereGeometry(radius: 0.5, subdivisions: 1),
        material: _matte(cFlowerB));
    _scatterDeco(_flowersA!, _flowerAData, 0.12, 0.12);
    _scatterDeco(_flowersB!, _flowerBData, 0.12, 0.12);
    _scene.add(Node()..addComponent(InstancedMeshComponent(_flowersA!)));
    _scene.add(Node()..addComponent(InstancedMeshComponent(_flowersB!)));

    // Tall grass tufts: slim tapered blades carpeting the roadside in three
    // green shades, each drawn in a single instanced call and scrolled + yawed
    // in the painter. High count + thin blades give a lush, fuzzy silhouette.
    _grassA = InstancedMesh(
        geometry: CylinderGeometry(
            bottomRadius: 0.06, topRadius: 0.0, height: 0.62, radialSegments: 3),
        material: _matte(cGrassA));
    _grassB = InstancedMesh(
        geometry: CylinderGeometry(
            bottomRadius: 0.055, topRadius: 0.0, height: 0.5, radialSegments: 3),
        material: _matte(cGrassB));
    _grassC = InstancedMesh(
        geometry: CylinderGeometry(
            bottomRadius: 0.06, topRadius: 0.0, height: 0.72, radialSegments: 3),
        material: _matte(cGrassC));
    _scatterGrass(_grassA!, _grassAData);
    _scatterGrass(_grassB!, _grassBData);
    _scatterGrass(_grassC!, _grassCData);
    _scene.add(Node()..addComponent(InstancedMeshComponent(_grassA!)));
    _scene.add(Node()..addComponent(InstancedMeshComponent(_grassB!)));
    _scene.add(Node()..addComponent(InstancedMeshComponent(_grassC!)));

    // Guardrails: a beam run on both shoulders with a post every other beam.
    // Fixed spacing means these need no scatter data at all — the painter maps
    // instance index -> side + z. Instances [0, n) are the left side, [n, 2n)
    // the right.
    _rails = InstancedMesh(
        // Beam length is the full spacing, not 92% of it: the 8% gap was
        // invisible at distance but broke the rail into separate floating
        // sticks in the near field, where one segment spans much of the screen.
        geometry: CuboidGeometry(vm.Vector3(0.07, 0.3, railSpacing)),
        material: _matte(cRail));
    _railPosts = InstancedMesh(
        geometry: CuboidGeometry(vm.Vector3(0.09, 0.66, 0.09)),
        material: _matte(cRailPost));
    for (int i = 0; i < railCount * 2; i++) {
      _rails!.addInstance(vm.Matrix4.identity());
    }
    for (int i = 0; i < railPostCount * 2; i++) {
      _railPosts!.addInstance(vm.Matrix4.identity());
    }
    _scene.add(Node()..addComponent(InstancedMeshComponent(_rails!)));
    _scene.add(Node()..addComponent(InstancedMeshComponent(_railPosts!)));

    // Roadside sign posts: a slim pole carrying a board near the top.
    _signPoles = InstancedMesh(
        geometry: CylinderGeometry(
            // Was 0.05, which vanished at road distance and left the boards
            // reading as grey squares floating in the trees.
            bottomRadius: 0.085,
            topRadius: 0.085,
            height: 2.0,
            radialSegments: 6),
        material: _matte(cSignPole));
    _signBoards = InstancedMesh(
        geometry: CuboidGeometry(vm.Vector3(0.62, 0.44, 0.05)),
        material: _matte(cSignBoard));
    for (int i = 0; i < signCount * 2; i++) {
      _signPoles!.addInstance(vm.Matrix4.identity());
      _signBoards!.addInstance(vm.Matrix4.identity());
    }
    _scene.add(Node()..addComponent(InstancedMeshComponent(_signPoles!)));
    _scene.add(Node()..addComponent(InstancedMeshComponent(_signBoards!)));

    for (int i = 0; i < rampCount; i++) {
      final Node n = _rampNode();
      _ramps.add(_Ramp(n));
      _scene.add(n);
    }

    // Pooled obstacles: a repeating mix of gift box / candy barrier / green
    // container so the road never shows a plain cube. Kind is fixed per slot
    // (built once), which is enough variety with 10 slots recycling.
    for (int i = 0; i < obstacleCount; i++) {
      final int kind = i % 3;
      final Node n = kind == 0
          ? _giftBox(boxHex: i.isEven ? cGiftA : cGiftB)
          : kind == 1
              ? _barrier()
              : _container(bodyHex: i.isEven ? cContainer : cContainerR);
      _obstacles.add(_Obstacle(n));
      _scene.add(n);
    }
    // Coins are upright discs (a cylinder stood on edge by the painter), not
    // flat cards — that is what gives the reference its edge-on/face-on flash
    // as they spin. All 36 share one geometry and one material, so they are a
    // single instanced set: 36 draw calls become 1.
    final PhysicallyBasedMaterial coinMat = PhysicallyBasedMaterial()
      ..baseColorFactor = _linearFromHex(cCoin)
      ..roughnessFactor = 0.3
      ..metallicFactor = 1.0;
    _coinMesh = InstancedMesh(
        geometry: CylinderGeometry(
            bottomRadius: coinRadius,
            topRadius: coinRadius,
            height: 0.1,
            radialSegments: 14),
        material: coinMat);
    for (int i = 0; i < coinCount; i++) {
      _coins.add(_Coin());
      _coinMesh!.addInstance(vm.Matrix4.identity());
    }
    _scene.add(Node()..addComponent(InstancedMeshComponent(_coinMesh!)));
    for (int i = 0; i < powerupCount; i++) {
      final UnlitMaterial mat = UnlitMaterial()
        ..baseColorFactor = _glowFromHex(cMagnet, powerGlow);
      final Node n = Node(
          mesh: Mesh(
              IcosphereGeometry(radius: powerRadius, subdivisions: 2), mat));
      _powerups.add(_PowerUp(n, mat));
      _scene.add(n);
    }
    // One instanced set per burst colour. Unlit on purpose: a spark should
    // read at full brightness regardless of where the sun is.
    for (final int hex in particleColors) {
      final UnlitMaterial mat = UnlitMaterial()
        ..baseColorFactor = _glowFromHex(hex, particleGlow);
      final InstancedMesh mesh = InstancedMesh(
          geometry: CuboidGeometry(vm.Vector3(0.18, 0.18, 0.18)),
          material: mat);
      _particlePools.add(_ParticlePool(hex, mesh, particlesPerColor));
      _scene.add(Node()..addComponent(InstancedMeshComponent(mesh)));
    }

    _runner = _box(vm.Vector3(1.0, 1.0, 1.0), debug: true);
    _scene.add(_runner);
  }

  /// One-time daylight scene setup: a shadow-casting sun + soft ambient so PBR
  /// surfaces are lit and Dash drops a real shadow, sky-colored distance haze
  /// so the far road melts into the horizon, and just a touch of bloom + grade.
  void _setupSceneLook() {
    _scene.root.addComponent(
      DirectionalLightComponent(
        DirectionalLight(
          direction: vm.Vector3(-0.5, -1.0, -0.42),
          intensity: sunIntensity,
          castsShadow: true,
          // The two overrides below are the point: leaving cascade count at
          // its default of 4 quadruples the shadow pass for a view distance
          // we never use.
          shadowCascadeCount: shadowCascades,
          shadowMapResolution: shadowMapRes,
          shadowMaxDistance: shadowDistance,
          // Raised from the 0.02 defaults. Cascade fitting follows the camera
          // frustum, so a taller or wider window spreads the same texels over
          // more world and the depth comparison starts failing against itself —
          // flat ground shadows itself in large dark patches. Tuning cascade
          // count and resolution alone fixed it at one window size and it came
          // straight back at another; bias is the part that does not depend on
          // the viewport. Peter-panning at this sun angle is not visible.
          shadowDepthBias: 0.06,
          shadowNormalBias: 0.09,
        ),
      ),
    );
    _scene.environmentIntensity = envIntensity;

    final vm.Vector4 f = _linearFromHex(cFogDay);
    _scene.fog
      ..enabled = true
      ..mode = FogMode.linear
      ..color = vm.Vector3(f.r, f.g, f.b)
      ..start = fogStartDay
      ..end = fogEndDay;

    _scene.postProcess.bloom
      ..enabled = true
      ..threshold = 1.1
      ..intensity = 0.28
      ..scatter = 0.6;
    _scene.postProcess.colorGrading
      ..enabled = true
      ..contrast = 1.0 // softer, less crushed shadows
      ..saturation = 1.12;
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
    final double k = dt <= 0 ? 1.0 : gm.smoothing(dashAnimBlend, dt);
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

  /// A lit PBR box — responds to the sun and casts/receives shadows. Used for
  /// the daylight world (road, grass, obstacles, coins) instead of [_box].
  Node _litBox(vm.Vector3 size, int colorHex,
      {double rough = 0.9, double metal = 0.0}) {
    final PhysicallyBasedMaterial material = PhysicallyBasedMaterial()
      ..baseColorFactor = _linearFromHex(colorHex)
      ..roughnessFactor = rough
      ..metallicFactor = metal;
    return Node(mesh: Mesh(CuboidGeometry(size), material));
  }

  PhysicallyBasedMaterial _matte(int colorHex) => PhysicallyBasedMaterial()
    ..baseColorFactor = _linearFromHex(colorHex)
    ..roughnessFactor = 1.0;

  /// A matte material whose colour comes from [tex] rather than a flat factor.
  ///
  /// `baseColorFactor` **multiplies** the texture, so it must be white here —
  /// the generated pixels already carry the surface's colour. Leaving the old
  /// hex in place would double-darken the surface.
  PhysicallyBasedMaterial _textured(Texture2D tex, {double rough = 1.0}) =>
      PhysicallyBasedMaterial()
        ..baseColorFactor = vm.Vector4(1, 1, 1, 1)
        ..baseColorTexture = tex
        ..roughnessFactor = rough;

  /// Uploads the procedural surface textures.
  ///
  /// Called once at the top of `_buildWorld`, before any material that samples
  /// them. Sizes are deliberately uneven: the road gets the most texels because
  /// a tile's 0..1 UV covers only 6x4 units (~43 texels/unit), while the ground
  /// slabs stretch one UV over ~280 units and would waste anything finer.
  void _buildTextures() {
    _texAsphaltA = Texture2D.fromPixels(
        gt.asphaltPixels(256, cAsphaltA & 0xFFFFFF), 256, 256);
    _texAsphaltB = Texture2D.fromPixels(
        gt.asphaltPixels(256, cAsphaltB & 0xFFFFFF, seed: 29), 256, 256);
    // Endpoints taken from the existing palette rather than invented, so the
    // ground varies between the same greens the instanced tufts already use.
    _texGrass = Texture2D.fromPixels(
        gt.grassPixels(128, cGrass & 0xFFFFFF, cGrassB & 0xFFFFFF), 128, 128);
    _texDirt = Texture2D.fromPixels(
        gt.dirtPixels(128, cShoulder & 0xFFFFFF), 128, 128);
  }

  /// Picks a foliage tint: pines stay green-ish; round trees occasionally go
  /// autumn for variety.
  int _foliageColor(bool pine) {
    final int r = _rng.nextInt(10);
    if (pine) return r < 7 ? cPine : cLeafB;
    if (r < 5) return cLeaf;
    if (r < 7) return cLeafB;
    if (r < 8) return cPine;
    return cAutumn;
  }

  /// Builds the instanced roadside trees.
  ///
  /// Two passes, because the mesh set cannot be known up front: the foliage
  /// colour is drawn at random per tree, so pass one decides every tree's type,
  /// colour, scale and phase, and pass two allocates exactly the meshes those
  /// choices need. Only non-empty meshes reach the scene — an unused
  /// (geometry, colour) pair would otherwise be a render item drawing nothing.
  void _buildTrees() {
    // Pass 1: choose each tree, grouping by foliage colour as we go.
    final List<bool> pines = <bool>[];
    final List<double> scales = <double>[];
    final List<double> xs = <double>[];
    final List<double> phases = <double>[];
    final List<_TreeFoliage> groups = <_TreeFoliage>[];
    final List<int> slots = <int>[];

    _TreeFoliage groupFor(int hex) {
      for (final _TreeFoliage f in _foliages) {
        if (f.colorHex == hex) return f;
      }
      final _TreeFoliage f = _TreeFoliage(hex);
      _foliages.add(f);
      return f;
    }

    for (int j = 0; j < postCount; j++) {
      for (int side = 0; side < 2; side++) {
        // Alternating pine/round per side, exactly as the node version did.
        final bool pine = side == 0 ? j.isEven : j.isOdd;
        final _TreeFoliage g = groupFor(_foliageColor(pine));
        pines.add(pine);
        scales.add(1.15 + _rng.nextDouble() * 0.95);
        xs.add(side == 0 ? -treeX : treeX);
        phases.add(j * postSpacing);
        groups.add(g);
        slots.add(pine ? g.pineCount++ : g.roundCount++);
      }
    }

    // Pass 2: one trunk mesh for every tree (they share a colour), then the
    // per-colour foliage meshes each group actually needs.
    _treeTrunks = InstancedMesh(
        geometry: CylinderGeometry(
            bottomRadius: 0.13,
            topRadius: 0.11,
            height: trunkH,
            radialSegments: 8),
        material: _matte(cTrunk));
    for (int i = 0; i < pines.length; i++) {
      _treeTrunks!.addInstance(vm.Matrix4.identity());
    }
    _scene.add(Node()..addComponent(InstancedMeshComponent(_treeTrunks!)));

    for (final _TreeFoliage f in _foliages) {
      if (f.pineCount > 0) {
        for (final List<double> t in _pineTierDims) {
          final InstancedMesh m = InstancedMesh(
              geometry: CylinderGeometry(
                  bottomRadius: t[0],
                  topRadius: 0.0,
                  height: t[1],
                  radialSegments: 12),
              material: _matte(f.colorHex));
          for (int i = 0; i < f.pineCount; i++) {
            m.addInstance(vm.Matrix4.identity());
          }
          f.pineTiers.add(m);
          _scene.add(Node()..addComponent(InstancedMeshComponent(m)));
        }
      }
      if (f.roundCount > 0) {
        for (int b = 0; b < _roundBlobRadii.length; b++) {
          final InstancedMesh m = InstancedMesh(
              geometry: IcosphereGeometry(
                  radius: _roundBlobRadii[b], subdivisions: 2),
              material: _matte(f.colorHex));
          // The middle radius carries two blobs per tree.
          final int per = b == 1 ? 2 : 1;
          for (int i = 0; i < f.roundCount * per; i++) {
            m.addInstance(vm.Matrix4.identity());
          }
          f.roundBlobs.add(m);
          _scene.add(Node()..addComponent(InstancedMeshComponent(m)));
        }
      }
    }

    for (int i = 0; i < pines.length; i++) {
      _trees.add(_Tree(
        x: xs[i],
        phaseZ: phases[i],
        scale: scales[i],
        pine: pines[i],
        foliage: groups[i],
        slot: slots[i],
        trunkSlot: i,
      ));
    }
  }

  // --- obstacle shapes (base at origin; painter places them at roadTopY) ----

  /// A wrapped present: a coloured cube crossed by two cream ribbons with a
  /// little bow on top.
  Node _giftBox({required int boxHex}) {
    final Node root = Node();
    const double s = 0.92; // body edge
    const double half = s / 2;
    root.add(Node(mesh: Mesh(CuboidGeometry(vm.Vector3(s, s, s)), _matte(boxHex)))
      ..localTransform = vm.Matrix4.translationValues(0, half, 0));
    // two ribbons wrapping the box (a "+" seen from the top / front)
    root.add(Node(
        mesh: Mesh(
            CuboidGeometry(vm.Vector3(0.18, s + 0.04, s + 0.04)),
            _matte(cRibbon)))
      ..localTransform = vm.Matrix4.translationValues(0, half, 0));
    root.add(Node(
        mesh: Mesh(
            CuboidGeometry(vm.Vector3(s + 0.04, s + 0.04, 0.18)),
            _matte(cRibbon)))
      ..localTransform = vm.Matrix4.translationValues(0, half, 0));
    // bow: a knot plus two angled loops
    root.add(Node(
        mesh: Mesh(
            IcosphereGeometry(radius: 0.1, subdivisions: 1), _matte(cRibbon)))
      ..localTransform = vm.Matrix4.translationValues(0, s + 0.05, 0));
    for (final double dir in <double>[-1.0, 1.0]) {
      final vm.Matrix4 m = vm.Matrix4.translationValues(dir * 0.16, s + 0.05, 0)
        ..rotateZ(dir * 0.6);
      root.add(Node(
          mesh: Mesh(
              CuboidGeometry(vm.Vector3(0.24, 0.12, 0.1)), _matte(cRibbon)))
        ..localTransform = m);
    }
    return root;
  }

  /// A candy-stripe road barricade: two grey legs carrying a striped crossbar
  /// plus a solid lower board so it fills the collision box fairly.
  Node _barrier() {
    final Node root = Node();
    for (final double dx in <double>[-0.5, 0.5]) {
      root.add(Node(
          mesh: Mesh(
              CuboidGeometry(vm.Vector3(0.1, 0.92, 0.1)), _matte(cBarrierLeg)))
        ..localTransform = vm.Matrix4.translationValues(dx, 0.46, 0));
    }
    // solid lower board (red)
    root.add(Node(
        mesh: Mesh(
            CuboidGeometry(vm.Vector3(1.12, 0.3, 0.14)), _matte(cBarrierA)))
      ..localTransform = vm.Matrix4.translationValues(0, 0.32, 0));
    // striped top rail
    for (int i = 0; i < 5; i++) {
      root.add(Node(
          mesh: Mesh(CuboidGeometry(vm.Vector3(0.224, 0.26, 0.16)),
              _matte(i.isEven ? cBarrierA : cBarrierB)))
        ..localTransform =
            vm.Matrix4.translationValues(-0.448 + i * 0.224, 0.74, 0));
    }
    return root;
  }

  /// A green shipping container: a body with darker top/bottom trim and a few
  /// vertical corrugation ribs on the front face the player sees.
  Node _container({required int bodyHex}) {
    final Node root = Node();
    const double w = 1.16, h = 0.96, d = 0.96;
    root.add(Node(
        mesh: Mesh(CuboidGeometry(vm.Vector3(w, h, d)), _matte(bodyHex)))
      ..localTransform = vm.Matrix4.translationValues(0, h / 2, 0));
    for (final double ty in <double>[0.07, h - 0.07]) {
      root.add(Node(
          mesh: Mesh(CuboidGeometry(vm.Vector3(w + 0.04, 0.12, d + 0.04)),
              _matte(cContainerB)))
        ..localTransform = vm.Matrix4.translationValues(0, ty, 0));
    }
    for (int i = 0; i < 5; i++) {
      root.add(Node(
          mesh: Mesh(CuboidGeometry(vm.Vector3(0.06, h - 0.28, 0.03)),
              _matte(cContainerB)))
        ..localTransform = vm.Matrix4.translationValues(
            -0.4 + i * 0.2, h / 2, d / 2 + 0.015));
    }
    return root;
  }

  /// A launch platform: a low blue slab with side rails and a darker sloped
  /// lip on its **+z** face — objects travel from -z toward the camera, so the
  /// +z end is the one the runner meets first. Base at origin.
  Node _rampNode() {
    final Node root = Node();
    root.add(Node(
        mesh: Mesh(CuboidGeometry(vm.Vector3(1.7, 0.18, rampHalfZ * 2)),
            _matte(cRamp)))
      ..localTransform = vm.Matrix4.translationValues(0, 0.09, 0));
    final vm.Matrix4 lip =
        vm.Matrix4.translationValues(0, 0.07, rampHalfZ + 0.18)
          ..rotateX(0.42);
    root.add(Node(
        mesh:
            Mesh(CuboidGeometry(vm.Vector3(1.7, 0.06, 0.5)), _matte(cRampEdge)))
      ..localTransform = lip);
    for (final double dx in <double>[-0.88, 0.88]) {
      root.add(Node(
          mesh: Mesh(CuboidGeometry(vm.Vector3(0.08, 0.26, rampHalfZ * 2)),
              _matte(cRampEdge)))
        ..localTransform = vm.Matrix4.translationValues(dx, 0.13, 0));
    }
    return root;
  }

  /// Seeds [decoCount] scattered instances into [mesh] (identity transforms,
  /// scrolled each frame by the painter) and records their (x, phaseZ, scale).
  void _scatterDeco(InstancedMesh mesh, List<vm.Vector3> data, double minScale,
      double scaleRange) {
    for (int i = 0; i < decoCount; i++) {
      final double side = _rng.nextBool() ? 1.0 : -1.0;
      final double x = side * (roadWidth / 2 + 1.6 + _rng.nextDouble() * 24);
      final double phase = _rng.nextDouble() * totalLen;
      final double sc = minScale + _rng.nextDouble() * scaleRange;
      data.add(vm.Vector3(x, phase, sc));
      mesh.addInstance(vm.Matrix4.identity());
    }
  }

  /// Seeds [grassCount] grass tufts hugging the road edge outward, each with a
  /// random yaw so the 3-sided blades face every way. Data is (x, phaseZ,
  /// scale, yaw); the painter scrolls + rotates them each frame.
  void _scatterGrass(InstancedMesh mesh, List<vm.Vector4> data) {
    for (int i = 0; i < grassCount; i++) {
      final double side = _rng.nextBool() ? 1.0 : -1.0;
      // Starts just outside the dirt shoulder rather than at the asphalt, so
      // the shoulder stays readable as its own band.
      final double x =
          side * (roadWidth / 2 + shoulderW + _rng.nextDouble() * 15);
      final double phase = _rng.nextDouble() * totalLen;
      final double sc = 0.7 + _rng.nextDouble() * 1.05;
      final double yaw = _rng.nextDouble() * 6.283;
      data.add(vm.Vector4(x, phase, sc, yaw));
      mesh.addInstance(vm.Matrix4.identity());
    }
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

  /// Renders the 3D view below native resolution and upscales on composite.
  /// The one performance lever that is independent of scene content, so it
  /// still helps on a device the geometry budget alone cannot save.
  /// Derives the render scale from the window's **real** pixel count and
  /// pushes it to the scene. Called at the top of `build`, so it is correct on
  /// the first frame and re-derives itself on a resize or a monitor change.
  ///
  /// `MediaQuery.sizeOf` is in logical pixels; multiplying by the device pixel
  /// ratio gives what the GPU actually fills. Dividing the budget by that and
  /// taking the square root converts an area ratio into the linear scale
  /// `renderScale` wants. Capped at 1.0 — a small window should stay sharp, not
  /// supersample.
  ///
  /// The HIGH/BALANCED/FAST preset multiplies this rather than replacing it, so
  /// the button still means something on every machine instead of meaning
  /// "unplayable" on one and "wasteful" on another.
  void _syncRenderScale(BuildContext context) {
    final double dpr = MediaQuery.devicePixelRatioOf(context);
    final Size size = MediaQuery.sizeOf(context);
    final double nativePixels = size.width * dpr * size.height * dpr;
    final double fit = nativePixels <= 0
        ? 1.0
        : math.min(1.0, math.sqrt(pixelBudget / nativePixels));
    final double target =
        math.max(minRenderScale, fit * qualityScales[_quality]);
    if ((target - _appliedScale).abs() < 0.01) return;
    _appliedScale = target;
    _scene.renderScale = target;
  }

  void _applyQuality() => _appliedScale = -1; // force a re-derive next build

  Future<void> _loadQuality() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final int q = prefs.getInt('quality.v1') ?? 0;
      if (!mounted) return;
      setState(() => _quality = q.clamp(0, qualityScales.length - 1));
      _applyQuality();
    } catch (_) {}
  }

  void _cycleQuality() {
    setState(() => _quality = (_quality + 1) % qualityScales.length);
    _applyQuality();
    _focus.requestFocus();
    _saveQuality();
  }

  Future<void> _saveQuality() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setInt('quality.v1', _quality);
    } catch (_) {}
  }

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
    _syncRenderScale(context);
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
                      colors: <Color>[Color(cSkyTop), Color(cSkyBot)],
                    ),
                  ),
                ),
              ),
              // Clouds ride between the sky gradient and the 3D layer. They
              // are deliberately NOT geometry: at fogEndDay everything real
              // dissolves into cSkyBot, so a 3D cloud would simply vanish.
              Positioned.fill(
                child: IgnorePointer(
                  child: ValueListenableBuilder<int>(
                    valueListenable: _repaint,
                    builder: (BuildContext context, int tick, Widget? child) =>
                        CustomPaint(painter: _CloudPainter(_elapsed)),
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
                right: 8,
                top: 44,
                child: TextButton(
                  onPressed: _cycleQuality,
                  style: TextButton.styleFrom(
                    minimumSize: Size.zero,
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(
                    qualityNames[_quality],
                    style: const TextStyle(
                      color: Colors.white38,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1,
                    ),
                  ),
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
              _popupLayer(),
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

  Widget _popupLayer() {
    return Positioned.fill(
      child: IgnorePointer(
        child: ValueListenableBuilder<int>(
          valueListenable: _repaint,
          builder: (BuildContext context, int _, Widget? __) {
            return Stack(
              children: <Widget>[
                for (final _Popup p in _popups)
                  Positioned(
                    left: p.x - 32,
                    top: p.y - 14,
                    child: Opacity(
                      opacity: (1 - p.age / _Popup.life).clamp(0.0, 1.0),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Container(
                            width: 13,
                            height: 13,
                            decoration: BoxDecoration(
                              color: cGold,
                              // Not `shape: BoxShape.circle` — flutter_scene
                              // exports a BoxShape too, so the bare name is
                              // ambiguous in this library (same trap as
                              // Animation; see CLAUDE.md).
                              borderRadius: BorderRadius.circular(7),
                              border: Border.all(
                                  color: Colors.black26, width: 1.5),
                            ),
                          ),
                          const SizedBox(width: 5),
                          Text(
                            p.text,
                            style: const TextStyle(
                              color: cGold,
                              fontSize: 27,
                              fontWeight: FontWeight.w900,
                              // Stacked shadows fake the dark outline the
                              // reference popups have; Flutter text has no
                              // stroke without a custom painter.
                              shadows: <Shadow>[
                                Shadow(color: Colors.black87, blurRadius: 2),
                                Shadow(
                                    color: Colors.black54,
                                    blurRadius: 6,
                                    offset: Offset(0, 2)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            );
          },
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
                _scoreCapsule(),
                const SizedBox(height: 6),
                _bestLine(),
                _powerChips(),
              ],
            );
          },
        ),
      ),
    );
  }

  /// The reference's signature HUD: one dark rounded capsule holding the score,
  /// with coins, speed and the frame rate on a smaller line beneath it. Speed
  /// is shown in m/s because `_curSpeed` already *is* world units per second —
  /// the old km/h line multiplied it by an invented factor.
  Widget _scoreCapsule() {
    return Container(
      padding: const EdgeInsets.fromLTRB(26, 8, 26, 9),
      decoration: BoxDecoration(
        color: const Color(0xE60E1A2B),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: cGold.withValues(alpha: 0.85), width: 2),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.28),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            '${_score.round()}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 38,
              fontWeight: FontWeight.w800,
              letterSpacing: 1,
              height: 1.0,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                    color: cGold, borderRadius: BorderRadius.circular(5)),
              ),
              const SizedBox(width: 5),
              Text('$_coinsCollected',
                  style: const TextStyle(
                      color: cGold,
                      fontSize: 13,
                      fontWeight: FontWeight.w700)),
              const SizedBox(width: 12),
              Text('${_curSpeed.round()} m/s',
                  style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 12,
                      fontWeight: FontWeight.w600)),
              const SizedBox(width: 12),
              // Density is a real draw-call budget here (see CLAUDE.md), so
              // the frame rate is on screen rather than guessed at.
              // The applied render scale is on screen next to the frame rate on
              // purpose: the resolution is derived from the device now, so
              // seeing "16 fps" without knowing what it was rendering at is
              // exactly how this shipped broken.
              Text(
                  '${_fps.round()} fps  ·  ${(_appliedScale * 100).round()}%',
                  style: TextStyle(
                      color: _fps < 45 ? cRed : Colors.white38,
                      fontSize: 11,
                      fontWeight: FontWeight.w600)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _bestLine() {
    final int cur = _score.round();
    final bool beating = _best > 0 && cur > _best;
    if (_best <= 0 && !beating) return const SizedBox.shrink();
    return Text(
      beating ? '★  NEW BEST' : 'BEST  $_best',
      style: TextStyle(
        color: beating ? cGold : Colors.white38,
        fontSize: 13,
        fontWeight: beating ? FontWeight.w800 : FontWeight.w600,
        letterSpacing: beating ? 1.5 : 0.5,
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
            if (_isNewBest) ...<Widget>[
              const Text(
                '★  NEW BEST!',
                style: TextStyle(
                  color: cGold,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 8),
            ],
            Text(
              'Score  ${_score.round()}      Best  $_best',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w600,
              ),
            ),
            // The reference's crash screen tells you where you landed, not
            // just that you qualified. Only shown before the name is saved —
            // afterwards the score is already on the board and would count
            // itself.
            if (_enteringName && _placeFor(_score.round()) != null) ...<Widget>[
              const SizedBox(height: 10),
              Text(
                'You got ${_ordinal(_placeFor(_score.round())!)} place!',
                style: const TextStyle(
                  color: cGold,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
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
      const SizedBox(height: 12),
      OutlinedButton.icon(
        onPressed: _shareScore,
        icon: const Icon(Icons.share, size: 18),
        label: const Text('SHARE SCORE'),
        style: OutlinedButton.styleFrom(
          foregroundColor: cTeal,
          side: const BorderSide(color: Color(0x554FD1C5)),
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
      const SizedBox(height: 10),
      const Text(
        'Space  play again    ·    M  menu',
        style: TextStyle(color: Colors.white38, fontSize: 13),
      ),
    ];
  }

  Future<void> _shareScore() async {
    final int s = _score.round();
    final String text =
        'I scored $s in flutter-scene-runner — a 3D endless runner I built '
        'from scratch in Flutter (Flutter GPU / Impeller), no game engine.\n\n'
        'Play it: https://saqrelfirgany.github.io/flutter-scene-runner/\n'
        '#Flutter #GameDev';
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Score copied — paste it anywhere to share!'),
        duration: Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
    _focus.requestFocus();
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
        // Pill, like the reference's START button. Colour stays brand teal
        // rather than the reference blue — that is a brand call, not a
        // look-and-feel one.
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
      ),
      child: Text(label),
    );
  }
}
