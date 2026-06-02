# GSY Flutter Demo Source Logic Parity Audit

Date: 2026-06-01

This is the source-level counterpart to
`docs/gsy_flutter_demo_visual_parity_audit.md`. It compares each JSON demo with
the upstream Flutter implementation under `/tmp/gsy_flutter_demo_source` and
focuses on behavior, state, gestures, scroll coupling, animation sequencing,
and runtime capability gaps.

Status meanings:

- `match`: the JSON version captures the upstream interaction/state flow closely
  enough for this port.
- `partial`: core idea exists, but important source behavior is simplified.
- `mismatch`: JSON implements a materially different behavior.
- `unsupported`: exact upstream behavior currently needs framework capability
  that is not available in the JSON runtime.

## Summary

- `match`: 58 scenes.
- `partial`: 68 scenes.
- `mismatch`: 0 scenes.
- `unsupported`: 0 scenes.

The high-risk generic gaps are not project-specific. They are reusable runtime
capabilities: GlobalKey scrolling, anchored overlays,
Hero transitions, drag verification, circular reveal clipping, overlay entry
lifecycle, scoped text scale, nested/overlap slivers, verification-code input,
sticky render/sliver builders, expression-driven path/shader/particle support,
raw gesture and scroll-controller handoff, projected 3D scenes, FragmentProgram shaders,
and 3D depth primitives. Scene-specific geometry formulas belong in JSON; the
runtime should expose reusable drawing and event primitives rather than named
demo painters.

## 001-042

