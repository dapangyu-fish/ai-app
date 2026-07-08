#!/usr/bin/env python3
"""Generate the 6502 CPU core as compute-kernel JSON-AST (1:1 port of NESd's
cpu/instruction/address_mode). Emits nesd_cpu.json consumed by the kernel.

Register file `reg` (Int32List): 0=A 1=X 2=Y 3=SP 4=P 5=PC 6=cyc 7=halt.
Buffers: ram=2048, prg=32768 (NROM mirrored at load).
Flags in P: bit0 C, bit1 Z, bit2 I, bit3 D, bit4 B, bit5(1), bit6 V, bit7 N.
P keeps bit5=1/bit4=0 in-register; B synthesized on push (matches nestest 0x24).
"""
import json

A, X, Y, SP, P, PC, CYC, HALT = 0, 1, 2, 3, 4, 5, 6, 7

def reg(i): return ["i32", "reg", i]
def setreg(i, v): return ["seti32", "reg", i, v]
def L(n): return ["var", n]
def setL(n, v): return ["set", n, v]
def RD(a): return ["call", "rd", [a]]
def WR(a, v): return ["call", "wr", [a, v]]      # statement
def AND(a, b): return ["&", a, b]
def OR(a, b): return ["|", a, b]
def XOR(a, b): return ["^", a, b]
def SHL(a, b): return ["<<", a, b]
def SHR(a, b): return [">>", a, b]
def ADDW(a, b): return ["+", a, b]
def m16(a): return AND(a, 0xFFFF)
def m8(a): return AND(a, 0xFF)

# flag bit positions
CF, ZF, IF_, DF, BF, VF, NF = 0, 1, 2, 3, 6, 7, 6  # note V=6, N=7
VF, NF = 6, 7

def getflag(bit): return AND(SHR(reg(P), bit), 1)
def setflag(bit, cond):
    # reg[P] = (P & ~(1<<bit)) | (cond<<bit); cond must be 0/1
    return setreg(P, OR(AND(reg(P), (~(1 << bit)) & 0xFF), SHL(cond, bit)))

def setzn(vexpr):
    # P = (P & 0x7D) | (v==0?2:0) | (v & 0x80)   ; touches Z(bit1),N(bit7)
    return [
        setL("_v", vexpr),
        setreg(P, OR(OR(AND(reg(P), 0x7D),
                        ["?:", ["==", AND(L("_v"), 0xFF), 0], 2, 0]),
                     AND(L("_v"), 0x80))),
    ]

def push(vexpr):
    return [
        WR(OR(0x100, reg(SP)), AND(vexpr, 0xFF)),
        setreg(SP, AND(["-", reg(SP), 1], 0xFF)),
    ]

def pop_to(local):
    return [
        setreg(SP, AND(["+", reg(SP), 1], 0xFF)),
        setL(local, RD(OR(0x100, reg(SP)))),
    ]

# ---- addressing modes: emit statements setting local 'ea'; advance PC ----
def fetch_pc():  # read byte at PC, advance PC
    return RD(reg(PC))  # caller advances PC separately

def adv(n): return setreg(PC, m16(ADDW(reg(PC), n)))

def mode_imm():
    return [setL("ea", reg(PC)), adv(1)]
def mode_zp():
    return [setL("ea", RD(reg(PC))), adv(1)]
def mode_zpx():
    return [setL("ea", AND(ADDW(RD(reg(PC)), reg(X)), 0xFF)), adv(1)]
def mode_zpy():
    return [setL("ea", AND(ADDW(RD(reg(PC)), reg(Y)), 0xFF)), adv(1)]
def mode_abs():
    return [setL("ea", ["call", "rd16", [reg(PC)]]), adv(2)]
def mode_absx():
    return [setL("ea", m16(ADDW(["call", "rd16", [reg(PC)]], reg(X)))), adv(2)]
def mode_absy():
    return [setL("ea", m16(ADDW(["call", "rd16", [reg(PC)]], reg(Y)))), adv(2)]
