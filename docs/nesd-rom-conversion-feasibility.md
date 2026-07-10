# NES ROM「转换」可行性 —— 以 SMB3(MMC3)为例

> 问题:能否把一个 NES ROM(具体:`mario.nes` = 超级马里奥兄弟3 汉化卡,mapper 4/MMC3,
> 256KB PRG + 128KB CHR)**转换**成 (a) Flame 原生游戏,或 (b) JSON-DSL 应用 ——
> 而不是在模拟器里运行?
>
> 结论来源:deep-research 工作流(105 agent,23 个源,113 条声明抽取,25 条三票
> 对抗校验:22 确认 / 3 证伪)+ 本仓库实证(真 ROM 实测)。2026-07。

## 四条路线的裁决

| 路线 | 可行性 | 工作量 | 保真度 | 可分发性 |
|---|---|---|---|---|
| **① 模拟器运行(现状)** | ✅ **已工作** | ~0(已上线) | 全保真(周期级) | App 可分发,ROM 用户自备 |
| ② 静态重编译 ROM | ❌ 实际不可行 | — | — | — |
| ③ 反汇编手工移植到 Flame | ⚠️ 原理可行 | **人·年级** | 亚像素物理/中帧光栅高风险 | ❌ 含任天堂素材/逻辑不可分发 |
| ④ 移植到 JSON-DSL | ⚠️ 严格难于 ③ | 更高(无先例) | 更低 | 同 ③ |

## ① 模拟器(唯一的全保真、近零成本路线)—— 本仓库已实证

- `mario.nes` 在 JSON 模拟器里**直接可跑且渲染正确**(开场幕布/标题/菜单逐帧截图验证,
  MMC3 bank 切换、8x16 精灵、调色板全对)。
- 性能经逐扫描线精灵求值优化后 1453→244ms/帧(6.0×,JIT 4.1fps;AOT 预计 ~8–16fps),
  见 `nesd-web-performance.md` §9.2.5。
- 所有被调研的「转换成功案例」最终都**收敛回模拟器形态**(见下)——平台已经拥有终点形态。

## ② 静态重编译:被两代实践证伪

- **jamulator**(2013,LLVM+Go,最认真的 NES 静态重编译尝试):作者亲自结论
  「静态重编译对游戏模拟没有实用价值」。mapper 从未解决(明确列为 Unsolved);唯一
  跑起来的游戏是 **mapper-0 的 SMB1**,且靠嵌入 6 条 opcode 的解释器兜底 ——
  作者原话「这已经违背了整个项目的意义,不如去模拟」。[andrewkelley.me/post/jamulator.html]
- **根本障碍(全部三票确认)**:
  - 不执行就无法完整反汇编:动态跳转表(SMB3 反汇编中实证 `DynJump` 107 处调用点 +
    ~10 处经 RAM 的计算间接跳转)、RTS-as-JMP、指令中部跳入;
  - **MMC3 两写协议**($8000 选寄存器 → $8001 写数据,R0–R7)使地址→代码/图形的
    映射成为**运行时状态**,静态分析无从解析 —— 要解析就得建模寄存器机制,即变回模拟器。
- **N64 的反例不迁移**:N64Recomp/Zelda64Recomp 确实产出可玩移植,但 (1) 需要 ELF
  符号级元数据(= 先有反编译工程),(2) 输出依赖手写运行时(硬件抽象层)。NES 是手写
  6502(无编译器结构可恢复)+ 内存映射 I/O($2000-$2007/$4000-$4017),CPU 转译后
  PPU/APU 仍需模拟 —— SMB1 的成功案例 SuperMarioBros-C 也是:只消掉 CPU 模拟,
  PPU/APU/手柄全是手写模拟层,且 CHR 图形**运行时从用户自备 ROM 读取**。
- 未深验的开放项:mstan/NESRecomp(声称支持 mapper 0/1/4/66,仍调用 PPU/APU 模拟
  runner 库)—— 若其 mapper-4 真可玩,②的裁决会软化,但形态依然是「原生 CPU + 模拟外设」。

## ③ 反汇编手工移植 Flame:原理可行,人·年级,且不可分发

- 前置条件齐全:**captainsouthbird/smb3** 反汇编可逐字节重组出 US(PRG1) ROM(作者
  耗时数年,RNG 等例程仍未完全语义化);**SMB3-Foundry** 关卡编辑器证明关卡/物件/调色板
  数据格式已完全逆向、可机器提取;SM64 反编译→移植生态是先例。
- 但 SMB3 是手写汇编(非 SM64 的编译 C),反汇编 ≠ 语义理解;需要手工翻译全部逻辑:
  亚像素物理、90+ 关卡、世界地图、敌人 AI、音乐引擎。唯一已知的 SMB3 现代引擎重制尝试
  (notchris/SMB3,Phaser 3)**止步于 2 次提交的原型**(2 种敌人)。
- 法律:所有幸存项目的共同模式 = **不分发任何任天堂素材**(sm64 需用户自备 ROM 提取素材;
  含素材的成品分发一律被 DMCA)。含原素材的转换 App 无法分发;即使素材干净,
  重建的原版逻辑仍可争议为衍生作品。

## ④ JSON-DSL 移植:严格难于 ③

继承 ③ 的全部成本,再叠加:翻译成声明式 jsonlogic/tick 形态(零先例)+ 解释器开销。
现实定位:**小体量净室致敬作**(自制素材+独立实现的类马里奥机制,走 `demo-mario-platformer`
路线)可行;「转换 SMB3」不可行。

## 给本平台的落地建议

1. **玩真 ROM = 模拟器路线**,即现状。继续按 `nesd-web-performance.md` 的优化路径推进
   (worker 模式已消除 UI 卡顿;AOT + 逐扫描线背景是剩余大头)。
2. **要「马里奥类游戏」= 净室重制**,用平台已有的 platformer 原语(tiled_map/物理/实体),
   自制素材 —— 这才是可上架分发的形态。
3. ROM 文件本身(mario.nes)仅限本地测试,**不入库、不上传对象存储、不随 App 分发**。

## 主要来源

jamulator 写作与仓库(andrewkelley.me/post/jamulator.html, github.com/andrewrk/jamulator)·
NESdev Wiki(Programming_MMC3, Tricky-to-emulate_games, RTS_Trick)·
github: N64Recomp/N64Recomp, Zelda64Recomp, MitchellSternke/SuperMarioBros-C,
captainsouthbird/smb3, n64decomp/sm64, mchlnix/SMB3-Foundry, notchris/SMB3,
doppelganger smbdis.asm(gist 1wErt3r/4048722)· VGC/GameDeveloper 任天堂 DMCA 报道。
完整校验记录(25 条声明逐条三票投票、证伪清单、开放问题)存于会话工作流
wf_f81f9e21-8f9 输出。
