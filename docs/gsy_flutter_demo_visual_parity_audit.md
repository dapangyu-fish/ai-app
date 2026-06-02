# GSY Flutter Demo Visual Parity Audit

Date: 2026-06-01

This audit compares the upstream Flutter demo app against the JSON-DSL port in Flutter Web release mode. It is intentionally visual and behavior-oriented: screenshots are taken before and after a simple interaction when the scene has an obvious interaction target.

Source-code behavior parity is tracked separately in
`docs/gsy_flutter_demo_source_logic_parity_audit.md`. Use both documents
together: visual similarity does not imply the JSON scene matches the upstream
state machine, gesture model, scroll coupling, or custom painter behavior.

## Method

- Upstream source clone: `/tmp/gsy_flutter_demo_source`
- Upstream web server: `http://127.0.0.1:5556/?demo=<index>`
- JSON web server: `http://127.0.0.1:5555/?local_json=<absolute-template-path>&local_json_server=http://127.0.0.1:8765/json`
- Local JSON helper: `python3 scripts/local_json_server.py --port 8765`
- Capture script: `/tmp/ai-app-gsy-audit/capture_gsy_parity.py`
- Capture result: `/tmp/ai-app-gsy-audit/capture_results.json`
- Screenshots: `/tmp/ai-app-gsy-audit/screens/<NNN>/{original_initial,json_initial,original_after,json_after}.png`
- Contact sheets: `/tmp/ai-app-gsy-audit/contact_sheets/contact_*.jpg`
- Viewport: `402x874`, mobile touch context. This is close to the current web test device size; future mobile audits should also include iPhone 17 standard logical size and an iPhone 13 mini lower bound.

Simple interactions were executed where useful: tap, drag slider, scroll, swipe, input focus, bottom/header tap, and basic gesture paths. Complex app-only or multi-step gestures are recorded as partially covered instead of guessed.

## Severity

- `P0`: Broken or unusable after interaction.
- `P1`: Main visual/behavior is materially different from upstream.
- `P2`: Usable, but style, spacing, timing, or secondary behavior differs.
- `P3`: Acceptable or only minor tuning needed.

## High-Level Findings

- The port is not yet 1:1. Most scenes are recognizable, but many are approximate rewrites rather than faithful ports.
- The largest gaps are refresh state, sticky/sliver behavior, page/list gesture arbitration, custom canvas/shader effects, 3D card scenes, and particle scenes.
- Several JSON templates still encode a different demo concept than upstream, especially scenes 102-126.
- Framework code currently has no `gsy`/`GSY`/`gsy_flutter` symbols in `lib/`, `backend/`, or `test/`. Project attribution and namespace strings only appear in docs/templates/assets, which is expected for this port.
- `visual_primitives_widget.dart` is now mostly a generic expression-driven animated canvas, not a named project bridge. Formulas for stars, waves, arcs, particles, and similar scene-specific geometry must live in JSON; Dart should only expose primitive drawing, expression evaluation, gesture/event input, and paint properties.

## Repair Priorities

1. No current `P0` after the v5 repair pass; keep regression tests around 010, 011 and 100 because they previously rendered blank after interaction.
2. No current `P1` visual rows after the 054 repair; continue reducing high-impact `P2` rows that still mask source-level runtime gaps.
3. Fix structural scroll/sliver demos: 033, 040-044, 047, 051-053, 068, 072-080, 091-092, 097-100.
4. Decide strategy for shader/canvas/particle scenes. If exact runtime effects are not expressible in JSON, use generic primitives or static/animated assets, but do not add project-specific Dart bridges.
5. For Web-unsupported upstream scenes such as 123, match upstream Web fallback unless the product explicitly wants a JSON-native replacement.

## Detailed Differences