def mode_ind():  # JMP indirect w/ page-boundary bug
    return [
        setL("ptr", ["call", "rd16", [reg(PC)]]), adv(2),
        setL("ea", OR(RD(L("ptr")),
                      SHL(RD(OR(AND(L("ptr"), 0xFF00), AND(ADDW(L("ptr"), 1), 0xFF))), 8))),
    ]
def mode_izx():
    return [
        setL("t", AND(ADDW(RD(reg(PC)), reg(X)), 0xFF)), adv(1),
        setL("ea", OR(RD(L("t")), SHL(RD(AND(ADDW(L("t"), 1), 0xFF)), 8))),
    ]
def mode_izy():
    return [
        setL("t", RD(reg(PC))), adv(1),
        setL("base", OR(RD(L("t")), SHL(RD(AND(ADDW(L("t"), 1), 0xFF)), 8))),
        setL("ea", m16(ADDW(L("base"), reg(Y)))),
    ]

MODES = {
    "imm": mode_imm, "zp": mode_zp, "zpx": mode_zpx, "zpy": mode_zpy,
    "abs": mode_abs, "absx": mode_absx, "absy": mode_absy,
    "ind": mode_ind, "izx": mode_izx, "izy": mode_izy,
    "acc": lambda: [], "imp": lambda: [],
}
M = RD(L("ea"))  # operand value from memory

# ---- instruction semantics (return list of statements) ----
def ld(regi):
    return setzn(M) + [setreg(regi, AND(M, 0xFF))]
    # note setzn reads M once into _v; then setreg reads M again — both RD(ea)
def i_LDA(): return _load(A)
def i_LDX(): return _load(X)
def i_LDY(): return _load(Y)
def _load(regi):
    return [setL("m", M)] + setzn(L("m")) + [setreg(regi, AND(L("m"), 0xFF))]

def i_STA(): return [WR(L("ea"), reg(A))]
def i_STX(): return [WR(L("ea"), reg(X))]
def i_STY(): return [WR(L("ea"), reg(Y))]

def i_TAX(): return [setreg(X, reg(A))] + setzn(reg(A))
def i_TAY(): return [setreg(Y, reg(A))] + setzn(reg(A))
def i_TXA(): return [setreg(A, reg(X))] + setzn(reg(X))
def i_TYA(): return [setreg(A, reg(Y))] + setzn(reg(Y))
def i_TSX(): return [setreg(X, reg(SP))] + setzn(reg(SP))
def i_TXS(): return [setreg(SP, reg(X))]

def i_ADC():
    return [
        setL("m", M),
        setL("r", ADDW(ADDW(reg(A), L("m")), getflag(CF))),
        setflag(CF, ["?:", [">", L("r"), 0xFF], 1, 0]),
        setflag(VF, ["?:", ["!=", AND(AND(["~", XOR(reg(A), L("m"))], XOR(reg(A), L("r"))), 0x80), 0], 1, 0]),
    ] + setzn(L("r")) + [setreg(A, AND(L("r"), 0xFF))]

def i_SBC():
    return [
        setL("m", M),
        setL("r", ["-", ["-", reg(A), L("m")], ["-", 1, getflag(CF)]]),
        setflag(CF, ["?:", [">=", L("r"), 0], 1, 0]),
        setflag(VF, ["?:", ["!=", AND(AND(XOR(reg(A), L("r")), XOR(reg(A), L("m"))), 0x80), 0], 1, 0]),
    ] + setzn(L("r")) + [setreg(A, AND(L("r"), 0xFF))]

def i_AND(): return [setL("m", AND(reg(A), M)), setreg(A, L("m"))] + setzn(L("m"))
def i_ORA(): return [setL("m", OR(reg(A), M)), setreg(A, L("m"))] + setzn(L("m"))
def i_EOR(): return [setL("m", XOR(reg(A), M)), setreg(A, L("m"))] + setzn(L("m"))

def i_BIT():
    return [
        setL("m", M),
        setflag(ZF, ["?:", ["==", AND(reg(A), L("m")), 0], 1, 0]),
        setflag(VF, AND(SHR(L("m"), 6), 1)),
        setflag(NF, AND(SHR(L("m"), 7), 1)),
    ]

