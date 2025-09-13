### AnyKernel3 Minimal Module Installer
## Your Custom Version

# Properties
properties() { '
kernel.string=Lineage-kernel by sm8550-devs
do.devicecheck=0
do.modules=0
do.systemless=1
do.cleanup=1
do.cleanuponabort=0
'; }

# Import AK3 core
. tools/ak3-core.sh

# === BOOT IMAGE (not modified here) ===
split_boot
flash_boot

# === FLASH VENDOR_DLKM ===
block=vendor_dlkm
is_slot_device=1
ramdisk_compression=auto
patch_vbmeta_flag=auto

# Backup vendor_dlkm image
dd if=/dev/block/mapper/vendor_dlkm${slot} of=${home}/vendor_dlkm.img
cp ${home}/vendor_dlkm.img ${home}/_orig/vendor_dlkm.img

# Mount vendor_dlkm
extract_vendor_dlkm_dir=${home}/_extract_vendor_dlkm
mkdir -p $extract_vendor_dlkm_dir
extract_erofs ${home}/vendor_dlkm.img $extract_vendor_dlkm_dir || vendor_dlkm_is_ext4=true

if ${vendor_dlkm_is_ext4}; then
    mount ${home}/vendor_dlkm.img $extract_vendor_dlkm_dir -o rw -t ext4 || abort "! Failed to mount vendor_dlkm!"
    extract_vendor_dlkm_modules_dir=${extract_vendor_dlkm_dir}/lib/modules
else
    extract_vendor_dlkm_modules_dir=${extract_vendor_dlkm_dir}/vendor_dlkm/lib/modules
fi

# Replace modules with your pre-stored ones
rm -f ${extract_vendor_dlkm_modules_dir}/*
cp -af ${home}/_modules/vendor_dlkm/* ${extract_vendor_dlkm_modules_dir}/

# Repack vendor_dlkm
if ${vendor_dlkm_is_ext4}; then
    umount $extract_vendor_dlkm_dir
else
    rm -f ${home}/vendor_dlkm.img
    mkfs_erofs ${extract_vendor_dlkm_dir}/vendor_dlkm ${home}/vendor_dlkm.img || abort "! Failed to repack vendor_dlkm!"
    rm -rf ${extract_vendor_dlkm_dir}
fi

flash_generic vendor_dlkm

# === FLASH VENDOR_BOOT ===
block=vendor_boot
is_slot_device=1
ramdisk_compression=auto
patch_vbmeta_flag=auto
no_magisk_check=true

reset_ak
dump_boot

vendor_boot_modules_dir=${ramdisk}/lib/modules
rm -f ${vendor_boot_modules_dir}/*
cp -af ${home}/_modules/vendor_boot/* ${vendor_boot_modules_dir}/
set_perm 0 0 0644 ${vendor_boot_modules_dir}/*

write_boot

# Done
ui_print "- Custom modules flashed successfully!"
