# PERFORMANCE — measurement procedure and running log

Read `CLAUDE.md` § "Performance model" for *why* the frame costs what it costs.
This file is the other half: **how to measure**, and **what every change has
actually measured**, in order, so nobody re-runs an experiment that already has
an answer.

Rule for this file: **one row per change, added when the change is measured,
not when it is written.** A row with no numbers is worse than no row.

---

## 1. The metric: `hit60`, not fps

The headline number is **the share of frames that land under one 60 Hz vsync
interval (17 ms)**. Not the mean, and not the fps readout in the HUD.

The reason is in the shape of the distribution. This game sits *right on* the
frame budget:

```
median = 16.67ms   ← half the frames hit a clean 60 fps
p95    = 50.00ms   ← exactly three vsync intervals
mean   = 26ms      ← "38 fps"
```

A frame that misses 16.67 ms by any margin waits for the next vsync and costs
33.3 ms. So the distribution is **bimodal**, not centred: frames either make it
or they double. The mean sits in a valley where almost no actual frame lands,
and reports "38 fps" for a game that is rendering 70% of its frames at 60.

Two consequences, and they are the whole reason this file exists:

- **Optimising against the mean measures the wrong thing.** Shaving 1 ms off a
  frame that already takes 12 ms changes the mean and changes nothing a player
  sees. Shaving 1 ms off a frame that takes 17.5 ms moves it from 33.3 ms to
  16.67 ms — a 2× improvement for that frame.
- **Small savings are worth far more than they look.** Near a vsync boundary a
  10% cost reduction can convert a large share of the missed frames, so several
  1 ms wins that each measure as "nothing" on the mean can stack into a visible
  jump. The earlier round of experiments (see `CLAUDE.md`) each read "flat"
  against the mean; some of them may not have been.

## 2. How to take a measurement

`lib/game_bench.dart` collects raw frame deltas and prints one summary line per
window. It is compiled out of a normal build — the `const` guard tree-shakes it
away — and turned on with a `--dart-define`.

**Use native macOS, not the browser.** Both Chrome and macOS stop rendering a
window that is not frontmost, and the browser additionally throttles a tab that
is not receiving input. Driving Chrome through automation therefore measures the
throttle, not the game: the fps readout decays 45 → 30 → 20 → 13 while idle and
looks exactly like a progressive leak. It is not one. `flutter run` on macOS
prints straight to the log, which is both reliable and readable without
screenshotting anything.

```bash
fvm flutter run -d macos --release --dart-define=BENCH=true \
  --enable-flutter-gpu --enable-impeller > /tmp/bench.log 2>&1 &

# then, with the app window frontmost:
grep "BENCH win=" /tmp/bench.log | sed 's/flutter: //'
```

```
BENCH win=1 n=195 dropped=0 hit60=71.8% mean=25.73ms/38.9fps median=16.67ms p95=50.00ms
```

- `n` — frames in the window. `dropped` — frames over 300 ms, discarded as
  not-rendering rather than slow.
- **A window with a nonzero `dropped`, or `n` far below ~190, was not
  frontmost. Throw it away.**
- Take **five consecutive clean windows** and compare `hit60`. Run-to-run
  spread is about ±2.5 points, so treat anything under ~3 points as noise.

Measure in the **menu**, not mid-run: the attract mode scrolls the full world
with no spawns and no random content, so two builds are comparing the same
scene. A gameplay measurement varies with whatever happened to spawn.

Web builds can use `--dart-define=BENCH=true` too and the line appears in the
devtools console, but only trust it in a real, focused browser window.

## 3. Baseline

Everything below is compared against this. Native macOS (Apple Silicon),
release, Impeller/Metal, default window size, menu.

| Date | Commit | `hit60` | mean | median | p95 |
|---|---|---|---|---|---|
| 2026-07-31 | `b343ef8` | **70 %** (67.2–72.1) | 26 ms | 16.67 ms | 50 ms |

Roughly **30% of frames miss vsync**. That is the number to move.

## 4. Change log

Append one row per measured change. "Verdict" is keep / revert / inconclusive.

| Date | Change | `hit60` | Δ | Verdict |
|---|---|---|---|---|
| 2026-07-31 | *(baseline — no change)* | 70 % | — | — |

### The device-measured round (2026-07-31)

