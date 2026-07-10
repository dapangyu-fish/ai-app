#!/usr/bin/env python3
"""Combined NES = CPU + PPU + bus + NROM, emitted as one compute-kernel program.
1:1 port of NESd (nes/cpu, nes/ppu, nes/bus, nes/cartridge/mapper/nrom).

Interleave: CPU is master; every CPU bus access (=1 CPU cycle) ticks the PPU 3
dots (NESd's stepUntil model). PPU renders per-dot into fb (256x240 palette
indices 0..63); RGB conversion happens at dump time via the standard NES palette.

State:
  buffers: ram2048 prg32768 chr8192 vram2048 pal32 oam256 oam2_32 fb61440
  i32 reg[8]  : CPU  0=A 1=X 2=Y 3=SP 4=P 5=PC 6=cyc 7=halt
  i32 p[40]   : PPU  (named indices below)
"""
import json
import gen_cpu as C
import gen_apu as APU

# PPU state indices in i32 'p'
(PV, PT, PX, PW, CTRL, MASK, STATUS, OAMADDR, SCAN, CYC, FRAMES, NMIEN,
 BGBASE, SPRBASE, RDBUF, NMIPEND, NTLATCH, ATLATCH, PTL, PTH,
 PTLSHIFT, PTHSHIFT, ATLSHIFT, ATHSHIFT, ATTR, SHOWBG, SHOWSP,
 SHOWBGL, SHOWSPL, SPRCOUNT, S0LINE, S0NEXT, VINC, PIXBASE,
 MIRROR, ODDFRAME, NMIED_PREV, SPR0HIT_ARMED, SCRATCH1, SCRATCH2,
 CTRL_STROBE, CTRL_SH0, CTRL_SH1, CTRL_LATCH0, CTRL_LATCH1,
 MAPPER, PRGBANKS, M1_SHIFT, M1_CTRL, M1_CHR0, M1_CHR1, M1_PRG,
 PB0, PB1, PB2, PB3, CB0, CB1, CB2, CB3, CB4, CB5, CB6, CB7,
 M3_REG, M3_PRGMODE, M3_CHRMODE, M3_R0, M3_R1, M3_R2, M3_R3, M3_R4, M3_R5, M3_R6, M3_R7,
 M3_IRQLATCH, M3_IRQCOUNT, M3_IRQRELOAD, M3_IRQEN, IRQPEND, PRG8,
 A12LOW, CPUCYC, NT0, NT1, NT2, NT3,
 M5_PRGMODE, M5_CHRMODE, M5_PRG0, M5_PRG1, M5_PRG2, M5_PRG3, M5_PRG4,
 M5_CHR0, M5_CHR1, M5_CHR2, M5_CHR3, M5_CHR4, M5_CHR5, M5_CHR6, M5_CHR7,
 M5_MULCAND, M5_MULER, M5_IRQTARGET, M5_IRQEN, M5_IRQPEND, M5_NT,
 M5_EXMODE, M5_EXBANK, M5_EXPAL, M5_FILLTILE, M5_FILLCOLOR,
 M5_CHR8, M5_CHR9, M5_CHR10, M5_CHR11,
 SPRCB0, SPRCB1, SPRCB2, SPRCB3, SPRCB4, SPRCB5, SPRCB6, SPRCB7,
 M5_SPLITEN, M5_SPLITSIDE, M5_SPLITTILE, M5_SPLITSCROLL, M5_SPLITBANK,
 M5_SPLITADDR, M5_SPLITACTIVE, SL_COUNT,
 # scanline-model state: sprite-0 hit promoted lazily by CPU-cycle compare;
 # absolute CPU-cycle target per line (instruction overshoot carries over);
 # dot remainder for the 341/3 division; CPU cycle count at current line start
 S0HITCYC, TGTCYC, DOTREM, LINESTART) = range(137)

def p(i): return ["i32", "p", i]
def setp(i, v): return ["seti32", "p", i, v]
L = C.L; setL = C.setL
def AND(a, b): return ["&", a, b]
def OR(a, b): return ["|", a, b]
def XOR(a, b): return ["^", a, b]
def SHL(a, b): return ["<<", a, b]
def SHR(a, b): return [">>", a, b]
def ADD(a, b): return ["+", a, b]
def SUB(a, b): return ["-", a, b]
def IF(c, t, e=None):
    a = {"cond": c, "then": t}
    if e:
        a["else"] = e
    return ["call", "@if", None] if False else ["if", c, t] + ([e] if e else [])
def gif(c, t, e=None):
    return ["if", c, t] + ([e] if e is not None else [])
def PR(fn, args=None): return ["call", fn, args or []]  # proc/expr call
def call(fn, args=None): return ["call", fn, args or []]

# loopy v decode helpers (v is 15-bit in p[PV])
def v_coarseX(): return AND(p(PV), 0x1F)
def v_coarseY(): return AND(SHR(p(PV), 5), 0x1F)
def v_ntX(): return AND(SHR(p(PV), 10), 1)
def v_ntY(): return AND(SHR(p(PV), 11), 1)
def v_fineY(): return AND(SHR(p(PV), 12), 7)

# ---- PPU memory (readPpuMemory / writePpuMemory) ----
# address 0x0000-0x1FFF: CHR (pattern); 0x2000-0x3EFF: nametable(mirrored);
# 0x3F00-0x3FFF: palette
def nt_index(addrL):
    # map 0x2000-0x2FFF into 2KB vram with mirroring (0=horiz,1=vert,2=single0,3=single1)
    return ["call", "nt_map", [addrL]]

def a12_inline(a):
    # a12_clock_fn body inlined (side effects only, no ret) — ppu_read/ppu_write run
    # it on every access (~tens of thousands/frame), so the call dispatch is pure
    # overhead. Behaviour is 1:1 identical for all mappers (m3_clock_irq stays a call,
    # taken only on mapper 4/118). `a` must already be a bound local expr.
    return gif(["==", AND(SHR(a, 12), 1), 1], [
        gif(["and", [">", p(A12LOW), 0], [">=", SUB(p(CPUCYC), p(A12LOW)), 3]],
            [gif(["or", ["==", p(MAPPER), 4], ["==", p(MAPPER), 118]], [call("m3_clock_irq")])]),
        setp(A12LOW, 0),
    ], [
        gif(["==", p(A12LOW), 0], [setp(A12LOW, p(CPUCYC))]),
    ])

def ppu_read_fn():
    return {"params": ["a"], "body": [
        setL("a", AND(L("a"), 0x3FFF)),
        a12_inline(L("a")),
        gif(["==", p(MAPPER), 9], [call("m9_latch", [L("a")])]),
        gif(["<", L("a"), 0x2000], [["ret", ["u8", "chr", call("chr_addr", [L("a")])]]]),
        gif(["and", ["==", p(MAPPER), 5], ["<", L("a"), 0x3F00]], [
            setL("rg", AND(SHR(L("a"), 10), 3)),
            setL("nm", AND(SHR(p(M5_NT), ["*", L("rg"), 2]), 3)),
            setL("off", AND(L("a"), 0x3FF)),
            gif(["==", L("nm"), 2], [["ret", ["u8", "exram", L("off")]]]),
            gif(["==", L("nm"), 3], [
                gif(["<", L("off"), 0x3C0], [["ret", p(M5_FILLTILE)]]),
                ["ret", OR(OR(SHL(p(M5_FILLCOLOR), 6), SHL(p(M5_FILLCOLOR), 4)),
                           OR(SHL(p(M5_FILLCOLOR), 2), p(M5_FILLCOLOR)))]]),
            ["ret", ["u8", "vram", OR(SHL(L("nm"), 10), L("off"))]]]),
        gif(["<", L("a"), 0x3F00], [["ret", ["u8", "vram", nt_index(L("a"))]]]),
        # palette
        setL("pi", AND(L("a"), 0x1F)),
        gif(["==", AND(L("pi"), 0x13), 0x10], [setL("pi", ["-", L("pi"), 0x10])]),
        ["ret", ["u8", "pal", L("pi")]],
    ]}

def ppu_write_fn():
    return {"params": ["a", "v"], "body": [
        setL("a", AND(L("a"), 0x3FFF)),
        a12_inline(L("a")),
        gif(["<", L("a"), 0x2000], [["setu8", "chr", call("chr_addr", [L("a")]), L("v")], ["ret", 0]]),
        gif(["and", ["==", p(MAPPER), 5], ["<", L("a"), 0x3F00]], [
            setL("rg", AND(SHR(L("a"), 10), 3)),
            setL("nm", AND(SHR(p(M5_NT), ["*", L("rg"), 2]), 3)),
            setL("off", AND(L("a"), 0x3FF)),
            gif(["==", L("nm"), 2], [["setu8", "exram", L("off"), L("v")], ["ret", 0]]),
            gif(["<", L("nm"), 2], [["setu8", "vram", OR(SHL(L("nm"), 10), L("off")), L("v")]]),
            ["ret", 0]]),
        gif(["<", L("a"), 0x3F00], [["setu8", "vram", nt_index(L("a")), L("v")], ["ret", 0]]),
        setL("pi", AND(L("a"), 0x1F)),
        gif(["==", AND(L("pi"), 0x13), 0x10], [setL("pi", ["-", L("pi"), 0x10])]),
        ["setu8", "pal", L("pi"), AND(L("v"), 0x3F)],
        # masked shadow for the scanline row→fb memlut (same value, kept in sync)
        ["setu8", "palsh", L("pi"), AND(L("v"), 0x3F)],
        ["ret", 0],
    ]}

def nt_map_fn():
    # returns index into 2KB vram given 0x2000-0x2FFF address
    return {"params": ["a"], "body": [
        setL("a", AND(L("a"), 0xFFF)),
        setL("tbl", AND(SHR(L("a"), 10), 3)),   # which nametable 0..3
        setL("off", AND(L("a"), 0x3FF)),
        # mirror mode
        gif(["==", p(MIRROR), 0], [   # horizontal: tbl 0,1->0 ; 2,3->1
            ["ret", OR(SHL(AND(SHR(L("tbl"), 1), 1), 10), L("off"))]]),
        gif(["==", p(MIRROR), 1], [   # vertical: tbl 0,2->0 ; 1,3->1
            ["ret", OR(SHL(AND(L("tbl"), 1), 10), L("off"))]]),
        gif(["==", p(MIRROR), 2], [["ret", L("off")]]),        # single screen 0
        gif(["==", p(MIRROR), 4], [                             # per-region (TxSROM)
            gif(["==", L("tbl"), 0], [["ret", OR(SHL(p(NT0), 10), L("off"))]]),
            gif(["==", L("tbl"), 1], [["ret", OR(SHL(p(NT1), 10), L("off"))]]),
            gif(["==", L("tbl"), 2], [["ret", OR(SHL(p(NT2), 10), L("off"))]]),
            ["ret", OR(SHL(p(NT3), 10), L("off"))]]),
        ["ret", OR(0x400, L("off"))],                          # single screen 1
    ]}