| # | Title | Interaction | Severity | Difference | Fix Direction |
|---:|---|---|---|---|---|
| 001 | 文本输入框简单的 Controller | scroll | P2 | Button content is close, but JSON uses white background instead of upstream pale scaffold. | Align scaffold/background defaults. |
| 002 | 实现控件圆角不同组合 | scroll | fixed | JSON now uses the source cat asset for all three cases and preserves the intentional un-clipped child case. | Recheck image-load screenshot. |
| 003 | 列表滑动监听 | scroll | P2 | List structure is close; row height, background, divider, bottom position text differ. | Match ListTile density, divider and footer text. |
| 004 | 滑动到指定位置 | tap footer | fixed | `onLoad` now generates runtime-random heights and footer scrolls/highlights index 13. | Recheck jump screenshot. |
| 005 | 滑动到指定位置2 | tap footer | fixed | `onLoad` now generates runtime-random card heights and footer scrolls/highlights index 12. | Recheck jump screenshot. |
| 006 | 展示渐变带边框的文本 | scroll | P2 | Number is close; top copy and gradient stroke/border are weaker. | Complete gradient text/border schema usage. |
| 007 | Transform 效果展示 | scroll | P2 | Card position, image scale/crop, and transformed anchor differ. | Match transform matrix, anchor, image sizing. |
| 008 | 计算另类文本行间距展示 | scroll | fixed | Source parity recheck: JSON uses the same 20px margin, blue-grey body, `translateY:-7.2`, font size 16 and forced strut leading 0.9. | No further visual action. |
| 009 | 简单上下刷新 | pull/scroll | fixed | Source parity recheck: JSON starts with `initialRefresh`, fills 30 `refresh` rows, keeps a bottom load-more indicator, and appends 30 `loadmore` rows like upstream. | Previous 0-11 vs 9-20 capture was a scroll-position snapshot difference. |
| 010 | 简单上下刷新2 | pull/scroll | fixed | `cupertino_refresh_list` with `initialRefresh` now renders and restores refreshed list content instead of blanking after interaction. | Recheck pull/load-more screenshots. |
| 011 | 简单上下刷新3 | pull/scroll | P2 | JSON no longer blanks and uses the generic custom Cupertino refresh indicator; source-specific release/notification details are still approximated. | Improve refresh-state builder only as a generic capability. |
| 012 | 通过绝对定位布局 | scroll | P2 | Colored blocks are close; offsets, sizes, radius and background differ. | Tune positioned coordinates and sizes. |
| 013 | 气泡提示框 | tap | fixed | Generic `anchored_popover` now measures trigger rects and renders dismissible arrow bubbles. | Recheck four tap screenshots. |
| 014 | Tag效果展示 | scroll | P2 | Tags are too pale and spacing/wrap differs. | Match tag border, fill, padding and wrap spacing. |
| 015 | 共享元素跳转效果 | tap | fixed | Detail view now disables AppBar, uses the same hero-tagged cat image at screen-width size, and tap returns to the thumbnail screen. | True route Hero animation remains source-audit partial. |
| 016 | 滑动验证 | drag | fixed | Generic `slide_verify` now covers drag clamp, success lock, snap-back and thumb image. | Recheck with interaction screenshot. |
| 017 | warpContent实现 | scroll | fixed | Screen now uses bounded vertical scrolling around wrap-content layout. | Recheck scroll screenshot. |
| 018 | 状态栏颜色修改（仅 App） | scroll | fixed | JSON has the 3x toolbar cat image AppBar, white back icon, centered Light/Dart buttons and system UI overlay actions. | App-only initial AnnotatedRegion semantics remain source-audit partial. |
| 019 | 键盘弹出与监听（仅 App） | scroll/input partial | P2 | Keyboard was not truly validated; input area/text positions differ. | Add tap/input capture and tune input appearance. |
| 020 | 控件动画组合展示（旋转加放大圆） | animation | fixed | JSON now rotates the 200px green square and paints the expanding red circle on the source 3s loop. | Recheck animation frame timing. |
| 021 | 控件展开动画效果 | tap | fixed | Generic `circular_reveal` now matches the centered green 250px child and 500ms hide/show circular clip. | Recheck tap/reverse screenshots. |
| 022 | 全局悬浮按键效果 | tap/drag/long-press | fixed | Generic `overlay_spawner` now inserts a red circular overlay entry, supports dragging, and removes it on long press. | Recheck tap/drag/long-press screenshots. |
| 023 | 全局设置字体大小 | tap +/- | fixed | Uses upstream text and scoped `MediaQuery.textScaler` via `text_scale_scope`. | Recheck after tapping +/- controls. |
| 024 | 旧版实现富文本 | scroll | P2 | Content exists; title alignment, image baseline and spacing differ. | Tune rich text/image span baseline. |
| 025 | 官方实现富文本 | scroll | P2 | Mostly close; inline image and button dimensions differ. | Tune WidgetSpan/image/button sizing. |
| 026 | 第三方 viewpager 封装实现 | swipe | P2 | Extra blue borders/dividers; swipe state not obvious. | Remove debug borders and validate page transition. |
| 027 | 列表滑动过程控件停靠效果 | scroll | fixed | JSON card items now use the supported `children` shape, restoring `Item N` rows; sticky button strip uses the source red header/orange button visual. | True NestedScrollView overlap/snap behavior remains source-audit partial. |
| 028 | 验证码输入框 | tap input | fixed | Generic `code_input` uses hidden `EditableText`, digit filtering and rectangle cells. | Recheck focus/input screenshot. |
| 029 | 验证码输入框2 | tap input | fixed | Generic `code_input` uses controller-backed PIN cells and bullet display. | Recheck focus/input screenshot. |
| 030 | 自定义布局展示效果 | tap footer | fixed | Generic `radial_layout` and Scaffold footer buttons now show the circular nodes and 加/减 controls. | Recheck add/remove interaction. |
| 031 | 自定义布局实现云词图展示 | initial | fixed | Generic `spiral_flow` now computes non-overlapping spiral placement instead of hard-coded coordinates. | Recheck initial screenshot. |
| 032 | 列表滑动停靠 （Stick） | scroll | P2 | Overall close; header text/icon/line/background details differ. | Tune sticky header details. |
| 033 | Stick + 展开收回 | tap/scroll | fixed | JSON now keeps 50 sticky sections collapsed by default, uses 150px pink content rows, gray 50px 查看更多/收起 rows, and toggles section state like the source. | Source-level animation, close scroll correction and custom StickWidget precision remain partial. |
| 034 | Stick 2 | scroll | P2 | Structure close; colors, dividers, text weights and sticky movement differ. | Tune colors and capture sticky offset. |
| 035 | 键盘顶起展示（仅 App） | scroll/input partial | P2 | Body close; Web did not validate keyboard lift. | Add input focus capture, tune bottom input. |
| 036 | Blur 高斯模糊效果 | scroll | fixed | Source parity recheck: JSON uses the cat image background, centered 200x200 rounded BackdropFilter with sigma 8, icon and text. | No further visual action. |
| 037 | 控件动画变形效果 | tap | fixed | Source parity recheck: JSON starts as the same 50x50 green rounded square and FAB randomizes size/color/radius with 1s fastOutSlowIn animation. | No further visual action. |
| 038 | 时钟动画绘制展示 | scroll | P2 | JSON now has center time/date and dense hour/minute/second text rings, but lacks CustomPainter angle highlighting and exact live rotation math. | Add generic clock/text-ring painter only if this fidelity matters beyond visual approximation. |
| 039 | 按键切换动画效果 | tap | P2 | X shape close; background/FAB style and initial state differ. | Tune FAB and page styling. |
| 040 | item 停靠动画效果 | scroll | P2 | JSON has the cat header, amber StickText card, card list, translucent top bar and sticky item; top appbar alpha and header marginEdge are still approximate. | Add continuous alpha/margin interpolation only via generic expression support. |
| 041 | item 停靠动画效果2 | scroll | P2 | JSON matches the same header/list/top bar structure and uses delayed slide visibility for the sticky item; exact AnimatedSwitcher curves remain approximate. | Tune animation curves if visual capture still differs materially. |
| 042 | 下弹筛选展示效果 | tap top | fixed | JSON now opens the correct filter panels with mask, grouped expand grid, grouped grid menu, normal list, reset and confirm controls. | Recheck tap/select screenshots. |
| 043 | 文本弹出动画效果 | tap | fixed | JSON now runs the source staggered slide/fade reveal and reverse with an in-flight guard. | Recheck after tapping FAB. |
| 044 | 自定义滑动与停靠结合 | scroll | P2 | JSON has the custom header image, red/image layer, 2-column grid, footer controls and pinned/minHeight/autoBack labels; pull-trigger `CustomSliver.handleShow/Hide` behavior is still approximate. | Runtime gap remains custom pull/sliver callbacks. |
| 045 | 自定义列表内 sliver 渲染顺序 | scroll | P2 | Main structure close; tab/grid colors and text placement differ. | Tune sliver colors and order. |
| 046 | 点击弹出动画提示 | tap partial | P2 | Capture likely missed trigger; background/text details differ. | Add accurate tap target and tune tip layer. |
| 047 | 停靠展开+回到当前头部 | scroll | P2 | JSON now uses default headers without top icons, 3 visible items, conditional 查看更多/收起 rows and per-section expansion. | Current-header overlay/jump still needs generic sliver offset inspection. |
| 048 | overflow 图片 | scroll | P3 | Close; crop height and blue region start differ slightly. | Tune overflow image size/crop. |
| 049 | Align 排布控件 | scroll | fixed | Generic `align` now supports arbitrary `alignmentX/alignmentY`, and JSON places 20 dots using the source `cos(index*pi/40), sin(index*pi/40)` formula. | No further visual action. |
| 050 | 尺寸比例展示 | scroll | P2 | Layout close; image size, wrapping, card border and blue area differ. | Tune card/media sizing. |
| 051 | 多列表+顶部 Tab | tap tab/scroll | fixed | JSON renders tab lists, active/inactive tab colors, cyan indicator, and tap-driven list swaps. | Nested shrink-on-scroll fidelity remains source-audit partial. |
| 052 | 多列表+顶部 Tab2 | tap tab/scroll | fixed | JSON renders the list content and source-style tab colors/indicator; tap switches pages. | PageView swipe and NestedScrollView coupling remain source-audit partial. |
| 053 | 多列表+顶部 Tab3 | tap tab/scroll | fixed | JSON renders tab list content with source-style tab colors/indicator and keeps scroll-driven icon shrink approximation. | PageView/scroll notification fidelity remains source-audit partial. |
| 054 | 仿真书本翻页动画（仅 App） | drag/tap partial | P2 | JSON now uses the source teal/yellow page palette, source text, pan/tap-down curl state, and JSON-level a/f/g/e/h/c/j/b/k/d/i-inspired fold geometry instead of a static yellow page. Exact offscreen text reflection, path difference and cancel animation still differ. | Add only generic path-combine/layer-transform/cancel animation primitives if exact curl parity is required. |
| 055 | 粒子动画效果 | wait/scroll | P2 | JSON now uses `animated_canvas` linear gradient plus 30 large translucent seeded particles. Exact upstream random restart timing remains simplified. | Recheck animation screenshots and tune particle timing if needed. |
| 056 | 动画背景效果 | wait/scroll | P2 | JSON now uses `animated_canvas` mirrored gradient and three JSON-formula wave paths. Exact `simple_animations` timing remains approximate. | Recheck animation screenshots and tune phase/easing if needed. |
| 057 | 手势效果 | drag | P2 | JSON renders the dark gradient plus original/inverse/transformed paths, and now consumes true multi-pointer pan/scale/rotation deltas from generic `transform_gesture`. | Recapture drag/pinch screenshots; remaining work should be visual tuning only. |
| 058 | 底部跟随和停靠 | scroll | P2 | JSON now uses generic `measured_box` RenderBox data for content bottom, viewport clamp and bottom padding; add/remove flow is measured rather than length-estimated. | Recapture add/remove screenshots; remaining work should be visual tuning only. |
| 059 | 圆形选择器 | tap bottom | P2 | JSON now opens a real transparent bottom sheet and renders the 18-item circular selector; Swiper arc/scale animation still needs visual tuning. | Recapture tap-bottom screenshots and tune arc motion. |
| 060 | 堆叠卡片 | drag | P2 | Card stack now uses draggable cancel offset thresholds instead of swipe shortcuts; image assets/crop still need visual recapture. | Recapture drag behavior and normalize assets if needed. |
| 061 | 堆叠卡片2 | drag | P2 | Drag threshold removal now uses draggable events; spring-back motion and image assets still differ. | Add spring-back alignment or tune visual behavior. |
| 062 | 动画按键 | tap | P2 | Background/copy close; icon state and spacing differ. | Tune button state machine and icons. |
| 063 | QQ 发送图片动画 | tap | P2 | JSON renders the source-sized image, overlay/progress state and finish indicator; painter blend/radial mask still differs. | Add generic blend-mask painter support for exact parity. |
| 064 | 探探扫描动画 | tap | P2 | JSON renders centered scan ring, rotating sweep line, ripple rings and avatar; sweep gradient/spring scale remain simplified. | Add generic sweep-gradient/ripple lifecycle support for exact parity. |
| 065 | 圆弧形 SeekBar | drag | fixed | Pure JSON formulas now map drag angle to progress and render the arc/thumb through `animated_canvas` segments/circles. | Recheck drag screenshot. |
| 066 | 口香糖动画 | tap | P2 | JSON now uses `particle_stream_canvas` to append/cap particles at the source cadence with HSL linear/radial highlights. | Exact platform-specific painter rotation/highlight behavior still needs visual recapture. |
| 067 | Canvas 闹钟 | scroll | P2 | JSON now draws source-style alarm ears, head pin, feet, blue ring, tick marks and hands in one canvas. | Exact path ears, real-time hand angles and bounce rotation still differ. |
| 068 | boss 我的页联动 | scroll | P2 | JSON renders the header/profile/list structure and scrolls; linked flexible-space collapse and tab/list coupling still differ. | Add generic linked sliver behavior for exact parity. |
| 069 | Matrix 拖拽 | drag | P2 | Drag now updates continuous pan/scale/rotate through `transform_gesture`; remaining risk is image sizing/crop parity. | Recapture drag/pinch screenshots. |
| 070 | 彩色进度条 | animation | fixed | Generic `gradient_progress` now reproduces source layered gradients, borders, delayed fill and bounce repeat bars. | Recheck animation frames. |
| 071 | 动画字体 | wait/scroll | fixed | JSON now renders the nine source animated text examples with cycling title, tap count and animated stages through generic `animated_text`. | Recheck animation timing screenshots. |
| 072 | 首尾添加数据不抖动 | tap FAB | fixed | JSON now uses reverse centered slivers, source-style AppBar actions, Send FAB, 20-item append actions, and newest-edge scroll after send. | Recheck scroll-anchor screenshot. |
| 073 | 首尾添加数据不抖动2 | tap FAB | fixed | JSON has source-style Send FAB, labeled AppBar actions, 20-item old/new append, snackbar branch, and bottom scroll action. | Exact extentAfter and recursive scroll remain source-audit partial. |
| 074 | 路由嵌套 | tap | P2 | Layout is recognizable but sidebar/content proportions differ. | Tune sidebar width and nested route card. |
| 075 | canvas 阴影 | scroll | P2 | JSON now uses two source-height static wave/shadow canvases with value=50, blue overlay and black blur. | Exact `ui.Gradient.linear`/MaskFilter shader fidelity remains approximate. |
| 076 | 控件动画切换 | tap | fixed | JSON shows the 300px three-block animated layout and FAB cycles the positions. | Recheck animation screenshots. |
| 077 | ListView 嵌套 ViewPager | swipe | P2 | Gesture touchSlop scope now matches source; list row density and swipe screenshots still need visual confirmation. | Recapture diagonal swipe behavior. |
| 078 | 垂直 ViewPager 嵌套 ListView | swipe/scroll | P2 | JSON builds the nested page/list structure and now uses generic `scroll_drag_handoff` to switch drag ownership from list to page at the list bottom. | Recapture vertical drag interaction and tune hit testing/keepAlive details. |
| 079 | ListView 嵌套 ViewPager | scroll | P2 | JSON now uses generic `scroll_drag_handoff` for the first 300px page area and returns control to the list at the page boundary; colors/spacing are close. | Recapture vertical drag interaction and tune source direction thresholds. |
| 080 | ListView 联动 ListView | scroll | fixed | JSON renders the source side-by-side green/orange 55-item lists and now links the secondary offset at the source 1/30 ratio. | Recapture linked scroll interaction. |
| 081 | 3D 透视卡片 | drag/scroll | P2 | Card content and parallax layers now render with generic positioned sizing; perspective/shadow still differ. | Tune gradient/shadow and drag clamp limits. |
| 082 | 3D 卡片旋转 | animation | P2 | Front/back card body and overlays now render; rotation remains a transform approximation. | Fine tune radian mapping and asset sizing. |
| 083 | 硬核 3D 卡片旋转 | animation | P2 | JSON now uses `projected_scene` with front/back card images, card thickness, back text and source-style z-path number strokes. | True ZFlutter backface/orientation precision still differs. |
| 084 | 3D Dash | animation | P2 | JSON now uses `projected_scene` geometry nodes for body, wings, hair, eyes and beak with drag rotation and smooth flight. | Tune exact ZFlutter arcs, wing-axis rotation and delayed flight intervals. |
| 085 | canvas transform | scroll | fixed | JSON now draws source-positioned red rounded strokes inside a centered 200x200 canvas instead of widget rectangles. | Recheck with upstream screenshot because the first source line is clipped at y=-100. |
| 086 | rive 掘金 logo | animation | fixed | JSON now loads the real `.riv` file from OSS through generic `rive_animation`. | Widget tests skip network Rive loading because Flutter test blocks HTTP. |
| 087 | 掘金 3d logo | animation | fixed | JSON now renders the source blue logo polygon point sets with drag rotation. | True ZFlutter depth/projection remains approximate. |
| 088 | 掘金更 3d logo | animation | P2 | JSON box-logo layers now render after generic positioned sizing support; depth is still a 2D approximation. | Add a generic 3D box primitive if exact ZFlutter parity is required. |
| 089 | png shadow | scroll | fixed | JSON now renders the source-sized image with a blurred offset PNG shadow. | Recheck exact blur spread against upstream screenshot. |
| 090 | path 路径 png 效果 | scroll | fixed | JSON now uses generic `image_shader_path` for the repeated cat ImageShader stroke and clipped 1px grid in the 200x200 green panel. | Recheck screenshot against upstream shader scale. |
| 091 | BottomSheet 联动 | drag sheet | P2 | JSON now renders a persistent bottom Header/body sheet instead of opening a modal, and uses drag-up/down state plus background list/page handoff. | Recapture sheet drag and tune max height/snap behavior. |
| 092 | DraggableSheet stick | tap FAB | P2 | Sheet now starts near half-screen and expands close to fullscreen over the 300px cat header; drag extent and pinned sliver coupling still differ. | Add generic draggable sheet behavior for exact parity. |
| 093 | 异步调用顺序执行 | partial | P3 | Both mostly blank; script likely did not trigger async flow. | Add click sequence for validation. |
| 094 | 点击爆炸五角星 | tap | fixed | Pure JSON state and `animated_canvas` formulas now draw the five-point star and tap-triggered particle burst. | Recheck tap screenshot. |
| 095 | 有趣画廊 | swipe | P2 | JSON now renders the colorful 5x5 gallery grid and swipe translation; animated cutout overlay remains simplified. | Recreate cutout overlay animation for exact parity. |
| 096 | 文本撕裂动画 | tap | P2 | JSON now shows glowing text plus clipped gradient/italic tear layers driven by two periodic triggers. | Exact random polygon tear shape per frame remains approximate. |
| 097 | 自适应横竖列表 | scroll | P2 | JSON now uses generic `cross_axis_sizing_list` for both horizontal sections so list height is measured from children rather than fixed. | Random source text and some render edge cases still differ. |
| 098 | PageView 嵌套 PageView | swipe | P2 | JSON builds nested PageViews and now uses generic horizontal `scroll_drag_handoff` to transfer control between inner and outer controllers at page boundaries. Exact overscroll notification/correctPixels behavior still differs. | Recapture horizontal drag and tune page-boundary handoff if needed. |
| 099 | 手势密码 | gesture | fixed | JSON now uses a real pan-driven 3x3 gesture password board, draws the path while dragging, emits the joined password on release and clears selected dots. | Recheck gesture capture. |
| 100 | link scroll | click/scroll | fixed | JSON now renders the dual-list layout and implements left-tap/right-scroll bidirectional selection through generic scroll offset actions. | Recapture click and right-scroll interaction. |
| 101 | glass | scroll | P2 | Main card close; background bubbles/card/button spacing differ. | Tune glass card and background. |
| 102 | liquid glass | drag | P2 | JSON uses the source iOS26 texture and draggable blur lens approximation; real shader sampling/refraction still differs. | Add generic FragmentProgram/image-sampler support or improve lens approximation. |
| 103 | liquid glass 2 | drag | P2 | JSON uses the source person texture and draggable blur lens approximation; real shader sampling/refraction still differs. | Add generic FragmentProgram/image-sampler support or improve lens approximation. |
| 104 | 粒子动画 | scroll | P2 | JSON now shows the source mode label, Switch button and four color-coded attractor approximations. | Exact persistent particle simulation and reset behavior still need a generic stateful particle primitive. |
| 105 | 斐波那契球体动画 | scroll | P2 | JSON now includes the source five-control panel and feeds points, speed, wobble, size and trails into the sphere canvas. | Exact particle density, trail strokes and custom capsule slider thumb remain approximate. |
| 106 | 星云动画 | scroll | P2 | JSON now has dark background, cyan two-arm star field, pulsing bright core blobs and black-hole ovals. | Exact 30k-particle physics, opacity cycle and turbulence remain approximate. |
| 107 | 霓虹滑块 | drag | P2 | JSON now renders a single black neon capsule that handles tap/drag directly and updates the in-bar percentage. | Flash burst, hysteresis threshold and exact gradient glow remain approximate. |
| 108 | Radial lines | scroll | P2 | JSON now renders layer-to-layer projected cube vertex lines instead of a 2D center spiral; exact Perlin bends still differ. | Add generic continuous noise expression if exact source field is required. |
| 109 | 爆炸粒子 | drag partial | P2 | JSON now keeps the centered `点击，拖拽` prompt visible and overlays a denser interactive cyan particle field. | True persistent velocity field and explosion impulse remain approximate. |
| 110 | Black hole | scroll | P2 | JSON now has bright upper/lower lensing arcs, front/back accretion particles and layered black core masks. | Exact 12000-particle flow and distorted core edge remain approximate. |
| 111 | 流体太极 | scroll | P2 | Same concept but smaller/sparser. | Increase density/scale and tune yin-yang shape. |
| 112 | 黑洞流体 | scroll | P2 | JSON now shows a white-hole glow, black-hole core and S-shaped white particle stream on a black stage. | Real respawn/swallow physics and pointer perturbation remain approximate. |
| 113 | 太极粒子 | tap mode | P2 | JSON now has the source-style 柔和圆/几何S形 mode button; exact particle emission/death shape remains approximate. | Refine stateful particle lifecycle or canvas formulas. |
| 114 | 破坏杀·罗针 | scroll | P2 | JSON now removes the full-screen character background and renders the glowing cyan compass motif with branches, hexagons, endpoint marks and a small center character. | Exact staged drawing, tilt and replay button still need generic animation sequencing. |
| 115 | 骚气滑动列表 | scroll | P2 | JSON now has the black stage, source control text and Twist slider; the custom 3D tornado item transform is still missing. | Add generic scroll-linked 3D item transform if exact effect is required. |
| 116 | 骚气粒子效果 | tap controls | P2 | JSON now has SPHERE/CUBE/TORUS/HEART labels, left/right controls and random/structured distribution toggle; particle shape interpolation remains approximate. | Refine morphing particle formulas. |
| 117 | 炫酷圣诞树 | scroll | P2 | JSON now shows the formula HUD plus red spear, gold ribbon, green orbit particles and top light; exact 3D depth/tap shake still differs. | Tune 3D projection and tap shake if exact painter parity is required. |
| 118 | 炫酷二维码 | tap Start | P2 | Initial page now matches the white input + Start entry flow and navigates to a particle page; particle distribution still differs from the QR-derived source painter. | Refine particle generation and mode controls. |
| 119 | Cool Disco Sphere | tap mode | P2 | JSON now starts with a dark purple/silver sphere and source-style `模式: 纸张铺开` button; tile quads, hover offsets and breathing burst remain approximate. | Refine 3D tile rendering and hover behavior. |
| 120 | Cool Spatial Grid | tap mode | P2 | JSON now starts in the source-style white grid mode with black dark-mode FAB and can toggle to cyber mode; pointer deformation and moving beams remain approximate. | Refine pointer-driven grid deformation. |
| 121 | Shock Wave Chat | initial | fixed | JSON now matches the upstream Web fallback message for the shader-only effect instead of rendering a different chat/particle scene. | Native shader parity still needs screenshot texture + FragmentProgram support. |
| 122 | Particle Effect | tap mode | P2 | JSON now includes ground rings, central beam/fountain particles, background points and source-style NORMAL/CYBER mode button; exact particle reset and cyber wave layers remain simplified. | Refine cyber-mode particle formulas. |
| 123 | Mosaic Scanner | scroll | fixed | JSON now matches the upstream Web fallback: empty AppBar plus centered unsupported-Web message. | Native shader parity still needs generic FragmentProgram support. |
| 124 | Koi Fish | scroll | fixed | JSON now renders the upstream-style black background and dense white point-formula koi silhouette. | Recheck mobile frame time after full-suite run. |
| 125 | Jaw Control | drag | P2 | JSON now matches the dark preview/panel structure, mode buttons, UI-size slider, duration slider and trigger button, with a formula-drawn jaw preview. | Anatomical 3D tooth projection and one-shot controller remain approximate. |
| 126 | Fire Shader | scroll | P2 | JSON uses a full-screen turbulent fire grid with source-inspired UV twist, heat, ember and smoke formulas. | Exact ray-marched FragmentProgram needs a compile-time shader asset pipeline. |

