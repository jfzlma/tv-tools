#!/bin/sh
# Runs a command in the TV's adb shell. Set TV to its address (from ./find-tv.sh), e.g.
#   TV=192.168.1.50:5555 ./tv-shell.sh 'getprop ro.product.model'
# Without TV set, uses adb's only connected device.
if [ -n "${TV:-}" ]; then
  exec adb -s "$TV" shell "$@"
fi
exec adb shell "$@"