# ---- PPU register read/write (CPU side) ----
def ppu_reg_read_fn():
    # a = 0x2000..0x3FFF (mirrored to 8); returns value
    return {"params": ["a"], "body": [
        setL("r", AND(L("a"), 7)),
        gif(["==", L("r"), 2], [   # PPUSTATUS
            # scanline model: sprite-0 hit is precomputed as an absolute CPU
            # cycle when the line renders; promote it into STATUS dot-exactly
            gif(["and", [">", p(S0HITCYC), 0], [">=", p(CPUCYC), p(S0HITCYC)]],
                [setp(STATUS, OR(p(STATUS), 0x40)), setp(S0HITCYC, 0)]),
            setL("val", p(STATUS)),
            setp(STATUS, AND(p(STATUS), 0x7F)),   # clear vblank
            setp(PW, 0),
            ["ret", L("val")]]),
        gif(["==", L("r"), 4], [["ret", ["u8", "oam", p(OAMADDR)]]]),   # OAMDATA
        gif(["==", L("r"), 7], [   # PPUDATA (buffered)
            setL("val", p(RDBUF)),
            setp(RDBUF, call("ppu_read", [p(PV)])),
            gif([">=", AND(p(PV), 0x3FFF), 0x3F00], [setL("val", call("ppu_read", [p(PV)]))]),
            setp(PV, AND(ADD(p(PV), p(VINC)), 0x7FFF)),
            ["ret", L("val")]]),
        ["ret", 0],
    ]}

def ppu_reg_write_fn():
    return {"params": ["a", "v"], "body": [
        setL("r", AND(L("a"), 7)),
        setp(STATUS, OR(AND(p(STATUS), 0xE0), AND(L("v"), 0x1F))),  # bus latch bits (approx)
        gif(["==", L("r"), 0], [   # PPUCTRL
            setL("oldnmi", p(NMIEN)),
            setp(CTRL, L("v")),
            setp(NMIEN, AND(SHR(L("v"), 7), 1)),
            # NMI line edge: enabling NMI while vblank set fires NMI, but recognized
            # after the NEXT instruction (SCRATCH1 = 1-instruction delay, promoted in run_frame)
            gif(["and", ["and", ["==", AND(SHR(L("v"), 7), 1), 1], ["==", L("oldnmi"), 0]],
                        ["==", AND(SHR(p(STATUS), 7), 1), 1]],
                [setp(SCRATCH1, 1)]),
            setp(VINC, ["?:", AND(SHR(L("v"), 2), 1), 32, 1]),
            setp(BGBASE, SHL(AND(SHR(L("v"), 4), 1), 12)),
            setp(SPRBASE, SHL(AND(SHR(L("v"), 3), 1), 12)),
            setp(PT, OR(AND(p(PT), 0x73FF), SHL(AND(L("v"), 3), 10))),
            gif(["==", p(MAPPER), 5], [call("m5_update_chr")]),
            ["ret", 0]]),
        gif(["==", L("r"), 1], [   # PPUMASK
            setp(MASK, L("v")),
            setp(SHOWBGL, AND(SHR(L("v"), 1), 1)),
            setp(SHOWSPL, AND(SHR(L("v"), 2), 1)),
            setp(SHOWBG, AND(SHR(L("v"), 3), 1)),
            setp(SHOWSP, AND(SHR(L("v"), 4), 1)),
            ["ret", 0]]),
        gif(["==", L("r"), 3], [setp(OAMADDR, L("v")), ["ret", 0]]),   # OAMADDR
        gif(["==", L("r"), 4], [   # OAMDATA
            ["setu8", "oam", p(OAMADDR), L("v")],
            setp(OAMADDR, AND(ADD(p(OAMADDR), 1), 0xFF)), ["ret", 0]]),
        gif(["==", L("r"), 5], [   # PPUSCROLL
            gif(["==", p(PW), 0], [
                setp(PT, OR(AND(p(PT), 0xFFE0), SHR(L("v"), 3))),
                setp(PX, AND(L("v"), 7)), setp(PW, 1)],
                [setp(PT, OR(OR(AND(p(PT), 0xC1F), SHL(AND(L("v"), 0xF8), 2)),
                             SHL(AND(L("v"), 7), 12))), setp(PW, 0)]),
            ["ret", 0]]),
        gif(["==", L("r"), 6], [   # PPUADDR
            gif(["==", p(PW), 0], [
                setp(PT, OR(AND(p(PT), 0x00FF), SHL(AND(L("v"), 0x3F), 8))),
                setp(PW, 1)],
                [setp(PT, OR(AND(p(PT), 0xFF00), L("v"))),
                 setp(PV, p(PT)), setp(PW, 0),
                 a12_inline(AND(p(PV), 0x3FFF))]),
            ["ret", 0]]),
        gif(["==", L("r"), 7], [   # PPUDATA
            call("ppu_write", [p(PV), L("v")]),
            setp(PV, AND(ADD(p(PV), p(VINC)), 0x7FFF)), ["ret", 0]]),
        ["ret", 0],
    ]}

# ---- PPU dot step (background pipeline, faithful to NESd _step*) ----
def ppu_incx():
    return gif(["==", v_coarseX(), 31],
               [setp(PV, AND(XOR(AND(p(PV), 0x7FE0), 0x400), 0x7FFF))],  # coarseX=0, flip ntX
               [setp(PV, ADD(p(PV), 1))])
def ppu_incy():
    return gif(["<", v_fineY(), 7],
        [setp(PV, ADD(p(PV), 0x1000))],
        [setp(PV, AND(p(PV), 0xFFF)),  # fineY=0
         setL("cy", v_coarseY()),
         gif(["==", L("cy"), 29],
             [setp(PV, XOR(AND(p(PV), 0x7C1F), 0x800))],  # coarseY=0, flip ntY
             [gif(["==", L("cy"), 31],
                  [setp(PV, AND(p(PV), 0x7C1F))],
                  [setp(PV, OR(AND(p(PV), 0x7C1F), SHL(ADD(L("cy"), 1), 5)))])])])
def ppu_copyh():
    return setp(PV, OR(AND(p(PV), 0x7BE0), AND(p(PT), 0x41F)))
def ppu_copyv():
    return setp(PV, OR(AND(p(PV), 0x041F), AND(p(PT), 0x7BE0)))

def render_line_fn():
    # Render one full visible scanline in batches (scanline model): 33 bg tiles
    # -> planar8 into 'row' (264px, fineX picks the 256 window), bg left clip,
    # <=8 cached line sprites merged interpreted (first-in-OAM-order wins,
    # front/back priority, sprite-0 recorded as an ABSOLUTE CPU CYCLE), then a
    # single memlut through the masked palette shadow into fb. v (loopy)
    # advances exactly like the per-dot pipeline: 33x incx during the fetch,
    # incy + copyh afterwards (done by line_step). NT/AT/PT go through
    # ppu_read, preserving mirroring, mapper-9 latches, MMC5 split/ExGrafix
    # and the per-tile A12 pattern.
    body = [
        gif(["==", p(SHOWBG), 1], [
            setL("t", 0),
            ["while", ["<", L("t"), 33], [
                # MMC5 split: per-tile window decision (port of per-dot sc==1)
                gif(["and", ["==", p(MAPPER), 5], ["==", p(M5_SPLITEN), 1]], [
                    setL("cx", v_coarseX()),
                    setL("ins", ["?:", ["==", p(M5_SPLITSIDE), 0],
                                 ["<", L("cx"), p(M5_SPLITTILE)], [">=", L("cx"), p(M5_SPLITTILE)]]),
                    gif(["==", L("ins"), 1], [
                        setp(M5_SPLITACTIVE, 1),
                        setL("scr", ADD(p(SCAN), p(M5_SPLITSCROLL))),
                        gif([">=", L("scr"), 240], [setL("scr", ["-", L("scr"), 240])]),
                        setp(M5_SPLITADDR, OR(SHL(AND(L("scr"), 0xF8), 2), L("cx"))),
                        setp(NTLATCH, ["u8", "exram", p(M5_SPLITADDR)])],
                        [setp(M5_SPLITACTIVE, 0)])]),
                # NT fetch (unless the MMC5 split provided it)
                gif(["or", ["!=", p(MAPPER), 5], ["==", p(M5_SPLITACTIVE), 0]],
                    [setp(NTLATCH, call("ppu_read", [OR(0x2000, AND(p(PV), 0xFFF))]))]),
                gif(["and", ["==", p(MAPPER), 5], ["==", p(M5_EXMODE), 1]], [
                    setL("ex", ["u8", "exram", AND(p(PV), 0x3FF)]),
                    setp(M5_EXBANK, AND(L("ex"), 0x3F)), setp(M5_EXPAL, AND(SHR(L("ex"), 6), 3))]),
                # AT fetch
                setL("at", call("ppu_read", [OR(OR(OR(0x23C0, SHL(AND(SHR(p(PV), 10), 3), 10)),
                                                   SHL(AND(SHR(p(PV), 5), 0x1C), 1)),
                                                SHR(AND(p(PV), 0x1C), 2))])),
                setL("shift", OR(AND(SHR(p(PV), 4), 4), AND(p(PV), 2))),
                setL("atb", AND(SHR(L("at"), L("shift")), 3)),
                gif(["and", ["==", p(MAPPER), 5], ["==", p(M5_EXMODE), 1]], [setL("atb", p(M5_EXPAL))]),
                gif(["and", ["==", p(MAPPER), 5], ["==", p(M5_SPLITACTIVE), 1]], [
                    setL("ab", ["u8", "exram", ADD(0x3C0, OR(AND(SHR(p(M5_SPLITADDR), 4), 0x38), AND(SHR(p(M5_SPLITADDR), 2), 7)))]),
                    setL("atb", AND(SHR(L("ab"), L("shift")), 3))]),
                # pattern fetch (lo + hi planes)
                setL("sfy", AND(ADD(p(SCAN), p(M5_SPLITSCROLL)), 7)),
                gif(["and", ["==", p(MAPPER), 5], ["==", p(M5_SPLITACTIVE), 1]],
                    [setL("ptl", ["u8", "chr", AND(OR(OR(SHL(p(M5_SPLITBANK), 12), SHL(p(NTLATCH), 4)), L("sfy")), 0x1FFFF)]),
                     setL("pth", ["u8", "chr", AND(OR(OR(OR(SHL(p(M5_SPLITBANK), 12), SHL(p(NTLATCH), 4)), L("sfy")), 8), 0x1FFFF)])],
                    [gif(["and", ["==", p(MAPPER), 5], ["==", p(M5_EXMODE), 1]],
                        [setL("ptl", ["u8", "chr", AND(OR(OR(SHL(p(M5_EXBANK), 12), SHL(p(NTLATCH), 4)), v_fineY()), 0x1FFFF)]),
                         setL("pth", ["u8", "chr", AND(OR(OR(OR(SHL(p(M5_EXBANK), 12), SHL(p(NTLATCH), 4)), v_fineY()), 8), 0x1FFFF)])],
                        [setL("ptl", call("ppu_read", [OR(OR(p(BGBASE), SHL(p(NTLATCH), 4)), v_fineY())])),
                         setL("pth", call("ppu_read", [OR(OR(OR(p(BGBASE), SHL(p(NTLATCH), 4)), v_fineY()), 8)]))])]),
                ["planar8", "row", SHL(L("t"), 3), L("ptl"), L("pth"), SHL(L("atb"), 2), 0],
                ppu_incx(),
                setL("t", ADD(L("t"), 1)),
            ]],
        ], [
            # background disabled -> backdrop row (sprites may still show)
            ["memset", "row", 0, 264, 0],
        ]),
        # left-edge clip: hide bg in visible x 0..7 when SHOWBGL off
        gif(["==", p(SHOWBGL), 0], [["memset", "row", p(PX), 8, 0]]),
        # sprites: merge <=8 cached line sprites over the row (<=64 px/line).
        # sclaim = first-in-OAM-order ownership: a claimed pixel blocks later
        # sprites even when the claimant sits behind an opaque background.
        gif(["and", ["==", p(SHOWSP), 1], [">", p(SL_COUNT), 0]], [
            ["memset", "sclaim", 0, 264, 0],
            setL("j", 0),
            ["while", ["<", L("j"), p(SL_COUNT)], [
                setL("b", ["*", L("j"), 5]),
                setL("oa", ["i32", "sline", ADD(L("b"), 1)]),
                ["planar8", "sprscr", 0, ["i32", "sline", ADD(L("b"), 2)],
                 ["i32", "sline", ADD(L("b"), 3)], 0, AND(SHR(L("oa"), 6), 1)],
                setL("ox", ["i32", "sline", L("b")]),
                setL("beh", AND(SHR(L("oa"), 5), 1)),
                setL("por", OR(0x10, SHL(AND(L("oa"), 3), 2))),
                setL("s0", ["?:", ["==", ["i32", "sline", ADD(L("b"), 4)], 0], 1, 0]),
                setL("dx", 0),
                ["while", ["<", L("dx"), 8], [
                    setL("x", ADD(L("ox"), L("dx"))),
                    gif([">=", L("x"), 256], [["break"]]),
                    setL("spx", ["u8", "sprscr", L("dx")]),
                    gif(["and", ["!=", L("spx"), 0],
                              ["or", [">=", L("x"), 8], ["==", p(SHOWSPL), 1]]], [
                        gif(["==", ["u8", "sclaim", L("x")], 0], [
                            ["setu8", "sclaim", L("x"), 1],
                            setL("rx", ADD(p(PX), L("x"))),
                            # sprite-0 hit (never at x=255): dot = x+1 -> cycle
                            gif(["and", ["and", ["==", L("s0"), 1], ["<", L("x"), 255]],
                                      ["and", ["!=", ["u8", "row", L("rx")], 0],
                                              ["and", ["==", p(S0HITCYC), 0],
                                                      ["==", AND(p(STATUS), 0x40), 0]]]],
                                [setp(S0HITCYC, ADD(p(LINESTART), ["/", ADD(L("x"), 3), 3]))]),
                            gif(["or", ["==", L("beh"), 0], ["==", ["u8", "row", L("rx")], 0]],
                                [["setu8", "row", L("rx"), OR(L("spx"), L("por"))]]),
                        ]),
                    ]),
                    setL("dx", ADD(L("dx"), 1)),
                ]],
                setL("j", ADD(L("j"), 1)),
            ]],
        ]),
        # row -> fb through the masked palette shadow (fineX window shift)
        ["memlut", "fb", p(PIXBASE), "row", p(PX), 256, "palsh", 0],
        ["ret", 0],
    ]
    return {"params": [], "body": body}

