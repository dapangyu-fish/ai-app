# NESd（NES 模拟器）→ JSON 框架完整移植：可行性实测与缺失原语清单

> 任务：把 [jpjonte/NESd](https://github.com/jpjonte/NESd)（33k LOC 纯 Dart NES 模拟器）
> **完整移植进 JSON-DSL 架构**（明确排除"专用 NES 桥"方案）。
> 结论先行：**在当前框架下不可行，且差距是实测的 3 个数量级**；本文档给出
> 使其可行所需的**全部缺失原语**（分 7 层），其中表达式层原语已在
> `feat/nesd-primitives` 分支实现。所有数字均为实测或源码逐行统计，非估算的
> 标注为"推导"。

## 1. 结论

| 维度 | 需要 | 框架实测 | 差距 |
|---|---|---|---|
| 解释执行吞吐（综合） | ~1.0×10⁸ 原语操作/秒 | **62,700 步/秒**（裸算术封顶） | **~1,600×** |
| 6502 指令吞吐 | ~600,000 条/秒 | **12,600 条/秒**（6 指令最优切片实测） | ~48×（真实指令混合含大量位运算 → 120-230×） |
| 按位运算 | 每秒数百万次 | 算术仿真 **5,066 次/秒**（单次 ≈130 节点） | — |
| 帧缓冲 | 256×240×4 RGBA @60Hz 纹理上传 | 无任何像素缓冲原语 | 定性缺失 |
| 音频 | 48kHz Float32 推流合成 | 仅文件播放（文档明示无合成/混音） | 定性缺失 |
| 二进制 | ROM/存档 Uint8List、位掩码、LZ4、SHA-1 | 表达式层无字节缓冲、无位运算符 | 定性缺失 |

**即使把目标降到 1fps 幻灯片**（1/60 计算量 ≈ 1.7M 操作/秒），仍差 ~27 倍。
参照系：NESd 原生 Dart 在主 isolate 上跑这套逻辑（~3.6×10⁷ 操作/秒起步），
还需要 FFI malloc 帧缓冲 + 原生 C++ 纹理插件（`nesd_texture`，Method Channel
传裸指针零拷贝）+ miniaudio FFI 推流才能达到实时——**上游自己就是"解释层
不够用"的活证据**。

## 2. 实测方法与数据

基准应用：`scripts/bench_jsonlogic_throughput.py` 生成（flame_game +
`@loop_by_num` 每帧 N 次负载 + 屏上计数器，headless Chrome CDP 驱动，读数
来自截屏调试行）。环境为 headless CPU 渲染，真机约 2-4× 于此，不影响
数量级结论。

| 负载 | 内容 | 实测吞吐 |
|---|---|---|
| RAW | `a=(a+1)%256`（1 个 @set，2 节点表达式） | 60fps@n=100；封顶 **62.7k 步/s**（n=51200 时 1fps） |
| AND8 | 8 位按位与的算术仿真（逐位 `x/2^k - (x/2^k)%1` 分解，≈130 节点） | **5,066 步/s** |
| MEM | 2KB RAM 动态寻址读+写（`{"var":{"cat":["vars.ram.",addr]}}` + 模板路径写） | **16,000 步/s** |
| 6502 | 真实取指-译码-执行切片（LDA/ADC/STA/INX/BNE/JMP，含 Z/C 标志） | **12,600 指令/s**，寄存器/内存状态自洽（a=145、ram[16]=107 持续推进） |

关键定性实测：`@loop_by_num` 无上限但**与 UI 同线程**——n=51200 时整个应用
掉到 1fps（游戏逻辑无隔离执行环境）；动态列表寻址可用（`_walkPath` 支持
数字下标；写路径模板 `vars.ram.{{ addr }}` 可用）；表达式层无
`floor`/整除/位运算原语（均需算术仿真）。

## 3. NESd 需求量化（源码逐行统计）

- **CPU**（2,311 LOC）：256/256 opcode（105 个非官方全实现）、13 种寻址模式、
  逐周期时序（无周期表——每次总线访问=1 周期，含 dummy read/write 复现）、
  OAM DMA 513/514 周期、NMI/IRQ 边沿逐周期轮询。每指令 ≈60-120 原语操作
  （CLC≈45、LDA zp≈60、SLO (zp,X)≈150-180）。CPU 核心 **~185 处静态位运算**。
- **主循环**：CPU 为主时钟，**每个 CPU 周期**拉动 3 个 PPU 点 + APU 步进 +
  Mapper IRQ 计数（MMC3 的 A12 上升沿滤波要求 ≥3 CPU 周期低电平判定——
  时序精度是周期级，不可帧级近似）。
- **PPU**（1,716 LOC）：逐点（per-dot）渲染，89,341.5 点/帧 ×60；帧缓冲
  256×240×4 RGBA 写入 FFI malloc 内存，经 `nesd_texture` 原生插件裸指针
  上屏（Linux 端未实现时回退 `decodeImageFromPixels` CPU 路径）。
- **APU**（2,316 LOC）：5 通道 48kHz Float32 合成，音频时钟反过来驱动帧
  节奏（sleep = 样本数/48000 − 已耗时），mp_audio_stream(miniaudio FFI)
  50ms 环形缓冲 + 欠载/过载策略。
- **卡带**（3,619 LOC）：13 个 Mapper（MMC1/2/3/5、N163 等），1KB 粒度
  块表 MMU（`Uint8List.sublistView` 视图），iNES/NES2.0 头解析，SHA-1 建库
  索引，电池存档同步落盘。217 处位运算。
- **周边**：存档态 21-85KB 二进制（binarize），回放 = 每帧全量快照 ×3600
  帧环形缓冲（关键帧 + XOR 差分 + LZ4，FFI malloc 堆外内存），金手指
  Game Genie 位解扰，Zapper 光枪（读 PPU 像素亮度），调试器（断点/反汇编/
  执行日志），zip 虚拟文件系统，键盘/手柄和弦绑定 57 个动作。

## 4. 能力矩阵

| NESd 子系统 | 框架现状 | 可移植性 |
|---|---|---|
| 6502 CPU | jsonlogic 解释执行；无位运算/整除原语 | **形式可行（PoC 已证）、速度差 50-230×** |
| PPU 渲染 | 无像素缓冲实体；value_grid 为棋盘级 | **不可行**（6 万格/帧渲染+计算双重墙） |
| APU 合成 | @audio.* 仅文件播放 | **不可行** |
| 总线/RAM | List+动态路径可用（16k 步/s） | 慢 ~200×，形式可行 |
| Mapper MMU | 无字节视图/批量拷贝 | 形式可行，周期级 IRQ 时序不可行 |
| ROM 载入 | 无二进制资产读取（loadBytes 未暴露给 JSON） | **不可行** |
| 存档/回放 | 无二进制 blob 存储、无 LZ4/SHA-1 | 不可行（可降级为放弃回放） |
| 手柄 UI | analog_stick + gesture 组合（三次游戏移植验证） | **可行 ✓** |
| 菜单/设置/存档 UI | button/list/dialog/tab 全套 | **可行 ✓** |
| ROM 浏览器 | 无文件系统枚举原语（沙箱设计使然） | 需 OSS 侧列表替代 |
| 键盘（桌面） | 游戏 input 无键盘事件 | 缺失 |
| Zapper | 无 PPU 像素可读 → 依赖帧缓冲原语 | 随 T3 |

## 5. 缺失原语清单（穷尽，分层）

**T1 表达式层（已在 `feat/nesd-primitives` 分支实现）**
`bit_and / bit_or / bit_xor / bit_not / shl / shr / idiv`——注册进主解释器
jsonlogic 自定义算子 + 游戏逻辑白名单。收益：位运算步成本从 ≈130 节点降到
≈3 节点（推导：AND8 步 ≈ RAW 步 → ~12×提升）。**但总吞吐天花板仍是 62k
步/s，单独落地无法改变结论。**

**T2 数据层**：类型化字节缓冲原语
`@buf.alloc {id,size}` / `@buf.get {id,addr}` / `@buf.set` /
`@buf.fill/copy/slice`，底层 Uint8List；`@asset.load_bytes {url} -> buf`
（经 AssetCache）解决 ROM/存档二进制载入。

**T3 呈现层**：帧缓冲实体
`kind:"framebuffer", w,h`，绑定一个 buf，引擎每帧 `decodeImageFromPixels`
或纹理复用上屏（即 nesd_texture 的通用化）。对任意程序化图形（波形图、
赛璐璐动画、演示场景）都有通用价值。

**T4 音频层**：PCM 推流
`@audio.pcm_open {id, rate, channels}` / `@audio.pcm_push {id, buf|samples}`，
环形缓冲 + 欠载策略（即 mp_audio_stream 的通用化）。

**T5 输入层**：键盘按下/抬起事件进游戏 input 块（`input.key_down/key_up`
+ event.key）；手柄模拟量轴事件。

**T6 系统层**：受限持久化二进制 blob（存档 21-85KB，appId 命名空间下
读写）；可选：zip 解包、SHA-1（可由 T7 内核实现）。

**T7 计算层——真正的墙**：**原生执行的通用计算内核**。
一个 JSON 定义、装载时编译（AST→闭包或寄存器字节码）、运行于隔离执行环境
（isolate）、操作 T2 缓冲、带每 tick 预算的受限 VM：
```json
{ "kind": "compute", "program": [...受限指令序列...],
  "buffers": ["ram","prg","fb"], "budget_per_tick": 500000 }
```
没有 T7，T1-T6 全部落地也只是把 1,600× 差距压到 ~150×（推导）。有 T7，
预算内原生执行可达 10⁷-10⁸ 操作/秒（isolate 内普通 Dart 速度），NES 实时
可达。**T7 的本质是给框架增加一个沙箱脚本运行时**——这是"JSON 架构"边界
的产品决策，不是工程细节：它与"专用 NES 桥"的区别在于通用性（同一内核可
跑 CHIP-8、GB、音频合成、程序化生成），与"框架应保持声明式"的哲学存在
张力。此判断即本次任务的核心产出。

## 6. 若全部落地的移植路径（供决策参考）

1. T1-T2 落地 → 用 T7 内核语言重写 CPU/PPU/APU/Mapper（NESd 的 13.8k LOC
   核心是清晰的寄存器机代码，机械可译）；
2. T3/T4 接帧缓冲与音频；ROM 经 OSS + @asset.load_bytes；
3. 壳层（菜单/设置/存档 UI/触屏手柄）用现有 DSL 直接写（~2-3k 行 JSON，
   参照三次游戏移植的成熟模式）；
4. 残余风险：MMC3 A12 周期级滤波与音频时钟帧同步必须在内核内实现（预算
   模型要允许"跑到 vblank 为止"而非固定步数）；回放/LZ4 建议首版砍掉。

## 7. PoC 附录

- 基准生成器：`scripts/bench_jsonlogic_throughput.py`（4 负载、按钮调参、
  屏上读数）；6502 切片在 JSON 逻辑中的完整取指-译码-执行实现即在其中——
  **形式正确性已证明，纯粹是吞吐不可行**。
- 复现：loopback CORS 服务 + headless Chrome（工作流见团队记忆
  jsonapp-headless-probe），N×2 按钮加压至掉帧读 sps。
