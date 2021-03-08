#!/usr/bin/env bash

set -eux -o pipefail

IMAGE=$(mktemp k3os-arm64.img.XXXXXX)

BOOT_SIZE="100"
ROOT_SIZE="900"

function cleanup() {
    set +ue
    umount "${ROOTFS_MNT}/boot/efi"
    umount "${ROOTFS_MNT}"
    rm -f "${GRUB2_DEB}" "${GRUB2_SIGNED_DEB}" "${IMAGE}"
    rm -rf "${GRUB2_TMP_DIR}" "${RASPI_FIRMWARE_DIR}" "${ROOTFS_MNT}" "${BOOT_MNT}"
    losetup -d "${LODEV}"
}

trap cleanup SIGINT EXIT

rm -f "${IMAGE}"

IMAGE_SIZE="$((BOOT_SIZE + ROOT_SIZE))M"

truncate -s "${IMAGE_SIZE}" "${IMAGE}"

parted -s "${IMAGE}" mklabel msdos
parted -s "${IMAGE}" unit MiB mkpart primary fat32 0% "${BOOT_SIZE}"
parted -s "${IMAGE}" unit MiB mkpart primary $((BOOT_SIZE + 1)) "${IMAGE_SIZE}"
parted -s "${IMAGE}" set 1 boot on

fdisk -l "${IMAGE}"

LODEV=$(losetup --show -f "${IMAGE}")
partprobe -s "${LODEV}"

LODEV_BOOT="${LODEV}p1"
LODEV_ROOT="${LODEV}p2"

mkfs.fat "${LODEV_BOOT}"
fatlabel "${LODEV_BOOT}" K3OS_ESP
mkfs.ext4 -L K3OS_STATE "${LODEV_ROOT}"

ROOTFS_MNT=$(mktemp -d rootfs.XXXXXX)
BOOT_MNT=$(mktemp -d boot.XXXXXX)

mount "${LODEV_ROOT}" "${ROOTFS_MNT}"
mkdir -p "${ROOTFS_MNT}/boot/efi"
mkdir -p "${ROOTFS_MNT}/boot/grub"
mount "${LODEV_BOOT}" "${ROOTFS_MNT}/boot/efi"

# mkdir -p "${ROOTFS_MNT}"/bin "${ROOTFS_MNT}"/boot "${ROOTFS_MNT}"/dev "${ROOTFS_MNT}"/etc "${ROOTFS_MNT}"/home "${ROOTFS_MNT}"/lib "${ROOTFS_MNT}"/media
# mkdir -p "${ROOTFS_MNT}"/mnt "${ROOTFS_MNT}"/opt "${ROOTFS_MNT}"/proc "${ROOTFS_MNT}"/root "${ROOTFS_MNT}"/sbin "${ROOTFS_MNT}"/sys
# mkdir -p "${ROOTFS_MNT}"/tmp "${ROOTFS_MNT}"/usr "${ROOTFS_MNT}"/var
# chmod 0755 "${ROOTFS_MNT}"/*
# chmod 0700 "${ROOTFS_MNT}"/root
# chmod 1777 "${ROOTFS_MNT}"/tmp
# ln -s /proc/mounts "${ROOTFS_MNT}"/etc/mtab
# mknod -m 0666 "${ROOTFS_MNT}"/dev/null c 1 3

K3OS_URL="https://github.com/rancher/k3os/releases/download/v0.11.1/k3os-rootfs-arm64.tar.gz"

if [[ ! -f k3os-rootfs.tar.gz ]]; then
    curl -fsSL "${K3OS_URL}" -o k3os-rootfs.tar.gz
fi

tar xzf k3os-rootfs.tar.gz --strip-components=1 -C "${ROOTFS_MNT}"

cp config.yaml "${ROOTFS_MNT}/k3os/system/"

RASPI_FIRMWARE_DIR=$(mktemp -d raspi-firmware.XXXXXX)

RASPI_FIRMWARE_URL="https://github.com/raspberrypi/firmware/archive/1.20210303.tar.gz"
RASPI_FIRMWARE_VERSION=$(basename "${RASPI_FIRMWARE_URL}" .tar.gz)

if [[ ! -f "firmware-${RASPI_FIRMWARE_VERSION}.tar.gz" ]]; then
    curl -fsSL "${RASPI_FIRMWARE_URL}" -o "firmware-${RASPI_FIRMWARE_VERSION}.tar.gz"
fi