def spr_line_eval_fn():
    # Per-SCANLINE sprite evaluation (runs once at dot 1 of each visible line):
    # scan OAM in order, cache the first ≤8 in-range sprites' x/attr/pattern
    # bytes/OAM-index into i32 'sline' (5 words each). Semantically equal to the
    # old per-pixel 64-entry scan (OAM order = priority, 8-sprite limit, V flip
    # and 8x16 tile split resolved per line); CHR is fetched once per sprite per
    # line through the SAME mapper paths (ppu_read → A12/MMC3, spr_chr_addr →
    # MMC5) instead of once per covered pixel — real HW also fetches sprite
    # patterns once per line (cycles 257-320), so batching is the faithful shape.
    # Verified bit-identical on an MMC3 SMB3 trace + the bg-only test ROM.
    return {"params": [], "body": [
        setp(SL_COUNT, 0),
        gif(["==", p(SHOWSP), 1], [
            setL("big", AND(SHR(p(CTRL), 5), 1)),
            setL("h", ["?:", ["==", L("big"), 1], 16, 8]),
            setL("i", 0), setL("n", 0),
            ["while", ["and", ["<", L("i"), 64], ["<", L("n"), 8]], [
                setL("oy", ["u8", "oam", SHL(L("i"), 2)]),
                setL("dy", ["-", ["-", p(SCAN), L("oy")], 1]),  # sprites delayed 1 scanline
                gif(["and", [">=", L("dy"), 0], ["<", L("dy"), L("h")]], [
                    setL("ot", ["u8", "oam", ADD(SHL(L("i"), 2), 1)]),
                    setL("oa", ["u8", "oam", ADD(SHL(L("i"), 2), 2)]),
                    # V flip over full sprite height (per line, not per pixel)
                    gif(["==", AND(SHR(L("oa"), 7), 1), 1], [setL("dy", ["-", ["-", L("h"), 1], L("dy")])]),
                    # pattern address (8x16 selects table via tile bit0, splits top/bottom tile)
                    gif(["==", L("big"), 1], [
                        setL("tl", AND(L("ot"), 0xFE)),
                        gif([">=", L("dy"), 8], [setL("tl", ADD(L("tl"), 1)), setL("dy", ["-", L("dy"), 8])]),
                        setL("pa", OR(OR(SHL(AND(L("ot"), 1), 12), SHL(L("tl"), 4)), L("dy")))],
                        [setL("pa", OR(OR(p(SPRBASE), SHL(L("ot"), 4)), L("dy")))]),
                    setL("b", ["*", L("n"), 5]),
                    ["seti32", "sline", L("b"), ["u8", "oam", ADD(SHL(L("i"), 2), 3)]],  # x
                    ["seti32", "sline", ADD(L("b"), 1), L("oa")],                        # attr
                    # A12-NEUTRAL pattern fetch (chr_addr direct, not ppu_read): real
                    # HW raises A12 once per line during the sprite-fetch phase, and
                    # THAT edge is already modeled by the synthetic c==260 read in
                    # ppu_step — going through ppu_read here would double-clock the
                    # MMC3 IRQ counter. MMC2/MMC9 tile latches still honored below.
                    gif(["==", p(MAPPER), 9], [call("m9_latch", [L("pa")]),
                                               call("m9_latch", [ADD(L("pa"), 8)])]),
                    ["seti32", "sline", ADD(L("b"), 2), ["?:", ["==", p(MAPPER), 5],
                        ["u8", "chr", call("spr_chr_addr", [L("pa")])],
                        ["u8", "chr", call("chr_addr", [L("pa")])]]],
                    ["seti32", "sline", ADD(L("b"), 3), ["?:", ["==", p(MAPPER), 5],
                        ["u8", "chr", call("spr_chr_addr", [ADD(L("pa"), 8)])],
                        ["u8", "chr", call("chr_addr", [ADD(L("pa"), 8)])]]],
                    ["seti32", "sline", ADD(L("b"), 4), L("i")],                         # OAM index (sprite0)
                    setL("n", ADD(L("n"), 1)),
                ]),
                setL("i", ADD(L("i"), 1)),
            ]],
            setp(SL_COUNT, L("n")),
        ]),
        ["ret", 0],
    ]}

def spr_overflow_eval_fn():
    # count sprites in range on this scanline (Y+1 delay); set overflow flag (bit5)
    # if >8. runs whenever rendering is active (bg OR sprites) — independent of display.
    return {"params": [], "body": [
        setL("i", 0), setL("n", 0),
        setL("h", ["?:", ["==", AND(SHR(p(CTRL), 5), 1), 1], 16, 8]),
        ["while", ["and", ["<", L("i"), 64], ["<", L("n"), 9]], [
            setL("dy", ["-", ["-", p(SCAN), ["u8", "oam", SHL(L("i"), 2)]], 1]),
            gif(["and", [">=", L("dy"), 0], ["<", L("dy"), L("h")]],
                [setL("n", ADD(L("n"), 1))]),
            setL("i", ADD(L("i"), 1)),
        ]],
        gif([">", L("n"), 8], [setp(STATUS, OR(p(STATUS), 0x20))]),
        ["ret", 0],
    ]}

def line_step_fn():
    # One scanline boundary, called at line START (before the line's CPU
    # batch). Events at line granularity; sprite-0 stays dot-exact via
    # S0HITCYC. Replaces the per-dot ppu_step/ppu_tick3 (89k calls/frame).
    return {"params": ["line"], "body": [
        setL("s", L("line")),
        setp(SCAN, L("s")),
        setL("active", ["or", ["==", p(SHOWBG), 1], ["==", p(SHOWSP), 1]]),
        # promote a pending sprite-0 hit whose cycle has passed (keeps STATUS
        # coherent even if the game never reads $2002 at the exact moment)
        gif(["and", [">", p(S0HITCYC), 0], [">=", p(CPUCYC), p(S0HITCYC)]],
            [setp(STATUS, OR(p(STATUS), 0x40)), setp(S0HITCYC, 0)]),
        # vblank start (line 241)
        gif(["==", L("s"), 241], [
            setp(STATUS, OR(p(STATUS), 0x80)),
            gif(["==", p(NMIEN), 1], [setp(NMIPEND, 1)])]),
        # pre-render (261): clear vblank/sprite0/overflow, drop pending s0
        gif(["==", L("s"), 261], [
            setp(STATUS, AND(p(STATUS), 0x1F)),
            setp(S0HITCYC, 0)]),
        # visible line 0: rendering v receives ALL of t (equivalent of the
        # pre-render copyh@257 + copyv@280-304, both done by end of 261 on HW)
        gif(["and", ["==", L("s"), 0], ["==", L("active"), 1]],
            [setp(PV, p(PT))]),
        gif(["and", ["<", L("s"), 240], ["==", L("active"), 1]], [
            setp(PIXBASE, ["*", L("s"), 256]),
            setp(LINESTART, p(CPUCYC)),
            call("spr_overflow_eval"),
            call("spr_line_eval"),
            call("render_line"),
            # v: end-of-line increment + horizontal restore (dots 256/257)
            ppu_incy(),
            ppu_copyh(),
            # MMC3 IRQ: real HW sees exactly one filtered A12 rise per rendered
            # line (the sprite pattern-fetch phase). In the line-batched model
            # ALL fetches share one CPUCYC instant, so the "low ≥3 CPU cycles"
            # filter in a12_clock can never pass — clock the counter directly.
            gif(["or", ["==", p(MAPPER), 4], ["==", p(MAPPER), 118]],
                [call("m3_clock_irq")]),
            # MMC5 scanline IRQ
            gif(["==", p(MAPPER), 5],
                [gif(["==", L("s"), p(M5_IRQTARGET)],
                    [setp(M5_IRQPEND, 1), gif(["==", p(M5_IRQEN), 1], [setp(IRQPEND, 1)])])]),
        ]),
        ["ret", 0],
    ]}