def _cmp(regi):
    return [
        setL("m", M),
        setL("r", ["-", reg(regi), L("m")]),
        setflag(CF, ["?:", [">=", reg(regi), L("m")], 1, 0]),
    ] + setzn(L("r"))
def i_CMP(): return _cmp(A)
def i_CPX(): return _cmp(X)
def i_CPY(): return _cmp(Y)

def i_INC():
    return [setL("m", AND(ADDW(M, 1), 0xFF)), WR(L("ea"), L("m"))] + setzn(L("m"))
def i_DEC():
    return [setL("m", AND(["-", M, 1], 0xFF)), WR(L("ea"), L("m"))] + setzn(L("m"))
def i_INX(): return [setreg(X, AND(ADDW(reg(X), 1), 0xFF))] + setzn(reg(X))
def i_INY(): return [setreg(Y, AND(ADDW(reg(Y), 1), 0xFF))] + setzn(reg(Y))
def i_DEX(): return [setreg(X, AND(["-", reg(X), 1], 0xFF))] + setzn(reg(X))
def i_DEY(): return [setreg(Y, AND(["-", reg(Y), 1], 0xFF))] + setzn(reg(Y))

# shifts/rotates: acc flag distinguishes A vs memory
def _shift(acc, kind):
    src = reg(A) if acc else M
    body = [setL("m", src)]
    if kind == "ASL":
        body += [setflag(CF, AND(SHR(L("m"), 7), 1)),
                 setL("r", AND(SHL(L("m"), 1), 0xFF))]
    elif kind == "LSR":
        body += [setflag(CF, AND(L("m"), 1)),
                 setL("r", SHR(L("m"), 1))]
    elif kind == "ROL":
        body += [setL("oc", getflag(CF)),
                 setflag(CF, AND(SHR(L("m"), 7), 1)),
                 setL("r", AND(OR(SHL(L("m"), 1), L("oc")), 0xFF))]
    elif kind == "ROR":
        body += [setL("oc", getflag(CF)),
                 setflag(CF, AND(L("m"), 1)),
                 setL("r", OR(SHL(L("oc"), 7), SHR(L("m"), 1)))]
    body += setzn(L("r"))
    if acc:
        body += [setreg(A, AND(L("r"), 0xFF))]
    else:
        body += [WR(L("ea"), AND(L("r"), 0xFF))]
    return body

def i_JMP(): return [setreg(PC, L("ea"))]
def i_JSR():
    # ea already computed via abs mode (PC advanced by 2). return = PC-1.
    return [setL("ret", m16(["-", reg(PC), 1]))] + \
        push(SHR(L("ret"), 8)) + push(AND(L("ret"), 0xFF)) + [setreg(PC, L("ea"))]
def i_RTS():
    return pop_to("lo") + pop_to("hi") + \
        [setreg(PC, m16(ADDW(OR(SHL(L("hi"), 8), L("lo")), 1)))]
def i_RTI():
    return pop_to("sp") + [setreg(P, AND(OR(L("sp"), 0x20), 0xEF))] + \
        pop_to("lo") + pop_to("hi") + [setreg(PC, OR(SHL(L("hi"), 8), L("lo")))]
def i_BRK():
    return [adv(1)] + push(SHR(reg(PC), 8)) + push(AND(reg(PC), 0xFF)) + \
        push(OR(reg(P), 0x10)) + [setflag(IF_, 1),
        setreg(PC, ["call", "rd16", [0xFFFE]])]

def i_PHA(): return push(reg(A))
def i_PHP(): return push(OR(reg(P), 0x10))
def i_PLA(): return pop_to("m") + [setreg(A, L("m"))] + setzn(L("m"))
def i_PLP(): return pop_to("m") + [setreg(P, AND(OR(L("m"), 0x20), 0xEF))]

def _branch(bit, want):
    return [
        setL("rel", RD(reg(PC))), adv(1),
        ["if", ["==", getflag(bit), want], [
            ["if", [">", L("rel"), 127], [setL("rel", ["-", L("rel"), 256])]],
            setreg(PC, m16(ADDW(reg(PC), L("rel")))),
        ]],
    ]