## Framework Specificity Check

Command:

```bash
rg -n "gsy|GSY|gsy_flutter|procedural_visual|floating_touch_demo|star_burst_canvas|arc_slider|bubble_button|rotating_circle_painter|wave_painter|particle_burst_button" lib test backend
```

Result: no matches.

Template namespace and source attribution still contain `gsy_flutter_demo`, which is expected because these JSON apps are published under that namespace and cite the upstream project. Future framework additions must be named by reusable capability, for example `animated_canvas`, `linked_list_view`, `transform_gesture`, `measured_box`, `path_clip_image`, or `fragment_shader`, never by the source app/project. Scene formulas should be expressed in JSON whenever the existing expression language can model them.

## Next Fix Queue

- Immediate P0: `010-refresh-demo-page2`, `011-refresh-demo-page3`, `100-link-list-view-page` were retested after the first repair pass. They now render usable list content in `/tmp/ai-app-gsy-audit/screens_after_p0_fix_v5/`, so they are no longer P0. Remaining work is visual and interaction parity.
- No remaining P1 rows. Next visual queue is high-impact P2 interaction fidelity: `063`-`069`, `075`, `078`, `091`-`098`, and shader/particle scenes where screenshots still differ.
- Visual primitive review: ensure `animated_canvas` remains generic, remove any JSON template that only selects a hidden hard-coded visual mode, and reject Dart painters that encode a scene-specific formula when JSON expressions can express it.

