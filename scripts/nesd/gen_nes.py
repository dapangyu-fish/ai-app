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
 A12LOW, CPUCYC) = range(83)

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

def ppu_read_fn():
    return {"params": ["a"], "body": [
        setL("a", AND(L("a"), 0x3FFF)),
        call("a12_clock", [L("a")]),
        gif(["<", L("a"), 0x2000], [["ret", ["u8", "chr", call("chr_addr", [L("a")])]]]),
        gif(["<", L("a"), 0x3F00], [["ret", ["u8", "vram", nt_index(L("a"))]]]),
        # palette
        setL("pi", AND(L("a"), 0x1F)),
        gif(["==", AND(L("pi"), 0x13), 0x10], [setL("pi", ["-", L("pi"), 0x10])]),
        ["ret", ["u8", "pal", L("pi")]],
    ]}

def ppu_write_fn():
    return {"params": ["a", "v"], "body": [
        setL("a", AND(L("a"), 0x3FFF)),
        call("a12_clock", [L("a")]),
        gif(["<", L("a"), 0x2000], [["setu8", "chr", call("chr_addr", [L("a")]), L("v")], ["ret", 0]]),
        gif(["<", L("a"), 0x3F00], [["setu8", "vram", nt_index(L("a")), L("v")], ["ret", 0]]),
        setL("pi", AND(L("a"), 0x1F)),
        gif(["==", AND(L("pi"), 0x13), 0x10], [setL("pi", ["-", L("pi"), 0x10])]),
        ["setu8", "pal", L("pi"), AND(L("v"), 0x3F)],
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
        ["ret", OR(0x400, L("off"))],                          # single screen 1
    ]}