def i_BPL(): return _branch(NF, 0)
def i_BMI(): return _branch(NF, 1)
def i_BVC(): return _branch(VF, 0)
def i_BVS(): return _branch(VF, 1)
def i_BCC(): return _branch(CF, 0)
def i_BCS(): return _branch(CF, 1)
def i_BNE(): return _branch(ZF, 0)
def i_BEQ(): return _branch(ZF, 1)

def i_CLC(): return [setflag(CF, 0)]
def i_SEC(): return [setflag(CF, 1)]
def i_CLI(): return [setflag(IF_, 0)]
def i_SEI(): return [setflag(IF_, 1)]
def i_CLV(): return [setflag(VF, 0)]
def i_CLD(): return [setflag(DF, 0)]
def i_SED(): return [setflag(DF, 1)]
def i_NOP(): return []

# ---- unofficial ----
def i_LAX(): return [setL("m", M), setreg(A, AND(L("m"), 0xFF)),
                     setreg(X, AND(L("m"), 0xFF))] + setzn(L("m"))
def i_SAX(): return [WR(L("ea"), AND(reg(A), reg(X)))]
def i_DCP():  # DEC then CMP
    return [setL("m", AND(["-", M, 1], 0xFF)), WR(L("ea"), L("m")),
            setL("r", ["-", reg(A), L("m")]),
            setflag(CF, ["?:", [">=", reg(A), L("m")], 1, 0])] + setzn(L("r"))
def i_ISC():  # INC then SBC
    return [setL("m", AND(ADDW(M, 1), 0xFF)), WR(L("ea"), L("m")),
            setL("r", ["-", ["-", reg(A), L("m")], ["-", 1, getflag(CF)]]),
            setflag(CF, ["?:", [">=", L("r"), 0], 1, 0]),
            setflag(VF, ["?:", ["!=", AND(AND(XOR(reg(A), L("r")), XOR(reg(A), L("m"))), 0x80), 0], 1, 0])] + \
        setzn(L("r")) + [setreg(A, AND(L("r"), 0xFF))]
def i_SLO():  # ASL mem then ORA
    return [setL("m", M), setflag(CF, AND(SHR(L("m"), 7), 1)),
            setL("s", AND(SHL(L("m"), 1), 0xFF)), WR(L("ea"), L("s")),
            setreg(A, OR(reg(A), L("s")))] + setzn(reg(A))
def i_RLA():  # ROL mem then AND
    return [setL("m", M), setL("oc", getflag(CF)),
            setflag(CF, AND(SHR(L("m"), 7), 1)),
            setL("s", AND(OR(SHL(L("m"), 1), L("oc")), 0xFF)), WR(L("ea"), L("s")),
            setreg(A, AND(reg(A), L("s")))] + setzn(reg(A))
def i_SRE():  # LSR mem then EOR
    return [setL("m", M), setflag(CF, AND(L("m"), 1)),
            setL("s", SHR(L("m"), 1)), WR(L("ea"), L("s")),
            setreg(A, XOR(reg(A), L("s")))] + setzn(reg(A))
def i_ANC():
    return [setreg(A, AND(reg(A), M))] + setzn(reg(A)) + [setflag(CF, AND(SHR(reg(A), 7), 1))]
def i_ALR():
    return [setreg(A, AND(reg(A), M)), setflag(CF, AND(reg(A), 1)),
            setreg(A, SHR(reg(A), 1))] + setzn(reg(A))
def i_ARR():
    return [setreg(A, AND(reg(A), M)),
            setreg(A, OR(SHL(getflag(CF), 7), SHR(reg(A), 1)))] + setzn(reg(A)) + [
            setflag(CF, AND(SHR(reg(A), 6), 1)),
            setflag(VF, XOR(getflag(CF), AND(SHR(reg(A), 5), 1)))]
def i_XAA():  # flags from OLD A (matches NESd cascade order), then A recomputed
    return setzn(reg(A)) + [setreg(A, AND(AND(OR(reg(A), 0xEE), reg(X)), M))]
def i_AXS():
    return [setL("ax", AND(reg(A), reg(X))), setL("m", M),
            setL("r", AND(["-", L("ax"), L("m")], 0xFF)),
            setflag(CF, ["?:", [">=", L("ax"), L("m")], 1, 0]),
            setreg(X, L("r"))] + setzn(L("r"))