def bus_rd_fn():
    return {"params": ["a"], "body": [
        setp(CPUCYC, ADD(p(CPUCYC), 1)),
        call("apu_step"),
        gif(["==", p(MAPPER), 19], [call("m19_irq_tick")]),
        setL("aa", AND(L("a"), 0xFFFF)),
        gif(["<", L("aa"), 0x2000], [["ret", ["u8", "ram", AND(L("aa"), 0x7FF)]]]),
        gif(["<", L("aa"), 0x4000], [["ret", call("ppu_reg_read", [OR(0x2000, AND(L("aa"), 7))])]]),
        gif(["==", L("aa"), 0x4015], [["ret", call("apu_status")]]),
        gif(["==", L("aa"), 0x4016], [["ret", call("ctrl_read", [0])]]),
        gif(["==", L("aa"), 0x4017], [["ret", call("ctrl_read", [1])]]),
        gif(["and", ["==", p(MAPPER), 5], ["and", [">=", L("aa"), 0x5200], ["<", L("aa"), 0x5210]]],
            [["ret", call("mmc5_read", [L("aa")])]]),
        gif(["and", [">=", L("aa"), 0x6000], ["<", L("aa"), 0x8000]],
            [["ret", ["u8", "prgram", ["-", L("aa"), 0x6000]]]]),
        gif(["<", L("aa"), 0x8000], [["ret", 0]]),
        ["ret", ["u8", "prg", call("prg_addr", [L("aa")])]],
    ]}

def bus_wr_fn():
    return {"params": ["a", "v"], "body": [
        setp(CPUCYC, ADD(p(CPUCYC), 1)),
        call("apu_step"),
        gif(["==", p(MAPPER), 19], [call("m19_irq_tick")]),
        setL("aa", AND(L("a"), 0xFFFF)),
        gif(["<", L("aa"), 0x2000], [["setu8", "ram", AND(L("aa"), 0x7FF), L("v")], ["ret", 0]]),
        gif(["<", L("aa"), 0x4000], [call("ppu_reg_write", [OR(0x2000, AND(L("aa"), 7)), L("v")]), ["ret", 0]]),
        gif(["==", L("aa"), 0x4014], [call("oam_dma", [L("v")]), ["ret", 0]]),
        gif(["==", L("aa"), 0x4016], [call("ctrl_strobe", [L("v")]), ["ret", 0]]),
        gif(["and", [">=", L("aa"), 0x4000], ["<", L("aa"), 0x4018]],
            [call("apu_write", [AND(L("aa"), 0x1F), L("v")]), ["ret", 0]]),
        gif(["and", ["==", p(MAPPER), 19], ["and", [">=", L("aa"), 0x4800], ["<", L("aa"), 0x6000]]],
            [call("m19_write", [L("aa"), L("v")]), ["ret", 0]]),
        gif(["and", ["==", p(MAPPER), 5], ["and", [">=", L("aa"), 0x5000], ["<", L("aa"), 0x6000]]],
            [call("mmc5_write", [L("aa"), L("v")]), ["ret", 0]]),
        gif(["and", [">=", L("aa"), 0x6000], ["<", L("aa"), 0x8000]],
            [["setu8", "prgram", ["-", L("aa"), 0x6000], L("v")], ["ret", 0]]),
        gif(["and", [">=", L("aa"), 0x8000], ["==", p(MAPPER), 1]],
            [call("m1_write", [L("aa"), L("v")]), ["ret", 0]]),
        gif(["and", [">=", L("aa"), 0x8000], ["==", p(MAPPER), 4]],
            [call("m3_write", [L("aa"), L("v")]), ["ret", 0]]),
        gif(["and", [">=", L("aa"), 0x8000], ["==", p(MAPPER), 206]],
            [call("n108_write", [L("aa"), L("v")]), ["ret", 0]]),
        gif(["and", [">=", L("aa"), 0x8000], ["==", p(MAPPER), 9]],
            [call("m9_write", [L("aa"), L("v")]), ["ret", 0]]),
        gif(["and", [">=", L("aa"), 0x8000], ["==", p(MAPPER), 118]],
            [call("m118_write", [L("aa"), L("v")]), ["ret", 0]]),
        gif(["and", [">=", L("aa"), 0x8000], ["==", p(MAPPER), 19]],
            [call("m19_write", [L("aa"), L("v")]), ["ret", 0]]),
        gif(["and", [">=", L("aa"), 0x8000],
                    ["or", ["or", ["==", p(MAPPER), 2], ["==", p(MAPPER), 3]],
                           ["or", ["or", ["==", p(MAPPER), 7], ["==", p(MAPPER), 66]],
                                  ["==", p(MAPPER), 71]]]],
            [call("simple_write", [L("aa"), L("v")]), ["ret", 0]]),
        ["ret", 0],
    ]}

def oam_dma_fn():
    return {"params": ["page"], "body": [
        setL("base", SHL(L("page"), 8)),
        setp(CPUCYC, ADD(p(CPUCYC), 513)),   # DMA stall (~513 CPU cycles)
        setL("i", 0),
        ["while", ["<", L("i"), 256], [
            ["setu8", "oam", AND(ADD(p(OAMADDR), L("i")), 0xFF),
             call("rd_nodma", [ADD(L("base"), L("i"))])],
            setL("i", ADD(L("i"), 1))]],
        ["ret", 0],
    ]}

def rd_nodma_fn():  # read without ticking (used inside DMA which ticks itself)
    return {"params": ["a"], "body": [
        setL("aa", AND(L("a"), 0xFFFF)),
        gif(["<", L("aa"), 0x2000], [["ret", ["u8", "ram", AND(L("aa"), 0x7FF)]]]),
        gif([">=", L("aa"), 0x8000], [["ret", ["u8", "prg", call("prg_addr", [L("aa")])]]]),
        ["ret", 0],
    ]}

# controller state uses p[] slots CTRL_STROBE/SH0/SH1/LATCH0/LATCH1 (see indices)
def ctrl_read_fn():
    # 1:1 port of NESd input/controller.dart: strobe→A repeatedly; else serial
    # shift of latched status; reads past 8 return 1. Button order a,b,select,
    # start,up,down,left,right (bit0..7). Host input[n] holds the 8-bit mask.
    return {"params": ["n"], "body": [
        gif(["==", p(CTRL_STROBE), 1], [["ret", AND(["host", "input", [L("n")]], 1)]]),
        gif(["==", L("n"), 0], [
            setL("sh", p(CTRL_SH0)),
            setL("bit", ["?:", ["<", L("sh"), 8], AND(SHR(p(CTRL_LATCH0), L("sh")), 1), 1]),
            gif(["<", L("sh"), 8], [setp(CTRL_SH0, ADD(L("sh"), 1))]),
            ["ret", L("bit")]]),
        setL("sh", p(CTRL_SH1)),
        setL("bit", ["?:", ["<", L("sh"), 8], AND(SHR(p(CTRL_LATCH1), L("sh")), 1), 1]),
        gif(["<", L("sh"), 8], [setp(CTRL_SH1, ADD(L("sh"), 1))]),
        ["ret", L("bit")],
    ]}
def ctrl_strobe_fn():
    return {"params": ["v"], "body": [
        setp(CTRL_STROBE, AND(L("v"), 1)),
        gif(["==", AND(L("v"), 1), 1], [
            setp(CTRL_LATCH0, ["host", "input", [0]]),
            setp(CTRL_LATCH1, ["host", "input", [1]]),
            setp(CTRL_SH0, 0), setp(CTRL_SH1, 0)]),
        ["ret", 0],
    ]}


def prg_addr_fn():
    return {"params": ["a"], "body": [
        setL("reg", AND(SHR(L("a"), 13), 3)),
        setL("off", AND(L("a"), 0x1FFF)),
        gif(["==", L("reg"), 0], [["ret", ADD(p(PB0), L("off"))]]),
        gif(["==", L("reg"), 1], [["ret", ADD(p(PB1), L("off"))]]),
        gif(["==", L("reg"), 2], [["ret", ADD(p(PB2), L("off"))]]),
        ["ret", ADD(p(PB3), L("off"))],
    ]}

def spr_chr_addr_fn():
    return {"params": ["a"], "body": [
        setL("reg", AND(SHR(L("a"), 10), 7)),
        setL("off", AND(L("a"), 0x3FF)),
        gif(["==", L("reg"), 0], [["ret", ADD(p(SPRCB0), L("off"))]]),
        gif(["==", L("reg"), 1], [["ret", ADD(p(SPRCB1), L("off"))]]),
        gif(["==", L("reg"), 2], [["ret", ADD(p(SPRCB2), L("off"))]]),
        gif(["==", L("reg"), 3], [["ret", ADD(p(SPRCB3), L("off"))]]),
        gif(["==", L("reg"), 4], [["ret", ADD(p(SPRCB4), L("off"))]]),
        gif(["==", L("reg"), 5], [["ret", ADD(p(SPRCB5), L("off"))]]),
        gif(["==", L("reg"), 6], [["ret", ADD(p(SPRCB6), L("off"))]]),
        ["ret", ADD(p(SPRCB7), L("off"))],
    ]}

def chr_addr_fn():
    return {"params": ["a"], "body": [
        setL("reg", AND(SHR(L("a"), 10), 7)),
        setL("off", AND(L("a"), 0x3FF)),
        gif(["==", L("reg"), 0], [["ret", ADD(p(CB0), L("off"))]]),
        gif(["==", L("reg"), 1], [["ret", ADD(p(CB1), L("off"))]]),
        gif(["==", L("reg"), 2], [["ret", ADD(p(CB2), L("off"))]]),
        gif(["==", L("reg"), 3], [["ret", ADD(p(CB3), L("off"))]]),
        gif(["==", L("reg"), 4], [["ret", ADD(p(CB4), L("off"))]]),
        gif(["==", L("reg"), 5], [["ret", ADD(p(CB5), L("off"))]]),
        gif(["==", L("reg"), 6], [["ret", ADD(p(CB6), L("off"))]]),
        ["ret", ADD(p(CB7), L("off"))],
    ]}

