// Part of the flutter-scene-runner library — see lib/main.dart.
// `part of` keeps the game one library so the sim/render split can use
// library-private access (e.g. _GamePainter reads _GamePageState fields).
part of 'main.dart';

/// Owns **every** per-frame transform write, the camera, and `scene.render()`.
///
/// The simulation (`_GamePageState._update`) never touches a scene node; this
/// painter never touches gameplay state. That split is what keeps a 60 Hz
/// ticker and a `CustomPainter` from fighting over the same data.
///
/// ## Allocation policy
///
/// This method runs 60 times a second over ~1,600 transforms. Allocating a
/// `Matrix4` per transform would churn ~1,600 objects per frame (~96k/s), so
/// nothing here allocates. Two different techniques, because the two sinks
/// have different ownership rules:
///
/// * **Instanced meshes** — `InstancedMesh.setInstanceTransform` does
///   `_instances[i].setFrom(m)`, i.e. it *copies*. One shared [_scratch]
///   matrix is therefore safe for every instance of every mesh.
/// * **Scene nodes** — `Node.localTransform`'s setter stores the reference it
///   is handed. A shared scratch would alias every node onto one matrix. So
///   nodes are updated by mutating *their own* matrix in place and calling
///   `markTransformDirty()`, which is exactly what that method is documented
///   for. See [_place].
class _GamePainter extends CustomPainter {
  _GamePainter({required this.state, required Listenable repaint})
      : super(repaint: repaint);

  final _GamePageState state;

  /// Shared scratch for instanced writes only — never assigned to a node.
  static final vm.Matrix4 _scratch = vm.Matrix4.identity();

  /// Holds a composite prop's world transform while its parts are composed
  /// onto it. Separate from [_scratch] because [_compose] writes the result
  /// into [_scratch] and must not clobber the base between parts.
  static final vm.Matrix4 _base = vm.Matrix4.identity();

  // Tree part-local transforms. Built once: they are pure constants derived
  // from `trunkH` and the tier/blob tables, and rebuilding them per frame would
  // reintroduce exactly the allocation churn this painter avoids.
  static final vm.Matrix4 _kTrunk =
      vm.Matrix4.translationValues(0, _GamePageState.trunkH / 2, 0);

  static final List<vm.Matrix4> _kPineTiers = <vm.Matrix4>[
    // Each tier sits on the one below with a deliberate overlap, so the cones
    // read as a single layered conifer rather than three stacked hats.
    vm.Matrix4.translationValues(0, _GamePageState.trunkH + 1.2 / 2 - 0.15, 0),
    vm.Matrix4.translationValues(
        0, _GamePageState.trunkH + 1.2 + 0.95 / 2 - 0.55, 0),
    vm.Matrix4.translationValues(
        0, _GamePageState.trunkH + 1.2 + 0.95 + 0.72 / 2 - 0.95, 0),
  ];

  /// Crown centre height for the round trees.
  static const double _crownY = _GamePageState.trunkH + 0.62;
  static final vm.Matrix4 _kCrown = vm.Matrix4.translationValues(0, _crownY, 0);
  static final vm.Matrix4 _kBlobA =
      vm.Matrix4.translationValues(0.4, _crownY + 0.04, 0.12);
  static final vm.Matrix4 _kBlobB =
      vm.Matrix4.translationValues(-0.36, _crownY, -0.14);
  static final vm.Matrix4 _kBlobTop =
      vm.Matrix4.translationValues(0.05, _crownY + 0.4, -0.05);

  /// Writes `_base * partLocal` into instance [index] of [mesh].
  static void _compose(InstancedMesh mesh, int index, vm.Matrix4 partLocal) {
    _scratch.setFrom(_base);
    _scratch.multiply(partLocal);
    mesh.setInstanceTransform(index, _scratch);
  }

  /// Moves [node] to (x, y, z) without allocating.
  ///
  /// Assigning `localTransform` would store a new matrix and mark the node
  /// dirty for us; mutating in place skips the allocation but leaves the
  /// cached world transform stale, hence the explicit `markTransformDirty()`.
  static void _place(Node node, double x, double y, double z) {
    final vm.Matrix4 m = node.localTransform;
    m.setIdentity();
    m.setTranslationRaw(x, y, z);
    node.markTransformDirty();
  }