def i_LAS():
    return [setreg(A, AND(reg(SP), M)), setreg(X, reg(A)), setreg(SP, reg(A))] + setzn(reg(A))
def i_AHX():
    return [WR(L("ea"), AND(AND(reg(A), reg(X)), ADDW(SHR(L("ea"), 8), 1)))]
def i_TAS():
    return [setreg(SP, AND(reg(A), reg(X))),
            WR(L("ea"), AND(reg(SP), ADDW(SHR(L("ea"), 8), 1)))]
def _shstore(regi, indexReg):
    # SHY/SHX: mangle high byte on page cross, store regi & ((ea>>8)+1)
    return [
        setL("base", ["-", L("ea"), reg(indexReg)]),
        setL("hi", SHR(L("ea"), 8)),
        ["if", ["!=", AND(L("base"), 0xFF00), AND(L("ea"), 0xFF00)],
            [setL("hi", AND(L("hi"), reg(regi)))]],
        setL("ea", OR(SHL(L("hi"), 8), AND(L("ea"), 0xFF))),
        WR(L("ea"), AND(reg(regi), ADDW(SHR(L("ea"), 8), 1))),
    ]
def i_SHY(): return _shstore(Y, X)
def i_SHX(): return _shstore(X, Y)
def i_STP(): return [setreg(HALT, 1)]

def i_RRA():  # ROR mem then ADC
    return [setL("m", M), setL("oc", getflag(CF)),
            setflag(CF, AND(L("m"), 1)),
            setL("s", OR(SHL(L("oc"), 7), SHR(L("m"), 1))), WR(L("ea"), L("s")),
            setL("r", ADDW(ADDW(reg(A), L("s")), getflag(CF))),
            setflag(CF, ["?:", [">", L("r"), 0xFF], 1, 0]),
            setflag(VF, ["?:", ["!=", AND(AND(["~", XOR(reg(A), L("s"))], XOR(reg(A), L("r"))), 0x80), 0], 1, 0])] + \
        setzn(L("r")) + [setreg(A, AND(L("r"), 0xFF))]

