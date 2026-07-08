#!/usr/bin/env python3
"""APU (audio) as compute-kernel AST — 1:1 port of NESd nes/apu (pulse1/2,
triangle, noise, envelope/sweep/length/linear units, frame counter, integer
mixer + DMC 通道). DMC 经 rd_nodma 同步取样字节(mapper 感知)。

Emits int16 samples into a `samples` buffer via NESd's integer sample-rate
accumulator (emit when accumulator >= cpuFrequency; 48kHz over NTSC 1.789773MHz).
Mixer tables precomputed from the canonical hardware formulas (scaled to int16).

State lives in i32 'a'. Helper AST builders mirror gen_nes.
"""

CPU_FREQ = 1789773
APU_RATE = 48000

# --- 'a' (APU state) indices ---
_names = """
EN1 DUTY1 DIDX1 TMR1 TP1 CV1 VOL1 E1V E1P E1T E1S E1L L1H L1V S1E S1P S1V S1SH S1N S1R S1M
EN2 DUTY2 DIDX2 TMR2 TP2 CV2 VOL2 E2V E2P E2T E2S E2L L2H L2V S2E S2P S2V S2SH S2N S2R S2M
ENT DIDXT TMRT TPT LIN LINP LINREL CTRLT LTH LTV
ENN TMRN TPN CVN VOLN ENV ENP ENT2 ENS ENL LNH LNV SHN MODEN
FCCOUNT FCMODE FCINH APUCYC SACC SIDX DMCLVL FCIRQ DMCIRQ
DMC_EN DMC_IRQEN DMC_LOOP DMC_SIL DMC_BUF DMC_RATE DMC_BITS DMC_SHIFT DMC_TMR
DMC_SADDR DMC_SLEN DMC_ADDR DMC_LEN DMC_LOADED
""".split()
IDX = {n: i for i, n in enumerate(_names)}
A_SIZE = len(_names)


def a(n): return ["i32", "a", IDX[n]]
def seta(n, v): return ["seti32", "a", IDX[n], v]
def L(x): return ["var", x]
def setL(x, v): return ["set", x, v]
def AND(x, y): return ["&", x, y]
def OR(x, y): return ["|", x, y]
def XOR(x, y): return ["^", x, y]
def SHL(x, y): return ["<<", x, y]
def SHR(x, y): return [">>", x, y]
def ADD(x, y): return ["+", x, y]
def SUB(x, y): return ["-", x, y]
def gif(c, t, e=None): return ["if", c, t] + ([e] if e is not None else [])
def bit(v, k): return AND(SHR(v, k), 1)

# --- hardware tables ---
LENGTH_TABLE = [10, 254, 20, 2, 40, 4, 80, 6, 160, 8, 60, 10, 14, 12, 26, 14,
                12, 16, 24, 18, 48, 20, 96, 22, 192, 24, 72, 26, 16, 28, 32, 30]
DUTY_SEQ = [0x40, 0x30, 0x38, 0xE7]  # NESd bit-order variant handled below
# NESd dutyCycleSequences: 0x01,0x03,0x0f,0xfc (see tables.dart) — output uses
# (mask >> (7-dutyIndex)) & 1, dutyIndex counting down. Use those exact masks:
DUTY_SEQ = [0x01, 0x03, 0x0F, 0xFC]
TRIANGLE_TABLE = list(range(15, -1, -1)) + list(range(0, 16))  # 15..0,0..15
NOISE_TABLE = [4, 8, 16, 32, 64, 96, 128, 160, 202, 254, 380, 508, 762, 1016,
               2034, 4068]
DMC_RATE_TABLE = [428, 380, 340, 320, 286, 254, 226, 214, 190, 160, 142, 128,
                  106, 84, 72, 54]

def _pulse_table():
    t = [0]
    for i in range(1, 31):
        t.append(round(32767 * (95.52 / (8128.0 / i + 100))))
    return t

def _tnd_table():
    t = [0]
    for i in range(1, 203):
        t.append(round(32767 * (163.67 / (24329.0 / i + 100))))
    return t

PULSE_TABLE = _pulse_table()
TND_TABLE = _tnd_table()