| # | Upstream source file | Status | Main logic difference | Fix scope |
|---:|---|---|---|---|
| 001 | `lib/widget/basic/controller_demo_page.dart` | match | Tap navigates to edit screen with input; route style differs but flow matches. | none |
| 002 | `lib/widget/basic/clip_demo_page.dart` | match | Static clip/decoration examples only. | none |
| 003 | `lib/widget/scroll/scroll_listener_demo_page.dart` | match | Generic list scroll callbacks cover offset/end/notification and scroll-to-top. | none |
| 004 | `lib/widget/scroll/scroll_to_index_demo_page.dart` | match | `onLoad` now generates 100 runtime-random heights and `@scroll_to_index` highlights item 13. | none |
| 005 | `lib/widget/scroll/scroll_to_index_demo_page2.dart` | match | Runtime-random card heights plus existing GlobalKey/`ensureVisible` index targets match the source flow. | none |
| 006 | `lib/widget/basic/gradient_text_demo_page.dart` | match | Gradient/stroke text intent is represented. | none |
| 007 | `lib/widget/basic/transform_demo_page.dart` | match | Static translated avatar/card flow matches. | none |
| 008 | `lib/widget/basic/text_line_height_demo_page.dart` | match | Strut/leading and translate behavior represented. | none |
| 009 | `lib/widget/basic/refresh_demo_page.dart` | match | `initialRefresh`, `onRefresh`, and `onLoadMore` cover the core flow. | none |
| 010 | `lib/widget/basic/refresh_demo_page2.dart` | match | `cupertino_refresh_list` captures auto refresh and load-more. | none |
| 011 | `lib/widget/scroll/custom_pull/refresh_demo_page3.dart` | partial | Custom release/indicator notification is approximated by a generic custom indicator. | runtime: richer refresh-state builder |
| 012 | `lib/widget/basic/positioned_demo_page.dart` | match | Responsive positioning factors and safe/top subtraction match. | none |
| 013 | `lib/widget/basic/bubble/bubble_demo_page.dart` | match | Generic `anchored_popover` measures trigger rects and renders dismissible arrow bubbles for all four arrow directions. | none |
| 014 | `lib/widget/basic/tag_demo_page.dart` | match | Wrap/tag static layout matches. | none |
| 015 | `lib/widget/basic/honor_demo_page.dart` | partial | Thumbnail/detail image, `heroTag`, no-appbar detail, and tap-back flow exist; true fullscreen MaterialRoute Hero transition is still not modeled by JSON navigation. | runtime: route-level Hero transition |
| 016 | `lib/widget/scroll/slider_verify_page.dart` | match | Generic `slide_verify` now matches drag start/update/end, clamp, success lock, failed-release snap-back and optional thumb image. | none |
| 017 | `lib/widget/basic/wrap_content_page.dart` | match | Layout is wrapped in a bounded vertical scroll container like upstream `SingleChildScrollView`. | none |
| 018 | `lib/widget/basic/statusbar_demo_page.dart` | partial | Image AppBar, white back button and Light/Dart `SystemChrome.setSystemUIOverlayStyle` actions exist; the initial `AnnotatedRegion<SystemUiOverlayStyle.dark>` wrapper is still not modeled as a screen-level system UI default. | runtime: screen-level system UI default |
| 019 | `lib/widget/basic/keyboard_demo_page.dart` | match | Keyboard detector, focus/unfocus and visible state match. | none |
| 020 | `lib/widget/animation/anima_demo_page.dart` | match | JSON rotates the 200px green square on a 3s loop and paints the foreground red circle from 0 to 300px radius. | none |
| 021 | `lib/widget/animation/anima_demo_page2.dart` | match | Generic `circular_reveal` models the source 500ms ease-in-sine circular clip and target-state reversal behavior. | none |
| 022 | `lib/widget/basic/floating_touch_demo_page.dart` | match | Generic `overlay_spawner` inserts independent overlay entries, supports pan-down/pan-update drag, and long-press removal. | none |
| 023 | `lib/widget/basic/text_size_demo_page.dart` | match | Generic `text_scale_scope` applies `MediaQuery.textScaler` to the subtree, with source text and +/- controls. | none |
| 024 | `lib/widget/basic/rich_text_demo_page.dart` | match | Rich text spans, images and tap snackbars represented. | none |
| 025 | `lib/widget/basic/rich_text_demo_page2.dart` | match | Generic `rich_text` widget spans now support `selectable:false`, so the disabled-selection widget span maps to upstream `SelectionContainer.disabled`. | none |
| 026 | `lib/widget/scroll/viewpager_demo_page.dart` | match | Page views and transformer names represent the core behavior. | none |
| 027 | `lib/widget/scroll/sliver_list_demo_page.dart` | partial | Upstream uses `NestedScrollView`, overlap absorber/injector and snap config; JSON uses simpler pinned slivers. | runtime: nested/overlap slivers |
| 028 | `lib/widget/basic/verification_code_input_demo_page.dart` | match | Generic `code_input` now uses hidden `EditableText`, length limiting, digit filtering and rectangle character cells. | none |
| 029 | `lib/widget/basic/verification_code_input_demo_page2.dart` | match | Generic `code_input` covers controller/focus-backed PIN cells, bullet display and grouped title row. | none |
| 030 | `lib/widget/basic/custom_multi_render_demo_page.dart` | match | Generic `radial_layout` plus Scaffold `footerButtons` match source circular child layout and add/remove footer controls. | none |
| 031 | `lib/widget/basic/cloud/cloud_demo_page.dart` | match | Generic `spiral_flow` computes non-overlapping spiral child placement, centers the record rect and fits the cloud into a square viewport. | none |
| 032 | `lib/widget/scroll/stick/stick_demo_page.dart` | partial | Upstream `StickRender` moves each header relative to item scroll; JSON approximates with pinned headers. | runtime: per-item sticky render |
| 033 | `lib/widget/scroll/stick/stick_demo_page2.dart` | partial | Pure JSON now models 50 default-collapsed sections, 150px visible content rows, gray 查看更多/收起 rows and per-section expanded state; upstream's random counts, `Expandable` animation, close-time scroll correction and custom `StickWidget` render precision are still simplified. | runtime: sticky render + scroll correction |
| 034 | `lib/widget/scroll/sliver_stick_demo_page.dart` | partial | Upstream recalculates each header translation from scroll position; JSON uses pinned pairs. | runtime: scroll-aware sliver header |
| 035 | `lib/widget/basic/input_bottom_demo_page.dart` | match | Keyboard detector, bottom input and unfocus behavior match. | none |
| 036 | `lib/widget/canvas/blur_demo_page.dart` | match | Backdrop blur primitive matches core behavior. | none |
| 037 | `lib/widget/animation/animation_container_demo_page.dart` | match | Random size/color/radius animated container flow matches. | none |
| 038 | `lib/widget/canvas/tick_click_demo_page.dart` | partial | Upstream custom painter draws clock rings/text from current time; JSON approximates. | runtime: canvas clock painter |
| 039 | `lib/widget/animation/anima_demo_page4.dart` | match | Animated icon switch and FAB represented. | none |
| 040 | `lib/widget/scroll/list_anim/list_anim_demo_page.dart` | partial | Scroll-linked appbar alpha and sticky threshold are approximated. | template/runtime interpolation |
| 041 | `lib/widget/scroll/list_anim_2/list_anim_demo_page.dart` | partial | Slide/fade `AnimatedSwitcher` fidelity is simplified. | runtime: switcher transition fidelity |
| 042 | `lib/widget/basic/drop_select_menu/drop_select_demo_page.dart` | match | Pure JSON state now models the three menu types, grouped expansion, multi-select with `全部` conflict handling, reset/confirm, normal single-select, mask hide, and menu heights. | none |