# opcode table: op -> (mnemonic, mode, cycles). cycles informational.
# Comprehensive incl. unofficial (NESd parity).
OPS = {
 0x00:("BRK","imp"),0x01:("ORA","izx"),0x05:("ORA","zp"),0x06:("ASL","zp"),
 0x08:("PHP","imp"),0x09:("ORA","imm"),0x0A:("ASL","acc"),0x0D:("ORA","abs"),
 0x0E:("ASL","abs"),0x10:("BPL","imp"),0x11:("ORA","izy"),0x15:("ORA","zpx"),
 0x16:("ASL","zpx"),0x18:("CLC","imp"),0x19:("ORA","absy"),0x1D:("ORA","absx"),
 0x1E:("ASL","absx"),0x20:("JSR","abs"),0x21:("AND","izx"),0x24:("BIT","zp"),
 0x25:("AND","zp"),0x26:("ROL","zp"),0x28:("PLP","imp"),0x29:("AND","imm"),
 0x2A:("ROL","acc"),0x2C:("BIT","abs"),0x2D:("AND","abs"),0x2E:("ROL","abs"),
 0x30:("BMI","imp"),0x31:("AND","izy"),0x35:("AND","zpx"),0x36:("ROL","zpx"),
 0x38:("SEC","imp"),0x39:("AND","absy"),0x3D:("AND","absx"),0x3E:("ROL","absx"),
 0x40:("RTI","imp"),0x41:("EOR","izx"),0x45:("EOR","zp"),0x46:("LSR","zp"),
 0x48:("PHA","imp"),0x49:("EOR","imm"),0x4A:("LSR","acc"),0x4C:("JMP","abs"),
 0x4D:("EOR","abs"),0x4E:("LSR","abs"),0x50:("BVC","imp"),0x51:("EOR","izy"),
 0x55:("EOR","zpx"),0x56:("LSR","zpx"),0x58:("CLI","imp"),0x59:("EOR","absy"),
 0x5D:("EOR","absx"),0x5E:("LSR","absx"),0x60:("RTS","imp"),0x61:("ADC","izx"),
 0x65:("ADC","zp"),0x66:("ROR","zp"),0x68:("PLA","imp"),0x69:("ADC","imm"),
 0x6A:("ROR","acc"),0x6C:("JMP","ind"),0x6D:("ADC","abs"),0x6E:("ROR","abs"),
 0x70:("BVS","imp"),0x71:("ADC","izy"),0x75:("ADC","zpx"),0x76:("ROR","zpx"),
 0x78:("SEI","imp"),0x79:("ADC","absy"),0x7D:("ADC","absx"),0x7E:("ROR","absx"),
 0x81:("STA","izx"),0x84:("STY","zp"),0x85:("STA","zp"),0x86:("STX","zp"),
 0x88:("DEY","imp"),0x8A:("TXA","imp"),0x8C:("STY","abs"),0x8D:("STA","abs"),
 0x8E:("STX","abs"),0x90:("BCC","imp"),0x91:("STA","izy"),0x94:("STY","zpx"),
 0x95:("STA","zpx"),0x96:("STX","zpy"),0x98:("TYA","imp"),0x99:("STA","absy"),
 0x9A:("TXS","imp"),0x9D:("STA","absx"),0xA0:("LDY","imm"),0xA1:("LDA","izx"),
 0xA2:("LDX","imm"),0xA4:("LDY","zp"),0xA5:("LDA","zp"),0xA6:("LDX","zp"),
 0xA8:("TAY","imp"),0xA9:("LDA","imm"),0xAA:("TAX","imp"),0xAC:("LDY","abs"),
 0xAD:("LDA","abs"),0xAE:("LDX","abs"),0xB0:("BCS","imp"),0xB1:("LDA","izy"),
 0xB4:("LDY","zpx"),0xB5:("LDA","zpx"),0xB6:("LDX","zpy"),0xB8:("CLV","imp"),
 0xB9:("LDA","absy"),0xBA:("TSX","imp"),0xBC:("LDY","absx"),0xBD:("LDA","absx"),
 0xBE:("LDX","absy"),0xC0:("CPY","imm"),0xC1:("CMP","izx"),0xC4:("CPY","zp"),
 0xC5:("CMP","zp"),0xC6:("DEC","zp"),0xC8:("INY","imp"),0xC9:("CMP","imm"),
 0xCA:("DEX","imp"),0xCC:("CPY","abs"),0xCD:("CMP","abs"),0xCE:("DEC","abs"),
 0xD0:("BNE","imp"),0xD1:("CMP","izy"),0xD5:("CMP","zpx"),0xD6:("DEC","zpx"),
 0xD8:("CLD","imp"),0xD9:("CMP","absy"),0xDD:("CMP","absx"),0xDE:("DEC","absx"),
 0xE0:("CPX","imm"),0xE1:("SBC","izx"),0xE4:("CPX","zp"),0xE5:("SBC","zp"),
 0xE6:("INC","zp"),0xE8:("INX","imp"),0xE9:("SBC","imm"),0xEA:("NOP","imp"),
 0xEC:("CPX","abs"),0xED:("SBC","abs"),0xEE:("INC","abs"),0xF0:("BEQ","imp"),
 0xF1:("SBC","izy"),0xF5:("SBC","zpx"),0xF6:("INC","zpx"),0xF8:("SED","imp"),
 0xF9:("SBC","absy"),0xFD:("SBC","absx"),0xFE:("INC","absx"),
 # unofficial NOPs (implied/imm/zp/zpx/abs/absx variants)
 0x1A:("NOP","imp"),0x3A:("NOP","imp"),0x5A:("NOP","imp"),0x7A:("NOP","imp"),
 0xDA:("NOP","imp"),0xFA:("NOP","imp"),
 0x80:("NOP","imm"),0x82:("NOP","imm"),0x89:("NOP","imm"),0xC2:("NOP","imm"),0xE2:("NOP","imm"),
 0x04:("NOP","zp"),0x44:("NOP","zp"),0x64:("NOP","zp"),
 0x14:("NOP","zpx"),0x34:("NOP","zpx"),0x54:("NOP","zpx"),0x74:("NOP","zpx"),0xD4:("NOP","zpx"),0xF4:("NOP","zpx"),
 0x0C:("NOP","abs"),
 0x1C:("NOP","absx"),0x3C:("NOP","absx"),0x5C:("NOP","absx"),0x7C:("NOP","absx"),0xDC:("NOP","absx"),0xFC:("NOP","absx"),
 # LAX / SAX
 0xA3:("LAX","izx"),0xA7:("LAX","zp"),0xAF:("LAX","abs"),0xB3:("LAX","izy"),0xB7:("LAX","zpy"),0xBF:("LAX","absy"),
 0x83:("SAX","izx"),0x87:("SAX","zp"),0x8F:("SAX","abs"),0x97:("SAX","zpy"),
 # DCP / ISC
 0xC3:("DCP","izx"),0xC7:("DCP","zp"),0xCF:("DCP","abs"),0xD3:("DCP","izy"),0xD7:("DCP","zpx"),0xDB:("DCP","absy"),0xDF:("DCP","absx"),
 0xE3:("ISC","izx"),0xE7:("ISC","zp"),0xEF:("ISC","abs"),0xF3:("ISC","izy"),0xF7:("ISC","zpx"),0xFB:("ISC","absy"),0xFF:("ISC","absx"),
 # SLO / RLA / SRE / RRA
 0x03:("SLO","izx"),0x07:("SLO","zp"),0x0F:("SLO","abs"),0x13:("SLO","izy"),0x17:("SLO","zpx"),0x1B:("SLO","absy"),0x1F:("SLO","absx"),
 0x23:("RLA","izx"),0x27:("RLA","zp"),0x2F:("RLA","abs"),0x33:("RLA","izy"),0x37:("RLA","zpx"),0x3B:("RLA","absy"),0x3F:("RLA","absx"),
 0x43:("SRE","izx"),0x47:("SRE","zp"),0x4F:("SRE","abs"),0x53:("SRE","izy"),0x57:("SRE","zpx"),0x5B:("SRE","absy"),0x5F:("SRE","absx"),
 0x63:("RRA","izx"),0x67:("RRA","zp"),0x6F:("RRA","abs"),0x73:("RRA","izy"),0x77:("RRA","zpx"),0x7B:("RRA","absy"),0x7F:("RRA","absx"),
 # unofficial SBC
 0xEB:("SBC","imm"),
 # ANC/ALR/ARR/XAA/LAX#/AXS/LAS + store-high AHX/TAS/SHY/SHX
 0x0B:("ANC","imm"),0x2B:("ANC","imm"),0x4B:("ALR","imm"),0x6B:("ARR","imm"),
 0x8B:("XAA","imm"),0xAB:("LAX","imm"),0xCB:("AXS","imm"),0xBB:("LAS","absy"),
 0x93:("AHX","izy"),0x9F:("AHX","absy"),0x9B:("TAS","absy"),
 0x9C:("SHY","absx"),0x9E:("SHX","absy"),
 # STP/KIL (halt; nestest never executes these)
 0x02:("STP","imp"),0x12:("STP","imp"),0x22:("STP","imp"),0x32:("STP","imp"),
 0x42:("STP","imp"),0x52:("STP","imp"),0x62:("STP","imp"),0x72:("STP","imp"),
 0x92:("STP","imp"),0xB2:("STP","imp"),0xD2:("STP","imp"),0xF2:("STP","imp"),
}

