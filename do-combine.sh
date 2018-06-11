#!/bin/bash -x
opt='discard'

mountAndClean() {
	if [[ $1 =~ '/' ]]; then
		mount -o $opt $1 /mnt
	else
		qemu-img convert -p -S 512 $1.qcow2 -O raw $1.raw
		mount -o $opt,loop,offset=$(( 512 * 2048 )) $1.raw /mnt
	fi
	dd if=/dev/zero of=/mnt/ZERO bs=256k conv=fsync status=progress
	rm -f /mnt/ZERO
	fstrim -v /mnt
	umount /mnt
}
setupLoop() {
	losetup -D
	if [[ $(losetup -l | wc -l) -ne 0 ]]; then
		echo Something is wrong with loop device, can\'t continue
		exit 1
	fi
	losetup -f $1.raw
	kpartx -a /dev/loop0
	vgscan
	vgchange -a y lnxvg
}
cleanupLoop() {
	vgchange -a n lnxvg
	#kpartx -d /dev/loop0
	dmsetup remove_all
	losetup -D
	if [[ $(losetup -l | wc -l) -ne 0 ]]; then
		echo Something is wrong with loop device, clean up manually
		exit 1
	fi
}

mountAndClean $1 # glance
mountAndClean $2 # nova
setupLoop $1
mountAndClean /dev/lnxvg/root
dd if=$2.raw of=/dev/lnxvg/DEFAULT bs=4k conv=sparse,fsync status=progress

bash; cleanupLoop

qemu-img convert -S 4096 -cp $1.raw -O qcow2 $1-z.qcow2
