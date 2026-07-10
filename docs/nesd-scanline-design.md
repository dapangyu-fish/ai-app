# 计算层通用化设计:数组算法内建 + 逐扫描线批处理

> 背景:iOS 实测仍不可玩。逐点(per-dot)模型的**硬下限**已实测:把渲染全部剥掉,
> SMB3 仍要 **122.9ms/帧**(89k 次 ppu_step 计数 + 每 CPU 周期 3 次总线分派)——
> AOT 后 ~40-60ms,零渲染也到不了 30fps。**架构必须换**,微优化无解。

## 原则

1. **框架侧只加通用算法**:内核新增的每个 op 都是教科书级字节数组算法
   (memset/memcpy/查表映射/位平面解码),对任意 compute 程序有意义,零 NES 语义。
2. **NES 语义全部留在数据层**(gen_nes.py):逐扫描线管线、精灵合成规则、
   sprite-0、IRQ 时序都是 JSON 程序的事。
3. 每个 op 按处理长度计预算(`budget -= 1 + (len>>3)`),越界钳制(与 setu8 一致)。

## 一、内核新增 4 个通用 intrinsic(语句 op)

| op | 形式 | 语义 |
|---|---|---|
| `memset` | `["memset", buf, off, len, val]` | `buf[off..off+len) = val&0xFF`;范围钳制到缓冲边界 |
| `memcpy` | `["memcpy", dst, doff, src, soff, len]` | 字节拷贝(memmove 语义,支持同缓冲重叠) |
| `memlut` | `["memlut", dst, doff, src, soff, len, lut, loff]` | `dst[doff+i] = lut[loff + src[soff+i]]`;查表越界→0 |
| `planar8` | `["planar8", dst, doff, loE, hiE, orE, flipE]` | 2bpp 位平面行解码(NES/GB/SNES 通用):8 像素,`px=((hi>>b&1)<<1)\|(lo>>b&1)`,`px==0→0`(透明),否则 `px\|or`;flip 反转位序 |

buf 名编译期解析;off/len/val/lo/hi/or/flip 均为表达式。除此以外**内核不再为本次改动
添加任何东西** —— 精灵优先级合成、sprite-0 命中等保持解释执行(每线 ≤8 精灵 × 8 像素,
量级无害),避免发明"疑似 NES 形状"的 op。

## 二、数据层:逐扫描线模型(gen_nes.py 重写)

### 帧循环(run_frame)

```
for line in 0..261:
    line_events(line)          # 见下
    cpu_target += cycles_of_line(line)   # 341 dots/3,余数进位;奇帧 pre-render 少 1 dot
    while CPUCYC < cpu_target: cpu_step()   # 总线 rd/wr 不再 tick PPU(apu_step 保留)
```

### line_events(line)(在该线 CPU 批次**之前**执行 = 线首)

- `line==241`:STATUS|=0x80;NMIEN→NMIPEND(NMI 粒度 = 线级,标准 scanline 模拟器行为)
- `line==261`(pre-render):清 vblank/s0/overflow;S0HITCYC=0;若渲染开:copyv(v←t 垂直位)
- `line<240` 且渲染开:
  1. `spr_overflow_eval`(沿用)
  2. `spr_line_eval`(沿用,≤8 精灵进 sline)
  3. **渲染整线**(见下)→ 记录 sprite-0 命中点 dot d → `S0HITCYC = line_start_cyc + d/3`
  4. 合成后 `memlut` 调色板 → fb 行
  5. v 更新:incy;copyh(等效原 dot256/257)
  6. MMC3 A12 合成时钟(原 c==260 的 `ppu_read(SPRBASE|0xFF0)`,一线一次)
  7. MMC5:线首 IRQ 判定、split/ExGrafix 在逐 tile 取数处理

### 整线渲染(bg 33 tile + 精灵合成)

- 33 个 tile:NT/AT/PT 经 `ppu_read`(保 mirror/mapper9 latch/MMC5 split-ExGrafix/a12 模式)
  → 每 tile 一次 `planar8` 解码进 264 宽行缓冲 `row`(or = attr<<2,0=背景透明);
- fineX:`memlut(fb, PIXBASE, row, fineX, 256, palmask, 0)` 一步完成移位+调色板
  (`palmask` = 32B 调色板的 &0x3F 影子,pal 写时同步);
- 左缘裁剪:`memset(row, fineX, 8, 0)`(SHOWBGL=0 时);
- 精灵:每精灵 `planar8` 解码 8 像素进 scratch,解释执行合成循环(OAM 序先占先赢、
  前后优先级、s0 命中在合成时逐像素判定并记录 dot)。

### 时序语义(与逐点模型的差异及理由)

| 项 | 处理 | 影响 |
|---|---|---|
| $2002 vblank/s0 中线读 | s0 经 `S0HITCYC`(CPUCYC 比较)dot 级精确;vblank 线级 | SMB1/SMB3 的 s0 轮询正确;vblank 竞态边缘(dot 级)近似 |
| NMI | 线 241 首 | 抖动 ≤1 线,商业游戏无感 |
| MMC3 IRQ | 线首合成时钟(原 c==260,提前 ~87 CPU 周期) | 手柄处理程序均在 hblank 写寄存器,同线内落地,分割线不变 |
| 中线 scroll 写(可见段内) | 下一线生效 | 仅极端 raster 演示受影响,商业游戏 hblank 写 |
| 渲染时点 | 线首用当前 v 渲染 | 等效 HW 的"上线 hblank 写影响本线" |

### 验证口径

- 纯背景测试 ROM:静态画面 → fb 校验和必须仍为 `0xe9bc91c5`(逐位);
- SMB3:260 帧确定输入脚本,关键帧截图肉眼比对(开场/标题/菜单/入关),
  标题动画相位允许移动(IRQ 时钟修正的延续),画面内容必须无损;
- 预算:每线解释 op ≈ bg 1.5k + 精灵 0.8k + 事件 50 → 全帧 ≈ 0.6M + CPU 0.4M + APU 0.45M
  ≈ **~25ms JIT ≈ 8-15ms AOT(30-60fps)**;二期 APU 事件化再砍 ~10ms。

## 三、不做的事

- 不加"精灵合成/优先级"类 intrinsic(疑似 NES 形状,解释执行量级已无害);
- 不动 CPU 内核(6502 解释是内容本体,~10ms JIT 可接受);
- APU 批处理留二期(独立提交,纯数据层)。