INSTR = {
 "LDA": i_LDA, "LDX": i_LDX, "LDY": i_LDY, "STA": i_STA, "STX": i_STX, "STY": i_STY,
 "TAX": i_TAX, "TAY": i_TAY, "TXA": i_TXA, "TYA": i_TYA, "TSX": i_TSX, "TXS": i_TXS,
 "ADC": i_ADC, "SBC": i_SBC, "AND": i_AND, "ORA": i_ORA, "EOR": i_EOR, "BIT": i_BIT,
 "CMP": i_CMP, "CPX": i_CPX, "CPY": i_CPY, "INC": i_INC, "DEC": i_DEC,
 "INX": i_INX, "INY": i_INY, "DEX": i_DEX, "DEY": i_DEY,
 "JMP": i_JMP, "JSR": i_JSR, "RTS": i_RTS, "RTI": i_RTI, "BRK": i_BRK,
 "PHA": i_PHA, "PHP": i_PHP, "PLA": i_PLA, "PLP": i_PLP,
 "BPL": i_BPL, "BMI": i_BMI, "BVC": i_BVC, "BVS": i_BVS, "BCC": i_BCC, "BCS": i_BCS,
 "BNE": i_BNE, "BEQ": i_BEQ, "CLC": i_CLC, "SEC": i_SEC, "CLI": i_CLI, "SEI": i_SEI,
 "CLV": i_CLV, "CLD": i_CLD, "SED": i_SED, "NOP": i_NOP,
 "LAX": i_LAX, "SAX": i_SAX, "DCP": i_DCP, "ISC": i_ISC,
 "SLO": i_SLO, "RLA": i_RLA, "SRE": i_SRE, "RRA": i_RRA,
 "ANC": i_ANC, "ALR": i_ALR, "ARR": i_ARR, "XAA": i_XAA, "AXS": i_AXS, "LAS": i_LAS,
 "AHX": i_AHX, "TAS": i_TAS, "SHY": i_SHY, "SHX": i_SHX, "STP": i_STP,
}
SHIFTS = {"ASL", "LSR", "ROL", "ROR"}