## 043-084

| # | Upstream source file | Status | Main logic difference | Fix scope |
|---:|---|---|---|---|
| 043 | `lib/widget/animation/anima_demo_page5.dart` | match | JSON now has the source `playing` guard, `played` toggle, concurrent 80ms staggered tasks, and 600ms per-character slide/fade animation. | none |
| 044 | `lib/widget/scroll/custom_sliver/scroll_header_demo_page.dart` | partial | Pull threshold, `NotificationListener`, `CustomSliver.handleShow/Hide`, and initial negative offset are not modeled. | runtime: custom pull/sliver callbacks |
| 045 | `lib/widget/scroll/custom_viewport/custom_viewport_page.dart` | partial | JSON uses normal sliver order; upstream demonstrates custom viewport/render ordering. | runtime: custom viewport/render sliver |
| 046 | `lib/widget/animation/anim_tip_demo_page.dart` | match | Click shows tip then hides after 1s with slide switcher. | none |
| 047 | `lib/widget/scroll/stick_sliver_list_demo_page.dart` | partial | Per-section default collapsed state, conditional 查看更多/收起 rows and expanded item visibility now match the core source flow; active sticky title, current-header jump and random group sizes remain simplified. | runtime: sliver offset inspection |
| 048 | `lib/widget/basic/overflow_image_page.dart` | match | Static overflow layout only. | none |
| 049 | `lib/widget/basic/align_demo_page.dart` | match | Static align/radial placement. | none |
| 050 | `lib/widget/basic/card_item_page.dart` | match | Static card sizing examples. | none |
| 051 | `lib/widget/scroll/sliver_tab_demo_page.dart` | partial | Tab select and list swap exist; shrinking icon/header and `TabController` indicator are simplified. | template/runtime tab primitive |
| 052 | `lib/widget/scroll/sliver_tab_demo_page2.dart` | partial | Upstream `NestedScrollView` + `PageView` swipe-to-tab sync is simplified. | runtime: nested scroll + page/tab sync |
| 053 | `lib/widget/scroll/sliver_tab/sliver_tab_demo_page3.dart` | partial | Header shrink and horizontal `PageView` sync are incomplete. | runtime: page controller + scroll notifications |
| 054 | `lib/widget/animation/book_page/book_page.dart` | partial | JSON now keeps the source text/palette, pan/tap-down curl state, and source-inspired a/f/g/e/h/c/j/b/k/d/i fold geometry in event-computed JSON variables. Exact `PathOperation` difference regions, offscreen text picture reflection, gradient shadows and cancel animation are still simplified. | runtime: generic path combine + layer transform + cancel animation |
| 055 | `lib/widget/animation/particle/particle_page.dart` | partial | JSON now models the mirrored gradient and 30 large floating particles with formula-driven `animated_canvas`; exact random durations/restarts remain simplified. | template timing tune |
| 056 | `lib/widget/animation/anim_bg_demo_page.dart` | partial | JSON now models the mirrored color tween and three wave layers with formula-driven paths; exact package animation timing remains approximate. | template timing tune |
| 057 | `lib/widget/canvas/matrix_custom_painter_page.dart` | match | JSON paints original, inverse and transformed paths with formula-driven `animated_canvas`; generic `transform_gesture` now supplies true focal-point pan, scale and rotation deltas. | none |
| 058 | `lib/widget/scroll/scroll_inner_content_demo_page.dart` | match | Generic `measured_box` publishes the content RenderBox rect and viewport/safe-area data; JSON computed values reproduce follower-button docking, clamp and add/remove text flow. | none |
| 059 | `lib/widget/basic/bottom_anim_nav_page.dart` | partial | JSON now uses the generic `@show_bottom_sheet` with transparent background/padding controls and renders the 18-item circular selector; exact Swiper angle transformer and scale animation are still simplified. | template animation tune |
| 060 | `lib/widget/basic/index_stack_drag_card_demo_page.dart` | match | Generic `draggable` now exposes cancel offset/velocity events; JSON applies the source drag-end thresholds, removes the dragged card, and resets data when empty. | none |
| 061 | `lib/widget/basic/index_stack_drag_card_demo_page2.dart` | partial | JSON now uses draggable cancel offset events and source-style removal thresholds; spring-back alignment physics from the custom `DraggableCard` is still simplified. | runtime/template: spring-back pan alignment |
| 062 | `lib/widget/animation/anim_button/anim_button_demo_page.dart` | partial | Custom play/loading animations and web-hide behavior are approximated. | runtime: animated buttons |
| 063 | `lib/widget/animation/anim_progress_img_demo_page.dart` | partial | Pulsing radial mask and finish reveal painter are simplified. | runtime: canvas blend/progress painter |
| 064 | `lib/widget/animation/anim_scan_demo_page.dart` | partial | Sweep gradient, ripple lifecycle, spring image scale and debounce are simplified. | runtime: animated canvas + debounce |
| 065 | `lib/widget/animation/arc_seek_bar_demo_page.dart` | match | Pure JSON `atan2` logic maps pointer angle to bound progress; `animated_canvas` segments/circles paint the source-style arc, shadow and thumb. | none |
| 066 | `lib/widget/animation/anim_bubble_gum.dart` | partial | Generic `particle_stream_canvas` now appends 29 formula particles every 50ms, keeps the latest 299, applies HSL linear highlight and radial highlight, and uses the source position/radius formulas. Exact platform-specific highlight behavior and cumulative painter rotation fidelity remain approximate. | template/runtime tuning |
| 067 | `lib/widget/canvas/canvas_click_demo_page.dart` | partial | JSON now draws the alarm-clock head, ears, feet, ring, tick marks and hands through `animated_canvas`; exact painter path rotation, bounce curve and real DateTime hands remain simplified. | template/custom painter |
| 068 | `lib/widget/scroll/link_sliver/link_sliver_demo_page.dart` | partial | `NestedScrollView`, linked flexible space and pull header behavior are missing. | runtime: linked sliver behavior |
| 069 | `lib/widget/canvas/drag_img_demo_page.dart` | match | Generic `transform_gesture` now drives continuous pan/scale/rotate state for the full-screen cat image instead of cycling preset transforms. | none |
| 070 | `lib/widget/basic/color_progress_demo_page.dart` | match | Generic `gradient_progress` reproduces delayed fills, repeat/reverse bounce animation, layered gradients and borders. | none |
| 071 | `lib/widget/animation/anim_text_demo_page.dart` | match | Generic `animated_text` now models the source Rotate/Fade/Typer/Typewriter/Scale/Colorize/TextLiquidFill/Wavy/Combination examples, tap counting and example cycling. | none |
| 072 | `lib/widget/basic/chat_list_scroll_demo_page.dart` | match | Generic `custom_scroll_view.reverse` plus `centerIndex` now match the centered reverse sliver layout; add-old/add-new append 20 items and Send jumps back to the newest edge. | none |
| 073 | `lib/widget/basic/chat_list_scroll_demo_page_2.dart` | partial | `extentAfter` decision, snackbar action, recursive bottom scroll and random heights are simplified. | runtime: scroll metrics + snackbar action |
| 074 | `lib/widget/basic/route_demo_page.dart` | partial | JSON now models the nested region as an independent `routeStack`: left clicks push indices, the right card pops one level when possible, and the stack bottoms out at route 0. It still does not instantiate a real nested Flutter `Navigator` or Cupertino route transition. | template/runtime: route transition fidelity |
| 075 | `lib/widget/canvas/shader_canvas_demo_page.dart` | match | No interaction logic upstream; visual painter still can be refined. | visual-only |
| 076 | `lib/widget/animation/anim_switch_layout_demo_page.dart` | match | FAB cycles three animated positioned panels. | none |
| 077 | `lib/widget/scroll/vp_list_demo_page.dart` | match | Generic `gesture_settings_scope` reproduces the outer 50px touchSlop and inner default touchSlop around the nested PageView/ListView structure. | none |
| 078 | `lib/widget/scroll/vp_list_demo_page.dart` | partial | Generic `scroll_drag_handoff` now forwards vertical drags to registered list/page controllers and switches from list to page at list max extent, matching the source's core controller-handoff flow. Exact render-box hit testing, keepAlive and overscroll configuration still need interaction recapture. | runtime/template: drag handoff tuning |
| 079 | `lib/widget/scroll/vp_list_demo_page.dart` | partial | Generic `scroll_drag_handoff` now starts the inner page controller when the outer list is at top and touch begins in the first 300px, then switches back to the list when the page controller reaches its max extent. Exact source drag-direction semantics and keepAlive details remain approximate. | runtime/template: drag handoff tuning |
| 080 | `lib/widget/scroll/vp_list_demo_page.dart` | match | Generic `@scroll_to_offset` plus list `physics:"never"` links the secondary list to primary scroll offset at the source 1/30 ratio. | none |
| 081 | `lib/widget/visual/card_perspective_demo_page.dart` | partial | Generic `positioned` sizing now preserves the layered card content; pan perspective exists, but clamp regions, radian formulas and shadow/parallax remain approximate. | template |
| 082 | `lib/widget/visual/card_3d_demo_page.dart` | partial | Generic `positioned` sizing now keeps front/back card overlays visible; auto-spin and pan exist, but exact radian rotation/image sizing differ. | template/runtime transform audit |
| 083 | `lib/widget/visual/card_real_3d_demo_page.dart` | partial | Generic `projected_scene` now renders front/back image planes, thickness, `G S Y` back text and source-generated z-path number strokes with radian pan/autospin state. True ZFlutter plane orientation, backface handling and depth sorting precision are still simplified. | runtime/template: projected scene tuning |
| 084 | `lib/widget/visual/dash_3d_demo_page.dart` | partial | Generic `projected_scene` now models Dash as JSON 3D/depth nodes with body, wings, hair, eyes, cone beak, drag rotation and smooth flight/bob formulas. Exact ZFlutter arc primitives, wing-axis rotations and delayed 20-interval animation remain approximate. | runtime/template: projected scene tuning |