Everything above this line was measured on the development machine. The game
then shipped and **measured 16 fps on the machine it was actually played on**,
against 45–48 on the one it was tuned on. That gap is the most important entry
in this file.

Numbers below are read from the HUD during real play on the target machine
(1648×914 at 1x ≈ 1.5 MP), not from automation.

| Change | Result on target | Verdict |
|---|---|---|
| *(as shipped — fixed HIGH preset)* | **16 fps** | the failure |
| Lighting: sun 2.6→2.1, ambient 1.25→1.75 | — | **Kept** — fixed dark slabs across the road, no frame cost |
| fps-triggered auto quality step-down | **did not fire** | **Removed** — HIGH still selected after 20 s at 16 fps, cause never explained. Not shipped as something unexplained |
| Render scale **derived** from pixel count vs a 1.1 MP budget | **27–39 fps** | **Kept** — deterministic, applies on frame one, cannot silently not happen |
| Shadow cascades 2 → 1 @ 2048² | **31–33 fps** | **Kept** — two 2048² maps were 8.4 MP of shadow fill against a 1.1 MP screen |
| Presets thin scenery (`qualityDensity`), default BALANCED | *pending* | awaiting a device reading |

**Three lessons, in order of how much they cost:**

1. **`renderScale` multiplies the device pixel ratio.** A fixed preset is a bet
   on one machine's display. Derive it from the real pixel count.
2. **Never compare an early run to a mid-run.** With nothing spawned the scene
   is materially cheaper than it is with obstacles, coins and particles live.
   Several readings in this file's history were compared across that boundary
   and the conclusions drawn from them were noise.
3. **A dev-machine number is not a result.** Every conclusion here held until it
   met other hardware.

### Earlier experiments, measured against the old (mean-based) metric

These predate this file and were judged on the HUD's fps readout, whose spread
is roughly ±8 fps — **wide enough that a real 1–2 ms win would have read as
noise.** They are recorded here as history, not as settled answers. Anything
marked "re-test" is worth re-running against `hit60` before being trusted.

| Change | Old reading | Status |
|---|---|---|
| Shadow cascades 4 → 2 at 2048² (was 4 @ 1024²) | 12 → 37 fps | **Kept** — huge, and fixed a black self-shadowing patch |
| Instanced road tiles, lane dashes, coins, particles, houses, trees | ~350 → ~95 draw calls | **Kept** |
| `shadowMaxDistance` 42 → 24 | 0 fps | **Kept** for the visual win (tree shadows off the road) |
| `castsShadow: false` (diagnostic only) | +5 fps | Shadows are ~10% of the frame |
| `renderScale` 1.0 → 0.7 | +2–5 fps | Available as the FAST quality preset |
| `postProcess` bloom + colour grading off | 0 fps | Not worth disabling |
| `flutter build web --wasm` | no clear difference | Web only; inconclusive under throttling |
| `flutter_scene` 0.20.0 | 0 fps, shadows regressed | **Reverted** — stayed on 0.19.0 |
| Bake scenery over two wrap lengths, scroll the wrapper node | +2 fps | **Reverted — worth re-testing.** It removes ~1,400 `Aabb3` allocations per frame, and per-frame allocation is a prime suspect for the missed frames. Its one previous measurement was taken with the noisy metric. |

## 5. Open candidates

Ordered by expected value against `hit60`, not against the mean.

1. **Per-frame allocations.** `InstancedMesh.setInstanceTransform` marks bounds
   dirty and `refreshRenderItem` reads `aggregateBounds` every frame, which
   recomputes an O(n) AABB and allocates one `Aabb3` **per instance, per
   frame** — on the order of 1,400 objects a frame. That is the most plausible
   source of a periodic hitch, and the baked-scatter change above targets it
   directly.
2. **Fewer render items.** Trees, houses and particles are split across ~30
   meshes purely to carry different colours. Merging colour buckets cuts items
   directly and costs visual variety — a product decision, not an optimisation.
3. **Pooled obstacles are still composite nodes.** Small (only the active ones
   draw, and parked ones frustum-cull away), but it is the last unconverted
   prop.
4. **`depth_prepass` / `object_filter`.** Available in the engine, never tried.
   A prepass trades a pass for less overdraw, which only pays if the frame is
   fill-bound — and this one is not.
