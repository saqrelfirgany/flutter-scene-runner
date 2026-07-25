// Part of the flutter-scene-runner library — see lib/main.dart.
// `part of` keeps the game one library so the sim/render split can use
// library-private access (e.g. _GamePainter reads _GamePageState fields).
part of 'main.dart';

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
