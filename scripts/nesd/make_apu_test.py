import sys, os
sys.path.insert(0, os.path.dirname(__file__))
from make_test_rom import assemble
# pulse1: period ~253 (~440Hz), duty2, constant vol 15, length-halt on
PROG = """
reset:
  SEI
  CLD
  LDX #$FF
  TXS
  LDA #$01
  STA $4015
  LDA #$BF
  STA $4000
  LDA #$08
  STA $4001
  LDA #$FD
  STA $4002
  LDA #$08
  STA $4003
forever:
  JMP forever
nmi:
  RTI
"""
code, labels = assemble(PROG.strip().splitlines(), 0x8000)
prg = bytearray(16384)
prg[:len(code)] = code
def put16(off, addr): prg[off]=addr&0xFF; prg[off+1]=(addr>>8)&0xFF
put16(0x3FFA, labels["nmi"]); put16(0x3FFC, labels["reset"]); put16(0x3FFE, labels["nmi"])
rom = bytearray(b"NES\x1a" + bytes([1,1,0,0]) + bytes(8) + prg + bytes(8192))
open(os.path.join(os.path.dirname(__file__),"apu_test.nes"),"wb").write(rom)
print("wrote apu_test.nes code", len(code))