def op_body(mnem, mode):
    stmts = list(MODES[mode]())
    if mnem in SHIFTS:
        stmts += _shift(mode == "acc", mnem)
    else:
        stmts += INSTR[mnem]()
    return stmts

def build():
    cases = []
    for op in sorted(OPS):
        mnem, mode = OPS[op]
        cases.append([op, op_body(mnem, mode)])
    default = [setreg(HALT, 1)]  # unknown opcode halts (should not happen: all 256? we cover most)

    funcs = {
        "rd": {"params": ["a"], "body": [
            ["if", ["<", L("a"), 0x2000], [["ret", ["u8", "ram", AND(L("a"), 0x7FF)]]]],
            ["if", ["<", L("a"), 0x4020], [["ret", 0]]],       # PPU/APU/IO stub
            ["ret", ["u8", "prg", AND(["-", L("a"), 0x8000], 0x7FFF)]],
        ]},
        "wr": {"params": ["a", "v"], "body": [
            ["if", ["<", L("a"), 0x2000], [["setu8", "ram", AND(L("a"), 0x7FF), L("v")], ["ret", 0]]],
            ["ret", 0],
        ]},
        "rd16": {"params": ["a"], "body": [
            ["ret", OR(["call", "rd", [L("a")]], SHL(["call", "rd", [m16(ADDW(L("a"), 1))]], 8))],
        ]},
        "reset": {"params": ["pc"], "body": [
            setreg(A, 0), setreg(X, 0), setreg(Y, 0), setreg(SP, 0xFD),
            setreg(P, 0x24), setreg(PC, L("pc")), setreg(CYC, 0), setreg(HALT, 0),
        ]},
        "step": {"params": [], "body": [
            setL("op", RD(reg(PC))),
            setreg(PC, m16(ADDW(reg(PC), 1))),
            setreg(CYC, ADDW(reg(CYC), 1)),
            ["switch", L("op"), cases, default],
            ["ret", reg(PC)],
        ]},
        "run": {"params": ["maxSteps"], "body": [
            setL("i", 0),
            ["while", ["and", ["==", reg(HALT), 0], ["<", L("i"), L("maxSteps")]], [
                ["call", "step", []],
                setL("i", ADDW(L("i"), 1)),
            ]],
            ["ret", reg(CYC)],
        ]},
    }
    prog = {"buffers": {"ram": 2048, "prg": 32768}, "i32": {"reg": 8}, "functions": funcs}
    return prog

if __name__ == "__main__":
    prog = build()
    import os
    out = os.path.join(os.path.dirname(__file__), "nesd_cpu.json")
    json.dump(prog, open(out, "w"))
    print("wrote", out, "opcodes:", len(OPS), "functions:", len(prog["functions"]))
