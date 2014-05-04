#!/usr/bin/env python
#
# A slightly more paranoid UV5R programmer.  I found that some combination
# of my radio and programming cable liked to crash mid-way through reads or
# writes, and so I created this brute-force solution.  It seems to work, and
# should produce CHIRP-compatible image files.
#
# Example usage:
#  ./uv5r.py --read radio.img
#  # load radio.img into chirp, edit to your heart's content, save back
#  ./uv5r.py --write radio.img
#
# You should probably re-"--read" your radio after programming to make sure
# that everything seems to have gotten there.  e.g.:
#  ./uv5r.py --read radio2.img && cmp radio.img radio2.img && echo "OK"
#
# (C) 2014 Nathaniel Wesley Filardo
# Distributable under terms of GNU GPLv3
# Most code here originally "Copyright 2012 Dan Smith <dsmith@danplanet.com>"
# as part of the CHIRP project.

import sys, os, serial, time, struct
import traceback
import argparse

def hexprint(data):
    """Return a hexdump-like encoding of @data"""
    line_sz = 8

    lines = len(data) / line_sz
    
    if (len(data) % line_sz) != 0:
        lines += 1
        data += "\x00" * ((lines * line_sz) - len(data))

    out = ""
        
    for i in range(0, (len(data)/line_sz)):
        out += "%03i: " % (i * line_sz)

        left = len(data) - (i * line_sz)
        if left < line_sz:
            limit = left
        else:
            limit = line_sz
            
        for j in range(0, limit):
            out += "%02x " % ord(data[(i * line_sz) + j])

        out += "  "

        for j in range(0, limit):
            char = data[(i * line_sz) + j]

            if ord(char) > 0x20 and ord(char) < 0x7E:
                out += "%s" % char
            else:
                out += "."

        out += "\n"

    return out

def et(ser) :
    ser.write("\x06")
    assert (ser.read(1) == '\x06')

def magic(ser) :
    UV5R_MODEL_291  = "\x50\xBB\xFF\x20\x12\x07\x25"

    for byte in UV5R_MODEL_291 :
        ser.write(byte)
    assert (ser.read(1) == '\x06')

    ser.write('\x02')
    ident = ser.read(8)
    et(ser)

    return ident

def _readblk(ser, start, size) :
    msg = struct.pack(">BHB", ord("S"), start, size)
    ser.write(msg)

    answer = ser.read(4)
    assert (4 == len(answer))

    cmd, addr, length = struct.unpack(">BHB", answer)
    # print "CMD: %s  ADDR: %04x  SIZE: %02x" % (cmd, addr, length)
    assert (cmd == ord("X") and addr == start and length == size)

    chunk = ser.read(size)
    assert (size == len(chunk))
    et(ser)

    return chunk

def readblk(ser, start, size) :
    needs_init = 0
    while True:
        print "ATTEMPTING READ OF BLOCK %x" % i
        try:
            if needs_init :
                print "REINIT..."
                time.sleep(10)
                magic(ser)
                needs_init = 0
            return _readblk(ser, start, size)
        except Exception:
            traceback.print_exc()
            needs_init = 1

def writeblk(ser, start, chunk) :
    size = len(chunk)
    msg = struct.pack(">BHB", ord("X"), start, size)
    needs_init = 0
    while True:
        print "ATTEMPTING WRITE TO BLOCK %x" % start
        try:
            if needs_init :
                print "REINIT..."
                time.sleep(10)
                magic(ser)
                needs_init = 0

            assert (ser.write(msg) == len(msg))
            assert (ser.write(chunk) == size)
            assert (ser.read(1) == '\x06')

            return
        except Exception:
            traceback.print_exc()
            needs_init = 1

parser = argparse.ArgumentParser(description='UV-5R image extractor')
parser.add_argument('--radio', dest='radio', default="/dev/ttyUSB0")
parser.add_argument('--read', dest='outfile', type=argparse.FileType('w'))
parser.add_argument('--dump', dest='dump', action='store_true')
parser.add_argument('--write', dest='infile', type=argparse.FileType('r'))

args = parser.parse_args()

ser = serial.Serial(args.radio, 9600, timeout=1)
assert (ser)

if args.outfile is not None or args.dump :

  blocks = {}
  
  try:
      ident = magic(ser)
  except Exception:
      traceback.print_exc()
      print "Retrying initialization..."
      ident = magic(ser)
  
  for i in range(0, 0x1800, 0x40):
      blocks[i] = readblk(ser, i, 0x40)
  
  for i in range(0x1EC0, 0x2000, 0x40):
      blocks[i] = readblk(ser, i, 0x40)
  
  bitems = blocks.items()
  bitems.sort()
  sblocks = [blk for (_,blk) in bitems]

  data = ident + ''.join(sblocks)

  if args.dump :
    print "%s\n" % hexprint(data)
  if args.outfile :
    args.outfile.write(data)
    args.outfile.close()

if args.infile is not None :

  expected_ident = args.infile.read(8)
  blocks = {}

  for i in range(0, 0x1800, 0x10):
    blocks[i] = args.infile.read(0x10)

  for i in range(0x1EC0, 0x2000, 0x10):
    blocks[i] = args.infile.read(0x10)

  assert(args.infile.read(1) == '')
  args.infile.close()

  actual_ident = magic(ser)
  assert(expected_ident == actual_ident)

  sblocks = blocks.items()
  sblocks.sort()

  for (k,v) in sblocks :
    writeblk(ser, k, v)
