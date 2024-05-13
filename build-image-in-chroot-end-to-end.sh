#!/bin/bash

if [ "$#" -lt 1 ]; then
	echo "We need to know which platform we're building for."
	echo "Should be one of: {replicape, recore, raspihf, raspi64}"
	echo "Usage: build-image-in-chroot-end-to-end.sh platform [system-build-script]"
	exit
fi

if [ "$#" -gt 1 ]; then
	SYSTEM_ANSIBLE=$2
else
	SYSTEM_ANSIBLE=SYSTEM_klipper_octoprint-DEFAULT.yml
fi

if [ "$#" -eq 3 ]; then
	RESUME=$3
else
	RESUME=0
fi

if [ ! -f ${SYSTEM_ANSIBLE} ]; then
	echo "Could not find the system build playbook ${SYSTEM_ANSIBLE}. Cannot continue."
	exit
fi

set -x
set -e

TARGET_PLATFORM=$1

REFACTOR_HOME="/usr/src/Refactor"
MOUNTPOINT=$(mktemp -d /tmp/umikaze-root.XXXXXX)
for f in $(ls BaseLinux/${TARGET_PLATFORM}/*)
do
	source $f
done

if [ ${RESUME} -eq 1 -a -f "resume.img" ]; then
	cp resume.img use.img
	DEVICE=`losetup -P -f --show use.img`
	echo "preparing the partition layout"
	if [ ${TARGET_PLATFORM} == "recore" ]; then
		PARTITION=${DEVICE}p2
	fi
	if [ ${TARGET_PLATFORM} == 'replicape' ]; then
		PARTITION=${DEVICE}p1
	fi
	echo "Beginning the mount sequence."
	mount ${PARTITION} ${MOUNTPOINT}
	if [ ${TARGET_PLATFORM} == "recore" ]; then
		mount ${DEVICE}p1 ${MOUNTPOINT}/boot
	fi
	mount -o bind /dev ${MOUNTPOINT}/dev
	mount -o bind /sys ${MOUNTPOINT}/sys
	mount -o bind /proc ${MOUNTPOINT}/proc
	mount -o bind /dev/pts ${MOUNTPOINT}/dev/pts

	rm -rf ${MOUNTPOINT}${REFACTOR_HOME}/*
	find "$(pwd)" -mindepth 1 -maxdepth 1 ! -name "*.img" ! -name "*.7z" -exec cp -r {} ${MOUNTPOINT}${REFACTOR_HOME} \;
else
	
	if [ -f "customize.sh" ] ; then
		source customize.sh
	fi

	TARGETIMAGE=refactor-${TARGET_PLATFORM}-rootfs.img

	if [ ! -f $BASEIMAGE ]; then
		wget -q $BASEIMAGE_URL -O $BASEIMAGE
	fi

	rm -f $TARGETIMAGE
	decompress || $(echo "check your Linux platform file is correct!"; exit) # defined in the BaseLinux/{platform}/Linux file

	echo "preparing the partition layout"
	if [ ${TARGET_PLATFORM} == "recore" ]; then
		truncate -s 6000M $TARGETIMAGE
		DEVICE=`losetup -P -f --show $TARGETIMAGE`
		PARTITION=${DEVICE}p2
		printf "%s\n%s\n\n%s : start=8192, size=524288, type=83\n%s : start=532480, size=11303520, type=83\n" \
			"# partition table of ${DEVICE}" \
			"unit: sectors" \
			"${DEVICE}p1" \
			"${DEVICE}p2" > image.layout
	fi

	if [ ${TARGET_PLATFORM} == 'replicape' ]; then
		truncate -s 6000M $TARGETIMAGE
		DEVICE=`losetup -P -f --show $TARGETIMAGE`
		PARTITION=${DEVICE}p1
		#7364608
		printf "%s\n%s\n\n%s : start=8192, size=12000000, type=83\n" \
			"# partition table of ${DEVICE}" \
			"unit: sectors" \
			"${DEVICE}p1" > image.layout
	fi

	sfdisk --delete ${DEVICE}
	# Perform actual modifications to the partition layout
	sfdisk ${DEVICE} < image.layout
	echo "checking the filesystem..."

	e2fsck -f -p ${PARTITION}
	clean_status=$?
	if [ "$clean_status" -ne "0" ]; then
		echo "had to clear out something on the FS..."
	fi
	echo "resizing"
	resize2fs ${PARTITION}

	echo "Beginning the mount sequence."
	mount ${PARTITION} ${MOUNTPOINT}
	cp /usr/bin/qemu-arm-static ${MOUNTPOINT}/usr/bin/
	if [ ${TARGET_PLATFORM} == "recore" ]; then
		mount ${DEVICE}p1 ${MOUNTPOINT}/boot
	fi
	mount -o bind /dev ${MOUNTPOINT}/dev
	mount -o bind /sys ${MOUNTPOINT}/sys
	mount -o bind /proc ${MOUNTPOINT}/proc
	mount -o bind /dev/pts ${MOUNTPOINT}/dev/pts

	rm ${MOUNTPOINT}/etc/resolv.conf
	echo "nameserver 8.8.8.8" >> ${MOUNTPOINT}/etc/resolv.conf

	# don't git clone here - if someone did a commit since this script started, Unexpected Things will happen
	# instead, do a deep copy so the image has a git repo as well
	mkdir -p ${MOUNTPOINT}${REFACTOR_HOME}

	find "$(pwd)" -mindepth 1 -maxdepth 1 ! -name "*.img" ! -name "*.7z" -exec cp -r {} ${MOUNTPOINT}${REFACTOR_HOME} \;

	set +e # allow this to fail - we'll check the return code
	chroot ${MOUNTPOINT} su -c "\
	cd ${REFACTOR_HOME} && \
	apt update && DEBIAN_FRONTEND=noninteractive apt -y upgrade && \
	apt install -y git ansible && \
	export LC_ALL=\"en_US.UTF-8\" && \
	locale-gen --purge en_US.UTF-8 && \
	echo -e 'LANG=en_US.UTF-8\nLANGUAGE=\"en_CA:en\"\nLC_CTYPE=\"en_US.UTF-8\"\nLC_ALL=\"en_US.UTF-8\"\n' > /etc/default/locale && \
	apt install -y python3-pip python3-venv build-essential ansible"
	if [ ${RESUME} -eq 1 ] ; then
		chroot ${MOUNTPOINT} su -c "sync && df -h"
		df -h
		echo "Generating resume.img now."
		blocksize=$(fdisk -l $DEVICE | grep Units: | awk '{printf $8}')
		count=$(fdisk -l -o Device,End $DEVICE | grep $PARTITION | awk '{printf $2}')
		ddcount=$((count*blocksize/1000000+1))
		dd if=$DEVICE bs=1MB count=${ddcount} status=progress > resume.img
	fi
fi

chroot ${MOUNTPOINT} su -c "\
cd ${REFACTOR_HOME} && \
apt install -y debconf-utils && \
cat /etc/resolv.conf
LC_ALL=en_US.UTF-8 ansible-playbook ${SYSTEM_ANSIBLE} -T 180 --extra-vars '${ANSIBLE_PLATFORM_VARS}' -i hosts -e 'ansible_python_interpreter=/usr/bin/python3'"

status=$?
set -e

rm -rf ${MOUNTPOINT}${REFACTOR_HOME}
rm -rf ${MOUNTPOINT}/root/.ansible

rm ${MOUNTPOINT}/etc/resolv.conf
umount -l ${MOUNTPOINT}/dev/pts
umount -l ${MOUNTPOINT}/dev
umount -l ${MOUNTPOINT}/proc
umount -l ${MOUNTPOINT}/sys
if [ ${TARGET_PLATFORM} == "recore" ]; then
	umount -l ${MOUNTPOINT}/boot
fi
umount -l ${MOUNTPOINT}
rmdir ${MOUNTPOINT}

if [ ${RESUME} -eq 1 -a -f "use.img" ]; then
	rm use.img
fi

if [ $status -eq 0 ]; then
    echo "Looks like the image was prepared successfully - packing it up"
    if [ ${TARGET_PLATFORM} == 'replicape' ]; then
			if [ ! -f ${UBOOT_SPL} ] ; then
				wget ${UBOOT_SPL_URL}
			fi
			if [ ! -f ${UBOOT_BIN} ] ; then
				wget ${UBOOT_BIN_URL}
			fi
			dd if=${UBOOT_SPL} of=${DEVICE} seek=1 bs=128k
			dd if=${UBOOT_BIN} of=${DEVICE} seek=1 bs=384k
    fi
    ./generate-image-from-sd.sh $DEVICE $TARGET_PLATFORM
	losetup -d $DEVICE
else
    echo "image generation seems to have failed - cleaning up, returning $status"
    losetup -d $DEVICE
    exit ${status}
fi
