# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A 3D endless runner written directly against [`flutter_scene`](https://pub.dev/packages/flutter_scene) (Flutter GPU / Impeller) — no game engine. It is a build-in-public project, **live at https://saqrelfirgany.github.io/flutter-scene-runner/**.

> **Read `docs/VISION.md` before doing visual work.** It holds the look-and-feel
> target (a bright low-poly daylight world, à la DashSurfers), the art-direction
> rules to get there, the current state, and the roadmap. Target screenshots are
> in `docs/target-reference/` (gitignored, local reference only).

The game is **one Dart library split across four files**, joined with `part` / `part of` so library-private access still works across the sim/render split:

- `lib/main.dart` — entry point (`main`, `RunnerApp`, `GamePage`) + `part` directives + all package imports (parts inherit them).
- `lib/game_state.dart` — `_GamePageState`: gameplay logic, spawns, collision, power-ups, audio, and the Flutter UI.
- `lib/game_painter.dart` — `_GamePainter`: per-frame node transforms + camera + `scene.render()`.
- `lib/models.dart` — entities (`_Obstacle`/`_Coin`/`_PowerUp`/`_Ramp`/`_Score`/`_Particle`), the `_Audio` SFX wrapper, and the `_linearFromHex`/`_glowFromHex` aliases.

Plus one file that is **not** part of that library:

- `lib/game_math.dart` — a standalone, GPU-free library of pure gameplay math, imported by `main.dart` as `gm`. It exists so the arithmetic is unit-testable (the game widget is not — see below). Prefixed on import because names like `wrapZ` also exist as painter locals and a silent shadow would be hard to spot.

The character is the Flutter mascot **Dash**, imported from `assets/models/dash.glb` at runtime via `Node.fromGlbAsset` with blended Idle/Run/Jump clips. Extras layered on: post-FX (`_setupSceneLook`: sun + shadows + fog + bloom + colour grade), power-ups (magnet/shield/×2), SFX via `audioplayers` with a persisted 3-step volume, and score sharing via `Clipboard`.

**Current look = bright daylight world** (a visual overhaul on top of the original neon build). What's in it and what's still open is tracked in `docs/VISION.md §3–4`. Newer patterns beyond the four-file basics:

- **Instanced scenery** — rocks, bushes, flowers, and tall grass are each a single `InstancedMesh` seeded in `_buildWorld()` and moved per-frame with `setInstanceTransform(i, matrix)` in the painter. Reuse this pattern for anything that repeats. Per-instance data is kept in `List<Vector3>`/`List<Vector4>` (x, phaseZ, scale[, yaw]). The registration idiom is `_scene.add(Node()..addComponent(InstancedMeshComponent(mesh)))` plus one `mesh.addInstance(Matrix4.identity())` per instance at build time — the count is fixed there and never grows at runtime.
- **Instancing here is real hardware instancing — do not trust the `InstancedMesh` docstring.** That comment says *"The naive backend still issues one draw call per instance"*; the code around it disagrees, and the code wins. `UnskinnedGeometry` — which every primitive inherits (`CuboidGeometry` → `MeshGeometry` → `UnskinnedGeometry`) — returns a **non-null** `instancedVertexLayout`, so `scene_encoder.dart:443` takes the packed branch and issues `geometry.draw(pass, instanceCount: …)` for the whole set: **1 draw call per `InstancedMesh`, or 2 if some instances are mirrored** (negative determinant flips winding, which splits the batch). The ~1,240 scenery instances therefore cost roughly **14 draw calls, not 1,240**. Instance *count* is cheap on the draw-call axis; it costs vertex/fragment work and CPU packing, nothing more.
- **The draw-call load is the individually-`Node`d meshes, not the instanced scenery.** Every `Node` carrying a `Mesh` is its own draw call, and composite props multiply: a tree is 4 meshes, a house 4, a barrier 8, a container 8. Road tiles and lane dashes were 54 of these and are now instanced (3 draw calls). What remains: trees (72) + obstacles (~72) + houses (40) + coins (36) + particles (48) ≈ **~270 draw calls** against ~17 for every instanced set combined. When draw calls need to come down, that list is where to look. The three still worth converting, and why they weren't:
  - **coins** (36 → 1) — mechanical and safe; the only reason it is still open is that it touches gameplay code (`_Coin.node` disappears and the painter keys off the pool index).
  - **particles** (48 → 1) — blocked: each particle recolours its own material per burst, and instancing shares one material across the batch.
  - **trees / houses / obstacles** (~184 → ~25) — blocked for the same reason: per-prop colour variety. Would need one `InstancedMesh` per (part, colour) pair.