def m1_update_fn():
    return {"params": [], "body": [
        setL("pm", AND(SHR(p(M1_CTRL), 2), 3)),
        setL("pb", AND(p(M1_PRG), 0x0F)),
        setL("b0", 0), setL("b1", 0),
        gif(["<", L("pm"), 2], [setL("b0", AND(L("pb"), 0x0E)), setL("b1", OR(AND(L("pb"), 0x0E), 1))]),
        gif(["==", L("pm"), 2], [setL("b0", 0), setL("b1", L("pb"))]),
        gif(["==", L("pm"), 3], [setL("b0", L("pb")), setL("b1", SUB(p(PRGBANKS), 1))]),
        setp(PB0, ["*", L("b0"), 16384]), setp(PB1, ADD(["*", L("b0"), 16384], 8192)),
        setp(PB2, ["*", L("b1"), 16384]), setp(PB3, ADD(["*", L("b1"), 16384], 8192)),
        setL("cm", AND(SHR(p(M1_CTRL), 4), 1)),
        setL("c0", 0), setL("c1", 0),
        gif(["==", L("cm"), 0], [setL("c0", AND(p(M1_CHR0), 0x1E)), setL("c1", OR(AND(p(M1_CHR0), 0x1E), 1))],
            [setL("c0", p(M1_CHR0)), setL("c1", p(M1_CHR1))]),
    ] + [setp([CB0,CB1,CB2,CB3][i], ADD(["*", L("c0"), 4096], i*1024)) for i in range(4)]
      + [setp([CB4,CB5,CB6,CB7][i], ADD(["*", L("c1"), 4096], i*1024)) for i in range(4)]
      + [
        setL("mm", AND(p(M1_CTRL), 3)),
        setp(MIRROR, ["?:", ["==", L("mm"), 0], 2, ["?:", ["==", L("mm"), 1], 3, ["?:", ["==", L("mm"), 2], 0, 1]]]),
        ["ret", 0],
    ]}

def m1_write_fn():
    return {"params": ["a", "v"], "body": [
        gif(["==", AND(SHR(L("v"), 7), 1), 1], [
            setp(M1_SHIFT, 0x10), setp(M1_CTRL, OR(p(M1_CTRL), 0x0C)),
            call("m1_update"), ["ret", 0]]),
        gif(["==", AND(p(M1_SHIFT), 1), 1], [
            setL("reg", AND(SHR(L("a"), 13), 3)),
            setL("rv", OR(SHL(AND(L("v"), 1), 4), AND(SHR(p(M1_SHIFT), 1), 0x0F))),
            setp(M1_SHIFT, 0x10),
            gif(["==", L("reg"), 0], [setp(M1_CTRL, L("rv"))]),
            gif(["==", L("reg"), 1], [setp(M1_CHR0, L("rv"))]),
            gif(["==", L("reg"), 2], [setp(M1_CHR1, L("rv"))]),
            gif(["==", L("reg"), 3], [setp(M1_PRG, L("rv"))]),
            call("m1_update"), ["ret", 0]]),
        setp(M1_SHIFT, OR(SHR(p(M1_SHIFT), 1), SHL(AND(L("v"), 1), 4))),
        ["ret", 0],
    ]}


def m3_update_fn():
    body = [
        # PRG (8KB banks)
        gif(["==", p(M3_PRGMODE), 0], [
            setp(PB0, ["*", p(M3_R6), 8192]), setp(PB1, ["*", p(M3_R7), 8192]),
            setp(PB2, ["*", SUB(p(PRG8), 2), 8192]), setp(PB3, ["*", SUB(p(PRG8), 1), 8192])],
            [setp(PB0, ["*", SUB(p(PRG8), 2), 8192]), setp(PB1, ["*", p(M3_R7), 8192]),
             setp(PB2, ["*", p(M3_R6), 8192]), setp(PB3, ["*", SUB(p(PRG8), 1), 8192])]),
        # CHR (1KB banks)
        gif(["==", p(M3_CHRMODE), 0], [
            setp(CB0, ["*", p(M3_R0), 1024]), setp(CB1, ["*", ADD(p(M3_R0), 1), 1024]),
            setp(CB2, ["*", p(M3_R1), 1024]), setp(CB3, ["*", ADD(p(M3_R1), 1), 1024]),
            setp(CB4, ["*", p(M3_R2), 1024]), setp(CB5, ["*", p(M3_R3), 1024]),
            setp(CB6, ["*", p(M3_R4), 1024]), setp(CB7, ["*", p(M3_R5), 1024])],
            [setp(CB0, ["*", p(M3_R2), 1024]), setp(CB1, ["*", p(M3_R3), 1024]),
             setp(CB2, ["*", p(M3_R4), 1024]), setp(CB3, ["*", p(M3_R5), 1024]),
             setp(CB4, ["*", p(M3_R0), 1024]), setp(CB5, ["*", ADD(p(M3_R0), 1), 1024]),
             setp(CB6, ["*", p(M3_R1), 1024]), setp(CB7, ["*", ADD(p(M3_R1), 1), 1024])]),
        ["ret", 0]]
    return {"params": [], "body": body}

def m3_write_fn():
    return {"params": ["a", "v"], "body": [
        setL("k", AND(L("a"), 0xE001)),
        gif(["==", L("k"), 0x8000], [
            setp(M3_REG, AND(L("v"), 7)), setp(M3_PRGMODE, AND(SHR(L("v"), 6), 1)),
            setp(M3_CHRMODE, AND(SHR(L("v"), 7), 1)), call("m3_update"), ["ret", 0]]),
        gif(["==", L("k"), 0x8001], [
            setL("r", p(M3_REG)),
            gif(["==", L("r"), 0], [setp(M3_R0, AND(L("v"), 0xFE))]),
            gif(["==", L("r"), 1], [setp(M3_R1, AND(L("v"), 0xFE))]),
            gif(["==", L("r"), 2], [setp(M3_R2, L("v"))]),
            gif(["==", L("r"), 3], [setp(M3_R3, L("v"))]),
            gif(["==", L("r"), 4], [setp(M3_R4, L("v"))]),
            gif(["==", L("r"), 5], [setp(M3_R5, L("v"))]),
            gif(["==", L("r"), 6], [setp(M3_R6, AND(L("v"), 0x3F))]),
            gif(["==", L("r"), 7], [setp(M3_R7, AND(L("v"), 0x3F))]),
            call("m3_update"), ["ret", 0]]),
        gif(["==", L("k"), 0xA000], [setp(MIRROR, AND(L("v"), 1)), ["ret", 0]]),
        gif(["==", L("k"), 0xC000], [setp(M3_IRQLATCH, L("v")), ["ret", 0]]),
        gif(["==", L("k"), 0xC001], [setp(M3_IRQRELOAD, 1), setp(M3_IRQCOUNT, 0), ["ret", 0]]),
        gif(["==", L("k"), 0xE000], [setp(M3_IRQEN, 0), setp(IRQPEND, 0), ["ret", 0]]),
        gif(["==", L("k"), 0xE001], [setp(M3_IRQEN, 1), ["ret", 0]]),
        ["ret", 0],
    ]}


def a12_clock_fn():
    # 1:1 NESd mmc3._a12RisingEdgeDetected: rising edge counts only if A12 was
    # low >= 3 CPU cycles; on such an edge, clock the MMC3 IRQ counter.
    return {"params": ["addr"], "body": [
        gif(["==", AND(SHR(L("addr"), 12), 1), 1], [
            gif(["and", [">", p(A12LOW), 0], [">=", SUB(p(CPUCYC), p(A12LOW)), 3]],
                [gif(["or", ["==", p(MAPPER), 4], ["==", p(MAPPER), 118]], [call("m3_clock_irq")])]),
            setp(A12LOW, 0),
        ], [
            gif(["==", p(A12LOW), 0], [setp(A12LOW, p(CPUCYC))]),
        ]),
        ["ret", 0]]}

def m3_clock_irq_fn():
    return {"params": [], "body": [
        gif(["or", ["==", p(M3_IRQCOUNT), 0], ["==", p(M3_IRQRELOAD), 1]],
            [setp(M3_IRQCOUNT, p(M3_IRQLATCH))],
            [setp(M3_IRQCOUNT, SUB(p(M3_IRQCOUNT), 1))]),
        gif(["and", ["==", p(M3_IRQCOUNT), 0], ["==", p(M3_IRQEN), 1]], [setp(IRQPEND, 1)]),
        setp(M3_IRQRELOAD, 0), ["ret", 0]]}



def n108_update_fn():
    return {"params": [], "body": [
        setp(PB0, ["*", p(M3_R6), 8192]), setp(PB1, ["*", p(M3_R7), 8192]),
        setp(PB2, ["*", SUB(p(PRG8), 2), 8192]), setp(PB3, ["*", SUB(p(PRG8), 1), 8192]),
        setp(CB0, ["*", p(M3_R0), 1024]), setp(CB1, ["*", ADD(p(M3_R0), 1), 1024]),
        setp(CB2, ["*", p(M3_R1), 1024]), setp(CB3, ["*", ADD(p(M3_R1), 1), 1024]),
        setp(CB4, ["*", p(M3_R2), 1024]), setp(CB5, ["*", p(M3_R3), 1024]),
        setp(CB6, ["*", p(M3_R4), 1024]), setp(CB7, ["*", p(M3_R5), 1024]),
        ["ret", 0]]}

def n108_write_fn():
    return {"params": ["a", "v"], "body": [
        gif(["==", AND(L("a"), 0x9001), 0x8000], [setp(M3_REG, AND(L("v"), 7)), ["ret", 0]]),
        gif(["==", AND(L("a"), 0x9001), 0x8001], [
            gif(["==", p(M3_REG), 0], [setp(M3_R0, L("v"))]),
            gif(["==", p(M3_REG), 1], [setp(M3_R1, L("v"))]),
            gif(["==", p(M3_REG), 2], [setp(M3_R2, L("v"))]),
            gif(["==", p(M3_REG), 3], [setp(M3_R3, L("v"))]),
            gif(["==", p(M3_REG), 4], [setp(M3_R4, L("v"))]),
            gif(["==", p(M3_REG), 5], [setp(M3_R5, L("v"))]),
            gif(["==", p(M3_REG), 6], [setp(M3_R6, L("v"))]),
            gif(["==", p(M3_REG), 7], [setp(M3_R7, L("v"))]),
            call("n108_update"), ["ret", 0]]),
        ["ret", 0]]}