  /// Parks a pooled node out of sight. Despawning never removes a node from
  /// the scene (see the pooling contract in CLAUDE.md) — it hides it here.
  static void _park(Node node) => _place(node, 0, -1000, 0);

  @override
  void paint(Canvas canvas, Size size) {
    final double scroll = state._scrollZ;
    final double t = state._elapsed;

    // The endless-scroll illusion: a node's fixed phase offset is mapped into
    // the visible span [zFar, zFar + totalLen). Nothing actually travels the
    // length of the world, and the camera never moves forward.
    double wrapZ(double phase) => gm.wrapZ(
        phase, scroll, _GamePageState.zFar, _GamePageState.totalLen);

    // ---- road surface (instanced) -----------------------------------------
    // Tiles alternate two asphalt tones, so they are two instanced sets rather
    // than one: per-instance colour is not a thing, only per-instance
    // transform. Set A holds the even tiles, set B the odd ones.
    for (int pass = 0; pass < 2; pass++) {
      final InstancedMesh? tiles = pass == 0 ? state._tilesA : state._tilesB;
      if (tiles == null) continue;
      final int n = tiles.instanceCount;
      for (int j = 0; j < n; j++) {
        final int tileIndex = j * 2 + pass;
        _scratch.setIdentity();
        _scratch.setTranslationRaw(0, _GamePageState.roadTopY - 0.1,
            wrapZ(tileIndex * _GamePageState.segLen));
        tiles.setInstanceTransform(j, _scratch);
      }
    }

    // Lane dividers: [0, n) is the left line, [n, 2n) the right.
    final InstancedMesh? dashes = state._dashes;
    if (dashes != null) {
      const int nDash = _GamePageState.dashCount;
      for (int i = 0; i < nDash * 2; i++) {
        final double side = i < nDash ? -1.0 : 1.0;
        _scratch.setIdentity();
        _scratch.setTranslationRaw(
            side * _GamePageState.laneWidth / 2,
            _GamePageState.roadTopY + 0.02,
            wrapZ((i % nDash) * _GamePageState.dashSpacing));
        dashes.setInstanceTransform(i, _scratch);
      }
    }

    // ---- roadside trees (instanced, composed per part) --------------------
    // `_base` is the tree's own world transform (position × uniform scale) and
    // every part is `_base * partLocal` — the composition the old
    // root -> body(scale) -> parts node tree used to do for us. All 18 trees
    // are always on screen, so this was the largest fixed draw-call cost.
    final InstancedMesh? trunks = state._treeTrunks;
    for (final _Tree tr in state._trees) {
      _base.setIdentity();
      _base.setTranslationRaw(tr.x, _GamePageState.roadTopY, wrapZ(tr.phaseZ));
      _base.scaleByDouble(tr.scale, tr.scale, tr.scale, 1.0);

      if (trunks != null) _compose(trunks, tr.trunkSlot, _kTrunk);

      final _TreeFoliage f = tr.foliage;
      if (tr.pine) {
        for (int t = 0; t < f.pineTiers.length; t++) {
          _compose(f.pineTiers[t], tr.slot, _kPineTiers[t]);
        }
      } else {
        // Blob radii are [0.64, 0.42, 0.40] and the 0.42 mesh holds two blobs
        // per tree, so its slots are 2*slot and 2*slot + 1.
        _compose(f.roundBlobs[0], tr.slot, _kCrown);
        _compose(f.roundBlobs[1], tr.slot * 2, _kBlobA);
        _compose(f.roundBlobs[1], tr.slot * 2 + 1, _kBlobB);
        _compose(f.roundBlobs[2], tr.slot, _kBlobTop);
      }
    }

    // Houses are instanced per part, so each part's instance transform is
    // `houseWorld * partLocal` — the composition the old root/body/parts node
    // tree used to do for us. The roof lives in a per-colour mesh at a
    // different slot, hence `_houseRoofSlot`.
    final InstancedMesh? hWalls = state._houseWalls;
    if (hWalls != null) {
      final List<vm.Vector4> data = state._houseData;
      for (int h = 0; h < data.length; h++) {
        final vm.Vector4 d = data[h];
        _base.setIdentity();
        _base.setTranslationRaw(d.x, _GamePageState.roadTopY, wrapZ(d.y));
        _base.scaleByDouble(d.z, d.z, d.z, 1.0);
        _compose(hWalls, h, _GamePageState.kHouseWall);
        _compose(state._houseDoors!, h, _GamePageState.kHouseDoor);
        _compose(state._houseWindows!, h, _GamePageState.kHouseWindow);
        _compose(state._houseRoofs[d.w.toInt()], state._houseRoofSlot[h],
            _GamePageState.kHouseRoof);
      }
    }

    // ---- scattered scenery (instanced, data-driven) -----------------------
    // Each set is one draw call regardless of count (hardware instancing — see
    // CLAUDE.md). Data layout is (x, phaseZ, scale) for Vector3 sets and
    // (x, phaseZ, scale, yaw) for the grass.
    _scatteredPass(state._rocks, state._rockData, _GamePageState.roadTopY - 0.15,
        wrapZ);
    _scatteredPass(
        state._bushes, state._bushData, _GamePageState.roadTopY, wrapZ);
    _scatteredPass(state._flowersA, state._flowerAData,
        _GamePageState.roadTopY + 0.05, wrapZ);
    _scatteredPass(state._flowersB, state._flowerBData,
        _GamePageState.roadTopY + 0.05, wrapZ);

    _grassPass(state._grassA, state._grassAData, _GamePageState.roadTopY + 0.1,
        wrapZ);
    _grassPass(state._grassB, state._grassBData, _GamePageState.roadTopY + 0.08,
        wrapZ);
    _grassPass(state._grassC, state._grassCData, _GamePageState.roadTopY + 0.12,
        wrapZ);

    // ---- evenly-spaced scenery (instanced, index-derived) -----------------
    // No scatter data at all: side and z fall out of the instance index.
    // [0, n) is the left shoulder, [n, 2n) the right.
    final InstancedMesh? rails = state._rails;
    if (rails != null) {
      const int nRail = _GamePageState.railCount;
      for (int i = 0; i < nRail * 2; i++) {
        final double side = i < nRail ? -1.0 : 1.0;
        _scratch.setIdentity();
        _scratch.setTranslationRaw(side * _GamePageState.railX,
            _GamePageState.railY, wrapZ((i % nRail) * _GamePageState.railSpacing));
        rails.setInstanceTransform(i, _scratch);
      }
    }
    final InstancedMesh? railPosts = state._railPosts;
    if (railPosts != null) {
      const int nPost = _GamePageState.railPostCount;
      for (int i = 0; i < nPost * 2; i++) {
        final double side = i < nPost ? -1.0 : 1.0;
        _scratch.setIdentity();
        _scratch.setTranslationRaw(
            side * _GamePageState.railX,
            _GamePageState.roadTopY + 0.33,
            wrapZ((i % nPost) * _GamePageState.railSpacing * 2));
        railPosts.setInstanceTransform(i, _scratch);
      }
    }
    final InstancedMesh? poles = state._signPoles;
    final InstancedMesh? boards = state._signBoards;
    if (poles != null && boards != null) {
      const int nSign = _GamePageState.signCount;
      for (int i = 0; i < nSign * 2; i++) {
        final double side = i < nSign ? -1.0 : 1.0;
        // The right side is offset half a spacing so the two sides interleave
        // instead of arriving in pairs.
        final double z = wrapZ((i % nSign) * _GamePageState.signSpacing +
            (side > 0 ? _GamePageState.signSpacing / 2 : 0.0));
        final double x = side * _GamePageState.signX;
        _scratch.setIdentity();
        _scratch.setTranslationRaw(x, _GamePageState.roadTopY + 1.0, z);
        poles.setInstanceTransform(i, _scratch);
        _scratch.setIdentity();
        _scratch.setTranslationRaw(x, _GamePageState.roadTopY + 1.75, z + 0.05);
        boards.setInstanceTransform(i, _scratch);
      }
    }

    // ---- pooled gameplay objects ------------------------------------------
    for (final _Ramp r in state._ramps) {
      if (r.active) {
        _place(r.node, _GamePageState._laneX(r.lane), _GamePageState.roadTopY,
            r.z);
      } else {
        _park(r.node);
      }
    }

    for (final _Obstacle o in state._obstacles) {
      if (o.active) {
        // Composite obstacles are built base-at-origin, so they sit on the
        // road surface (roadTopY); collision still uses obstacleCenterY.
        _place(o.node, _GamePageState._laneX(o.lane), _GamePageState.roadTopY,
            o.z);
      } else {
        _park(o.node);
      }
    }

    // Coins are instanced, so an inactive one cannot be parked at y = -1000
    // the way a pooled Node is: the set's aggregate bounds would stretch a
    // thousand units and the whole batch would stop frustum-culling. A zero
    // scale collapses it to degenerate triangles instead — nothing rasterises
    // and the bounds stay tight.
    final InstancedMesh? coinMesh = state._coinMesh;
    if (coinMesh != null) {
      for (int i = 0; i < state._coins.length; i++) {
        final _Coin c = state._coins[i];
        _scratch.setIdentity();
        if (c.active) {
          // c.y, not the coinY const — an arc gives every coin its own height.
          _scratch.setTranslationRaw(c.cx, c.y, c.z);
          _scratch.rotateY(t * 4.0);
          // Applied last, so it runs first: stands the cylinder on edge (its
          // Y axis becomes world Z) before the spin about world Y flashes it.
          _scratch.rotateX(math.pi / 2);
        } else {
          _scratch.scaleByDouble(0.0, 0.0, 0.0, 1.0);
        }
        coinMesh.setInstanceTransform(i, _scratch);
      }
    }

    for (final _PowerUp p in state._powerups) {
      if (p.active) {
        final vm.Matrix4 m = p.node.localTransform;
        m.setIdentity();
        m.setTranslationRaw(
            _GamePageState._laneX(p.lane), _GamePageState.powerY, p.z);
        m.rotateY(t * 2.5);
        p.node.markTransformDirty();
      } else {
        _park(p.node);
      }
    }

    // ---- the runner --------------------------------------------------------
    final double lateralV = state._runnerX - state._prevRunnerX;
    final Node? dash = state._dash;
    if (dash != null) {
      // Dash is loaded: feet on the road, facing forward, with a small yaw
      // lean toward the lane it's entering. The Run clip supplies the bob.
      final double turn = (lateralV * _GamePageState.dashTurnGain)
          .clamp(-_GamePageState.dashTurnMax, _GamePageState.dashTurnMax);
      final vm.Matrix4 dm = dash.localTransform;
      dm.setIdentity();
      dm.setTranslationRaw(
        state._runnerX,
        _GamePageState.dashFootY + state._jumpY,
        _GamePageState.runnerZ,
      );
      dm.rotateY(_GamePageState.dashYaw + turn);
      dm.scaleByDouble(_GamePageState.dashScale, _GamePageState.dashScale,
          _GamePageState.dashScale, 1.0);
      dash.markTransformDirty();
      _park(state._runner); // hide the placeholder cube
    } else {
      // Placeholder cube until the model finishes importing.
      final double lean = (lateralV * 6.0).clamp(-0.35, 0.35);
      final double idleBob = state._grounded ? math.sin(t * 3.0) * 0.06 : 0.0;
      final vm.Matrix4 rt = state._runner.localTransform;
      rt.setIdentity();
      rt.setTranslationRaw(
        state._runnerX,
        _GamePageState.groundY + state._jumpY + idleBob,
        _GamePageState.runnerZ,
      );
      rt.rotateZ(-lean);
      rt.rotateY(t * 0.6);
      state._runner.markTransformDirty();
    }

    // Particles are instanced per colour. Inactive ones collapse to a zero
    // scale for the same reason coins do — parking far away would wreck the
    // set's bounds and disable frustum culling for the whole batch.
    for (final _ParticlePool pool in state._particlePools) {
      for (int i = 0; i < pool.parts.length; i++) {
        final _Particle p = pool.parts[i];
        _scratch.setIdentity();
        if (p.active) {
          final double s = (p.life / p.maxLife).clamp(0.0, 1.0);
          final double sc = 0.25 + 0.75 * s;
          _scratch.setTranslationRaw(p.pos.x, p.pos.y, p.pos.z);
          _scratch.rotateY(t * 6.0);
          _scratch.scaleByDouble(sc, sc, sc, 1.0);
        } else {
          _scratch.scaleByDouble(0.0, 0.0, 0.0, 1.0);
        }
        pool.mesh.setInstanceTransform(i, _scratch);
      }
    }

    // ---- camera ------------------------------------------------------------
    double shx = 0;
    double shy = 0;
    if (state._shakeT > 0) {
      final double amp = 0.4 * (state._shakeT / _GamePageState.shakeDuration);
      shx = math.sin(t * 80.0) * amp;
      shy = math.cos(t * 67.0) * amp;
    }

    final double camX = state._runnerX * 0.35;
    final PerspectiveCamera camera = PerspectiveCamera(
      position: vm.Vector3(
          camX + shx, _GamePageState.camY + shy, _GamePageState.camZ),
      target: vm.Vector3(state._runnerX * 0.5, _GamePageState.camTargetY,
          _GamePageState.camTargetZ),
    );

    // Cached for `_spawnPopup`, which projects a world point to screen space
    // with the camera the frame was actually drawn from.
    state._lastCamera = camera;
    state._lastViewport = size;
    state._scene.render(camera, canvas, viewport: Offset.zero & size);
  }