# tar xzf "firmware-${RASPI_FIRMWARE_VERSION}.tar.gz" --strip-components=1 -C "${RASPI_FIRMWARE_DIR}" "firmware-${RASPI_FIRMWARE_VERSION}/boot"
# cp -r "${RASPI_FIRMWARE_DIR}"/boot/* "${ROOTFS_MNT}/boot/efi"
tar xzf "firmware-${RASPI_FIRMWARE_VERSION}.tar.gz" --strip-components=1 -C "${RASPI_FIRMWARE_DIR}"
cp -R "${RASPI_FIRMWARE_DIR}"/boot/* "${ROOTFS_MNT}/boot/efi"
cp -R "${RASPI_FIRMWARE_DIR}/modules" "${ROOTFS_MNT}/lib"

cp config.txt "${ROOTFS_MNT}/boot/efi"
cp u-boot.bin "${ROOTFS_MNT}/boot/efi"

GRUB2_DEB_URL="https://ftp.debian.org/debian/pool/main/g/grub2/grub-efi-arm64-bin_2.04-16_arm64.deb"
GRUB2_SIGNED_DEB_URL="https://ftp.debian.org/debian/pool/main/g/grub-efi-arm64-signed/grub-efi-arm64-signed_1+2.04+16_arm64.deb"

GRUB2_DEB=$(mktemp grub2arm64.XXXXXX)
GRUB2_SIGNED_DEB=$(mktemp grub2arm64-signed.XXXXXX)
GRUB2_TMP_DIR=$(mktemp -d grub2.XXXXX)

curl -fsSL "${GRUB2_DEB_URL}" -o "${GRUB2_DEB}"
curl -fsSL "${GRUB2_SIGNED_DEB_URL}" -o "${GRUB2_SIGNED_DEB}"

ar x "${GRUB2_DEB}" --output "${GRUB2_TMP_DIR}" data.tar.xz
tar xf "${GRUB2_TMP_DIR}/data.tar.xz" --strip-components=1 -C "${GRUB2_TMP_DIR}"
rm -f "${GRUB2_TMP_DIR}/data.tar.gz"

ar x "${GRUB2_SIGNED_DEB}" --output "${GRUB2_TMP_DIR}" data.tar.xz
tar xf "${GRUB2_TMP_DIR}/data.tar.xz" --strip-components=1 -C "${GRUB2_TMP_DIR}"
rm -f "${GRUB2_TMP_DIR}/data.tar.gz"

cat > "${ROOTFS_MNT}/boot/grub/grub.cfg" << EOF
set default=0
set timeout=10

set gfxmode=auto
set gfxpayload=text
insmod all_video
insmod gfxterm

terminal_input console
terminal_output console

menuentry "k3OS Current" {
  search.fs_label K3OS_STATE root
  set sqfile=/k3os/system/kernel/current/kernel.squashfs
  loopback loop0 /\$sqfile
  set root=(\$root)
  linux (loop0)/vmlinuz printk.devkmsg=on console=tty0 console=ttyAMA0,115200
  initrd /k3os/system/kernel/current/initrd
}
menuentry "k3OS Previous" {
  search.fs_label K3OS_STATE root
  set sqfile=/k3os/system/kernel/previous/kernel.squashfs
  loopback loop0 /\$sqfile
  set root=(\$root)
  linux (loop0)/vmlinuz printk.devkmsg=on console=tty0 console=ttyAMA0,115200
  initrd /k3os/system/kernel/previous/initrd
}
menuentry "k3OS Rescue (current)" {
  search.fs_label K3OS_STATE root
  set sqfile=/k3os/system/kernel/current/kernel.squashfs
  loopback loop0 /\$sqfile
  set root=(\$root)
  linux (loop0)/vmlinuz printk.devkmsg=on rescue console=tty0 console=ttyAMA0,115200
  initrd /k3os/system/kernel/current/initrd
}
menuentry "k3OS Rescue (previous)" {
  search.fs_label K3OS_STATE root
  set sqfile=/k3os/system/kernel/previous/kernel.squashfs
  loopback loop0 /\$sqfile
  set root=(\$root)
  linux (loop0)/vmlinuz printk.devkmsg=on rescue console=tty0 console=ttyAMA0,115200
  initrd /k3os/system/kernel/previous/initrd
}
EOF

grub-install --directory="${GRUB2_TMP_DIR}/usr/lib/grub/arm64-efi" --boot-directory="${ROOTFS_MNT}/boot" --efi-directory="${ROOTFS_MNT}/boot/efi" --uefi-secure-boot --bootloader-id=debian

mv "${IMAGE}" k3os-arm64.img