def m9_update_chr_fn():
    return {"params": [], "body": [
        setL("c0", ["*", ["?:", ["==", p(M3_R5), 0], p(M3_R1), p(M3_R2)], 4096]),
        setL("c1", ["*", ["?:", ["==", p(M3_R6), 0], p(M3_R3), p(M3_R4)], 4096]),
        setp(CB0, L("c0")), setp(CB1, ADD(L("c0"), 1024)), setp(CB2, ADD(L("c0"), 2048)), setp(CB3, ADD(L("c0"), 3072)),
        setp(CB4, L("c1")), setp(CB5, ADD(L("c1"), 1024)), setp(CB6, ADD(L("c1"), 2048)), setp(CB7, ADD(L("c1"), 3072)),
        ["ret", 0]]}

def m9_write_fn():
    return {"params": ["a", "v"], "body": [
        setL("r", AND(L("a"), 0xF000)),
        gif(["==", L("r"), 0xA000], [setp(M3_R0, AND(L("v"), 0xF)),
            setp(PB0, ["*", AND(L("v"), 0xF), 8192]),
            setp(PB1, ["*", SUB(p(PRG8), 3), 8192]),
            setp(PB2, ["*", SUB(p(PRG8), 2), 8192]),
            setp(PB3, ["*", SUB(p(PRG8), 1), 8192]), ["ret", 0]]),
        gif(["==", L("r"), 0xB000], [setp(M3_R1, AND(L("v"), 0x1F)), call("m9_update_chr"), ["ret", 0]]),
        gif(["==", L("r"), 0xC000], [setp(M3_R2, AND(L("v"), 0x1F)), call("m9_update_chr"), ["ret", 0]]),
        gif(["==", L("r"), 0xD000], [setp(M3_R3, AND(L("v"), 0x1F)), call("m9_update_chr"), ["ret", 0]]),
        gif(["==", L("r"), 0xE000], [setp(M3_R4, AND(L("v"), 0x1F)), call("m9_update_chr"), ["ret", 0]]),
        gif(["==", L("r"), 0xF000], [setp(MIRROR, AND(L("v"), 1)), ["ret", 0]]),  # 0=horiz,1=vert (1:1 NESd)
        ["ret", 0]]}

def m9_latch_fn():
    return {"params": ["addr"], "body": [
        gif(["==", L("addr"), 0x0FD8], [setp(M3_R5, 0), call("m9_update_chr")]),
        gif(["==", L("addr"), 0x0FE8], [setp(M3_R5, 1), call("m9_update_chr")]),
        gif(["and", [">=", L("addr"), 0x1FD8], ["<=", L("addr"), 0x1FDF]], [setp(M3_R6, 0), call("m9_update_chr")]),
        gif(["and", [">=", L("addr"), 0x1FE8], ["<=", L("addr"), 0x1FEF]], [setp(M3_R6, 1), call("m9_update_chr")]),
        ["ret", 0]]}


def m118_write_fn():
    return {"params": ["a", "v"], "body": [
        setL("k", AND(L("a"), 0xE001)),
        gif(["==", L("k"), 0x8001], [
            setL("nt", AND(SHR(L("v"), 7), 1)),
            gif(["and", ["==", p(M3_REG), 0], ["==", p(M3_CHRMODE), 0]], [setp(NT0, L("nt")), setp(NT1, L("nt"))]),
            gif(["and", ["==", p(M3_REG), 1], ["==", p(M3_CHRMODE), 0]], [setp(NT2, L("nt")), setp(NT3, L("nt"))]),
            gif(["and", ["==", p(M3_REG), 2], ["==", p(M3_CHRMODE), 1]], [setp(NT0, L("nt"))]),
            gif(["and", ["==", p(M3_REG), 3], ["==", p(M3_CHRMODE), 1]], [setp(NT1, L("nt"))]),
            gif(["and", ["==", p(M3_REG), 4], ["==", p(M3_CHRMODE), 1]], [setp(NT2, L("nt"))]),
            gif(["and", ["==", p(M3_REG), 5], ["==", p(M3_CHRMODE), 1]], [setp(NT3, L("nt"))]),
            call("m3_write", [L("a"), AND(L("v"), 0x7F)]), ["ret", 0]]),
        gif(["==", L("k"), 0xA000], [["ret", 0]]),   # TxSROM ignores mirroring writes
        call("m3_write", [L("a"), L("v")]), ["ret", 0]]}


def m19_chr_write(bank_expr, val):
    # bank 0-7 -> CB[bank]=val*1024 (pattern); 8-11 -> NT[bank-8]=val&1 (internal-RAM nametable)
    cbs = [CB0, CB1, CB2, CB3, CB4, CB5, CB6, CB7]
    body = []
    for b in range(8):
        body.append(gif(["==", bank_expr, b], [setp(cbs[b], ["*", val, 1024])]))
    nts = [NT0, NT1, NT2, NT3]
    for b in range(8, 12):
        body.append(gif(["==", bank_expr, b], [setp(nts[b-8], AND(val, 1))]))
    return body

def m19_write_fn():
    return {"params": ["a", "v"], "body": [
        setL("k", AND(L("a"), 0xF800)),
        gif(["==", L("k"), 0x5000], [
            setp(M3_IRQCOUNT, OR(AND(p(M3_IRQCOUNT), 0xFF00), L("v"))), setp(IRQPEND, 0), ["ret", 0]]),
        gif(["==", L("k"), 0x5800], [
            setp(M3_IRQCOUNT, OR(SHL(AND(L("v"), 0x7F), 8), AND(p(M3_IRQCOUNT), 0xFF))),
            setp(M3_IRQEN, AND(SHR(L("v"), 7), 1)), setp(IRQPEND, 0), ["ret", 0]]),
        gif(["and", [">=", L("k"), 0x8000], ["<=", L("k"), 0xD800]],
            [setL("bk", SHR(SUB(L("k"), 0x8000), 11))] + m19_chr_write(L("bk"), L("v")) + [["ret", 0]]),
        gif(["==", L("k"), 0xE000], [setp(M3_R0, AND(L("v"), 0x3F)),
            setp(PB0, ["*", AND(L("v"), 0x3F), 8192]), ["ret", 0]]),
        gif(["==", L("k"), 0xE800], [setp(M3_R1, AND(L("v"), 0x3F)),
            setp(PB1, ["*", AND(L("v"), 0x3F), 8192]), ["ret", 0]]),
        gif(["==", L("k"), 0xF000], [setp(M3_R2, AND(L("v"), 0x3F)),
            setp(PB2, ["*", AND(L("v"), 0x3F), 8192]), ["ret", 0]]),
        ["ret", 0]]}

def m19_irq_tick_fn():
    # 15-bit counter increments each CPU cycle; IRQ fires on reaching 0x7FFF when enabled
    return {"params": [], "body": [
        gif(["<", p(M3_IRQCOUNT), 0x7FFF], [
            setp(M3_IRQCOUNT, ADD(p(M3_IRQCOUNT), 1)),
            gif(["and", ["==", p(M3_IRQCOUNT), 0x7FFF], ["==", p(M3_IRQEN), 1]], [setp(IRQPEND, 1)])]),
        ["ret", 0]]}


def m5_update_prg_fn():
    m = p(M5_PRGMODE)
    def mask(slot, kind):
        v = AND(p(slot), 0x7F)
        if kind == "r2":
            return ["?:", ["or", ["==", m, 1], ["==", m, 2]], AND(v, 0x7E), v]
        if kind == "r4":
            return ["?:", ["==", m, 0], AND(v, 0x7C), ["?:", ["==", m, 1], AND(v, 0x7E), v]]
        return v
    p1 = ["*", AND(p(M5_PRG1), 0x7F), 8192]
    p2 = ["*", mask(M5_PRG2, "r2"), 8192]
    p3 = ["*", AND(p(M5_PRG3), 0x7F), 8192]
    p4 = ["*", mask(M5_PRG4, "r4"), 8192]
    return {"params": [], "body": [
        setL("q2", p2), setL("q4", p4),
        gif(["==", m, 0], [setp(PB0, L("q4")), setp(PB1, ADD(L("q4"), 8192)),
            setp(PB2, ADD(L("q4"), 16384)), setp(PB3, ADD(L("q4"), 24576))]),
        gif(["==", m, 1], [setp(PB0, L("q2")), setp(PB1, ADD(L("q2"), 8192)),
            setp(PB2, L("q4")), setp(PB3, ADD(L("q4"), 8192))]),
        gif(["==", m, 2], [setp(PB0, L("q2")), setp(PB1, ADD(L("q2"), 8192)), setp(PB2, p3), setp(PB3, L("q4"))]),
        gif(["==", m, 3], [setp(PB0, p1), setp(PB1, L("q2")), setp(PB2, p3), setp(PB3, L("q4"))]),
        ["ret", 0]]}

def _m5_chr_banks(dst, r):
    # dst: 8 target CB slots; r: 8 register slots (low or high-repeated) for this mode
    m = p(M5_CHRMODE)
    return [
        gif(["==", m, 0], [setp(dst[i], ADD(["*", p(r[7]), 8192], i*1024)) for i in range(8)]),
        gif(["==", m, 1],
            [setp(dst[i], ADD(["*", p(r[3]), 4096], i*1024)) for i in range(4)] +
            [setp(dst[i], ADD(["*", p(r[7]), 4096], (i-4)*1024)) for i in range(4, 8)]),
        gif(["==", m, 2],
            [setp(dst[2*j],   ["*", p(r[2*j+1]), 2048]) for j in range(4)] +
            [setp(dst[2*j+1], ADD(["*", p(r[2*j+1]), 2048], 1024)) for j in range(4)]),
        gif(["==", m, 3], [setp(dst[i], ["*", p(r[i]), 1024]) for i in range(8)]),
    ]

def m5_update_chr_fn():
    low = [M5_CHR0, M5_CHR1, M5_CHR2, M5_CHR3, M5_CHR4, M5_CHR5, M5_CHR6, M5_CHR7]
    high = [M5_CHR8, M5_CHR9, M5_CHR10, M5_CHR11, M5_CHR8, M5_CHR9, M5_CHR10, M5_CHR11]
    sprcb = [SPRCB0, SPRCB1, SPRCB2, SPRCB3, SPRCB4, SPRCB5, SPRCB6, SPRCB7]
    cb = [CB0, CB1, CB2, CB3, CB4, CB5, CB6, CB7]
    # sprites always use low registers -> SPRCB
    body = _m5_chr_banks(sprcb, low)
    # background: 8x16 sprite mode (PPUCTRL bit5) -> high registers; else low
    body += [gif(["==", AND(SHR(p(CTRL), 5), 1), 1],
                 _m5_chr_banks(cb, high),
                 _m5_chr_banks(cb, low))]
    return {"params": [], "body": body + [["ret", 0]]}

