# VISION — where this game is going

Read this together with `CLAUDE.md` (root). `CLAUDE.md` = how the code works and
how to run it. This file = **what we are trying to build and why**, the
art-direction rules that get us there, and what is done vs. still open.

This is an **original** build-in-public project by Ahmed ElFirgany. It is not a
clone of anything — the reference game below is a *look-and-feel target only*.
Everything in this repo is hand-written. Commits are authored by Ahmed, in his
own style (`Day N:` / `Improvement N:` / `docs:`), with **no AI co-author
trailer**. Treat every change as his work.

---

## 1. The visual target

We are matching the *look and feel* of **DashSurfers** (an fscene.dev demo): a
bright, populated, low-poly **daylight** endless runner. Reference screenshots
live in `docs/target-reference/target-01.png … target-18.png` (gitignored — they
are someone else's game, kept locally only as a north star). **Open them before
doing any visual work.**

What the target actually contains, element by element:

- **World:** soft blue sky with faint clouds, rolling green hills, a multi-lane
  asphalt road with dashed lane lines. Everything is low-poly but *polished*.
- **Vegetation:** layered conifers + rounded leafy trees (some autumn-red),
  and — critically — **dense tall grass** carpeting the ground with a fuzzy
  silhouette. The lushness is a big part of the feel.
- **Roadside:** houses with coloured roofs, rocks, bushes, guardrails along the
  road edge, lamp/sign posts, the occasional checkpoint arch.
- **Obstacles (never plain cubes):** wrapped **gift/present boxes**, red/white
  **candy-stripe barriers**, green **shipping containers**. The player switches
  lane or jumps to avoid them.
- **Collectibles:** coins laid out in **rising arcs and long curving trails**
  (not scattered singles), plus occasional secondary pickups (bananas).
- **Feel elements:** **jump ramps** (blue raised platforms), floating **`+N`
  score popups**, a rounded **HUD capsule** (score · coins · timer) centered
  top, and a **crash screen with a leaderboard name-entry**.
- **Lighting:** this is the single biggest reason the target reads as "modern"
  and ours can read as "primitive." The target has **soft shadows and bright
  ambient fill** — low contrast, no harsh black shadows. See §3.

---

## 2. Art-direction principles (how to hit the target)

1. **Soft lighting > more geometry.** The DashSurfers "high-graphics" feel is
   mostly *lighting*, not polygon count. Keep a gentle key light + **high
   ambient / environment intensity** so shadows stay soft. Harsh sun + low
   ambient is what makes low-poly look cheap. Tuning lives in
   `_setupSceneLook()` and the `sunIntensity` / `envIntensity` consts.
2. **Density sells lushness.** Many small instanced elements (grass, flowers,
   bushes) read as a rich world. Prefer adding instanced density over adding
   one big detailed mesh.
3. **Low-poly, but polished.** The target is *itself* low-poly. We are not
   chasing photorealism. "Polished" = soft light + density + tidy silhouettes +
   subtle post (bloom/vignette/grade), not more triangles.
4. **Performance is a feature.** Ahmed explicitly wants richer visuals *without*
   losing performance. The lever is **instancing**: one `InstancedMesh` + many
   `setInstanceTransform` calls. Use it for anything that repeats
   (grass/rocks/bushes/flowers), and do NOT add hundreds of individual
   `Node`s for scenery.

   **It really is hardware instancing — and the `InstancedMesh` docstring lies
   about it.** That comment claims *"The naive backend still issues one draw
   call per instance"*, but every primitive we use inherits
   `UnskinnedGeometry`, whose `instancedVertexLayout` is non-null, so
   `scene_encoder.dart` takes the packed branch and draws the whole set with a
   single `instanceCount:` call. The ~1,240 scenery instances cost about **14
   draw calls**. Density is genuinely cheap here; what it costs is vertex and
   fragment work, not draw calls.

   Where the draw calls actually go is the ~350 individually-`Node`d meshes
   (trees, obstacles, houses, coins, particles, lane dashes). If a frame-rate
   problem needs draw calls cut, cut there — or convert a repeated prop to an
   `InstancedMesh` — before touching `grassCount`. The HUD capsule carries a
   live fps readout so this stays measured rather than argued about.
5. **Silhouette first.** Trees = fuller multi-tier cones / clustered spheres;
   grass = many thin tapered blades. A good silhouette beats surface detail at
   this scale.
6. **The honest ceiling of primitives.** Everything here is built from
   `CuboidGeometry` / `IcosphereGeometry` / `CylinderGeometry`. That can reach
   *polished low-poly*. To go beyond that (truly "authored" trees/rocks/props),
   the next level is importing **low-poly `.glb` models** at runtime via
   `Node.fromGlbAsset` (same path as the Dash character) and **instancing** them.
   That is a deliberate, larger step (sourcing/licensing/bundling assets) — raise
   it with Ahmed before taking it; don't silently swap primitives for models.

---

## 3. Current state (2026-07 — delivered, may be uncommitted)

Shipped & live earlier (commit `29d0940`): Days 1-3 + 7 improvements — Dash
character, power-ups, SFX, touch controls, high-score/share, neon post-FX.

Visual-overhaul pass since then (delivered to the working tree; confirm `git
status` and commit when happy):

- **Daylight world** — sky/grass/asphalt/hedges, replacing the night look for
  the play space. Sun + real shadows, sky-coloured distance fog.
- **Trees** — 3-tier conifers + clustered round crowns, foliage-colour variety.
- **Houses** — box walls + pyramid roofs, coloured.
- **Instanced scenery** — rocks, bushes, two flower colours, and **tall grass
  tufts** (three green shades, thin tapered blades, high count), each a single
  `InstancedMesh` scrolled in the painter. See §2.4 for what that actually
  costs at the pinned `flutter_scene`.
- **Obstacle variety** — pooled mix of **gift boxes / candy-stripe barriers /
  green containers** (composite nodes, base-at-origin, placed on `roadTopY`;
  collision stays a uniform AABB via `obHalf*`). No more plain cubes.
- **Score popups** — `_Popup` projected to screen via
  `Camera.worldToScreen(...)`, drawn as a Flutter overlay that rises & fades.
- **Lighting pass** — softer sun, high ambient, gentle grade (the "modern" look).
- **Removed** — the old dust trail behind Dash, and the ambient floating
  "motes" (Ahmed disliked both).

### Target-reference pass (2026-07-29 — in the working tree, unreviewed)

Built against the 18 `docs/target-reference/` shots, but **not yet looked at
running** — treat every number below as a first guess, not a tuned value.

- **Road** — white *lit* lane dashes (were unlit gold), solid white edge lines,
  and packed-dirt shoulders. Edge lines and shoulders are static: a continuous
  line has no phase to scroll.
- **Guardrails + sign posts** — instanced, placed from the instance index
  rather than from scatter data.
- **Distant hills** — static fogged ellipsoids on the horizon.
- **Clouds** — a Flutter painter between the sky gradient and the 3D layer.
- **Coins** — upright spinning discs, laid out as flat lines, **rising arcs**,
  or **lane-to-lane trails**. Each coin now carries its own `y` and `restX`.
- **Jump ramps** — pooled, additive only (they launch, never block).
- **HUD** — the reference's dark rounded capsule (score · coins · m/s · fps).
  Speed is now m/s, which is what `_curSpeed` already was; the old km/h line
  multiplied it by an invented factor.
- **Crash screen** — adds "You got Nth place!" before the name is saved.
- **Grass** 240 → 320 per shade, and it now starts outside the dirt shoulder.
- **Camera** pulled in and down via four new consts.

### Performance + code pass (2026-07-29)

Driven by reading `flutter_scene`'s source rather than its doc comments. Full
model in `CLAUDE.md` § "Performance model"; the headlines:

- **Shadow cascades 4 → 2** and an explicit shadow map resolution. The default
  four cascades re-render every caster four times for a view distance we don't
  use — the biggest single cost in the frame.
- **`shadowStatic`** on all non-moving geometry, so the shadow pass bakes it
  once instead of every frame.
- **Zero-allocation painter** — ~1,600 transforms a frame now write in place
  instead of allocating a `Matrix4` each.
- **Instancing pass** — road tiles, lane dividers, coins, particles and houses
  all converted from individual nodes to instanced sets: **178 draw calls down
  to 16**. Trees (72) and pooled obstacles (~72) are the remaining candidates;
  the recipe is written up in `CLAUDE.md`.
- **Quality presets** via `Scene.renderScale` (HIGH · BALANCED · FAST).
- **First tests in the project**: `lib/game_math.dart` holds the GPU-free
  gameplay math and `test/game_math_test.dart` covers it, 21 cases. The game
  itself still cannot be widget-tested.
- Analyzer baseline improved 23 → 14 (all nine `Matrix4.scale` deprecations
  gone).

### Measured pass (2026-07-30) — first time the build was actually run

Served the release web build locally and read the fps from the HUD. Every
number before this was inferred from reading the engine source; these are not.

**12 fps → 46–48 fps**, and the black blob that was sitting across the near road
is gone. Full table and reasoning in `CLAUDE.md` § "Measured baseline".

- The blob was mine: an unverified cascade cut. Fixed by pairing 2 cascades with
  a 2048² map, same texel density, half the geometry submissions.
- Trees instanced (they were the largest fixed draw-call cost — all 18 are
  always on screen).
- **Procedural textures** on the asphalt, ground and dirt shoulder — generated
  arithmetically at startup, no bundled images, no licensing. This closes the
  "speckled asphalt" gap listed below.
- Guardrail beams were 92% of their spacing (floating sticks up close) and sign
  poles were too thin to see (boards hanging in the trees). Both fixed.

The lesson worth keeping: the frame is **draw-call bound, not fill bound**, so
visual richness that costs *fragments* (textures, and by extension SSAO or
image-based lighting) is nearly free here, while anything that adds a `Node` is
not. That inverts the usual instinct — spend on shading, not on geometry.

## 4. Roadmap — remaining gap to the target

Next, and needing Ahmed's eyes first:
- **Tune the pass above** — camera framing, grass count vs fps, ramp impulse.

### Built, then cut on first look (2026-07-29)

- **Ambient wind petals** — small flecks drifting past the camera, built for
  the reference's "alive" cue. **Do not re-add.** This is the third time the
  same call has been made, after the dust trail and the floating motes:
  ambient floating particles are not wanted in this game.
- **Checkpoint arches** — a gate spanning the road. Note this one is *not* a
  rejection of the idea: the target does have arches (§1, target-05), but as a
  rare landmark. Ours sat at `archCount = 2` on a 72-unit wrap, so one arrived
  every 1.5–2.4 s and the frame was never without one. If it is ever revisited,
  it needs to be far rarer than the wrap cycle allows — which means spawning it
  on a timer like an obstacle, not placing it on the scroll phase.

Still missing vs. the reference:
- **Wooden bridge / boardwalk** road sections (target-09, target-15).
- **Bare/dead trees** for silhouette variety (the reference has several).
- The trees nearest the camera fill the frame edges in a way the reference never
  does — either push `treeX` out or suppress the last few phases.

**Performance is done for now — the frame is flat.** Four experiments after the
46–48 fps build each returned 0–5 fps (table in `CLAUDE.md`), including turning
shadows off entirely. Nothing dominates any more, so there is no single thing
left to fix; the remaining cost is the engine's per-frame overhead on WebGL2.
Don't spend more effort here without first measuring **native macOS/Metal**,
which has never been checked and where draw calls are far cheaper.

Cheap now that the frame is draw-call bound and has fragment headroom:
- **`scene.ambientOcclusion`** (SSAO) — contact shadows where props meet the
  ground, the cue that most separates our look from the reference's.
- **`EnvironmentMap.fromSky()` / `studio()`** — image-based lighting with no
  asset, which is the single biggest PBR realism lever available.
- **Normal maps** on the asphalt and dirt (`normalTexture`, generated the same
  way as the albedo) so the sun catches the surface.

Feature depth & platforms (separate tracks Ahmed picked):
- Perf & feel (isolate the Dash glTF load off the first frame, collision juice).
- Gameplay depth (double-jump, slide, moving obstacles).
- **Mobile** (Android/iOS): needs `fvm flutter create --platforms=android,ios .`
  plus per-platform Flutter GPU opt-in (see CLAUDE.md).

Bigger optional leap: authored **`.glb` scenery models** instanced in place of
primitive-built trees/rocks/props (see §2.6).

---

## 5. How to work in this repo (for a coding agent)

- **You cannot headless-test the 3D.** `flutter_scene` needs a real GPU/Impeller
  context; widget tests can't mount the game (see CLAUDE.md). So: make a change,
  run `fvm flutter analyze` (must be clean), then `fvm flutter run -d macos
  --enable-flutter-gpu --enable-impeller` (or `-d chrome`) and **look at it**.
  Visual judgement is human — show Ahmed a screenshot/clip and iterate.
- **Always `fvm`.** The repo is pinned to Flutter master (Flutter GPU only
  exists there). A bare `flutter` may fail at pub-get/build.
- **Verify APIs against the pinned version before writing them.** `flutter_scene`
  0.19 has sharp edges — e.g. `Animation` is exported by *both* `flutter/material`
  and `flutter_scene`, so never write that type name; use
  `final x = node.findAnimationByName(...)` and let it infer. When unsure of an
  API, read the package source at its tag rather than guessing.
- **Where things live:** all tuning is in the `static const` block at the top of
  `_GamePageState` (`lib/game_state.dart`) — change feel/colour/look there, not
  inline. Sim/render split is strict: `_update(dt)` owns state and never touches
  nodes; `_GamePainter.paint()` owns every `node.localTransform`, the camera, and
  `scene.render()`. To add a visual element: build the node in `_buildWorld()`
  and position it in the painter. Instanced scenery: build the `InstancedMesh` +
  scatter data in `_buildWorld()`, then `setInstanceTransform` per-frame in the
  painter (see the grass/rocks blocks as the template).
- **Commits are Ahmed's.** Don't commit as an agent; don't add co-author
  trailers. Match his subject style. (Note: a global hook may enforce
  Conventional Commits — see CLAUDE.md "Commit conventions".)

---

## 6. One-line summary

Bright, lush, polished **low-poly daylight** runner. Get there with **soft
lighting + instanced density + fuller silhouettes**, keep it fast with
**instancing**, and treat the `docs/target-reference/` screenshots as the bar.
