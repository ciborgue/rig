#!/bin/bash

META_SIZE=8

free=$(vgdisplay | sed -e '/Free/!d;s/.*Size\s*//;s/\s.*//')
name=$(vgdisplay | sed -e '/Name/!d;s/^.*Name\s*//')

if [[ $(lvdisplay /dev/$name/POOL 2> /dev/null | wc -l) -gt 0 ]]; then
  [[ $(lvdisplay /dev/$name/POOL | grep -c 'LV Pool') -gt 0 ]] && \
      exit 0 # pool is already defined and seems OK
  exit 1 # pool is defined but has no metadata and not thin pool?
fi

lvcreate --name META --extents $META_SIZE $name
lvcreate --name POOL --extents $((free - 2 * META_SIZE)) $name
lvconvert --yes --type thin-pool --poolmetadata /dev/$name/META POOL

lvcreate --name SWAP -V 4G --thinpool POOL $name
mkswap -L SWAP /dev/$name/SWAP