## 085-126

| # | Upstream source file | Status | Main logic difference | Fix scope |
|---:|---|---|---|---|
| 085 | `lib/widget/canvas/transform_canvas_demo_page.dart` | match | JSON now uses a 200x200 canvas and source-coordinate red stroke segments with the 300ms/pi/10 rotateY compression behavior. | template canvas/path parity |
| 086 | `lib/widget/visual/anim_juejin_logo_demo_page.dart` | match | Generic `rive_animation` now loads the upstream `.riv` from OSS with the Rive runtime instead of a hand-drawn fallback. Widget tests skip remote loading because Flutter test blocks HTTP. | none |
| 087 | `lib/widget/visual/juejin_3d_logo_demo_page.dart` | partial | JSON now ports the three source ZShape polygon point sets and keeps drag rotation via generic transform; true ZFlutter projection remains approximate. | template + 3D/path support |
| 088 | `lib/widget/visual/juejin_3d_box_logo_demo_page.dart` | partial | Generic `positioned` width/height support now lets the JSON box-logo layers render; true ZFlutter boxes, depth faces and Z ordering remain approximate. | runtime: 3D boxes/depth |
| 089 | `lib/widget/basic/png_shadow_demo_page.dart` | match | JSON now uses the source-sized image, offset duplicate layer and generic ImageFiltered blur to reproduce DropShadow behavior. | runtime: image-mask shadow |
| 090 | `lib/widget/canvas/custom_shader_path_demo_page.dart` | match | Generic `image_shader_path` now draws the source quadratic path with repeated cat `ImageShader`, 0.2 shader scale, 20px stroke and clipped 1px grid inside the 200x200 green panel. | none |
| 091 | `lib/widget/scroll/list_link_bottomsheet_demo_page.dart` | partial | JSON now uses a persistent bottom sheet layer with drag-driven `sheetHeight`, source-style Header/content, and generic `scroll_drag_handoff` for the background list/page controller switch. Exact inner/outer drag coupling, `_LinkBottomSheet` controller stream semantics and hide/show callbacks are still simplified. | runtime/template: sheet-controller handoff tuning |
| 092 | `lib/widget/scroll/demo_draggable_sheet_stick_page.dart` | partial | JSON sheet now uses closer half/fullscreen heights and animated FAB expansion; true `DraggableScrollableSheet` extent, pinned header and sheet scroll coupling are approximated. | runtime: draggable sheet + sliver |
| 093 | `lib/widget/basic/async_to_sync_call_page.dart` | match | Observable async order/timing is serialized correctly. | none |
| 094 | `lib/widget/scroll/star_bomb_button_page.dart` | match | Pure JSON state plus `animated_canvas` path/particle formulas draw the five-point star and tap-triggered 500ms particle explosion. | none |
| 095 | `lib/widget/visual/photo_gallery_demo_page.dart` | partial | JSON renders the 5x5 colored gallery grid with directional swipe state; cutout overlay animation, random color regeneration, haptics and exact responsive sizing are simplified. | template animation polish |
| 096 | `lib/widget/animation/tear_text_demo_page.dart` | partial | JSON now uses generic polygon/rect clipping, glow shadows, gradient stroke tear layer and dual 400/600ms triggers; remaining gap is true random polygon regeneration per tear frame. | runtime: custom clipper/path polygons |
| 097 | `lib/widget/scroll/unbounded_listview.dart` | partial | Generic `cross_axis_sizing_list` ports the unbounded viewport/sliver-list sizing behavior so horizontal lists derive height from measured children; both source horizontal sections now use it without fixed heights. Random text generation and every render-edge case remain simplified. | template/runtime: edge-case parity |
| 098 | `lib/widget/scroll/pageview_in_pageview_demo_page.dart` | partial | Outer and inner PageViews now register controllers, disable native gestures, and use generic horizontal `scroll_drag_handoff` rules to transfer drag ownership at inner page boundaries. Exact `OverscrollNotification`, `correctPixels`, accumulated left/right overscroll and keepAlive semantics remain simplified. | runtime: scroll notification/correctPixels fidelity |
| 099 | `lib/widget/basic/gesture_password/gesture_password_demo_page.dart` | match | Generic `gesture_password` now hit-tests the 3x3 dots by pan, draws the selected path, emits the joined password on pan end and clears selection like upstream. | none |
| 100 | `lib/widget/scroll/link_scroll_page.dart` | match | Left tap scrolls the right list to precomputed item offsets; right-list scroll updates selected index and keeps the left list aligned through generic `@scroll_to_offset`. | none |
| 101 | `lib/widget/canvas/glass_demo_page.dart` | partial | Dialog/sheet buttons exist; animated bubbles and exact blur/gradient layering are simplified. | template animation/detail |
| 102 | `lib/widget/canvas/liquid_glass_demo.dart` | partial | JSON uses the source `iOS26.png` texture and a draggable blur lens approximation; the real FragmentProgram uniforms and sampling are still missing. | runtime: FragmentProgram shader |
| 103 | `lib/widget/canvas/liquid_glass_demo2.dart` | partial | JSON uses the source `person.jpg` texture and a draggable blur lens approximation; the real FragmentProgram uniforms and sampling are still missing. | runtime: FragmentProgram shader |
| 104 | `lib/widget/animation/attractor_page.dart` | partial | JSON now exposes the four source modes, Switch button, labels, colors and scale-specific formula approximations; persistent Euler-integrated particle state/reset remains missing. | runtime: stateful particle simulation |
| 105 | `lib/widget/animation/fibonacci_sphere_page.dart` | partial | Sphere animation, POINTS/SPEED/WOBBLE/SIZE/TRAILS controls and point-count/size/trail variables now feed the JSON canvas; exact 3000-5000 point painter density and custom capsule slider thumb remain approximate. | template/canvas params |
| 106 | `lib/widget/visual/galaxy_scene_page.dart` | partial | JSON now models the dark stage, cyan two-arm star field, pulsing orange/green core blobs and black-hole ovals; exact 30k particle physics and lobe reset cycle remain missing. | runtime: large particle model |
| 107 | `lib/widget/animation/neon_slider_page.dart` | partial | Slider value changes; custom neon painter, flash burst and hysteresis are missing. | runtime: custom slider painter |
| 108 | `lib/widget/canvas/radial_lines_page.dart` | partial | JSON now connects projected 3D cube vertices layer-by-layer with source-style perspective; remaining gap is exact Perlin noise field parity. | template math/runtime painter |
| 109 | `lib/widget/animation/boom_particle_page.dart` | partial | Source prompt text, interactive particle field and tap/pulse burst approximation exist; persistent velocity arrays and true attraction/explosion physics remain missing. | runtime: particle physics |
| 110 | `lib/widget/visual/black_hole_simulation_page.dart` | partial | JSON now layers upper/lower lensed arcs, front/back accretion disk particles, hot/cool color mixing and black core masks; exact 12000 persistent particles and distorted core path remain simplified. | stateful particles/custom painter |
| 111 | `lib/widget/visual/stream_taichi_page.dart` | partial | Vector-field particle state, trails and reset rules are missing. | runtime: particle trails |
| 112 | `lib/widget/visual/black_hole_page.dart` | partial | JSON now models white-hole glow, black-hole core and an S-shaped flowing particle field; pointer perturbation, respawn/swallow lifecycle and persistent velocity remain missing. | runtime: pointer + stateful particles |
| 113 | `lib/widget/visual/taichi_page.dart` | partial | Source-style 柔和圆/几何S形 toggle exists; exact reset plus stateful particle emission/death logic remain simplified. | runtime: stateful particles |
| 114 | `lib/widget/basic/akaza_page.dart` | partial | JSON now recreates the cyan/purple compass geometry, center ring, branches, forks, hexagons, kanji labels and small center character; staged draw/rotate/tilt/replay chain remains approximate. | template animation sequencing |
| 115 | `lib/widget/scroll/tornado_scroll_demo.dart` | partial | JSON now has the source black stage, item list and `Twist Intensity (Zoom)` slider; upstream custom 3D spiral drag transform remains simplified. | runtime: 3D scroll transforms |
| 116 | `lib/widget/animation/particle_morphing_page.dart` | partial | Shape labels, left/right page controls and random/structured distribution toggle now exist; true shape interpolation and rotation pause/resume remain simplified. | runtime: morphing particle system |
| 117 | `lib/widget/animation/combined_scene_page.dart` | partial | JSON now includes HUD formulas, red double helix, gold conical ribbon and green orbital particles; remaining gap is exact 3D projection/tap shake parity. | template/custom painter |
| 118 | `lib/widget/visual/notion_qrcode_page.dart` | partial | Entry screen now matches the source input + Start flow and navigates to a particle screen; the QR-derived particle generation and mode transitions remain simplified. | template particle algorithm |
| 119 | `lib/widget/visual/disco_sphere_page.dart` | partial | Source-style mode FAB, initial label and purple/silver palette exist; true tile quads, hover offsets and breathing burst remain simplified. | runtime: pointer/stateful 3D tiles |
| 120 | `lib/widget/visual/spatial_grid_page.dart` | partial | Initial white grid, dark-mode FAB and cyber toggle now exist; pointer deformation, lag and moving beams remain simplified. | runtime: pointer-driven canvas |
| 121 | `lib/widget/scroll/shock_wave_chat_page.dart` | partial | JSON now matches the upstream Web fallback message; the native screenshot-to-texture shader overlay on press remains unsupported. | runtime: screenshot texture + shader |
| 122 | `lib/widget/animation/particle_effect_screen.dart` | partial | JSON now includes floor rings, vertical beam, fountain/background particles and source-style NORMAL/CYBER mode button; exact stateful particle reset and cyber wave layers remain simplified. | template rewrite/stateful canvas |
| 123 | `lib/widget/visual/mosaic_scanner_page.dart` | partial | JSON now matches the upstream Web fallback message; the native FragmentProgram image shader path remains unsupported. | runtime: FragmentProgram image shader |
| 124 | `lib/widget/visual/koi_fish_animation.dart` | match | JSON now ports the 10k-point `y/k/e/d/q/c` formula, including the bitwise texture term through generic `bitxor`. | template math fidelity |
| 125 | `lib/widget/canvas/dynamic_jaw_control_page.dart` | partial | JSON now exposes the source-style dark preview, mode buttons, UI-size/duration sliders and trigger control, with formula-drawn jaw/teeth approximation; exact anatomical 3D projection and one-shot controller remain missing. | runtime: complex painter / one-shot animation |
| 126 | `lib/widget/canvas/fire_shader_demo_page.dart` | partial | JSON approximates the full-screen fire shader with source-inspired UV twist, turbulence heat grid, ember and smoke layers. Exact 70-step ray-marched `FragmentProgram` remains a Flutter compile-time shader asset pipeline gap; remote `.frag` cannot be executed directly. | runtime: FragmentProgram asset pipeline |