# ---- PPU register read/write (CPU side) ----
def ppu_reg_read_fn():
    # a = 0x2000..0x3FFF (mirrored to 8); returns value
    return {"params": ["a"], "body": [
        setL("r", AND(L("a"), 7)),
        gif(["==", L("r"), 2], [   # PPUSTATUS
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
                 call("a12_clock", [AND(p(PV), 0x3FFF)])]),
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

def ppu_fetch_cycle():
    # subcycle = cycle & 7
    return [setL("sc", AND(p(CYC), 7)),
        gif(["==", L("sc"), 1], [setp(NTLATCH, call("ppu_read", [OR(0x2000, AND(p(PV), 0xFFF))]))]),
        gif(["==", L("sc"), 3], [   # attribute
            setL("at", call("ppu_read", [OR(OR(OR(0x23C0, SHL(AND(SHR(p(PV), 10), 3), 10)),
                                               SHL(AND(SHR(p(PV), 5), 0x1C), 1)),
                                            SHR(AND(p(PV), 0x1C), 2))])),
            setL("shift", OR(AND(SHR(p(PV), 4), 4), AND(p(PV), 2))),
            setp(ATLATCH, AND(SHR(L("at"), L("shift")), 3))]),
        gif(["==", L("sc"), 5], [
            setp(PTL, call("ppu_read", [OR(OR(p(BGBASE), SHL(p(NTLATCH), 4)), v_fineY())]))]),
        gif(["==", L("sc"), 7], [
            setp(PTH, call("ppu_read", [OR(OR(OR(p(BGBASE), SHL(p(NTLATCH), 4)), v_fineY()), 8)]))]),
        gif(["==", L("sc"), 0], [
            # load shift regs
            setp(PTLSHIFT, OR(AND(p(PTLSHIFT), 0xFF00), p(PTL))),
            setp(PTHSHIFT, OR(AND(p(PTHSHIFT), 0xFF00), p(PTH))),
            setp(ATTR, p(ATLATCH)),
            ppu_incx()]),
    ]

def ppu_shift():
    return [setp(PTLSHIFT, AND(SHL(p(PTLSHIFT), 1), 0xFFFF)),
            setp(PTHSHIFT, AND(SHL(p(PTHSHIFT), 1), 0xFFFF)),
            setp(ATLSHIFT, OR(SHL(p(ATLSHIFT), 1), AND(p(ATTR), 1))),
            setp(ATHSHIFT, OR(SHL(p(ATHSHIFT), 1), AND(SHR(p(ATTR), 1), 1)))]

def bg_pixel():
    # returns 0..15 palette entry for background at fineX using shift regs
    return [
        setL("bit", ["-", 15, p(PX)]),
        setL("lo", AND(SHR(p(PTLSHIFT), L("bit")), 1)),
        setL("hi", AND(SHR(p(PTHSHIFT), L("bit")), 1)),
        setL("px", OR(SHL(L("hi"), 1), L("lo"))),
        setL("abit", ["-", 7, p(PX)]),
        setL("al", AND(SHR(p(ATLSHIFT), L("abit")), 1)),
        setL("ah", AND(SHR(p(ATHSHIFT), L("abit")), 1)),
        setL("at", OR(SHL(L("ah"), 1), L("al"))),
        gif(["==", L("px"), 0], [setL("bgc", 0)],
            [setL("bgc", OR(SHL(L("at"), 2), L("px")))]),
    ]

def render_pixel():
    # writes fb[PIXBASE + currentX] = palette index (0..63) from ppu_read(0x3F00+bgc)
    return [
        gif(["==", p(SHOWBG), 0],
            [setL("bgc", 0)],               # background off → backdrop (no bg pixel, no sprite-0 hit)
            bg_pixel()),
        # left-edge clip: hide background in leftmost 8 px when SHOWBGL off
        gif(["and", ["<", ["-", p(CYC), 1], 8], ["==", p(SHOWBGL), 0]], [setL("bgc", 0)]),
    ] + render_sprite_over() + [
        setL("palidx", call("ppu_read", [OR(0x3F00, L("bgc"))])),
        ["setu8", "fb", ADD(p(PIXBASE), ["-", p(CYC), 1]), AND(L("palidx"), 0x3F)],
    ]

def render_sprite_over():
    # per-pixel sprite scan of OAM. 8x8 and 8x16 (PPUCTRL bit5). first-opaque wins
    # (OAM order = priority). limits to 8 in-range sprites/scanline + sets overflow
    # flag; sprite0 hit + front/back priority respected.
    return [
        gif(["==", p(SHOWSP), 1], [
            setL("sx", ["-", p(CYC), 1]),
            setL("sy", p(SCAN)),
            setL("big", AND(SHR(p(CTRL), 5), 1)),          # 8x16 sprites?
            setL("h", ["?:", ["==", L("big"), 1], 16, 8]),
            setL("si", 0),
            setL("done", 0),
            setL("nvis", 0),                               # in-range sprite count this scanline
            gif(["or", [">=", L("sx"), 8], ["==", p(SHOWSPL), 1]], [   # left-edge sprite clip
            ["while", ["and", ["<", L("si"), 64], ["==", L("done"), 0]], [
                setL("oy", ["u8", "oam", SHL(L("si"), 2)]),
                setL("ot", ["u8", "oam", ADD(SHL(L("si"), 2), 1)]),
                setL("oa", ["u8", "oam", ADD(SHL(L("si"), 2), 2)]),
                setL("ox", ["u8", "oam", ADD(SHL(L("si"), 2), 3)]),
                setL("dy", ["-", ["-", L("sy"), L("oy")], 1]),   # sprites delayed 1 scanline (OAM Y = screen Y - 1)
                setL("dx", ["-", L("sx"), L("ox")]),
                gif(["and", [">=", L("dy"), 0], ["<", L("dy"), L("h")]], [
                    setL("nvis", ADD(L("nvis"), 1)),
                    gif([">", L("nvis"), 8],                # 9th in-range: not in secondary OAM (overflow set in eval pass)
                        [setL("done", 1)],
                    [gif(["and", [">=", L("dx"), 0], ["<", L("dx"), 8]], [
                    # V flip (over full sprite height), then H flip
                    gif(["==", AND(SHR(L("oa"), 7), 1), 1], [setL("dy", ["-", ["-", L("h"), 1], L("dy")])]),
                    gif(["==", AND(SHR(L("oa"), 6), 1), 1], [setL("dx", ["-", 7, L("dx")])]),
                    # pattern address (8x16 selects table via tile bit0, splits top/bottom tile)
                    gif(["==", L("big"), 1], [
                        setL("tl", AND(L("ot"), 0xFE)),
                        gif([">=", L("dy"), 8], [setL("tl", ADD(L("tl"), 1)), setL("dy", ["-", L("dy"), 8])]),
                        setL("pa", OR(OR(SHL(AND(L("ot"), 1), 12), SHL(L("tl"), 4)), L("dy")))],
                        [setL("pa", OR(OR(p(SPRBASE), SHL(L("ot"), 4)), L("dy")))]),
                    setL("plo", AND(SHR(call("ppu_read", [L("pa")]), ["-", 7, L("dx")]), 1)),
                    setL("phi", AND(SHR(call("ppu_read", [ADD(L("pa"), 8)]), ["-", 7, L("dx")]), 1)),
                    setL("spx", OR(SHL(L("phi"), 1), L("plo"))),
                    gif(["!=", L("spx"), 0], [
                        # sprite0 hit (never at x=255)
                        gif(["and", ["and", ["==", L("si"), 0], ["!=", L("bgc"), 0]], ["<", L("sx"), 255]],
                            [setp(STATUS, OR(p(STATUS), 0x40))]),
                        # priority: if front OR bg transparent, sprite wins
                        gif(["or", ["==", AND(SHR(L("oa"), 5), 1), 0], ["==", L("bgc"), 0]],
                            [setL("bgc", OR(0x10, OR(SHL(AND(L("oa"), 3), 2), L("spx"))))]),
                        setL("done", 1)]),
                    ])]),
                ]),
                setL("si", ADD(L("si"), 1)),
            ]]]),
        ]),
    ]

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

def ppu_step_fn():
    # one PPU dot. scanline in p[SCAN], cycle in p[CYC].
    body = [
        setL("s", p(SCAN)),
        setL("c", p(CYC)),
        setL("active", ["or", ["==", p(SHOWBG), 1], ["==", p(SHOWSP), 1]]),
        # visible scanlines 0..239
        gif(["<", L("s"), 240], [
            gif(["==", L("active"), 1], [
                gif(["and", [">=", L("c"), 1], ["<=", L("c"), 256]],
                    render_pixel() + ppu_shift() + ppu_fetch_cycle()),
                gif(["and", [">=", L("c"), 321], ["<=", L("c"), 336]],
                    ppu_shift() + ppu_fetch_cycle()),
                gif(["==", L("c"), 256], [ppu_incy()]),
                gif(["==", L("c"), 257], [ppu_copyh()]),
            ]),
            # sprite overflow eval runs only when rendering active (bg or sprites)
            gif(["and", ["==", L("c"), 256], ["==", L("active"), 1]], [call("spr_overflow_eval")]),
        ]),
        # pre-render line 261
        gif(["==", L("s"), 261], [
            gif(["==", L("c"), 1], [setp(STATUS, AND(p(STATUS), 0x1F))]),  # clear vblank+s0+overflow
            gif(["==", L("active"), 1], [
                gif(["and", [">=", L("c"), 1], ["<=", L("c"), 256]],
                    ppu_shift() + ppu_fetch_cycle()),
                gif(["and", [">=", L("c"), 321], ["<=", L("c"), 336]],
                    ppu_shift() + ppu_fetch_cycle()),
                gif(["==", L("c"), 256], [ppu_incy()]),
                gif(["==", L("c"), 257], [ppu_copyh()]),
                gif(["and", [">=", L("c"), 280], ["<=", L("c"), 304]], [ppu_copyv()]),
            ]),
        ]),
        # vblank start scanline 241 cycle 1
        # sprite pattern fetch phase raises A12 (SPRBASE); drives MMC3 IRQ via a12_clock
        gif(["and", ["and", ["<", L("s"), 240], ["==", L("c"), 260]],
                    ["==", L("active"), 1]],
            [call("ppu_read", [OR(p(SPRBASE), 0xFF0)])]),
        gif(["and", ["==", L("s"), 241], ["==", L("c"), 1]], [
            setp(STATUS, OR(p(STATUS), 0x80)),
            gif(["==", p(NMIEN), 1], [setp(NMIPEND, 1)]),
        ]),
        # advance counters
        setp(CYC, ADD(L("c"), 1)),
        # odd-frame dot skip: pre-render line is 340 dots (not 341) on odd frames
        # when rendering is enabled (1:1 NESd _updateCounters); shortens frame by 1 dot
        gif(["and", ["and", ["==", p(SCAN), 261], ["==", p(CYC), 340]],
                    ["and", ["==", AND(p(FRAMES), 1), 1], ["==", L("active"), 1]]],
            [setp(CYC, 0), setp(SCAN, 0),
             setp(FRAMES, ADD(p(FRAMES), 1)), setp(PIXBASE, 0)],
            [gif([">", p(CYC), 340], [
                setp(CYC, 0),
                setp(SCAN, ADD(p(SCAN), 1)),
                gif([">", p(SCAN), 261], [
                    setp(SCAN, 0), setp(FRAMES, ADD(p(FRAMES), 1)),
                    setp(PIXBASE, 0)]),
                gif(["and", ["<", p(SCAN), 240], [">", p(SCAN), 0]],
                    [setp(PIXBASE, ["*", p(SCAN), 256])]),
            ])]),
        ["ret", 0],
    ]
    return {"params": [], "body": body}

def ppu_tick3_fn():
    return {"params": [], "body": [
        call("ppu_step"), call("ppu_step"), call("ppu_step"), ["ret", 0]]}

# ---- Bus: CPU rd/wr with PPU tick + OAM DMA ----
def bus_rd_fn():
    return {"params": ["a"], "body": [
        setp(CPUCYC, ADD(p(CPUCYC), 1)),
        call("ppu_tick3"),
        call("apu_step"),
        setL("aa", AND(L("a"), 0xFFFF)),
        gif(["<", L("aa"), 0x2000], [["ret", ["u8", "ram", AND(L("aa"), 0x7FF)]]]),
        gif(["<", L("aa"), 0x4000], [["ret", call("ppu_reg_read", [OR(0x2000, AND(L("aa"), 7))])]]),
        gif(["==", L("aa"), 0x4015], [["ret", call("apu_status")]]),
        gif(["==", L("aa"), 0x4016], [["ret", call("ctrl_read", [0])]]),
        gif(["==", L("aa"), 0x4017], [["ret", call("ctrl_read", [1])]]),
        gif(["and", [">=", L("aa"), 0x6000], ["<", L("aa"), 0x8000]],
            [["ret", ["u8", "prgram", ["-", L("aa"), 0x6000]]]]),
        gif(["<", L("aa"), 0x8000], [["ret", 0]]),
        ["ret", ["u8", "prg", call("prg_addr", [L("aa")])]],
    ]}

def bus_wr_fn():
    return {"params": ["a", "v"], "body": [
        setp(CPUCYC, ADD(p(CPUCYC), 1)),
        call("ppu_tick3"),
        call("apu_step"),
        setL("aa", AND(L("a"), 0xFFFF)),
        gif(["<", L("aa"), 0x2000], [["setu8", "ram", AND(L("aa"), 0x7FF), L("v")], ["ret", 0]]),
        gif(["<", L("aa"), 0x4000], [call("ppu_reg_write", [OR(0x2000, AND(L("aa"), 7)), L("v")]), ["ret", 0]]),
        gif(["==", L("aa"), 0x4014], [call("oam_dma", [L("v")]), ["ret", 0]]),
        gif(["==", L("aa"), 0x4016], [call("ctrl_strobe", [L("v")]), ["ret", 0]]),
        gif(["and", [">=", L("aa"), 0x4000], ["<", L("aa"), 0x4018]],
            [call("apu_write", [AND(L("aa"), 0x1F), L("v")]), ["ret", 0]]),
        gif(["and", [">=", L("aa"), 0x6000], ["<", L("aa"), 0x8000]],
            [["setu8", "prgram", ["-", L("aa"), 0x6000], L("v")], ["ret", 0]]),
        gif(["and", [">=", L("aa"), 0x8000], ["==", p(MAPPER), 1]],
            [call("m1_write", [L("aa"), L("v")]), ["ret", 0]]),
        gif(["and", [">=", L("aa"), 0x8000], ["==", p(MAPPER), 4]],
            [call("m3_write", [L("aa"), L("v")]), ["ret", 0]]),
        gif(["and", [">=", L("aa"), 0x8000],
                    ["or", ["or", ["==", p(MAPPER), 2], ["==", p(MAPPER), 3]],
                           ["or", ["==", p(MAPPER), 7], ["==", p(MAPPER), 66]]]],
            [call("simple_write", [L("aa"), L("v")]), ["ret", 0]]),
        ["ret", 0],
    ]}

def oam_dma_fn():
    return {"params": ["page"], "body": [
        setL("base", SHL(L("page"), 8)),
        setL("i", 0),
        ["while", ["<", L("i"), 256], [
            ["setu8", "oam", AND(ADD(p(OAMADDR), L("i")), 0xFF),
             call("rd_nodma", [ADD(L("base"), L("i"))])],
            call("ppu_tick3"), call("ppu_tick3"),  # ~2 cycles/byte
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
                [gif(["==", p(MAPPER), 4], [call("m3_clock_irq")])]),
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


def simple_write_fn():
    return {"params": ["a", "v"], "body": [
        # UNROM (2): 16K switchable @ $8000, fixed last @ $C000; CHR-RAM
        gif(["==", p(MAPPER), 2], [
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
    funcs["ppu_step"] = ppu_step_fn()
    funcs["ppu_tick3"] = ppu_tick3_fn()
    funcs["oam_dma"] = oam_dma_fn()
    funcs["ctrl_read"] = ctrl_read_fn()
    funcs["ctrl_strobe"] = ctrl_strobe_fn()
    funcs["prg_addr"] = prg_addr_fn()
    funcs["chr_addr"] = chr_addr_fn()
    funcs["m1_update"] = m1_update_fn()
    funcs["m1_write"] = m1_write_fn()
    funcs["m3_update"] = m3_update_fn()
    funcs["m3_write"] = m3_write_fn()
    funcs["m3_clock_irq"] = m3_clock_irq_fn()
    funcs["a12_clock"] = a12_clock_fn()
    funcs["spr_overflow_eval"] = spr_overflow_eval_fn()
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

    # run_frame: step CPU (servicing NMI) until PPU frame counter advances
    funcs["run_frame"] = {"params": ["maxInstr"], "body": [
        setL("f0", p(FRAMES)),
        setL("i", 0),
        ["while", ["and", ["==", p(FRAMES), L("f0")], ["<", L("i"), L("maxInstr")]], [
            gif(["==", p(NMIPEND), 1], [setp(NMIPEND, 0), call("nmi")]),
            gif(["==", p(SCRATCH1), 1], [setp(SCRATCH1, 0), setp(NMIPEND, 1)]),  # delayed NMI (enable-in-vblank): fires after next instr
            gif(["and", ["or", ["==", p(IRQPEND), 1], ["==", call("apu_irq"), 1]], ["==", C.getflag(C.IF_), 0]],
                [setp(IRQPEND, 0), call("irq")]),
            call("step"),
            setL("i", ADD(L("i"), 1))]],
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
        gif(["==", L("mapper"), 2], [
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

    apu = APU.build_apu()
    funcs.update(apu["funcs"])
    buffers = {"ram": 2048, "prg": 524288, "chr": 131072, "vram": 2048,
               "pal": 32, "oam": 256, "oam2": 32, "fb": 61440, "prgram": 8192}
    buffers.update(apu["buffers"])
    for name, tbl in apu["u8tables"].items():
        buffers[name] = len(tbl)
    i32 = {"reg": 8, "p": 96}
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
