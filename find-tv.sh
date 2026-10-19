#!/bin/sh
# Finds Android TVs on this Mac's local network by looking for an open adb port (5555),
# then prints each one's address and model. Usage: ./find-tv.sh [subnet], e.g. 192.168.1
set -u

subnet="${1:-}"
if [ -z "$subnet" ]; then
  for ifc in en0 en1 en2 en3 en4 en5; do
    ip=$(ipconfig getifaddr "$ifc" 2>/dev/null) && [ -n "$ip" ] && { subnet=${ip%.*}; break; }
  done
fi
[ -n "$subnet" ] || { echo "Couldn't find this Mac's network; pass a subnet, e.g. ./find-tv.sh 192.168.1" >&2; exit 1; }

echo "Scanning $subnet.1-254 for adb (port 5555)…" >&2
tmp=$(mktemp)
# Two passes: dozing TV Wi-Fi often misses the first, short probe.
for wait in 1 2; do
  for h in $(seq 1 254); do
    ( nc -z -G "$wait" "$subnet.$h" 5555 >/dev/null 2>&1 && echo "$subnet.$h" >> "$tmp" ) &
  done
  wait
  [ -s "$tmp" ] && break
done

found=0
for ip in $(sort -u -t. -k4,4n "$tmp"); do
  adb connect "$ip:5555" >/dev/null 2>&1
  model=$(adb -s "$ip:5555" shell getprop ro.product.model 2>&1 | tr -d '\r')
  case "$model" in
    *unauthorized*) model="(allow debugging on the TV screen, then run again)" ;;
    *error*|*failed*|"") continue ;;
  esac
  echo "$ip:5555  $model"
  found=1
done
rm -f "$tmp"

[ "$found" = 1 ] || { echo "No TV found. Check that network debugging is on and the TV is on this network." >&2; exit 1; }
