# NESd 移植 · Web 端性能分析与优化方案

> 结论固化文档。记录 NES 模拟器 JSON-App 在浏览器里「能跑但卡到无法玩」的根因、
> 一次大规模联网调研(deep-research)的结论、以及在 **保持 JSON/框架隔离**
> (绝不把 NES 逻辑写进框架层)前提下的四条优化路径。
>
> 相关代码:`lib/json_ui/compute/compute_kernel.dart`(通用 compute 内核)、
> `lib/games/game_compute.dart`(GameCompute 封装)、`lib/games/flame_game_engine.dart`
> (逐帧驱动)、`scripts/nesd/gen_nes.py`(生成 NES 模拟器 JSON 程序)、
> `templates/demo_nes.json`(内嵌内核 + demo)。可行性背景见
> `docs/nesd-port-feasibility.md`。

## 1. 结论(TL;DR)

- **是性能问题,不是 bug。** 点击能响应、游戏能启动,只是渲染与输入被拖到肉眼可见的慢。
- **实测约 1.5 fps**(正常 60 fps):用户观察到「金币约 20 秒闪一次」,而真机约 0.5 秒
  → **约 40× 慢** → 60 / 40 ≈ 1.5 fps。所有卡顿(含「点击无响应」)都由此派生。
- **根因**:JSON 编译成的闭包树内核,每帧要执行 **几百万次闭包调用**,并且
  **同步跑在主 isolate(UI 线程)** 上,浏览器(无 JIT、单线程)算不完一帧。
- **`--wasm` 已上线(约 2×),仍不够**;需要更大的杠杆(Worker 卸载 + 逐扫描线 PPU)。

## 2. 症状与量化

| 观测 | 数值 |
|---|---|
| 金币动画一个循环 | 实测 ~20s / 真机 ~0.5s → **~40× 慢** |
| 推算模拟帧率 | **~1.5 fps**(目标 60) |
| 点击 | 大量丢失/延迟(主线程被 `run_frame` 占住) |
| `--wasm` 后 | 约 2× → ~3 fps,**仍不可玩** |

「点击无响应」不是输入 bug:输入链路已验证正确(屏幕手柄 → `@flame_game_input` →
`vars.pad` 位运算 `bit_or`/`bit_and` → `@compute.set_input` → 控制器 `$4016`;控制字累加有
单测)。真正原因是低帧率 + 主线程阻塞(见 §3.3)。

## 3. 根因分析

### 3.1 架构:JSON 数据 → 通用 compute 内核
`compute_kernel.dart` 把 JSON-AST **一次性编译**成一棵 `int Function(_Ctx)` 的 Dart 闭包树
(不是逐次解释 AST)。locals 用 `Int32List`(未装箱),缓冲区用 `Uint8List`/`Int32List`。
所以瓶颈**不是**装箱、也不是重复解析 AST,而是 **每个操作 = 一次闭包调用** 的分派开销。

### 3.2 每帧工作量(为什么闭包调用数是几百万)
一帧 NES(NTSC):

- CPU ≈ **29,780 周期/帧**;每次 CPU 总线周期驱动 PPU 走 3 个点
  → **~89,342 次 PPU 逐点更新/帧**(262 扫描线 × 341 点)。
- CPU 指令 ≈ **8,500 条/帧**(平均 ~3.5 周期/指令)。
- 每个 PPU 点、每条 CPU 指令都是多个闭包调用(背景取数流水线、精灵合成、像素输出、
  取指译码执行……)→ **每帧约几百万次闭包调用**,PPU 逐点部分是绝对大头。

要 60fps 就需要每秒约 **1.5–2.5 亿次闭包调用**,浏览器远远达不到 → 落到 ~1.5 fps。

### 3.3 主线程同步执行(为什么 UI/点击冻结)
`GameCompute.call(run_frame)` 是**同步**的,`flame_game` 每个 tick 同步调用它,且
**全程无 isolate/worker 卸载**(代码里没有任何 `Isolate.spawn`/worker)。于是
`run_frame` 每帧把主线程占住几百毫秒,期间 Flutter 收不到指针事件 → 点击被延迟/合并/丢弃。
「有一次点击生效、游戏启动了」是因为长按恰好跨过了一次模拟帧的采样边界。

## 4. 平台调研结论(deep-research, 2026-07)

一次 5 角度、20 信源、25 条断言对抗式核验的联网调研,得到以下**硬约束**:

1. **Flutter Web 没有 Dart isolate。** `compute()` 在 Web 上就在主线程跑,`Isolate.spawn`
   在 Web 上崩溃。唯一能把重计算移出 UI 线程的办法是**浏览器 Web Worker**;Flutter 不内置,
   需第三方桥接(`isolate_manager`),或 Dart 3.7+ 的 `Isolate.run` 会被映射成 Web Worker。
   来源:docs.flutter.dev/perf/isolates、/platform-integration/web/faq、pub.dev/packages/isolate_manager。
2. **跨线程共享可变大缓冲(RAM/VRAM/framebuffer)需要 `SharedArrayBuffer`**,而它要求
   **跨源隔离**头:`COOP: same-origin` + `COEP: require-corp`(或 `credentialless`)。没有这些头,
   多线程 Wasm/skwasm 会**静默退化为单线程**。transferable 是「移交/detach」语义,不是共享。
   来源:docs.flutter.dev/platform-integration/web/{renderers,wasm}、github.com/cedeber/framebuffer-worker。