def _env_step(V, P, T, S, Lp):
    return gif(["==", a(S), 1],
        [seta(V, 15), seta(T, a(P)), seta(S, 0)],
        [gif([">", a(T), 0], [seta(T, SUB(a(T), 1))],
            [seta(T, a(P)),
             gif([">", a(V), 0], [seta(V, SUB(a(V), 1))],
                 [gif(["==", a(Lp), 1], [seta(V, 15)])])])])


def _len_step(H, Vn):
    return gif(["and", ["==", a(H), 0], [">", a(Vn), 0]], [seta(Vn, SUB(a(Vn), 1))])


def _sweep_step(EN, PER, VAL, SH, NEG, REL, MUTE, TP, ones):
    # calculateTargetPeriod + muting + apply
    delta = SHR(a(TP), a(SH))
    target = ["?:", ["==", a(NEG), 1],
              ADD(a(TP), SUB(0, ADD(delta, 1 if ones else 0))),
              ADD(a(TP), delta)]
    return [
        setL("tp", ["max", 0, target]),
        seta(MUTE, ["?:", ["or", ["<", a(TP), 8], [">", L("tp"), 0x7FF]], 1, 0]),
        gif(["and", ["and", ["==", a(VAL), 0], ["==", a(EN), 1]],
                    ["and", [">", a(SH), 0], ["==", a(MUTE), 0]]],
            [seta(TP, L("tp"))]),
        gif(["or", ["==", a(VAL), 0], ["==", a(REL), 1]],
            [seta(VAL, a(PER)), seta(REL, 0)],
            [seta(VAL, SUB(a(VAL), 1))]),
    ]