## Repair Log

- 2026-06-01: Fixed a generic screen layout bug where list-containing screens were forced into `Column`, ignoring `screen.layout: row`. This restored side-by-side layouts such as scene 100.
- 2026-06-01: Registered `cupertino_refresh_list` as a bounded-height list surface and added generic `initialRefresh` support so Cupertino refresh demos can populate data on entry without relying on fragile programmatic overscroll.
- 2026-06-01: Reworked scene 100 JSON to use explicit `Expanded(flex: 1)` and `Expanded(flex: 2)` containers, matching upstream dual-list proportions more closely.
- 2026-06-01: Added a generic JsonLogic evaluation path for widget/sliver
  scalar fields and visibility conditions. This fixes scenes where `count`,
  `visible`, transform values, or positioned offsets were valid JsonLogic maps
  but were previously treated as non-true data.
- 2026-06-01: Added generic `circular_reveal` and explicit
  `animated_canvas.width/height` support, then moved scene 021 away from a
  simple slide/fade approximation toward upstream circular clipping behavior.
- 2026-06-01: Added framework settings UI for explicit `system/light/dark`
  theme mode, persisted through `SharedPreferences` and shared with JSON
  `@set_theme` / `@get_theme`.
- 2026-06-02: Added generic `slide_verify`, `code_input`,
  `text_scale_scope`, and `spiral_flow`. Updated scenes 016, 017, 023, 028,
  029, and 031 from source-level non-parity to source-equivalent
  JSON/runtime implementations.