3. **dart2wasm(`flutter build web --wasm`/WasmGC,Flutter 3.24+)** 能加速数值循环
   (Google Wonderous:帧渲染约 2×,最坏 3×;某 CPU 密集测试约快 75%),**但会把流经
   顶层类型/泛型容器(dynamic/Object/List/Map/JSON)的整数装箱**,分配开销大。
   **本内核用 `Int32List` locals + 类型化缓冲,正好避开这个坑** → 是受益方。
   来源:dart-lang/sdk#60930、docs.flutter.dev/platform-integration/web/wasm。
4. **VM 分派**:闭包树本身**已经是**函数指针分派(direct call threading);换成
   switch-bytecode 循环**不会自动更快**,而最快的 threaded/computed-goto 在 dart2js/WasmGC 里
   **根本没法生成**。通用提速只能靠 **减少被分派的操作数**(超级指令、类型化 locals),
   而不是换分派方式。来源:Ertl & Gregg(jilp.org/vol5/v5paper12.pdf)、Zaleski 学位论文、
   github.com/ethanblake4/dart_eval。
5. **软件 PPU**:一帧 89,342 个 PPU 周期若逐点模拟极贵;**逐扫描线/逐 tile** 渲染能把固定的
   「每 8 像素 tile 取 4 次数、每次 2 周期」批处理掉,操作数数倍下降。来源:nesdev.org/wiki/PPU_rendering。

## 5. 四个优化杠杆(全部通用,保持隔离)

> 隔离原则:优化只允许作用于 **①通用 compute 内核、②通用渲染/音频/驱动管线、
> ③JSON 程序本身(NES 模拟器 = 数据)**。**绝不**把 NES 语义写进框架。

### 杠杆 1 — `flutter build web --wasm`(吞吐;近乎免费;先做)【已完成】
- 收益:约 2×(Wonderous)/ 约 75%(CPU 密集)。内核已用类型化数组 → 避开整数装箱坑。
- 改动:**仅构建开关**,零代码、零隔离影响。部署侧需 `.wasm` 用 `application/wasm`
  (nginx 已内置);要用 skwasm 多线程再加 COOP/COEP。
- **状态:已构建并部署到 77(WasmGC 浏览器走 wasm,其它回退 main.dart.js)。实测仍卡 → 单靠它不够。**

### 杠杆 2 — Web Worker 卸载(响应性;修「卡顿/点击无响应」)
- 把 `run_frame` 移出主线程 → **哪怕帧率还低,UI 与输入立刻跟手**(不再被几百毫秒阻塞)。
- 做法:Web Worker(`isolate_manager` / `Isolate.run`);framebuffer 回传用 `SharedArrayBuffer`
  (需 COOP/COEP,建议 `credentialless` 以免挡掉 registry/OSS 的跨源请求),或每帧拷贝
  61KB 的 fb(便宜)。
- 隔离:通用管线新增「在 worker 上运行任意编译好的 `ComputeProgram` + 回传其 framebuffer」
  的模式,**无 NES 语义**。工程量最大。

### 杠杆 3 — 逐扫描线 PPU(真正的提速大头;在数据层)
- 把 ~89k 逐点合并为逐扫描线/逐 tile 批处理 → 操作数数倍下降。
- 位置:全在 `scripts/nesd/gen_nes.py` → 生成的 NES 程序(**数据**),内核/框架不动 →
  完全符合隔离。
- 风险(必须工程处理):**SMB 用 sprite-0 命中做状态栏分割**;朴素逐扫描线会让 HUD/分割花掉,
  需要 sprite-0 感知的分割点。属高收益、高风险、大改动。

### 杠杆 4 — 超级指令(通用内核;增量)
- 闭包树已是 direct-call-threading;真正的收益是**减少分派次数** → 在编译器里融合常见操作序列
  (peephole 超级指令)。位置 `compute_kernel.dart`,通用,收益中等偏小。

## 6. 现状与建议
- 杠杆 1(wasm)已上线,实测**不够**(符合预期,2× 只到 ~3fps)。
- 建议顺序:**先杠杆 2(Worker)** 消除最扎眼的卡顿/点击无响应,**再杠杆 3(逐扫描线 PPU)**
  拿真正速度;杠杆 4 作为收尾增量。
- 诚实判断:**浏览器 + JSON 解释器是最坏组合**;同一份 JSON 在**原生/移动端**(真 isolate、
  无浏览器 VM 开销)会快很多——若目标平台允许,原生端可能不需要这么激进就流畅。

## 7. 需要警惕/存疑(核验中被证伪或未量化)
- **被证伪(0-3)**:①WasmGC 不是硬性前置(wasm 模式不支持时会回退 CanvasKit);
  ②「dart_eval 慢 10–50×/Ruby 级」不是可靠的实测天花板;③函数指针/switch 分派「几乎全预测失败」。
- **未量化**:没有针对「本类型化 VM 内层循环」的 dart2js vs dart2wasm 实测数字;
  dart2js 上 `SharedArrayBuffer` 有已知 `UnimplementedError`(dart-lang/sdk#49610),
  Worker 与 UI 真·共享同一块可变 RAM 在 dart2js 上可能走不通,或需 dart2wasm / 手写 JS interop。

## 8. 参考资料
- Flutter Web 并发/渲染器/Wasm:docs.flutter.dev/perf/isolates、
  /platform-integration/web/{faq,renderers,wasm}
- Web Worker 桥接:pub.dev/packages/isolate_manager
- dart2wasm 整数装箱:github.com/dart-lang/sdk/issues/60930(及 #52713/#52714)
- 解释器分派:Ertl & Gregg《The Structure and Performance of Efficient Interpreters》
  (jilp.org/vol5/v5paper12.pdf)、Zaleski 学位论文、github.com/ethanblake4/dart_eval
- NES PPU 时序:www.nesdev.org/wiki/PPU_rendering
- Worker + SharedArrayBuffer framebuffer 模式:github.com/cedeber/framebuffer-worker