  /// Scrolls one scattered set whose per-instance data is (x, phaseZ, scale).
  /// How many of [n] instances this quality preset draws. The remainder are
  /// collapsed to a zero scale rather than skipped — an instance left at a
  /// stale transform would just keep drawing where it was.
  int _densityCut(int n) =>
      (n * _GamePageState.qualityDensity[state._quality]).round();

  void _scatteredPass(InstancedMesh? mesh, List<vm.Vector3> data, double y,
      double Function(double) wrapZ) {
    if (mesh == null) return;
    final int drawn = _densityCut(data.length);
    for (int i = 0; i < data.length; i++) {
      _scratch.setIdentity();
      if (i < drawn) {
        final vm.Vector3 d = data[i];
        _scratch.setTranslationRaw(d.x, y, wrapZ(d.y));
        _scratch.scaleByDouble(d.z, d.z, d.z, 1.0);
      } else {
        _scratch.scaleByDouble(0.0, 0.0, 0.0, 1.0);
      }
      mesh.setInstanceTransform(i, _scratch);
    }
  }

  /// Scrolls one grass set. Same as [_scatteredPass] plus a per-blade yaw, so
  /// the 3-sided blades do not all face the same way.
  void _grassPass(InstancedMesh? mesh, List<vm.Vector4> data, double y,
      double Function(double) wrapZ) {
    if (mesh == null) return;
    final int drawn = _densityCut(data.length);
    for (int i = 0; i < data.length; i++) {
      _scratch.setIdentity();
      if (i < drawn) {
        final vm.Vector4 d = data[i];
        _scratch.setTranslationRaw(d.x, y, wrapZ(d.y));
        _scratch.rotateY(d.w);
        _scratch.scaleByDouble(d.z, d.z, d.z, 1.0);
      } else {
        _scratch.scaleByDouble(0.0, 0.0, 0.0, 1.0);
      }
      mesh.setInstanceTransform(i, _scratch);
    }
  }