- 2026-06-02: Reworked scenes 004 and 005 to generate their item heights at
  runtime through existing JSON actions instead of storing static template
  lists.
- 2026-06-02: Added generic `anchored_popover` and moved scene 013 from
  inline hard-coded white boxes to measured trigger popovers with arrows.
- 2026-06-02: Added generic `gradient_progress`. Updated scenes 020, 021, 030,
  043, and 070 so their animation/state flows are expressed by reusable runtime
  primitives plus page-specific JSON, not source-project bridges.
- 2026-06-02: Added generic `overlay_spawner` and moved scene 022 from a
  single toggled floating layer to source-style overlay entry insertion, drag,
  and long-press removal.
- 2026-06-02: Rebuilt scene 042 as pure JSON state: three dropdown menus, overlay mask, grouped expansion, multi-select lists with `全部` conflict handling, reset/confirm actions, and normal single-select by index.
- 2026-06-02: Added generic `list.intrinsicHeight:false` for complex list items that contain their own shrink-wrapped viewport, preventing Flutter intrinsic measurement assertions without changing default list behavior.
- 2026-06-02: Tuned scenes 051-053 tab headers to source-style active cyan, inactive translucent white, and cyan indicator; added interaction coverage for 051. Confirmed scene 076 FAB cycles its animated three-block layout.
- 2026-06-02: Added generic `custom_scroll_view.reverse` and AppBar labeled actions. Updated scenes 072/073 to source-style chat FAB/actions and append behavior.
- 2026-06-02: Updated visual audit for scenes 002 and 080 after confirming current templates already render the source initial layouts; source audit for 080 remains mismatch because linked drag is not modeled.
- 2026-06-02: Updated scene 015 detail route JSON: heroTag on both images, no detail AppBar, screen-width detail image, and tap-back behavior.
- 2026-06-02: Added generic JsonLogic math ops, `animated_canvas.variables`,
  `animated_canvas.linear_gradient`, and paint `blurRadius`. Reworked scenes
  055, 056, 065, and 094 so their gradient, wave, arc, star and particle
  formulas live in JSON. Removed the dedicated `arc_slider` and
  `star_burst_canvas` Dart widgets.