## Repair Guidance

Do not add a project-specific Dart bridge. Framework additions must be named by
capability, for example `circular_reveal`, `anchored_overlay`,
`linked_scroll_view`, `transform_gesture`, `measured_box`, `path_clip`, `fragment_shader`,
`rive_asset`, or `particle_canvas`. Do not place a scene's star, wave, arc,
particle distribution, or other geometry formula in Dart when JSON expressions
can express it.

When a scene is `partial` because the template is weak but the runtime can
express it, repair the JSON template. When the row says `runtime`, adding more
template JSON will only produce a prettier approximation; exact parity needs a
generic reusable primitive first.
- 2026-06-02: Added generic `list.intrinsicHeight:false` for complex list items that contain their own shrink-wrapped viewport, preventing Flutter intrinsic measurement assertions without changing default list behavior.
- 2026-06-02: Added generic `custom_scroll_view.reverse` and AppBar labeled actions, then moved scene 072 to source parity for reverse centered chat slivers and 20-item append actions.
- 2026-06-02: Added generic JsonLogic math ops plus `animated_canvas.variables`,
  `linear_gradient`, and paint `blurRadius`. Reworked 055, 056, 065, and 094 so
  their wave/particle/arc/star formulas are JSON-level; removed dedicated
  `arc_slider` and `star_burst_canvas` runtime widgets.