- **Two ways to place instances.** Scattered scenery (rocks/bushes/flowers/grass) stores per-instance data in a parallel list. Evenly-spaced scenery (guardrails, sign posts) stores **nothing** — the painter derives side and z from the instance index, with `[0, n)` the left side and `[n, 2n)` the right. Prefer the index form whenever the spacing is uniform; it is less state to keep in sync.
- **Composite obstacles** — `_giftBox` / `_barrier` / `_container` build multi-mesh `Node` trees (base at origin); the pool holds a fixed mix. Collision stays a uniform AABB (`obHalf*`), so the varied shapes read fairly. The painter places them on `roadTopY`.
- **Score popups** — `_Popup` (screen-space) projected from a 3D point via `Camera.worldToScreen(vec, size)`; the painter caches `_lastCamera`/`_lastViewport`, and `_popupLayer()` renders a rising/fading Flutter overlay.
- **Lighting is the main "quality" lever** — soft key light + high `environmentIntensity` = the modern soft-shadow look. Tune in `_setupSceneLook()` / the `sunIntensity`,`envIntensity` consts, not by adding geometry.
- **The sky is a Flutter widget, not 3D** — a `LinearGradient` `DecoratedBox` sits *behind* the `CustomPaint` in `build()`'s `Stack`, running `cSkyTop` → `cSkyBot`, with `_CloudPainter` layered between the two. So: restyle the sky in the widget tree, not the scene. Clouds in particular **cannot** be geometry — fog resolves everything past `fogEndDay` to `cSkyBot`, so a cloud far enough away to read as sky would be fogged out of existence. And **`cSkyBot` and `cFogDay` are deliberately the same value** (`0xFFCDEBFF`) — that identity is what makes the fogged far road melt into the horizon. Change one without the other and a seam appears.
- **Distant hills are the one exception** — big static ellipsoids parked *inside* `fogEndDay` so they arrive pre-hazed. Their x is kept far clear of their own half-width, or a "distant" hill straddles the road.

## Commands

**Always prefix with `fvm`.** `.fvmrc` pins the Flutter **master** channel, and `flutter_scene` 0.19.0 hard-requires master because Flutter GPU only exists there. A bare `flutter` may resolve to a stable install and fail at pub-get or build time.

```bash
# one-time per machine (the README's documented setup) — flutter_scene ships
# its shader bundle as native + data assets, and both toggles are off by default
fvm flutter config --enable-native-assets --enable-dart-data-assets
fvm flutter pub get

fvm flutter run -d macos --enable-flutter-gpu --enable-impeller   # native (Metal)
fvm flutter run -d chrome                                         # web (WebGL2, no flags)
fvm flutter analyze                                               # NOT clean — see the baseline below
fvm flutter test                                                  # 21 tests over lib/game_math.dart
fvm flutter test test/game_math_test.dart                         # just that file
fvm flutter build web --release --base-href /flutter-scene-runner/  # gh-pages build
```

Only `macos/` and `web/` are configured. Adding another run target requires `fvm flutter create --platforms=<p> .` first (and its own Flutter GPU opt-in — see below).

**Deploy:** `build/web` is published to the `gh-pages` branch (fresh `git init` in `build/web`, then force-push). GitHub Pages serves it at the live URL above.

### Flutter GPU must be enabled per platform

Flutter GPU is opt-in. `macos/Runner/Info.plist` carries `FLTEnableFlutterGPU = true`; without it, `Scene.initializeStaticResources()` (`lib/main.dart:12`) throws `Failed to initialize ShaderLibrary` at startup even though Impeller is active. **Any new platform needs its own opt-in** — the same key in the iOS `Info.plist`, or `io.flutter.embedding.android.EnableFlutterGPU` metadata in `AndroidManifest.xml`. The CLI equivalent is `--enable-flutter-gpu`, but don't rely on it: IDE run configs live in gitignored `.idea/` and `flutter build` wouldn't get it.

### The analyzer is not clean — diff against the baseline

`fvm flutter analyze` reports **14 issues and exits `1`**, so it is not usable as a pass/fail gate. Compare against this baseline instead. As of 2026-07-29, by category:

