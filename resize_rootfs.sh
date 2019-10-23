#!/bin/bash

#set -xe

# ./resize_rootfs.sh <rootfs> <modules>
#
# Dependencies on Debian sid or Ubuntu 18.04:
# apt install xz-utils img2simg curl

LXC_ROOTFS_FILE=${1}
OVERLAY_FILE=${2:-/lava-lxc/overlays/target/overlay.tar.gz}
EXTRA_SIZE=${EXTRA_SIZE:-512000}
SPARSE_NEEDED=${3:-no}

find_extracted_size() {
	local local_file=${1}
	local local_size=
	if [[ ${local_file##*.} =~ tar ]]; then
		local_size=$(ls -l "${local_file}" | awk '{print $5}')
		local_size=$(( "${local_size}" / 1024 ))
	elif [[ ${local_file##*.} =~ gz ]]; then
		local_size=$(gzip -l "${local_file}" | tail -1 | awk '{print $2}')
		local_size=$(( "${local_size}" / 1024 ))
	elif [[ ${local_file##*.} =~ xz ]]; then
		local_size=$(xz -l "${local_file}" | tail -1 | awk '{print $5}'|sed 's/,//g' | awk -F'.' '{print $1}')
		local_size=$(( "${local_size}"+1 ))
		local_size=$(( "${local_size}" * 1024 ))
	else
		echo "ABORT: Format not supported: ${local_size}"
		exit 1
	fi
	echo ${local_size}
}

unpack_tar_file() {
	local local_file=${1}
	local local_mount_point=${2}
	tar -xvf ${local_file} -C ${local_mount_point}
}

curl_me() {
	local local_file=${1}
	if [[ ! -f $(basename "${local_file}") ]]; then
		curl -sSL -o "$(basename "${local_file}")" "${local_file}"
		retcode=$?
		if [[ ${retcode} -ne 0 ]]; then
			exit ${retconde}
		fi
	fi
	echo $(basename "${local_file}")
}

if [[ -d /lava-lxc ]]; then
	cd /lava-lxc
else
	mkdir -p $(pwd)/lava-lxc
	cd $(pwd)/lava-lxc
fi

OVERLAY_FILE=$(curl_me "${OVERLAY_FILE}")
LXC_ROOTFS_FILE=$(curl_me "${LXC_ROOTFS_FILE}")

overlay_size=$(find_extracted_size ${OVERLAY_FILE})
rootfs_size=$(find_extracted_size ${LXC_ROOTFS_FILE})

mount_point_dir=$(mktemp -p $(pwd) -d -t kcv_$(date +%y%m%d_%H%M%S)-XXXXXXXXXX)

echo ${mount_point_dir}

new_file_name="$(ls ${LXC_ROOTFS_FILE}| awk -F'.' '{print $1}').new.rootfs"
new_size=$(( $overlay_size + $rootfs_size + $EXTRA_SIZE ))
new_size=$(( $new_size / 1024 ))

dd if=/dev/zero of=${new_file_name} bs=1M count=60 seek=${new_size}
mkfs.ext4 ${new_file_name}
mount -o loop ${new_file_name} ${mount_point_dir}
unpack_tar_file ${LXC_ROOTFS_FILE} ${mount_point_dir}
unpack_tar_file ${OVERLAY_FILE} ${mount_point_dir}
cd ${mount_point_dir}
tar -cJf ../${new_file_name}.tar.xz .
cd ..
umount ${mount_point_dir}
rmdir ${mount_point_dir}
if [[ ${SPARSE_NEEDED} == "yes" ]]; then
	img_file="$(basename "${new_file_name}" .ext4).img"
	echo "execute this command: img2simg ${new_file_name} ${img_file}"
	img2simg "${new_file_name}" "${img_file}"
	echo "execute this command: xz -c ${img_file} > ${img_file}.xz"
	xz -c "${img_file}" > "${img_file}".xz
else
	echo "execute this command: xz -c ${new_file_name} > $(basename ${new_file_name} .ext4).ext4.xz"
	xz -c "${new_file_name}" > "$(basename "${new_file_name}" .ext4).ext4.xz"
fi

echo ${new_file_name}
exit 0

# Resize and add space for the overlay... lt-qcom...
simg2img ${LXC_ROOTFS_FILE} ${LXC_ROOTFS_FILE}.ext4
free_blocks=$(dumpe2fs -h ${LXC_ROOTFS_FILE}.ext4 | grep "Free blocks" | awk '{print $3}')
block_size=$(dumpe2fs -h ${LXC_ROOTFS_FILE}.ext4 | grep "Block size" | awk '{print $3}')
free_size=$(( $block_size * $free_blocks / 1024 ))
if [ "$free_size" -lt "$overlay_size" ]; then
	block_count=$(dumpe2fs -h ${LXC_ROOTFS_FILE}.ext4 | grep "Block count" | awk '{print $3}')
	current_size=$(( $block_size * $block_count / 1024 ))
	EXTRA_SIZE=32768
	final_size=$(( $current_size + $overlay_size + $EXTRA_SIZE ))
	fsck_code=$(e2fsck -y -f ${LXC_ROOTFS_FILE}.ext4)
	resize2fs ${LXC_ROOTFS_FILE}.ext4 "$final_size"K
	img2simg ${LXC_ROOTFS_FILE}.ext4 ${LXC_ROOTFS_FILE}
	echo "resize_rootfs:" "pass"
else
	echo "resize_rootfs:" "skip"
fi