def build_apu():
    funcs = {}

    # --- channel timer steps ---
    funcs["ap_pulse_step"] = {"params": ["ch"], "body": [
        gif(["==", L("ch"), 1], [
            gif([">", a("TMR1"), 0], [seta("TMR1", SUB(a("TMR1"), 1))],
                [seta("TMR1", a("TP1")), seta("DIDX1", AND(SUB(a("DIDX1"), 1), 7))])],
            [gif([">", a("TMR2"), 0], [seta("TMR2", SUB(a("TMR2"), 1))],
                [seta("TMR2", a("TP2")), seta("DIDX2", AND(SUB(a("DIDX2"), 1), 7))])]),
        ["ret", 0]]}

    funcs["ap_tri_step"] = {"params": [], "body": [
        gif(["and", ["<", a("TPT"), 2], ["==", a("TMRT"), 0]], [["ret", 0]]),
        gif(["==", a("LTV"), 0], [["ret", 0]]),
        gif(["==", a("LIN"), 0], [["ret", 0]]),
        gif([">", a("TMRT"), 0], [seta("TMRT", SUB(a("TMRT"), 1))],
            [seta("TMRT", a("TPT")), seta("DIDXT", ["%", ADD(a("DIDXT"), 1), 32])]),
        ["ret", 0]]}

    funcs["ap_noise_step"] = {"params": [], "body": [
        gif([">", a("TMRN"), 0], [seta("TMRN", SUB(a("TMRN"), 1))],
            [seta("TMRN", a("TPN")),
             setL("fb", XOR(bit(a("SHN"), ["?:", ["==", a("MODEN"), 1], 6, 1]), bit(a("SHN"), 0))),
             seta("SHN", SHR(a("SHN"), 1)),
             seta("SHN", OR(AND(a("SHN"), ["-", ["<<", 1, 14], 1] if False else 0x3FFF ^ (1 << 14)), SHL(L("fb"), 14)))]),
        ["ret", 0]]}

    # --- outputs (0..15 / triangle 0..15) ---
    funcs["ap_pulse_out"] = {"params": ["ch"], "body": [
        gif(["==", L("ch"), 1], [
            gif(["==", a("EN1"), 0], [["ret", 0]]),
            gif(["==", a("L1V"), 0], [["ret", 0]]),
            gif(["==", AND(SHR(["u8", "dutyseq", a("DUTY1")], SUB(7, a("DIDX1"))), 1), 0], [["ret", 0]]),
            gif(["==", a("S1M"), 1], [["ret", 0]]),
            ["ret", ["?:", ["==", a("CV1"), 1], a("VOL1"), a("E1V")]]],
            [
            gif(["==", a("EN2"), 0], [["ret", 0]]),
            gif(["==", a("L2V"), 0], [["ret", 0]]),
            gif(["==", AND(SHR(["u8", "dutyseq", a("DUTY2")], SUB(7, a("DIDX2"))), 1), 0], [["ret", 0]]),
            gif(["==", a("S2M"), 1], [["ret", 0]]),
            ["ret", ["?:", ["==", a("CV2"), 1], a("VOL2"), a("E2V")]]])]}

    funcs["ap_tri_out"] = {"params": [], "body": [
        gif(["==", a("ENT"), 0], [["ret", 0]]),
        gif(["<", a("TPT"), 2], [["ret", 7]]),
        gif(["==", a("LTV"), 0], [["ret", 0]]),
        gif(["==", a("LIN"), 0], [["ret", 0]]),
        ["ret", ["u8", "trisq", a("DIDXT")]]]}

    funcs["ap_noise_out"] = {"params": [], "body": [
        gif(["==", a("ENN"), 0], [["ret", 0]]),
        gif(["==", a("LNV"), 0], [["ret", 0]]),
        gif(["==", bit(a("SHN"), 0), 1], [["ret", 0]]),
        ["ret", ["?:", ["==", a("CVN"), 1], a("VOLN"), a("ENV")]]]}

    # --- frame counter quarter/half clocks ---
    funcs["ap_quarter"] = {"params": [], "body": [
        _env_step("E1V", "E1P", "E1T", "E1S", "E1L"),
        _env_step("E2V", "E2P", "E2T", "E2S", "E2L"),
        _env_step("ENV", "ENP", "ENT2", "ENS", "ENL"),
        # triangle linear counter
        gif(["==", a("LINREL"), 1], [seta("LIN", a("LINP"))],
            [gif([">", a("LIN"), 0], [seta("LIN", SUB(a("LIN"), 1))])]),
        gif(["==", a("CTRLT"), 0], [seta("LINREL", 0)]),
        ["ret", 0]]}
    funcs["ap_half"] = {"params": [], "body": [
        _len_step("L1H", "L1V"), _len_step("L2H", "L2V"),
        _len_step("LTH", "LTV"), _len_step("LNH", "LNV"),
    ] + _sweep_step("S1E", "S1P", "S1V", "S1SH", "S1N", "S1R", "S1M", "TP1", True)
      + _sweep_step("S2E", "S2P", "S2V", "S2SH", "S2N", "S2R", "S2M", "TP2", False)
      + [["ret", 0]]}

    funcs["ap_frame_step"] = {"params": [], "body": [
        setL("c", a("FCCOUNT")),
        gif(["==", a("FCMODE"), 0], [  # 4-step
            gif(["==", L("c"), 3728], [["call", "ap_quarter", []]]),
            gif(["==", L("c"), 7456], [["call", "ap_quarter", []], ["call", "ap_half", []]]),
            gif(["==", L("c"), 11185], [["call", "ap_quarter", []]]),
            gif(["==", L("c"), 14914], [["call", "ap_quarter", []], ["call", "ap_half", []],
                                        gif(["==", a("FCINH"), 0], [seta("FCIRQ", 1)]),
                                        seta("FCCOUNT", -1)]),
        ], [  # 5-step
            gif(["==", L("c"), 3728], [["call", "ap_quarter", []]]),
            gif(["==", L("c"), 7456], [["call", "ap_quarter", []], ["call", "ap_half", []]]),
            gif(["==", L("c"), 11185], [["call", "ap_quarter", []]]),
            gif(["==", L("c"), 18640], [["call", "ap_quarter", []], ["call", "ap_half", []],
                                        seta("FCCOUNT", -1)]),
        ]),
        seta("FCCOUNT", ADD(a("FCCOUNT"), 1)),
        ["ret", 0]]}


    # DMC: 1:1 port; DMA byte fetched synchronously via rd_nodma (mapper-aware)
    funcs["ap_dmc_step"] = {"params": [], "body": [
        gif([">", a("DMC_TMR"), 0], [seta("DMC_TMR", SUB(a("DMC_TMR"), 1)), ["ret", 0]]),
        seta("DMC_TMR", a("DMC_RATE")),
        gif(["==", a("DMC_SIL"), 0], [
            setL("diff", ["?:", ["==", bit(a("DMC_SHIFT"), 0), 1], 2, -2]),
            setL("nl", ADD(a("DMCLVL"), L("diff"))),
            seta("DMCLVL", ["max", 0, ["min", 127, L("nl")]]),
            seta("DMC_SHIFT", SHR(a("DMC_SHIFT"), 1))]),
        seta("DMC_BITS", SUB(a("DMC_BITS"), 1)),
        gif(["==", a("DMC_BITS"), 0], [
            seta("DMC_BITS", 8),
            gif(["==", a("DMC_LOADED"), 0], [seta("DMC_SIL", 1)],
                [seta("DMC_SIL", 0), seta("DMC_SHIFT", a("DMC_BUF")),
                 seta("DMC_LOADED", 0), ["call", "ap_dmc_dma", []]])]),
        ["ret", 0]]}

    funcs["ap_dmc_dma"] = {"params": [], "body": [
        gif(["==", a("DMC_LEN"), 0], [["ret", 0]]),
        seta("DMC_BUF", ["call", "rd_nodma", [a("DMC_ADDR")]]),
        seta("DMC_LOADED", 1),
        seta("DMC_ADDR", OR(0x8000, AND(ADD(a("DMC_ADDR"), 1), 0x7FFF))),
        seta("DMC_LEN", SUB(a("DMC_LEN"), 1)),
        gif(["==", a("DMC_LEN"), 0], [
            gif(["==", a("DMC_LOOP"), 1],
                [seta("DMC_ADDR", a("DMC_SADDR")), seta("DMC_LEN", a("DMC_SLEN"))],
                [gif(["==", a("DMC_IRQEN"), 1], [seta("DMC_EN", a("DMC_EN"))])])]),
        ["ret", 0]]}

    # --- main APU step (one CPU cycle) + sampling ---
    funcs["apu_step"] = {"params": [], "body": [
        ["call", "ap_tri_step", []],
        ["call", "ap_dmc_step", []],
        gif(["==", AND(a("APUCYC"), 1), 0], [
            ["call", "ap_pulse_step", [1]],
            ["call", "ap_pulse_step", [2]],
            ["call", "ap_noise_step", []],
            ["call", "ap_frame_step", []]]),
        # sample accumulator -> emit int16 when >= CPU_FREQ
        seta("SACC", ADD(a("SACC"), APU_RATE)),
        gif([">=", a("SACC"), CPU_FREQ], [
            seta("SACC", SUB(a("SACC"), CPU_FREQ)),
            ["call", "apu_emit", []]]),
        seta("APUCYC", ADD(a("APUCYC"), 1)),
        ["ret", 0]]}

    funcs["apu_emit"] = {"params": [], "body": [
        setL("p1", ["call", "ap_pulse_out", [1]]),
        setL("p2", ["call", "ap_pulse_out", [2]]),
        setL("pulse", ["u8", "" , 0] if False else ["i32", "ptbl", ADD(L("p1"), L("p2"))]),
        setL("tri", ["call", "ap_tri_out", []]),
        setL("noi", ["call", "ap_noise_out", []]),
        setL("tnd", ["i32", "tndtbl", ADD(ADD(["*", 3, L("tri")], ["*", 2, L("noi")]), a("DMCLVL"))]),
        setL("s", ADD(L("pulse"), L("tnd"))),
        # store int16 sample (as unsigned 16-bit halves in a byte buffer)
        gif(["<", a("SIDX"), 96000], [
            ["setu8", "samples", ["*", a("SIDX"), 2], AND(L("s"), 0xFF)],
            ["setu8", "samples", ADD(["*", a("SIDX"), 2], 1), AND(SHR(L("s"), 8), 0xFF)],
            seta("SIDX", ADD(a("SIDX"), 1))]),
        ["ret", 0]]}

    # --- register writes ($4000-$4017) ---
    funcs["apu_write"] = {"params": ["r", "v"], "body": [
        # $4000 pulse1 control
        gif(["==", L("r"), 0x00], [
            seta("DUTY1", AND(SHR(L("v"), 6), 3)),
            seta("L1H", bit(L("v"), 5)), seta("CV1", bit(L("v"), 4)),
            seta("VOL1", AND(L("v"), 0x0F)),
            seta("E1L", bit(L("v"), 5)), seta("E1P", AND(L("v"), 0x0F)), seta("E1S", 1)]),
        gif(["==", L("r"), 0x01], [
            seta("S1P", AND(SHR(L("v"), 4), 7)), seta("S1N", bit(L("v"), 3)),
            seta("S1SH", AND(L("v"), 7)), seta("S1R", 1),
            seta("S1E", ["?:", ["and", ["==", bit(L("v"), 7), 1], ["!=", AND(L("v"), 7), 0]], 1, 0])]),
        gif(["==", L("r"), 0x02], [seta("TP1", OR(AND(a("TP1"), 0x700), L("v")))]),
        gif(["==", L("r"), 0x03], [
            seta("TP1", OR(AND(a("TP1"), 0xFF), SHL(AND(L("v"), 7), 8))),
            seta("E1S", 1), seta("TMR1", a("TP1")), seta("DIDX1", 0),
            gif(["==", a("EN1"), 1], [seta("L1V", ["u8", "lentbl", SHR(L("v"), 3)])])]),
        # $4004-4007 pulse2
        gif(["==", L("r"), 0x04], [
            seta("DUTY2", AND(SHR(L("v"), 6), 3)), seta("L2H", bit(L("v"), 5)),
            seta("CV2", bit(L("v"), 4)), seta("VOL2", AND(L("v"), 0x0F)),
            seta("E2L", bit(L("v"), 5)), seta("E2P", AND(L("v"), 0x0F)), seta("E2S", 1)]),
        gif(["==", L("r"), 0x05], [
            seta("S2P", AND(SHR(L("v"), 4), 7)), seta("S2N", bit(L("v"), 3)),
            seta("S2SH", AND(L("v"), 7)), seta("S2R", 1),
            seta("S2E", ["?:", ["and", ["==", bit(L("v"), 7), 1], ["!=", AND(L("v"), 7), 0]], 1, 0])]),
        gif(["==", L("r"), 0x06], [seta("TP2", OR(AND(a("TP2"), 0x700), L("v")))]),
        gif(["==", L("r"), 0x07], [
            seta("TP2", OR(AND(a("TP2"), 0xFF), SHL(AND(L("v"), 7), 8))),
            seta("E2S", 1), seta("TMR2", a("TP2")), seta("DIDX2", 0),
            gif(["==", a("EN2"), 1], [seta("L2V", ["u8", "lentbl", SHR(L("v"), 3)])])]),
        # $4008 triangle
        gif(["==", L("r"), 0x08], [
            seta("CTRLT", bit(L("v"), 7)), seta("LTH", bit(L("v"), 7)),
            seta("LINP", AND(L("v"), 0x7F))]),
        gif(["==", L("r"), 0x0A], [seta("TPT", OR(AND(a("TPT"), 0x700), L("v")))]),
        gif(["==", L("r"), 0x0B], [
            seta("TPT", OR(AND(a("TPT"), 0xFF), SHL(AND(L("v"), 7), 8))),
            seta("LINREL", 1),
            gif(["==", a("ENT"), 1], [seta("LTV", ["u8", "lentbl", SHR(L("v"), 3)])])]),
        # $400C noise
        gif(["==", L("r"), 0x0C], [
            seta("LNH", bit(L("v"), 5)), seta("CVN", bit(L("v"), 4)),
            seta("VOLN", AND(L("v"), 0x0F)),
            seta("ENL", bit(L("v"), 5)), seta("ENP", AND(L("v"), 0x0F)), seta("ENS", 1)]),
        gif(["==", L("r"), 0x0E], [
            seta("MODEN", bit(L("v"), 7)),
            seta("TPN", SUB(["i32", "noistbl", AND(L("v"), 0x0F)], 1))]),
        gif(["==", L("r"), 0x0F], [
            seta("ENS", 1),
            gif(["==", a("ENN"), 1], [seta("LNV", ["u8", "lentbl", SHR(L("v"), 3)])])]),
        # $4010-$4013 DMC
        gif(["==", L("r"), 0x10], [
            seta("DMC_IRQEN", bit(L("v"), 7)), seta("DMC_LOOP", bit(L("v"), 6)),
            seta("DMC_RATE", ["i32", "dmctbl", AND(L("v"), 0x0F)])]),
        gif(["==", L("r"), 0x11], [seta("DMCLVL", AND(L("v"), 0x7F))]),
        gif(["==", L("r"), 0x12], [seta("DMC_SADDR", OR(0xC000, SHL(L("v"), 6)))]),
        gif(["==", L("r"), 0x13], [seta("DMC_SLEN", ADD(SHL(L("v"), 4), 1))]),
        # $4015 status (enable channels)
        gif(["==", L("r"), 0x15], [
            seta("EN1", bit(L("v"), 0)), seta("EN2", bit(L("v"), 1)),
            seta("ENT", bit(L("v"), 2)), seta("ENN", bit(L("v"), 3)),
            gif(["==", bit(L("v"), 0), 0], [seta("L1V", 0)]),
            gif(["==", bit(L("v"), 1), 0], [seta("L2V", 0)]),
            gif(["==", bit(L("v"), 2), 0], [seta("LTV", 0)]),
            gif(["==", bit(L("v"), 3), 0], [seta("LNV", 0)]),
            seta("DMC_EN", bit(L("v"), 4)),
            gif(["==", bit(L("v"), 4), 1], [
                gif(["==", a("DMC_LEN"), 0], [
                    seta("DMC_ADDR", a("DMC_SADDR")), seta("DMC_LEN", a("DMC_SLEN")),
                    ["call", "ap_dmc_dma", []]])],
                [seta("DMC_LEN", 0)])]),
        # $4017 frame counter
        gif(["==", L("r"), 0x17], [
            seta("FCMODE", bit(L("v"), 7)), seta("FCINH", bit(L("v"), 6)),
            seta("FCCOUNT", 0),
            gif(["==", bit(L("v"), 6), 1], [seta("FCIRQ", 0)]),   # inhibit clears frame IRQ flag
            gif(["==", bit(L("v"), 7), 1], [["call", "ap_quarter", []], ["call", "ap_half", []]])]),
        ["ret", 0]]}

    funcs["apu_status"] = {"params": [], "body": [
        setL("s", 0),
        gif([">", a("L1V"), 0], [setL("s", OR(L("s"), 1))]),
        gif([">", a("L2V"), 0], [setL("s", OR(L("s"), 2))]),
        gif([">", a("LTV"), 0], [setL("s", OR(L("s"), 4))]),
        gif([">", a("LNV"), 0], [setL("s", OR(L("s"), 8))]),
        gif([">", a("DMC_LEN"), 0], [setL("s", OR(L("s"), 0x10))]),
        gif(["==", a("FCIRQ"), 1], [setL("s", OR(L("s"), 0x40))]),
        gif(["==", a("DMCIRQ"), 1], [setL("s", OR(L("s"), 0x80))]),
        seta("FCIRQ", 0),                 # reading $4015 clears frame IRQ flag
        ["ret", L("s")]]}

    # frame/DMC IRQ line asserted to CPU (polled by run_frame)
    funcs["apu_irq"] = {"params": [], "body": [
        ["ret", ["?:", ["or", ["==", a("FCIRQ"), 1], ["==", a("DMCIRQ"), 1]], 1, 0]]]}

    funcs["apu_reset_state"] = {"params": [], "body": [
        seta("SHN", 1),  # noise shift register starts at 1
        ["ret", 0]]}

    buffers = {"samples": 192000}  # 96000 int16 (~2s @48k)
    i32bufs = {"a": A_SIZE, "ptbl": len(PULSE_TABLE), "tndtbl": len(TND_TABLE),
               "noistbl": len(NOISE_TABLE), "dmctbl": len(DMC_RATE_TABLE)}
    u8bufs_tables = {"lentbl": LENGTH_TABLE, "dutyseq": DUTY_SEQ,
                     "trisq": TRIANGLE_TABLE}
    return {
        "funcs": funcs, "buffers": buffers, "i32bufs": i32bufs,
        "u8tables": u8bufs_tables,
        "i32tables": {"ptbl": PULSE_TABLE, "tndtbl": TND_TABLE, "noistbl": NOISE_TABLE,
                      "dmctbl": DMC_RATE_TABLE},
    }


if __name__ == "__main__":
    r = build_apu()
    print("apu funcs:", len(r["funcs"]), "state slots:", A_SIZE,
          "pulseTable", len(PULSE_TABLE), "tndTable", len(TND_TABLE))
