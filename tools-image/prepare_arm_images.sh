#!/bin/bash
# This script prepares Kairos state, recovery, oem and pesistent partitions as img files.

set -e

# Temp dir used during build
WORKDIR=$(mktemp -d --tmpdir arm-builder.XXXXXXXXXX)
TARGET=$(mktemp -d --tmpdir arm-builder.XXXXXXXXXX)
STATEDIR=$(mktemp -d --tmpdir arm-builder.XXXXXXXXXX)

: "${OEM_LABEL:=COS_OEM}"
: "${RECOVERY_LABEL:=COS_RECOVERY}"
: "${ACTIVE_LABEL:=COS_ACTIVE}"
: "${PASSIVE_LABEL:=COS_PASSIVE}"
: "${PERSISTENT_LABEL:=COS_PERSISTENT}"
: "${SYSTEM_LABEL:=COS_SYSTEM}"
: "${STATE_LABEL:=COS_STATE}"
  
size="${SIZE:-7544}"
state_size="${STATE_SIZE:-4992}"
recovery_size="${RECOVERY_SIZE:-2192}"
default_active_size="${DEFAULT_ACTIVE_SIZE:-2400}"

container_image="${container_image:-quay.io/kairos/kairos-opensuse-leap-arm-rpi:v1.5.1-k3sv1.25.6-k3s1}"

ensure_dir_structure() {
    local target=$1
    for mnt in /sys /proc /dev /tmp /boot /usr/local /oem
    do
        if [ ! -d "${target}${mnt}" ]; then
          mkdir -p ${target}${mnt}
        fi
    done
}

mkdir -p ${STATEDIR}/cOS

dd if=/dev/zero of=${STATEDIR}/cOS/active.img bs=1M count=$default_active_size

mkfs.ext2 ${STATEDIR}/cOS/active.img -L ${ACTIVE_LABEL}


LOOP=$(losetup --show -f ${STATEDIR}/cOS/active.img)
if [ -z "$LOOP" ]; then
  echo "No device"
  exit 1
fi

mount -t ext2 $LOOP $TARGET

ensure_dir_structure $TARGET

# Download the container image
if [ -z "$directory" ]; then
  echo ">>> Downloading container image"
  luet util unpack $container_image $TARGET
else
  echo ">>> Copying files from $directory"
  rsync -axq --exclude='host' --exclude='mnt' --exclude='proc' --exclude='sys' --exclude='dev' --exclude='tmp' ${directory}/ $TARGET
fi

umount $TARGET
sync

losetup -d $LOOP


echo ">> Preparing passive.img"
cp -rfv ${STATEDIR}/cOS/active.img ${STATEDIR}/cOS/passive.img
tune2fs -L ${PASSIVE_LABEL} ${STATEDIR}/cOS/passive.img


# Preparing recovery
echo ">> Preparing recovery.img"
RECOVERY=$(mktemp -d --tmpdir arm-builder.XXXXXXXXXX)
mkdir -p ${RECOVERY}/cOS
cp -rfv ${STATEDIR}/cOS/active.img ${RECOVERY}/cOS/recovery.img
tune2fs -L ${SYSTEM_LABEL} ${RECOVERY}/cOS/recovery.img

# Install real grub config to recovery
cp -rfv /arm/grub/config/* $RECOVERY
mkdir -p $RECOVERY/grub2
cp -rfv /arm/grub/artifacts/* $RECOVERY/grub2

dd if=/dev/zero of=recovery_partition.img bs=1M count=$recovery_size
dd if=/dev/zero of=state_partition.img bs=1M count=$state_size

mkfs.ext4 -F -L ${RECOVERY_LABEL} recovery_partition.img
LOOP=$(losetup --show -f recovery_partition.img)
mkdir -p $WORKDIR/recovery
mount $LOOP $WORKDIR/recovery
cp -arf $RECOVERY/* $WORKDIR/recovery
umount $WORKDIR/recovery
losetup -d $LOOP

mkfs.ext4 -F -L ${STATE_LABEL} state_partition.img
LOOP=$(losetup --show -f state_partition.img)
mkdir -p $WORKDIR/state
mount $LOOP $WORKDIR/state
cp -arf $STATEDIR/* $WORKDIR/state
grub2-editenv $WORKDIR/state/grub_oem_env set "default_menu_entry=Kairos"
umount $WORKDIR/state
losetup -d $LOOP

cp -rfv state_partition.img bootloader/
cp -rfv recovery_partition.img bootloader/

## Optional, prepare COS_OEM and COS_PERSISTENT

# Create the grubenv forcing first boot to be on recovery system
mkdir -p $WORKDIR/oem
cp -rfv /defaults.yaml $WORKDIR/oem/01_defaults.yaml

# Create a 64MB filesystem for OEM volume
truncate -s $((64*1024*1024)) bootloader/oem.img
mkfs.ext2 -L "${OEM_LABEL}" -d $WORKDIR/oem bootloader/oem.img

# Create a 2GB filesystem for COS_PERSISTENT volume
truncate -s $((2048*1024*1024)) bootloader/persistent.img
mkfs.ext2 -L "${PERSISTENT_LABEL}" bootloader/persistent.img