- **11 × `unused_field`** — ten neon-era `static const`s (`coinGlow`, `postGlow`, `obstacleGlow`, `bloom*`, `vignetteIntensity`, `fog{Hex,Start,End}`) that are **kept deliberately** for a future "night" theme (see the comment above the daylight block in `game_state.dart`), plus `cHedge` — a daylight-era leftover, orphaned when the roadside posts became `_tree()` calls. Don't delete any of them to silence the analyzer without asking first.
- **2 × `unnecessary_underscores`** (`__` in two `ValueListenableBuilder`s), **1 × `unnecessary_import`** (`foundation.dart` in `main.dart`).

There are **no `deprecated_member_use` warnings any more** — the nine `Matrix4.scale` calls were replaced by `scaleByDouble` when the painter was rewritten for zero-allocation. New code should use `scaleByDouble`/`scaleByVector3`; re-introducing `scale` would move this baseline back up.

The exact count moves whenever the Flutter master pin bumps, so re-run analyze to re-establish the baseline before assuming a new issue is yours.

### Tests: the pure math is covered, the game itself cannot be

`fvm flutter test` runs **21 real tests** over `lib/game_math.dart`. That file is a standalone library — **not** a `part` of the game — holding every piece of gameplay arithmetic that needs no GPU: `laneX`, `wrapZ`, `smoothing`, `overlaps1D`, `speedAt`, `clampDt`, `linearFromHex`, `glowFromHex`, `ordinal`. The game calls straight into it (`_laneX`, `_curSpeed`, `_linearFromHex` etc. are thin aliases), so the tests cover shipping code rather than a copy.

**When you add gameplay math, put it there and add a case to `test/game_math_test.dart`.** Two things to know before writing one:

- `vector_math`'s `Vector4` stores **float32**, so comparing a component against a Dart `double` needs a ~`1e-6` tolerance. `1e-9` can never pass, however correct the function is.
- Don't try to add a `flutter_test` **widget** test for the game. `_GamePageState` declares `final Scene _scene = Scene();` as a *field initializer*, so it runs during `createState()` the instant `GamePage` mounts, and `Scene()` needs a GPU context. `flutter_test` is headless with no Impeller, so pumping `RunnerApp` throws `Flutter GPU requires the Impeller rendering backend` before any assertion runs.

For coverage of the rendered game, the only route is **`integration_test/`** — a real macOS window with Impeller, so the full game mounts. Requires the `integration_test` dev dependency and a device/CI runner; not set up.

## Architecture

The important structure is a **simulation/render split** — `_GamePageState` (`game_state.dart`) and `_GamePainter` (`game_painter.dart`) are separate files but one library (via `part`), so `_GamePainter` reads `_GamePageState`'s private fields directly. It looks wrong at a glance but is intentional:

- **`_GamePageState._update(dt)`** — driven by a `Ticker`, owns *all* gameplay state (`_scrollZ`, `_lane`, `_jumpY`, spawn timers, collision, score). It never touches scene nodes.
- **`_GamePainter.paint()`** — owns *all* `node.localTransform` writes, plus the per-frame `PerspectiveCamera` construction and the final `_scene.render(camera, canvas, viewport: ...)`.
- Repaints are driven by the `_repaint` `ValueNotifier` passed to `CustomPainter(repaint:)`; `shouldRepaint` correctly returns `false`. Do not "fix" `shouldRepaint`, and do not hoist transform writes into `_update` — either change breaks rendering.
- **The per-frame UI rides that same notifier.** `_hud()` and `_popupLayer()` wrap themselves in a `ValueListenableBuilder` on `_repaint`, so score, power-up chips, and `+N` popups refresh every frame *without* `setState`. `setState` is reserved for phase transitions (`_startGame` / `_goMenu` / `_crash` / name entry) and loaded prefs. Never put `setState` on the tick path.

### Node pooling contract

Every node — road tiles, lane dashes, side posts, obstacles, coins, the runner — is allocated once in `_buildWorld()` and added to the `Scene` permanently. Nothing is added to or removed from `_scene` at runtime.

- Spawning = finding an inactive pool entry and flipping `active = true`.
- Despawning = `active = false`; `paint()` parks inactive nodes at `y = -1000` to hide them.

**To add a new visual element you always edit two places:** create the node + `_scene.add(...)` in `_buildWorld()`, then position it in `_GamePainter.paint()`.

Two things sit outside that rule:

- **Static ground** — the two grass slabs and the road bed never scroll, so `_buildWorld()` sets their `localTransform` once and `paint()` ignores them entirely. Anything that doesn't move belongs in that group.
- **Instanced scenery** — the wrapper `Node` around an `InstancedMesh` is never transformed; the painter writes per-instance matrices instead.

Obstacle **shape** is likewise fixed at build time, not at spawn: `_buildWorld()` hands each of the 10 pool slots a kind via `i % 3` (gift box / barrier / container). `_spawnObstacle()` only picks lanes. Adding a new shape means changing that mix, not the spawn code.

**Jump ramps (`_Ramp`) are pooled the same way but are deliberately *additive only*** — overlapping one while grounded replaces the normal jump with a stronger launch, and that is all. A ramp never blocks and never crashes the runner. Keep it that way: it is what makes `rampImpulse` safe to tune without re-balancing the whole run.

### Coordinate and math conventions

- **The world wraps; the camera does not travel.** `wrapZ(phase)` maps a node's fixed phase offset through `zFar + ((phase + _scrollZ) % totalLen)` to produce the endless-scroll illusion. Camera stays near z ≈ 9 and only pans slightly with `_runnerX`.
- **Negative z is far, positive z is near.** Objects spawn at `spawnZ = -58` and are recycled past `despawnZ = 8`.
- **`_laneX(lane) = -lane * laneWidth`** — the sign is inverted relative to intuition. Use the helper; never compute lane x inline.
- `_linearFromHex()` converts sRGB `0xAARRGGBB` to linear space (pow 2.2) and is **required** for any `material.baseColorFactor`. Passing a raw hex-derived value gives visibly wrong colors.
- Frame-rate independence: `dt` is clamped to `0.05` to absorb hitches, and lane smoothing uses `1 - exp(-laneLerp * dt)` rather than a raw lerp factor.

All tuning lives in the `static const` block at the top of `_GamePageState` (`game_state.dart`), grouped by concern (world / character / camera / movement / obstacles / coins / palette / juice / neon look / daylight world / road markings + shoulder / hills / guardrails / sign posts / ramps / obstacle variety / power-ups). Change gameplay feel and colour there, not inline.

**Know which look knobs are live.** That block holds two generations of them. The daylight set is wired up: `sunIntensity`, `envIntensity`, `cFogDay`/`fogStartDay`/`fogEndDay`, `cSky*`, `cGrass*`, `decoCount`, `grassCount`, and the `c*` palette. The neon set — `coinGlow`, `postGlow`, `obstacleGlow`, `bloom*`, `vignetteIntensity`, `fog{Hex,Start,End}` — is **read by nothing**; editing those changes nothing on screen. Bloom and colour grading are hardcoded inline inside `_setupSceneLook()`, and there is **no vignette pass at all** despite the const. In practice `dashYaw`, `dashScale`, `sunIntensity`, `envIntensity`, `grassCount`, and `_powerColor` are the knobs actually touched most often. **Framing** has its own four — `camY` / `camZ` / `camTargetY` / `camTargetZ` — and nothing in the simulation reads them, so they are safe to nudge purely by eye.

## Performance model

Read this before changing anything that affects the frame. The costs are not where they look like they are, and two of them were documented wrongly for a while.

**1. Shadows are the multiplier, not the geometry count.** `DirectionalLight` defaults to `shadowCascadeCount = 4` at `shadowMapResolution = 1024`, and every caster is re-rendered into each cascade its bounds touch, *on top of* the colour pass. With hundreds of noded meshes that is the single most expensive thing in the frame. `_setupSceneLook()` overrides the count to **2** (`shadowCascades`) because the camera never moves and `shadowMaxDistance` is only 42 units — four cascades buy nothing over that range. If shadows ever look blocky up close, raise `shadowMapRes` before raising the cascade count.

**2. `shadowStatic` is set on everything that never moves** — the grass slabs, road bed, dirt shoulders, edge lines and hills. The shadow pass then bakes them once instead of re-rendering them every frame. This is only safe because those nodes never change transform, geometry or material after `_buildWorld()`; a static node that *does* change keeps showing a stale shadow, so don't set the flag on anything the painter touches.

**3. `Scene.renderScale` is the content-independent lever.** Three presets in `qualityScales` (1.0 / 0.85 / 0.7) behind the `HIGH · BALANCED · FAST` button, persisted under `quality.v1`. It trades sharpness for fragment work and helps on a device no geometry budget can save — reach for it last, but know it is there.