  /// Repaints are driven by the `_repaint` notifier passed to
  /// `CustomPainter(repaint:)`, so this correctly stays `false`. Returning
  /// `true` would repaint twice per frame.
  @override
  bool shouldRepaint(covariant _GamePainter oldDelegate) => false;
}

/// Soft drifting clouds for the sky layer.
///
/// Deliberately a Flutter painter rather than scene geometry: the scene's
/// distance fog ends at `fogEndDay` and resolves to `cSkyBot`, so a cloud
/// placed far enough away to read as sky would be fully fogged out. Drawn
/// between the sky gradient and the 3D layer in `build()`.
class _CloudPainter extends CustomPainter {
  _CloudPainter(this.t);

  final double t;

  static const int _count = 6;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint p = Paint()
      ..color = Colors.white.withValues(alpha: 0.72)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14);
    for (int i = 0; i < _count; i++) {
      final double w = size.width * (0.17 + (i % 3) * 0.06);
      final double speed = 5.0 + (i % 4) * 2.5;
      // Wrap over 1.3 screens so a cloud fully leaves before it re-enters.
      final double x =
          ((i * 0.23 + t * speed / 1000.0) % 1.3 - 0.15) * size.width;
      final double y = size.height * (0.07 + (i % 3) * 0.075);
      canvas.drawOval(
          Rect.fromCenter(center: Offset(x, y), width: w, height: w * 0.33), p);
      canvas.drawOval(
          Rect.fromCenter(
              center: Offset(x + w * 0.2, y - w * 0.08),
              width: w * 0.58,
              height: w * 0.3),
          p);
    }
  }

  @override
  bool shouldRepaint(covariant _CloudPainter oldDelegate) => oldDelegate.t != t;
}