def mmc5_write_fn():
    return {"params": ["a", "v"], "body": [
        gif(["==", L("a"), 0x5100], [setp(M5_PRGMODE, AND(L("v"), 3)), call("m5_update_prg"), ["ret", 0]]),
        gif(["==", L("a"), 0x5101], [setp(M5_CHRMODE, AND(L("v"), 3)), call("m5_update_chr"), ["ret", 0]]),
        gif(["==", L("a"), 0x5104], [setp(M5_EXMODE, AND(L("v"), 3)), ["ret", 0]]),
        gif(["==", L("a"), 0x5106], [setp(M5_FILLTILE, L("v")), ["ret", 0]]),
        gif(["==", L("a"), 0x5107], [setp(M5_FILLCOLOR, AND(L("v"), 3)), ["ret", 0]]),
        gif(["==", L("a"), 0x5200], [setp(M5_SPLITEN, AND(SHR(L("v"), 7), 1)),
            setp(M5_SPLITSIDE, AND(SHR(L("v"), 6), 1)), setp(M5_SPLITTILE, AND(L("v"), 0x1F)), ["ret", 0]]),
        gif(["==", L("a"), 0x5201], [setp(M5_SPLITSCROLL, L("v")), ["ret", 0]]),
        gif(["==", L("a"), 0x5202], [setp(M5_SPLITBANK, AND(L("v"), 0x3F)), ["ret", 0]]),
        gif(["and", [">=", L("a"), 0x5C00], ["<=", L("a"), 0x5FFF]],
            [["setu8", "exram", ["-", L("a"), 0x5C00], L("v")], ["ret", 0]]),
        gif(["==", L("a"), 0x5105], [setp(M5_NT, L("v")),
            setp(MIRROR, ["?:", ["==", AND(L("v"), 3), 0], 2, ["?:", ["==", AND(L("v"), 3), 1], 3, 1]]), ["ret", 0]]),
        gif(["==", L("a"), 0x5114], [setp(M5_PRG0, L("v")), call("m5_update_prg"), ["ret", 0]]),
        gif(["==", L("a"), 0x5115], [setp(M5_PRG1, L("v")), setp(M5_PRG2, L("v")), call("m5_update_prg"), ["ret", 0]]),
        gif(["==", L("a"), 0x5116], [setp(M5_PRG3, L("v")), call("m5_update_prg"), ["ret", 0]]),
        gif(["==", L("a"), 0x5117], [setp(M5_PRG4, L("v")), call("m5_update_prg"), ["ret", 0]]),
        gif(["and", [">=", L("a"), 0x5128], ["<=", L("a"), 0x512B]], [
            gif(["==", L("a"), 0x5128], [setp(M5_CHR8, L("v"))]),
            gif(["==", L("a"), 0x5129], [setp(M5_CHR9, L("v"))]),
            gif(["==", L("a"), 0x512A], [setp(M5_CHR10, L("v"))]),
            gif(["==", L("a"), 0x512B], [setp(M5_CHR11, L("v"))]),
            call("m5_update_chr"), ["ret", 0]]),
        gif(["and", [">=", L("a"), 0x5120], ["<=", L("a"), 0x5127]], [
            gif(["==", L("a"), 0x5120], [setp(M5_CHR0, L("v"))]),
            gif(["==", L("a"), 0x5121], [setp(M5_CHR1, L("v"))]),
            gif(["==", L("a"), 0x5122], [setp(M5_CHR2, L("v"))]),
            gif(["==", L("a"), 0x5123], [setp(M5_CHR3, L("v"))]),
            gif(["==", L("a"), 0x5124], [setp(M5_CHR4, L("v"))]),
            gif(["==", L("a"), 0x5125], [setp(M5_CHR5, L("v"))]),
            gif(["==", L("a"), 0x5126], [setp(M5_CHR6, L("v"))]),
            gif(["==", L("a"), 0x5127], [setp(M5_CHR7, L("v"))]),
            call("m5_update_chr"), ["ret", 0]]),
        gif(["==", L("a"), 0x5203], [setp(M5_IRQTARGET, L("v")), ["ret", 0]]),
        gif(["==", L("a"), 0x5204], [setp(M5_IRQEN, AND(SHR(L("v"), 7), 1)), ["ret", 0]]),
        gif(["==", L("a"), 0x5205], [setp(M5_MULCAND, L("v")), ["ret", 0]]),
        gif(["==", L("a"), 0x5206], [setp(M5_MULER, L("v")), ["ret", 0]]),
        ["ret", 0]]}

def mmc5_read_fn():
    return {"params": ["a"], "body": [
        gif(["==", L("a"), 0x5204], [
            setL("r", OR(["?:", ["==", p(M5_IRQPEND), 1], 0x80, 0], 0)),
            setp(M5_IRQPEND, 0), ["ret", L("r")]]),
        gif(["==", L("a"), 0x5205], [["ret", AND(["*", p(M5_MULCAND), p(M5_MULER)], 0xFF)]]),
        gif(["==", L("a"), 0x5206], [["ret", AND(SHR(["*", p(M5_MULCAND), p(M5_MULER)], 8), 0xFF)]]),
        ["ret", 0]]}

def simple_write_fn():
    return {"params": ["a", "v"], "body": [
        # UNROM (2): 16K switchable @ $8000, fixed last @ $C000; CHR-RAM
        gif(["==", p(MAPPER), 2], [
            setL("b", ["*", AND(L("v"), 0x0F), 16384]),
            setp(PB0, L("b")), setp(PB1, ADD(L("b"), 8192)),
            setp(PB2, ["*", SUB(p(PRGBANKS), 1), 16384]),
            setp(PB3, ADD(["*", SUB(p(PRGBANKS), 1), 16384], 8192)), ["ret", 0]]),
        # BR909x/Camerica (71): same as UNROM — 16K @ $8000, fixed last, CHR-RAM
        gif(["==", p(MAPPER), 71], [
            setL("b", ["*", AND(L("v"), 0x0F), 16384]),
            setp(PB0, L("b")), setp(PB1, ADD(L("b"), 8192)),
            setp(PB2, ["*", SUB(p(PRGBANKS), 1), 16384]),
            setp(PB3, ADD(["*", SUB(p(PRGBANKS), 1), 16384], 8192)), ["ret", 0]]),
        # CNROM (3): 8K CHR bank switch; PRG fixed
        gif(["==", p(MAPPER), 3], [
            setL("cb", ["*", AND(L("v"), 3), 8192])] +
            [setp([CB0,CB1,CB2,CB3,CB4,CB5,CB6,CB7][i], ADD(L("cb"), i*1024)) for i in range(8)] +
            [["ret", 0]]),
        # AxROM (7): 32K PRG bank + single-screen select
        gif(["==", p(MAPPER), 7], [
            setL("pb", ["*", AND(L("v"), 7), 32768]),
            setp(PB0, L("pb")), setp(PB1, ADD(L("pb"), 8192)),
            setp(PB2, ADD(L("pb"), 16384)), setp(PB3, ADD(L("pb"), 24576)),
            setp(MIRROR, ["?:", ["==", AND(SHR(L("v"), 4), 1), 1], 3, 2]), ["ret", 0]]),
        # GxROM (66): PRG 32K bank (bits4-5) + CHR 8K bank (bits0-1)
        gif(["==", p(MAPPER), 66], [
            setL("pb", ["*", AND(SHR(L("v"), 4), 3), 32768]),
            setp(PB0, L("pb")), setp(PB1, ADD(L("pb"), 8192)),
            setp(PB2, ADD(L("pb"), 16384)), setp(PB3, ADD(L("pb"), 24576)),
            setL("cb", ["*", AND(L("v"), 3), 8192])] +
            [setp([CB0,CB1,CB2,CB3,CB4,CB5,CB6,CB7][i], ADD(L("cb"), i*1024)) for i in range(8)] +
            [["ret", 0]]),
        ["ret", 0],
    ]}