- 2026-06-02: Reworked scene 057 into JSON-formula canvas paths for original,
  inverse and transformed rectangles, with pan-driven matrix variables. Reworked
  scene 058 into JSON computed layout for content height and follower-button
  position.
- 2026-06-02: Added generic `transform_gesture` and `measured_box`, then
  updated scenes 057/058 so true transform input and RenderBox measurement are
  exposed as data while scene-specific math stays in JSON. Visual screenshots
  should be recaptured before changing their severity.

- 2026-06-02: Updated scenes 059, 069, 077, 080, and 100 after adding generic bottom-sheet options, scroll offset actions, list physics, and gesture-settings scope.

- 2026-06-02: Updated scenes 060/061 to use generic draggable cancel events and JSON threshold removal instead of swipe-only shortcuts.
- 2026-06-02: Added generic `animated_text` and `gesture_password`. Updated scenes 071 and 099 to source-style animated text cycling and pan-driven password paths. Updated scene 118 entry flow and scene 123 Web fallback in JSON.
- 2026-06-02: Updated scene 119 with source-style mode FAB state and purple/silver initial palette.
- 2026-06-02: Updated scene 120 with source-style white grid initial mode, dark-mode FAB and cyber toggle.
- 2026-06-02: Updated scene 121 to match upstream Web fallback for the shader-only shock-wave effect.
- 2026-06-02: Updated scene 122 with ground rings, central beam/fountain particles, background points and NORMAL/CYBER mode button.
- 2026-06-02: Reclassified scenes 102/103 after validating current templates use source textures and draggable blur-lens approximations; shader parity remains a runtime gap.
- 2026-06-02: Updated scene 113 with source-style 柔和圆/几何S形 mode button.
- 2026-06-02: Updated scene 116 with source-style shape labels, side controls and random/structured distribution toggle.
- 2026-06-02: Updated scene 115 with the black stage, `Twist Intensity (Zoom)` label and interactive slider; the remaining difference is the generic 3D scroll transform.
- 2026-06-02: Updated scenes 104, 106 and 125 after adding generic rect/oval particle drawing to `animated_canvas`; these pages now carry their source controls and key visual structure instead of placeholders.
- 2026-06-02: Reworked scene 054 from a static yellow page into a JSON-formula drag curl approximation with source text/palette and path clipping. It remains source-audit partial because exact `PathOperation` difference, offscreen text reflection and cancel animation need generic runtime primitives.
- 2026-06-02: Added generic scroll drag handoff and updated scenes 078/079 so the nested list/page demos no longer rely on native nested scrolling.
- 2026-06-02: Reworked scene 091 to use a persistent draggable bottom sheet layer instead of a modal bottom sheet, with JSON height state and background scroll handoff.
- 2026-06-02: Updated scene 098 with horizontal nested PageView controller handoff, replacing passive native nesting.
- 2026-06-02: Updated scene 107 into a single tap/drag neon capsule instead of a display bar plus separate system slider.
- 2026-06-02: Updated scene 075 to source-style static 100px wave/shadow canvases and removed the 9999px placeholder width.
- 2026-06-02: Updated scene 067 from stacked boxes to a single formula-driven alarm-clock canvas.
- 2026-06-02: Updated scene 105 with source-order POINTS/SPEED/WOBBLE/SIZE/TRAILS controls and canvas variables.
- 2026-06-02: Updated scene 110 with layered accretion disk, lensed arcs and black core masks.
- 2026-06-02: Updated scene 109 to keep the prompt visible under a denser transparent particle canvas.
- 2026-06-02: Updated scene 112 to a white-hole/black-hole S-flow composition instead of the covered horizontal cloud.
- 2026-06-02: Updated scenes 066, 083, 084, 086, 090 and 097 after adding generic particle-stream, projected-scene, Rive, ImageShader-path and cross-axis-sizing-list primitives; scene 126 remains a JSON fire approximation because Flutter FragmentProgram requires a compile-time shader asset.