**4. The painter allocates nothing.** At ~1,600 transforms × 60 Hz, a `Matrix4` per transform would be ~96k allocations a second. Two techniques, and they are **not** interchangeable:
   - Instanced writes share one static scratch matrix, because `setInstanceTransform` copies (`_instances[i].setFrom(m)`).
   - Node writes **must not** — `Node.localTransform`'s setter stores the reference it is given, so a shared scratch would alias every node onto one matrix. Nodes are updated by mutating *their own* matrix in place and calling `markTransformDirty()`, which is exactly what that method is for. `_place()` / `_park()` in the painter are the helpers; use them.

**5. Deliberately not used.** `LodComponent` exists and is a good fit in principle, but it draws a *single* mesh and our trees and houses are composite `Node` trees — it cannot select a level for a subtree, so adopting it means restructuring those props first. `depth_prepass` and `object_filter` are likewise available and untried; a prepass trades an extra pass for less overdraw, which only pays off once measured.

**6. One known cost with no clean fix.** `InstancedMesh.setInstanceTransform` marks bounds dirty, and `InstancedMeshComponent.refreshRenderItem` reads `aggregateBounds` every frame — so every moving instanced set recomputes an O(n) AABB, allocating one `Aabb3` per instance, per frame. Avoiding it would mean not moving instances at all: lay the field out over *two* wrap lengths and scroll the wrapper `Node` instead, resetting it every `totalLen`. That is a real technique and a real redesign; it hasn't been done.

**Measure, don't reason.** The HUD capsule carries a live fps readout. Every claim above came from reading `flutter_scene`'s source at the pinned version, not from the package's own doc comments — which are stale in at least one load-bearing place.

## Repo notes

- `assets/` mixes two things: README media at the root (`hero.gif`/`hero.mp4`/`shot-*.png`, **not** bundled) and two runtime-asset folders that **are** declared under `flutter: assets:` — `assets/models/dash.glb` (loaded via `Node.fromGlbAsset`) and `assets/sfx/*.wav` (played via `audioplayers`). When adding runtime assets, put them in their own folder and declare it; don't declare `assets/` wholesale or the README media ships too.
- SFX (`assets/sfx/*.wav`) are synthesized offline (originally with a numpy script) — original, no licensing. Dash (`dash.glb`) is the Flutter mascot from the `flutter_scene` examples (MIT).
- `flutter_scene` builds through Dart Native Assets hooks (`.dart_tool/hooks_runner/`). A build break right after a Flutter upgrade usually means the master pin drifted, not that app code is wrong.
- **Watch for names both imports export.** `main.dart` imports `flutter/material.dart` *and* `flutter_scene/scene.dart`, so any name they share is ambiguous and won't compile. Two are known to bite:
  - **`Animation`** — write `final anim = node.findAnimationByName(...)` and let it infer; `AnimationClip` is unambiguous and is what the fields use.
  - **`BoxShape`** — `flutter_scene` has a physics `BoxShape`, so `shape: BoxShape.circle` in a `BoxDecoration` fails. Use `borderRadius: BorderRadius.circular(side / 2)` for round chips instead.

  Expect more of these; when a plain Flutter idiom refuses to compile here, suspect the collision before suspecting yourself, and read the package source at the pinned version rather than guessing an API.
- Persistence is `shared_preferences` under two versioned keys: `leaderboard.v1` (a `List<String>` of `"$score|$name"`, top 5) and `volume.v1` (an index into `volumes`). Both loaders swallow errors, so a format change without a key bump degrades silently to an empty board / default volume rather than failing loudly.
- `README.md` is **Arabic-first** (RTL `<div dir="rtl">` blocks around English code and commands). Its media and copy still show the **neon** build and its build-in-public log stops before the daylight overhaul — trust `lib/` and `docs/VISION.md` over the README for current state.

## Commit conventions — conflict to be aware of

This repo's history uses build-in-public journal subjects (`Day 1: …`, `Day 2A: player control — …`), but the global `~/.claude/CLAUDE.md` mandates Conventional Commits (`<type>(<scope>): <subject>`) and a PreToolUse hook **blocks** non-compliant `git commit` / `gh pr create` / `git checkout -b`. Ask the user which style they want here rather than guessing; matching the local history will be rejected by the hook.