def build():
    C_prog = C.build()
    funcs = dict(C_prog["functions"])
    # override CPU bus rd/wr to the ticking bus
    funcs["rd"] = bus_rd_fn()
    funcs["wr"] = bus_wr_fn()
    funcs["rd_nodma"] = rd_nodma_fn()
    funcs["ppu_read"] = ppu_read_fn()
    funcs["ppu_write"] = ppu_write_fn()
    funcs["nt_map"] = nt_map_fn()
    funcs["ppu_reg_read"] = ppu_reg_read_fn()
    funcs["ppu_reg_write"] = ppu_reg_write_fn()
    funcs["render_line"] = render_line_fn()
    funcs["line_step"] = line_step_fn()
    funcs["oam_dma"] = oam_dma_fn()
    funcs["ctrl_read"] = ctrl_read_fn()
    funcs["ctrl_strobe"] = ctrl_strobe_fn()
    funcs["prg_addr"] = prg_addr_fn()
    funcs["chr_addr"] = chr_addr_fn()
    funcs["spr_chr_addr"] = spr_chr_addr_fn()
    funcs["m1_update"] = m1_update_fn()
    funcs["m1_write"] = m1_write_fn()
    funcs["m3_update"] = m3_update_fn()
    funcs["m3_write"] = m3_write_fn()
    funcs["m3_clock_irq"] = m3_clock_irq_fn()
    funcs["a12_clock"] = a12_clock_fn()
    funcs["spr_overflow_eval"] = spr_overflow_eval_fn()
    funcs["spr_line_eval"] = spr_line_eval_fn()
    funcs["n108_update"] = n108_update_fn()
    funcs["n108_write"] = n108_write_fn()
    funcs["m118_write"] = m118_write_fn()
    funcs["m19_write"] = m19_write_fn()
    funcs["m19_irq_tick"] = m19_irq_tick_fn()
    funcs["m5_update_prg"] = m5_update_prg_fn()
    funcs["m5_update_chr"] = m5_update_chr_fn()
    funcs["mmc5_write"] = mmc5_write_fn()
    funcs["mmc5_read"] = mmc5_read_fn()
    funcs["m9_update_chr"] = m9_update_chr_fn()
    funcs["m9_write"] = m9_write_fn()
    funcs["m9_latch"] = m9_latch_fn()
    funcs["simple_write"] = simple_write_fn()

    # NMI service: push PC + P, set I, jump to NMI vector
    funcs["irq"] = {"params": [], "body":
        [C.DR(C.reg(C.PC)), C.DR(C.reg(C.PC))] +          # 2 dummy reads (7-cycle sequence)
        C.push(SHR(C.reg(C.PC), 8)) + C.push(AND(C.reg(C.PC), 0xFF)) +
        C.push(AND(C.reg(C.P), 0xEF)) + [C.setflag(C.IF_, 1),
        C.setreg(C.PC, call("rd16", [0xFFFE]))] + [["ret", 0]]}

    funcs["nmi"] = {"params": [], "body":
        [C.DR(C.reg(C.PC)), C.DR(C.reg(C.PC))] +          # 2 dummy reads (7-cycle sequence)
        C.push(SHR(C.reg(C.PC), 8)) + C.push(AND(C.reg(C.PC), 0xFF)) +
        C.push(C.reg(C.P)) + [C.setflag(C.IF_, 1),
        C.setreg(C.PC, call("rd16", [0xFFFA]))] + [["ret", 0]]}

    # run_frame (scanline model): per line, fire line events + render at line
    # start, then batch the CPU up to the line's absolute cycle target
    # (341 dots / 3; the odd-frame skip makes pre-render 340 when rendering).
    # Instruction overshoot carries into the next line/frame via TGTCYC.
    funcs["run_frame"] = {"params": ["maxInstr"], "body": [
        # resync guard: first call / reset paths re-anchor the cycle target
        gif(["or", ["<", p(TGTCYC), ["-", p(CPUCYC), 400]],
                  [">", p(TGTCYC), ADD(p(CPUCYC), 400)]],
            [setp(TGTCYC, p(CPUCYC)), setp(DOTREM, 0)]),
        # rebase: params live in an Int32List, so an absolute CPUCYC would wrap
        # at 2^31 (~20 min of play) and freeze every `CPUCYC < TGTCYC` compare.
        # Shift all CPUCYC-relative state down once per frame; per-frame growth
        # is ~30k cycles, so values stay bounded forever.
        gif([">", p(CPUCYC), 0x4000000], [
            setL("rb", p(CPUCYC)),
            setp(CPUCYC, 0),
            setp(TGTCYC, SUB(p(TGTCYC), L("rb"))),
            setp(LINESTART, 0),
            gif([">", p(S0HITCYC), 0], [setp(S0HITCYC, 1)]),   # past-due → promote asap
            gif([">", p(A12LOW), 0], [setp(A12LOW, 1)]),
        ]),
        setL("i", 0),
        setL("line", 0),
        ["while", ["and", ["<", L("line"), 262], ["<", L("i"), L("maxInstr")]], [
            call("line_step", [L("line")]),
            setL("dots", 341),
            gif(["and", ["==", L("line"), 261],
                      ["and", ["==", AND(p(FRAMES), 1), 1],
                              ["or", ["==", p(SHOWBG), 1], ["==", p(SHOWSP), 1]]]],
                [setL("dots", 340)]),
            setL("tot", ADD(p(DOTREM), L("dots"))),
            setp(TGTCYC, ADD(p(TGTCYC), ["/", L("tot"), 3])),
            setp(DOTREM, ["%", L("tot"), 3]),
            ["while", ["and", ["<", p(CPUCYC), p(TGTCYC)], ["<", L("i"), L("maxInstr")]], [
                gif(["==", p(NMIPEND), 1], [setp(NMIPEND, 0), call("nmi")]),
                gif(["==", p(SCRATCH1), 1], [setp(SCRATCH1, 0), setp(NMIPEND, 1)]),  # delayed NMI (enable-in-vblank)
                gif(["and", ["or", ["==", p(IRQPEND), 1], ["==", call("apu_irq"), 1]], ["==", C.getflag(C.IF_), 0]],
                    [setp(IRQPEND, 0), call("irq")]),
                call("step"),
                setL("i", ADD(L("i"), 1)),
            ]],
            setL("line", ADD(L("line"), 1)),
        ]],
        setp(FRAMES, ADD(p(FRAMES), 1)),
        setp(SCAN, 0), setp(PIXBASE, 0),
        ["ret", L("i")],
    ]}

    # reset also needs to read reset vector
    funcs["power_on"] = {"params": ["mapper", "prgbanks", "mirror"], "body": [
        setp(MAPPER, L("mapper")), setp(PRGBANKS, L("prgbanks")),
        setp(M1_SHIFT, 0x10), setp(M1_CTRL, 0x0C), setp(M1_CHR0, 0), setp(M1_CHR1, 1),
        setp(M1_PRG, 0),
        setp(PRG8, ["*", L("prgbanks"), 2]),
        # default NROM bank table
        setp(PB0, 0), setp(PB1, 8192),
        setp(PB2, ["?:", ["==", L("prgbanks"), 1], 0, 16384]),
        setp(PB3, ["?:", ["==", L("prgbanks"), 1], 8192, 24576]),
        setp(CB0, 0), setp(CB1, 1024), setp(CB2, 2048), setp(CB3, 3072),
        setp(CB4, 4096), setp(CB5, 5120), setp(CB6, 6144), setp(CB7, 7168),
        setp(M3_R6, 0), setp(M3_R7, 1),
        setp(IRQPEND, 0), setp(M3_IRQEN, 0),
        gif(["==", L("mapper"), 1], [call("m1_update")]),
        gif(["==", L("mapper"), 4], [call("m3_update")]),
        gif(["==", L("mapper"), 118], [setp(MIRROR, 4), call("m3_update")]),
        gif(["==", L("mapper"), 19], [setp(MIRROR, 4), setp(M3_IRQEN, 0), setp(M3_IRQCOUNT, 0)]),
        gif(["==", L("mapper"), 5], [
            setp(M5_PRGMODE, 3), setp(M5_CHRMODE, 3), setp(M5_IRQEN, 0),
            setp(M5_PRG1, 0), setp(M5_PRG2, 1), setp(M5_PRG3, SUB(p(PRG8), 2)),
            setp(M5_PRG4, SUB(p(PRG8), 1)), setp(M5_CHR7, 7), setp(M5_EXMODE, 0),
            call("m5_update_prg"), call("m5_update_chr")]),
        gif(["==", L("mapper"), 206], [setp(M3_R7, 1), call("n108_update")]),
        gif(["==", L("mapper"), 9], [
            setp(PB1, ["*", SUB(p(PRG8), 3), 8192]),
            setp(PB2, ["*", SUB(p(PRG8), 2), 8192]),
            setp(PB3, ["*", SUB(p(PRG8), 1), 8192]), call("m9_update_chr")]),
        gif(["or", ["==", L("mapper"), 2], ["==", L("mapper"), 71]], [
            setp(PB2, ["*", SUB(p(PRGBANKS), 1), 16384]),
            setp(PB3, ADD(["*", SUB(p(PRGBANKS), 1), 16384], 8192))]),
        C.setreg(C.A, 0), C.setreg(C.X, 0), C.setreg(C.Y, 0), C.setreg(C.SP, 0xFD),
        C.setreg(C.P, 0x24), C.setreg(C.CYC, 0), C.setreg(C.HALT, 0),
        setp(MIRROR, L("mirror")), setp(SCAN, 0), setp(CYC, 0), setp(FRAMES, 0),
        setp(VINC, 1), setp(STATUS, 0),
        C.setreg(C.PC, call("rd16", [0xFFFC])),
        call("apu_reset_state"),
        ["ret", 0],
    ]}

    # Load a full iNES (.nes) image sitting in the `ines` buffer: parse the 16-byte
    # header (PRG/CHR bank counts, mapper, mirroring, trainer), copy PRG-ROM -> prg
    # and CHR-ROM -> chr, then power_on with the decoded mapper. Returns the mapper
    # number, or -1 if the header magic ("NES\x1A") is missing. 1:1 with NESd's
    # cartridge/ines_reader (bytes 4/5 = 16K/8K bank counts; byte6: bit0 mirroring,
    # bit2 trainer, bit3 four-screen, hi-nibble mapper low; byte7 hi-nibble mapper high).
    funcs["load_ines"] = {"params": [], "body": [
        gif(["and", ["==", ["u8", "ines", 0], 0x4E], ["==", ["u8", "ines", 3], 0x1A]], [
            setL("prgbanks", ["u8", "ines", 4]),
            setL("chrbanks", ["u8", "ines", 5]),
            setL("f6", ["u8", "ines", 6]),
            setL("f7", ["u8", "ines", 7]),
            setL("mapper", OR(SHR(L("f6"), 4), AND(L("f7"), 0xF0))),
            setL("mirror", ["?:", ["==", AND(L("f6"), 8), 8], 4, AND(L("f6"), 1)]),
            setL("prgoff", ADD(16, ["?:", ["==", AND(L("f6"), 4), 4], 512, 0])),
            setL("prgsize", ["*", L("prgbanks"), 16384]),
            setL("chroff", ADD(L("prgoff"), L("prgsize"))),
            setL("chrsize", ["*", L("chrbanks"), 8192]),
            # PRG-ROM -> prg (clamped to prg buffer capacity, 512KB)
            setL("n", ["?:", ["<", 524288, L("prgsize")], 524288, L("prgsize")]),
            setL("i", 0),
            ["while", ["<", L("i"), L("n")], [
                ["setu8", "prg", L("i"), ["u8", "ines", ADD(L("prgoff"), L("i"))]],
                setL("i", ADD(L("i"), 1))]],
            # CHR-ROM -> chr (clamped to 128KB; chrbanks==0 => CHR-RAM, nothing to copy)
            setL("cn", ["?:", ["<", 131072, L("chrsize")], 131072, L("chrsize")]),
            setL("j", 0),
            ["while", ["<", L("j"), L("cn")], [
                ["setu8", "chr", L("j"), ["u8", "ines", ADD(L("chroff"), L("j"))]],
                setL("j", ADD(L("j"), 1))]],
            call("power_on", [L("mapper"), L("prgbanks"), L("mirror")]),
            ["ret", L("mapper")]]),
        ["ret", -1],
    ]}

    apu = APU.build_apu()
    funcs.update(apu["funcs"])
    buffers = {"ram": 2048, "prg": 524288, "chr": 131072, "vram": 2048,
               "pal": 32, "oam": 256, "oam2": 32, "fb": 61440, "prgram": 8192, "exram": 1024,
               # scanline-model scratch: 33-tile bg row (264px), sprite claim
               # mask (first-in-OAM-order wins), 8px sprite decode scratch,
               # masked palette shadow (pal[i]&0x3F) for the row→fb memlut
               "row": 264, "sclaim": 264, "sprscr": 8, "palsh": 32,
               # raw .nes image staging area for load_ines (holds header+PRG+CHR of a
               # picked ROM: up to 512KB PRG + 128KB CHR + trainer/header, 1MB headroom)
               "ines": 1048576}
    buffers.update(apu["buffers"])
    for name, tbl in apu["u8tables"].items():
        buffers[name] = len(tbl)
    i32 = {"reg": 8, "p": 144, "sline": 40}  # sline: 8 line sprites x [x,attr,plo,phi,idx]
    i32.update(apu["i32bufs"])
    init = {}
    init.update(apu["u8tables"])
    init.update(apu["i32tables"])
    prog = {"buffers": buffers, "i32": i32, "functions": funcs, "init": init}
    return prog

if __name__ == "__main__":
    import os
    prog = build()
    out = os.path.join(os.path.dirname(__file__), "nesd_nes.json")
    json.dump(prog, open(out, "w"))
    print("wrote", out, "functions:", len(prog["functions"]))
