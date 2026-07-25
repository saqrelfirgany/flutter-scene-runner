# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A 3D endless runner written directly against [`flutter_scene`](https://pub.dev/packages/flutter_scene) (Flutter GPU / Impeller) — no game engine. It is a build-in-public project; the entire game lives in `lib/main.dart`.

## Commands

**Always prefix with `fvm`.** `.fvmrc` pins the Flutter **master** channel, and `flutter_scene` 0.19.0 hard-requires master because Flutter GPU only exists there. A bare `flutter` may resolve to a stable install and fail at pub-get or build time.

```bash
fvm flutter run -d macos      # macos/ is the ONLY configured platform
fvm flutter analyze
fvm flutter build macos
```

There are no `ios/`, `android/`, `web/`, `linux/`, or `windows/` directories — adding a run target requires `fvm flutter create --platforms=<p> .` first.

### Flutter GPU must be enabled per platform

Flutter GPU is opt-in. `macos/Runner/Info.plist` carries `FLTEnableFlutterGPU = true`; without it, `Scene.initializeStaticResources()` (`lib/main.dart:12`) throws `Failed to initialize ShaderLibrary` at startup even though Impeller is active. **Any new platform needs its own opt-in** — the same key in the iOS `Info.plist`, or `io.flutter.embedding.android.EnableFlutterGPU` metadata in `AndroidManifest.xml`. The CLI equivalent is `--enable-flutter-gpu`, but don't rely on it: IDE run configs live in gitignored `.idea/` and `flutter build` wouldn't get it.

### There are no tests, and widget tests are not possible as written

There is no `test/` directory. `fvm flutter analyze` should report **no issues**; treat anything else as your own regression.

Don't try to add a `flutter_test` widget test for the game: `lib/main.dart:82` declares `final Scene _scene = Scene();` as a *field initializer*, so it runs during `createState()` the instant `GamePage` mounts, and `Scene()` needs a GPU context. `flutter_test` is headless with no Impeller, so pumping `RunnerApp` throws `Flutter GPU requires the Impeller rendering backend` before any assertion runs.

Two viable routes if coverage is wanted:

- **Unit tests** — first extract the pure math (lane mapping, AABB overlap, jump integration, speed ramp, `wrapZ`, `_linearFromHex`) out of `_GamePageState` into a file that doesn't import `flutter_scene`. That code is currently private and GPU-entangled, so it isn't reachable from a test as-is.
- **`integration_test/`** — runs on a real macOS window with Impeller, so the full game mounts. Requires adding the `integration_test` dev dependency and a device/CI runner.

## Architecture

Everything is `lib/main.dart`. The important structure is a **simulation/render split** that looks wrong at a glance but is intentional:

- **`_GamePageState._update(dt)`** — driven by a `Ticker`, owns *all* gameplay state (`_scrollZ`, `_lane`, `_jumpY`, spawn timers, collision, score). It never touches scene nodes.
- **`_GamePainter.paint()`** — owns *all* `node.localTransform` writes, plus the per-frame `PerspectiveCamera` construction and the final `_scene.render(camera, canvas, viewport: ...)`.
- Repaints are driven by the `_repaint` `ValueNotifier` passed to `CustomPainter(repaint:)`; `shouldRepaint` correctly returns `false`. Do not "fix" `shouldRepaint`, and do not hoist transform writes into `_update` — either change breaks rendering.

### Node pooling contract

Every node — road tiles, lane dashes, side posts, obstacles, coins, the runner — is allocated once in `_buildWorld()` and added to the `Scene` permanently. Nothing is added to or removed from `_scene` at runtime.

- Spawning = finding an inactive pool entry and flipping `active = true`.
- Despawning = `active = false`; `paint()` parks inactive nodes at `y = -1000` to hide them.

**To add a new visual element you always edit two places:** create the node + `_scene.add(...)` in `_buildWorld()`, then position it in `_GamePainter.paint()`.

### Coordinate and math conventions

- **The world wraps; the camera does not travel.** `wrapZ(phase)` maps a node's fixed phase offset through `zFar + ((phase + _scrollZ) % totalLen)` to produce the endless-scroll illusion. Camera stays near z ≈ 9 and only pans slightly with `_runnerX`.
- **Negative z is far, positive z is near.** Objects spawn at `spawnZ = -58` and are recycled past `despawnZ = 8`.
- **`_laneX(lane) = -lane * laneWidth`** — the sign is inverted relative to intuition. Use the helper; never compute lane x inline.
- `_linearFromHex()` converts sRGB `0xAARRGGBB` to linear space (pow 2.2) and is **required** for any `material.baseColorFactor`. Passing a raw hex-derived value gives visibly wrong colors.
- Frame-rate independence: `dt` is clamped to `0.05` to absorb hitches, and lane smoothing uses `1 - exp(-laneLerp * dt)` rather than a raw lerp factor.

All tuning lives in the `static const` block at the top of `_GamePageState`, grouped by concern (world / movement / obstacles / coins). Change gameplay feel there, not inline.

## Repo notes

- `assets/` holds README media (gif/png/mp4) only. It is **not** declared under `flutter: assets:` in `pubspec.yaml`, so nothing there is bundled at runtime.
- `flutter_scene` builds through Dart Native Assets hooks (`.dart_tool/hooks_runner/`). A build break right after a Flutter upgrade usually means the master pin drifted, not that app code is wrong.
- The README's "Status — Day 2" checklist lags the code: collision, coins, score/HUD, speed ramp, and the crash/restart state are already implemented. Trust `lib/main.dart` over the README.

## Commit conventions — conflict to be aware of

This repo's history uses build-in-public journal subjects (`Day 1: …`, `Day 2A: player control — …`), but the global `~/.claude/CLAUDE.md` mandates Conventional Commits (`<type>(<scope>): <subject>`) and a PreToolUse hook **blocks** non-compliant `git commit` / `gh pr create` / `git checkout -b`. Ask the user which style they want here rather than guessing; matching the local history will be rejected by the hook.
