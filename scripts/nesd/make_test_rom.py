#!/usr/bin/env python3
"""Emit a minimal deterministic NROM test ROM (nes_test.nes) exercising the PPU:
warmup vblank waits, palette upload, nametable fill with tile 1, enable rendering.
CHR tile 1 = a diagonal (pixel color 3 iff (x&7)==(y&7)) so the rendered frame is
a verifiable repeating hatch. All background → tile 1, palette[3]=white.
"""
import struct, os

# ---- tiny two-pass 6502 assembler ----
OPC = {
 ("SEI",None):0x78,("CLD",None):0xD8,("TXS",None):0x9A,("TAX",None):0xAA,
 ("INX",None):0xE8,("DEX",None):0xCA,("INY",None):0xC8,("DEY",None):0x88,
 ("RTI",None):0x40,("RTS",None):0x60,("NOP",None):0xEA,
 ("LDA","imm"):0xA9,("LDX","imm"):0xA2,("LDY","imm"):0xA0,
 ("STA","abs"):0x8D,("STX","abs"):0x8E,("STY","abs"):0x8C,
 ("STA","zp"):0x85,("LDA","zp"):0xA5,
 ("BIT","abs"):0x2C,("JMP","abs"):0x4C,("JSR","abs"):0x20,
 ("BPL","rel"):0x10,("BNE","rel"):0xD0,("BEQ","rel"):0xF0,
 ("CMP","imm"):0xC9,("CPX","imm"):0xE0,("CPY","imm"):0xC0,
}

def assemble(lines, org):
    labels = {}
    # pass 1: sizes
    def size(op, mode):
        if mode is None: return 1
        if mode in ("imm","zp","rel"): return 2
        return 3
    pc = org
    prog = []
    for ln in lines:
        ln = ln.split(";")[0].strip()
        if not ln: continue
        if ln.endswith(":"):
            labels[ln[:-1]] = pc; continue
        parts = ln.split(None, 1)
        mn = parts[0]; arg = parts[1].strip() if len(parts) > 1 else None
        mode = None
        if arg is not None:
            if arg.startswith("#"): mode = "imm"
            elif (mn in ("BPL","BNE","BEQ")): mode = "rel"
            elif arg.startswith("$") and len(arg) <= 3: mode = "zp"
            else: mode = "abs"
        prog.append((pc, mn, mode, arg))
        pc += size(mn, mode)
    # pass 2: encode
    out = bytearray()
    def val(a):
        a = a.lstrip("#")
        if a.startswith("$"): return int(a[1:], 16)
        return labels[a]
    for (pc, mn, mode, arg) in prog:
        out.append(OPC[(mn, mode)])
        if mode is None: continue
        if mode == "rel":
            target = labels[arg]; off = target - (pc + 2)
            out.append(off & 0xFF)
        elif mode in ("imm","zp"):
            out.append(val(arg) & 0xFF)
        else:
            v = val(arg); out.append(v & 0xFF); out.append((v >> 8) & 0xFF)
    return bytes(out), labels

PROG = """
reset:
  SEI
  CLD
  LDX #$FF
  TXS
  LDA #$00
  STA $2000
  STA $2001
vw1:
  BIT $2002
  BPL vw1
vw2:
  BIT $2002
  BPL vw2
  LDA #$3F
  STA $2006
  LDA #$00
  STA $2006
  LDA #$0F
  STA $2007
  LDA #$21
  STA $2007
  LDA #$16
  STA $2007
  LDA #$30
  STA $2007
  LDA #$20
  STA $2006
  LDA #$00
  STA $2006
  LDX #$00
  LDY #$03
pfull:
  LDA #$01
  STA $2007
  INX
  BNE pfull
  DEY
  BNE pfull
  LDX #$00
prem:
  LDA #$01
  STA $2007
  INX
  CPX #$C0
  BNE prem
  LDX #$00
pattr:
  LDA #$00
  STA $2007
  INX
  CPX #$40
  BNE pattr
  LDA #$00
  STA $2005
  STA $2005
  LDA #$0A
  STA $2001
  LDA #$80
  STA $2000
forever:
  JMP forever
nmi:
  RTI
"""

ORG = 0x8000
code, labels = assemble(PROG.strip().splitlines(), ORG)
prg = bytearray(16384)
prg[:len(code)] = code
# vectors at $FFFA/B (NMI), $FFFC/D (RESET), $FFFE/F (IRQ) -> offsets 0x3FFA..
def put16(off, addr):
    prg[off] = addr & 0xFF; prg[off + 1] = (addr >> 8) & 0xFF
put16(0x3FFA, labels["nmi"])
put16(0x3FFC, labels["reset"])
put16(0x3FFE, labels["nmi"])

# CHR: tile 1 diagonal. tile occupies 16 bytes: 8 plane0 + 8 plane1.
chr = bytearray(8192)
for row in range(8):
    chr[16 + row] = (1 << (7 - row))          # plane0: bit set at x==row
    chr[16 + 8 + row] = (1 << (7 - row))      # plane1: same -> color 3
# tile 0 stays blank (color 0)

rom = bytearray()
rom += b"NES\x1a"
rom += bytes([1, 1, 0x00, 0x00])  # 1x16K PRG, 1x8K CHR, mapper 0, horizontal mirror
rom += bytes(8)
rom += prg
rom += chr
out = os.path.join(os.path.dirname(__file__), "nes_test.nes")
open(out, "wb").write(rom)
print("wrote", out, "code bytes:", len(code), "reset@", hex(labels["reset"]))