- 2026-06-02: Reworked 057 and 058 without adding scene-specific runtime code:
  matrix path formulas moved to JSON `animated_canvas`, and bottom follower
  layout uses JSON computed values plus generic `str_replace_first`.
- 2026-06-02: Closed the remaining 057/058 runtime gaps with generic
  `transform_gesture` and `measured_box`. Dart now only emits transform and
  layout events; matrix accumulation and follower-button formulas remain in
  JSON templates.

- 2026-06-02: Added generic `@scroll_to_offset`, list `physics`, and `gesture_settings_scope`; updated 059, 069, 077, 080, and 100 without project-specific runtime bridges.

- 2026-06-02: Exposed generic draggable cancel offset/velocity events; updated 060/061 drag-card templates to use JSON-level threshold removal.
- 2026-06-02: Added generic `animated_text` and `gesture_password`. Updated 071 and 099 to source-style animated text cycling and pan-driven password paths. Updated 118 entry flow and 123 Web fallback in JSON.
- 2026-06-02: Updated 119 JSON with source-style mode FAB state and purple/silver disco-sphere palette; no project-specific runtime code added.
- 2026-06-02: Updated 120 JSON to source-style white grid initial mode with dark-mode FAB and cyber toggle; pointer deformation remains a generic canvas/input gap.
- 2026-06-02: Updated 121 JSON to match upstream Web fallback while keeping native shock-wave shader as an unsupported generic runtime gap.
- 2026-06-02: Updated 122 JSON with floor rings, beam/fountain/background particle layers and source-style NORMAL/CYBER mode button.
- 2026-06-02: Reclassified 102/103 after validating current templates: source textures and draggable blur-lens approximation exist, but FragmentProgram shader parity remains a generic runtime gap.
- 2026-06-02: Updated 113 JSON with source-style 柔和圆/几何S形 mode toggle while leaving stateful particle lifecycle as a runtime/template gap.
- 2026-06-02: Updated 116 JSON with SPHERE/CUBE/TORUS/HEART labels, left/right controls and random/structured distribution toggle.
- 2026-06-02: Updated 115 JSON with source-style black stage and Twist Intensity slider; the 3D tornado transform remains a generic scroll-transform runtime gap.
- 2026-06-02: Extended generic `animated_canvas` particle shapes with `rect`/`oval`; updated 104, 106 and 125 so source mode/control structure and key visuals live in JSON instead of mismatch placeholders.
- 2026-06-02: Reworked 054 as a JSON-level drag curl approximation. The geometry formulas live in JSON actions instead of `global.computed` to avoid recursive expression blow-up; remaining curl fidelity requires generic path-combine and layer-transform primitives, not a named book-page bridge.
- 2026-06-02: Reworked 074 from single `previousRoute` state into a JSON `routeStack`, matching the source nested push/pop behavior without adding a runtime bridge. Added a regression test for multi-level push/pop.
- 2026-06-02: Added generic `page_view.controller`, `list.expand:false`, and `scroll_drag_handoff`. Updated 078/079 so raw vertical drag ownership is data-driven by JSON controller IDs and boundary switch rules instead of relying on native nested scrolling.
- 2026-06-02: Reworked 091 from modal bottom sheet to a persistent JSON bottom sheet with drag-up/down height state plus background list/page handoff. Remaining fidelity is controller-callback coupling, not a project-specific bridge.
- 2026-06-02: Updated 098 with controller-registered nested PageViews and horizontal `scroll_drag_handoff`, clearing the last source-audit `mismatch` while keeping exact `correctPixels` overscroll behavior as a partial runtime gap.
- 2026-06-02: Cleared the remaining `unsupported` rows by adding generic `particle_stream_canvas`, `projected_scene`, `image_shader_path`, `cross_axis_sizing_list`, and `rive_animation`. Scenes 066, 083, 084, 097 and 126 remain partial where source-level painter/ZFlutter/shader edge cases still differ; 086 and 090 now use real runtime primitives instead of fallbacks.
