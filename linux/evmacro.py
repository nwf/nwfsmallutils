#!/usr/bin/env python3

import argparse
import asyncio
import evdev
import functools
import os
import signal
import sys

from evdev import ecodes as e
from natsort import natsorted

#  1:15  2:16  3:17  4:18  5:19
#  6:58  7:30  8:31  9:32 10:33
# 11:42 12:44 13:45 14:46 15:47
#
# little:56 big:57 u:103 l:105 r:106 d:108

remap_root = {
  15: e.KEY_ESC,
  # 16
  17: e.KEY_INSERT,
  # 18
  # 19
  19: lambda event : print("%r" % event),

  58: e.KEY_LEFTCTRL,
  # 30
  31: e.KEY_TAB, # for both xmonad and chrome?
  # 32
  # 33

  42: e.KEY_LEFTSHIFT,
  44: e.KEY_LEFTMETA,
  45:
    {
      57: e.KEY_ENTER,

      103: e.KEY_PAGEUP,
      105: e.KEY_HOME,
      106: e.KEY_END,
      108: e.KEY_PAGEDOWN,
    },
  # 46
  # 47

  56: e.KEY_ESC,
  57: e.KEY_SPACE,

  103: e.KEY_UP,
  105: e.KEY_LEFT,
  106: e.KEY_RIGHT,
  108: e.KEY_DOWN,
}

def stacklook(needle, haystacks):
  r = None
  for h in haystacks[::-1] :
    r = h.get(needle)
    if r is not None : break
  return r

async def process_events(inread,outdev):
  modsdown = []
  downsmap = {}
  modstack = [remap_root]

  try:
    async for event in inread :
      if event.type != e.EV_KEY : continue
      # print(event, file=sys.stderr)

      if event.value == evdev.events.KeyEvent.key_up :
        origdown = downsmap.get(event.code)

        # Used as a remap selector, pop it and find our new table
        if origdown is None and event.code in modsdown :
          modsdown.remove(event.code)

          remap = remap_root
          modstack = [remap]
          for code in modsdown:
            newmap = stacklook(code, modstack)
            if not isinstance(newmap, dict) :
              print("Warning: non-map when replaying %r" % code)
              break
            remap = newmap
            modstack.append(remap)

        # Must have been used as an actual key; we may have changed
        # modification tables since, so emit the original value
        elif origdown is not None :
          downsmap[event.code] = None

          if isinstance(origdown, int):
            event.code = origdown
            outdev.write_event(event)
            outdev.syn()
          elif callable(origdown) :
            origdown(event)
          else:
            print("Warning: Don't know what to do with down object")

        else:
          print("Warning: Don't know what to make of key up event")

      elif event.value == evdev.events.KeyEvent.key_down :
        origcode = event.code
        newcode = stacklook(origcode, modstack)

        # We're supposed to send a key.  Add it to the downsmap and send.
        if isinstance(newcode, int) :
          downsmap[origcode] = newcode
          event.code = newcode
          outdev.write_event(event)
          outdev.syn()

        # We're supposed to change our mapping structure; don't send any
        # keys, but log this one in the modsdown list
        elif isinstance(newcode, dict) :
          modsdown.append(origcode)
          modstack.append(newcode)

        elif callable(newcode) :
          downsmap[origcode] = newcode
          newcode(event)

        else:
          print("Warning: Don't know what to make of key down event")

      elif event.value == evdev.events.KeyEvent.key_hold :
        # We repeat ordinary keys and callable events

        origdown = downsmap.get(event.code)

        if isinstance(origdown, int):
          event.code = origdown
          outdev.write_event(event)
          outdev.syn()

        elif callable(origdown) :
          origdown(event)

        elif event.code in modsdown :
          pass

        else:
          print("Warning: Don't know what to make of key hold event")

  finally:
    print("PE ending")

argp = argparse.ArgumentParser()
argp.add_argument('indev',type=str,help="Input device")
argp.add_argument('--clone',type=str,help="Device to clone for emulation")

args = argp.parse_args()

if args.indev.startswith("/"):
  indev = evdev.InputDevice(args.indev)
else:
  for dfn in natsorted(evdev.list_devices()):
    indev = evdev.InputDevice(dfn)
    if indev.name == args.indev: break
  else:
    print("Couldn't find input device named '%s'; devices:" % (args.indev))
    for dfn in natsorted(evdev.list_devices()):
      indev = evdev.InputDevice(dfn)
      print("\t%s: %s" % (dfn, indev.name))
    exit(1)

clonedev = None
if args.clone: clonedev = evdev.InputDevice(args.clone)

outdev = evdev.uinput.UInput.from_device(clonedev or indev)
if clonedev: clonedev.close()

indev.grab()

inread = indev.async_read_loop()

readtask = asyncio.ensure_future(process_events(inread, outdev))
loop = asyncio.get_event_loop()

def sig_exit(signame):
  print("got signal %s: exit" % signame)

  indev.ungrab()
  indev.close()
  outdev.close()

  readtask.cancel()

  loop.stop()

for signame in ('SIGINT', 'SIGTERM'):
  loop.add_signal_handler(getattr(signal, signame), functools.partial(sig_exit, signame))

try:
  loop.run_forever()
finally:
  print("Closing event loop")
  loop.close()
