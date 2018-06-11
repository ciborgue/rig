#!/bin/bash

while true; do
  sleep 1
  nnn=$(printf '%03d' $(ip -4 -o addr show dev eth0 | sed -e 's/\/.*//;s/.*\.//'))
  [[ $nnn = "000" ]] && continue
  hostnamectl set-hostname nova-$nnn
  break
done
