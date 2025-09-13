#!/bin/bash

# Kernel-build Script by danielml3@github
# Adapted for all sm8550 xiaomi devices by ByteWave1014
# Modified to package AnyKernel3 flashable zip

# =========================
# Kernel / Toolchain setup
# =========================
KERNEL_TOOLS=../kernel-tools/linux-x86/bin/
CLANG_PATH=../toolchains/clang-17/bin/
export PATH="$KERNEL_TOOLS:$CLANG_PATH:$PATH"

if [[ -z "${1:-}" ]]; then
    echo "Usage: $0 <device>"
    echo "Devices: vermeer fuxi socrates ishtar"
    exit 1
fi

TARGET="$1"
BOARD_PLATFORM=kalama
export BOARD_PLATFORM
export TARGET_BOARD_PLATFORM=kalama
KERNEL_SRC=$(pwd)
O=out
OUT_DIR=$KERNEL_SRC/$O
INSTALL_MOD_PATH=modules_out

ANYKERNEL_DIR=$KERNEL_SRC/anykernel

case "$TARGET" in
    vermeer|fuxi|socrates|ishtar)
        TARGET_DEFCONFIG="gki_defconfig vendor/kalama_GKI.config vendor/${TARGET}_GKI.config"
    TARGET_KERNEL_EXT_MODULES="
      qcom/opensource/mmrm-driver
      qcom/opensource/mm-drivers/hw_fence
      qcom/opensource/mm-drivers/msm_ext_display
      qcom/opensource/mm-drivers/sync_fence
      qcom/opensource/audio-kernel
      qcom/opensource/securemsm-kernel
      qcom/opensource/dataipa/drivers/platform/msm
      qcom/opensource/datarmnet/core
      qcom/opensource/datarmnet-ext/aps
      qcom/opensource/datarmnet-ext/offload
      qcom/opensource/datarmnet-ext/shs
      qcom/opensource/datarmnet-ext/perf
      qcom/opensource/datarmnet-ext/perf_tether
      qcom/opensource/datarmnet-ext/sch
      qcom/opensource/datarmnet-ext/wlan
      qcom/opensource/camera-kernel
      qcom/opensource/display-drivers/msm
      qcom/opensource/video-driver
      qcom/opensource/graphics-kernel
      qcom/opensource/dsp-kernel
      qcom/opensource/eva-kernel
      qcom/opensource/wlan/platform
      qcom/opensource/wlan/qcacld-3.0
      qcom/opensource/bt-kernel
      nxp/opensource/driver"
    TARGET_KERNEL_EXT_MODULE_ROOT=$KERNEL_SRC/../sm8550-modules
    FIRST_STAGE_MODULES_LIST="modules.list.msm.kalama"
    RECOVERY_EXT_MODULES="msm_drm.ko"
    ;;
  *)
      echo "Unknown target: $TARGET"
      echo "Devices: vermeer fuxi socrates ishtar"
      exit 1
      ;;
esac

trap restore_qcacld_strict_prototypes EXIT

# =========================
# Helper functions
# =========================
function section() {
    local input="$1"
    local length=${#input}
    printf '%*s\n' "$length" '' | tr ' ' '='
    echo "$input"
    printf '%*s\n' "$length" '' | tr ' ' '='
}

function kernel_make() {
    make -j$(nproc) \
        O=$O \
        ARCH=arm64 \
        LLVM=1 \
        LLVM_IAS=1 \
        LD=ld.lld \
        BOARD_PLATFORM=$BOARD_PLATFORM \
        TARGET_BOARD_PLATFORM=$BOARD_PLATFORM \
        CROSS_COMPILE=aarch64-linux-gnu- \
        CROSS_COMPILE_ARM32=arm-linux-gnueabi- \
        INSTALL_MOD_PATH=$INSTALL_MOD_PATH \
        $@ < /dev/null
}

function ext_module_make() {
    module_path=$TARGET_KERNEL_EXT_MODULE_ROOT/$1
    kernel_make \
        OUT_DIR=$OUT_DIR \
        KERNEL_SRC=$KERNEL_SRC \
        KERNEL_UAPI_HEADERS_DIR=$OUT_DIR \
        BOARD_PLATFORM=$BOARD_PLATFORM \
        TARGET_BOARD_PLATFORM=$BOARD_PLATFORM \
        M=$(realpath --relative-to=$KERNEL_SRC $module_path) \
        -C $module_path \
        ${@:2}
}

function get_modlib_file_path() {
    local file="$1"
    
    # Search paths in order of preference
    local search_paths=(
        "$OUT_DIR/$INSTALL_MOD_PATH"
        "$TARGET_KERNEL_EXT_MODULE_ROOT"
        "$OUT_DIR"
        "$KERNEL_SRC/sm8550-modules"
    )
    
    # If it's a .ko file, search recursively
    if [[ "$file" == *.ko ]]; then
        for path in "${search_paths[@]}"; do
            if [[ -d "$path" ]]; then
                local found_file=$(find "$path" -name "$file" -type f 2>/dev/null | head -1)
                if [[ -n "$found_file" && -f "$found_file" ]]; then
                    echo "$found_file"
                    return 0
                fi
            fi
        done
    else
        # For non-.ko files, check direct paths and subdirectories
        for path in "${search_paths[@]}"; do
            # Check direct path first
            if [[ -f "$path/$file" ]]; then
                echo "$path/$file"
                return 0
            fi
            # Check with wildcard expansion for subdirectories
            if [[ -d "$path" ]]; then
                local found_file=$(find "$path" -name "$file" -type f 2>/dev/null | head -1)
                if [[ -n "$found_file" && -f "$found_file" ]]; then
                    echo "$found_file"
                    return 0
                fi
            fi
        done
    fi
    
    # File not found - return error but don't exit
    echo "ERROR: File not found: $file" >&2
    return 1
}

# Helper function to copy module with error handling
function copy_module_safe() {
    local modname="$1"
    local dest_dir="$2"
    local module_path
    
    module_path=$(get_modlib_file_path "$modname")
    if [[ $? -eq 0 && -f "$module_path" ]]; then
        cp "$module_path" "$dest_dir/"
        echo "  ? Copied: $modname"
        return 0
    else
        echo "  ? Missing: $modname"
        return 1
    fi
}

# Helper function to copy auxiliary module files
function copy_aux_file_safe() {
    local filename="$1"
    local dest_dir="$2"
    local module_path
    
    module_path=$(get_modlib_file_path "$filename")
    if [[ $? -eq 0 && -f "$module_path" ]]; then
        cp "$module_path" "$dest_dir/"
        echo "  ? Copied: $filename"
        return 0
    else
        echo "  ? Missing: $filename"
        return 1
    fi
}

function generate_module_deps() {
    modules_dep_file=$(get_modlib_file_path modules.dep)
    if [[ $? -ne 0 ]]; then
        echo "Error: modules.dep not found"
        exit 1
    fi
    
    if [[ "$(grep -e "^$1:" -e "/$1:" $modules_dep_file)" == "" ]]; then
        echo "Needed $1 was not found in modules.dep"
        exit 1
    fi

    module_data=$(grep -e "^$1:" -e "/$1:" "$modules_dep_file")
    module_name=$(basename $1)

    if [[ -f $2 ]] && [[ "$(grep "^$module_name" $2)" != "" ]]; then
        return
    fi

    echo $module_name >> $2

    module_deps=$(echo $module_data | cut -d ":" -f 2)
    for dep in $module_deps; do
        generate_module_deps $dep $2
    done
}

function generate_modules_load() {
    modules_order_file=$(get_modlib_file_path modules.order)
    modules_dep_file=$(get_modlib_file_path modules.dep)
    
    if [[ ! -f "$modules_order_file" || ! -f "$modules_dep_file" ]]; then
        echo "Warning: modules.order or modules.dep not found, skipping modules.load generation"
        return 1
    fi
    
    rm -f $OUT_DIR/modules.load.*

    # First stage
    echo "Generating first stage modules list"
    if [[ -f "$FIRST_STAGE_MODULES_LIST" ]]; then
        for mod in $(cat $FIRST_STAGE_MODULES_LIST); do
            if [[ "$(grep -e "^$mod:" -e "/$mod:" $modules_dep_file)" != "" ]]; then
                generate_module_deps $mod $OUT_DIR/modules.load.first_stage
            fi
        done
    else
        echo "Warning: $FIRST_STAGE_MODULES_LIST not found"
        touch $OUT_DIR/modules.load.first_stage
    fi

    # Recovery
    echo "Generating recovery modules list"
    cat $modules_order_file | rev | cut -d / -f 1 | rev > $OUT_DIR/modules.load.recovery
    for ext_mod in $RECOVERY_EXT_MODULES; do
        if [[ "$(grep -e "^$ext_mod:" -e "/$ext_mod:" $modules_dep_file)" != "" ]]; then
            generate_module_deps $ext_mod $OUT_DIR/modules.load.recovery
        fi
    done

    # Vendor DLKM
    echo "Generating vendor DLKM modules list"
    ext_modules=$(cat $modules_dep_file | cut -d ":" -f 1)
    for ext_mod in $ext_modules; do
        generate_module_deps $ext_mod $OUT_DIR/modules.load.vendor_dlkm
    done

    # Remove first stage from vendor_dlkm
    if [[ -f "$OUT_DIR/modules.load.first_stage" ]]; then
        for mod in $(cat $OUT_DIR/modules.load.first_stage); do
            sed -i /$mod/d $OUT_DIR/modules.load.vendor_dlkm
        done
    fi
}

prepare_qcacld_defconfig() {
    local qcacld_dir="$TARGET_KERNEL_EXT_MODULE_ROOT/qcom/opensource/wlan/qcacld-3.0"
    local configs_dir="$qcacld_dir/configs"

    echo "Checking qcacld defconfig..."

    if [[ ! -f "$configs_dir/wlan_defconfig" ]]; then
        echo "Error: missing $configs_dir/wlan_defconfig"
        exit 1
    fi

    if [[ ! -f "$configs_dir/qcacld-3.0_defconfig" ]]; then
        echo "Creating $configs_dir/qcacld-3.0_defconfig"
        cp -f "$configs_dir/wlan_defconfig" "$configs_dir/qcacld-3.0_defconfig"
    fi

    if [[ ! -f "$configs_dir/qcacld-3.0_defconfig" ]]; then
        echo "Error: failed to create qcacld-3.0_defconfig"
        exit 1
    fi
}

patch_qcacld_strict_prototypes() {
    local file="$TARGET_KERNEL_EXT_MODULE_ROOT/qcom/opensource/wlan/qcacld-3.0/cmn/hif/src/ce/ce_service_legacy.c"
    local backup="${file}.bak_build_kernel"

    [[ -f "$file" ]] || {
        echo "error: qcacld source not found: $file"
        exit 1
    }

    if [[ ! -f "$backup" ]]; then
        cp -f "$file" "$backup"
    fi

    sed -i 's/struct ce_ops \*ce_services_legacy()/struct ce_ops *ce_services_legacy(void)/' "$file"
}

restore_qcacld_strict_prototypes() {
    local file="$TARGET_KERNEL_EXT_MODULE_ROOT/qcom/opensource/wlan/qcacld-3.0/cmn/hif/src/ce/ce_service_legacy.c"
    local backup="${file}.bak_build_kernel"

    if [[ -f "$backup" ]]; then
        cp -f "$backup" "$file"
        rm -f "$backup"
    fi
}

# =========================
# Kernel build steps
# =========================
section "Kernel config"
make O=$O ARCH=arm64 $TARGET_DEFCONFIG

section "Kernel build"
kernel_make

section "Kernel modules install"
kernel_make modules_install

section "External kernel modules build + install"
prepare_qcacld_defconfig
patch_qcacld_strict_prototypes
echo "Module root is $TARGET_KERNEL_EXT_MODULE_ROOT"
for module in $TARGET_KERNEL_EXT_MODULES; do
    section "Building $module"
    ext_module_make $module
    section "Installing $module"
    ext_module_make $module modules_install
done

section "Generating modules.load files"
generate_modules_load

# =========================
# Prepare AnyKernel folders
# =========================
section "Preparing AnyKernel module folders"

# Track missing modules
missing_modules=()

# Vendor boot modules folder
echo "Preparing vendor boot modules..."
rm -rf $ANYKERNEL_DIR/_modules/vendor_boot
mkdir -p $ANYKERNEL_DIR/_modules/vendor_boot

# Copy vendor boot .ko modules
if [[ -f "$OUT_DIR/modules.load.first_stage" ]]; then
    while IFS= read -r mod; do
        [[ -z "$mod" || "$mod" =~ ^[[:space:]]*# ]] && continue  # Skip empty lines and comments
        modname=$(basename "$mod")
        if ! copy_module_safe "$modname" "$ANYKERNEL_DIR/_modules/vendor_boot"; then
            missing_modules+=("$modname")
        fi
    done < "$OUT_DIR/modules.load.first_stage"
fi

# Copy msm_drm.ko module to vendor_boot (needed for recovery)
echo "Adding msm_drm.ko to vendor_boot..."
if ! copy_module_safe "msm_drm.ko" "$ANYKERNEL_DIR/_modules/vendor_boot"; then
    missing_modules+=("msm_drm.ko")
fi

# Copy vendor boot auxiliary files
echo "Copying vendor boot auxiliary files..."

# modules.alias
copy_aux_file_safe "modules.alias" "$ANYKERNEL_DIR/_modules/vendor_boot"

# modules.blocklist (from vendor blocklist file)
if [[ -f "$KERNEL_SRC/modules.vendor_blocklist.msm.kalama" ]]; then
    cp "$KERNEL_SRC/modules.vendor_blocklist.msm.kalama" "$ANYKERNEL_DIR/_modules/vendor_boot/modules.blocklist"
    echo "  ? Copied: modules.blocklist (from vendor blocklist)"
else
    echo "  ? Missing: modules.vendor_blocklist.msm.kalama"
fi

# modules.dep
copy_aux_file_safe "modules.dep" "$ANYKERNEL_DIR/_modules/vendor_boot"

# modules.load (from modules.load.first_stage)
if [[ -f "$OUT_DIR/modules.load.first_stage" ]]; then
    cp "$OUT_DIR/modules.load.first_stage" "$ANYKERNEL_DIR/_modules/vendor_boot/modules.load"
    echo "  ? Copied: modules.load (from first_stage)"
else
    echo "  ? Missing: modules.load.first_stage"
    touch "$ANYKERNEL_DIR/_modules/vendor_boot/modules.load"
fi

# modules.load.recovery
if [[ -f "$OUT_DIR/modules.load.recovery" ]]; then
    cp "$OUT_DIR/modules.load.recovery" "$ANYKERNEL_DIR/_modules/vendor_boot/modules.load.recovery"
    echo "  ? Copied: modules.load.recovery"
else
    echo "  ? Missing: modules.load.recovery"
fi

# modules.softdep
copy_aux_file_safe "modules.softdep" "$ANYKERNEL_DIR/_modules/vendor_boot"

# Vendor DLKM modules folder
echo "Preparing vendor DLKM modules..."
rm -rf $ANYKERNEL_DIR/_modules/vendor_dlkm
mkdir -p $ANYKERNEL_DIR/_modules/vendor_dlkm

# Copy vendor DLKM .ko modules
if [[ -f "$OUT_DIR/modules.load.vendor_dlkm" ]]; then
    while IFS= read -r mod; do
        [[ -z "$mod" || "$mod" =~ ^[[:space:]]*# ]] && continue  # Skip empty lines and comments
        modname=$(basename "$mod")
        if ! copy_module_safe "$modname" "$ANYKERNEL_DIR/_modules/vendor_dlkm"; then
            missing_modules+=("$modname")
        fi
    done < "$OUT_DIR/modules.load.vendor_dlkm"
fi

# Copy vendor DLKM auxiliary files
echo "Copying vendor DLKM auxiliary files..."

# modules.alias
copy_aux_file_safe "modules.alias" "$ANYKERNEL_DIR/_modules/vendor_dlkm"

# modules.blocklist (from vendor blocklist file)
if [[ -f "$KERNEL_SRC/modules.vendor_blocklist.msm.kalama" ]]; then
    cp "$KERNEL_SRC/modules.vendor_blocklist.msm.kalama" "$ANYKERNEL_DIR/_modules/vendor_dlkm/modules.blocklist"
    echo "  ? Copied: modules.blocklist (from vendor blocklist)"
else
    echo "  ? Missing: modules.vendor_blocklist.msm.kalama"
fi

# modules.dep
copy_aux_file_safe "modules.dep" "$ANYKERNEL_DIR/_modules/vendor_dlkm"

# modules.load (from modules.load.vendor_dlkm)
if [[ -f "$OUT_DIR/modules.load.vendor_dlkm" ]]; then
    cp "$OUT_DIR/modules.load.vendor_dlkm" "$ANYKERNEL_DIR/_modules/vendor_dlkm/modules.load"
    echo "  ? Copied: modules.load (from vendor_dlkm)"
else
    echo "  ? Missing: modules.load.vendor_dlkm"
    touch "$ANYKERNEL_DIR/_modules/vendor_dlkm/modules.load"
fi

# modules.softdep
copy_aux_file_safe "modules.softdep" "$ANYKERNEL_DIR/_modules/vendor_dlkm"

# Report missing modules
if [[ ${#missing_modules[@]} -gt 0 ]]; then
    echo ""
    echo "? Warning: ${#missing_modules[@]} module(s) not found:"
    printf '  - %s\n' "${missing_modules[@]}"
    echo ""
    echo "This might be due to:"
    echo "  1. Modules not enabled in kernel config"
    echo "  2. Build errors during module compilation"
    echo "  3. Modules in unexpected locations"
    echo ""
    echo "Search paths checked:"
    echo "  - $OUT_DIR/$INSTALL_MOD_PATH"
    echo "  - $TARGET_KERNEL_EXT_MODULE_ROOT"
    echo "  - $OUT_DIR"
    echo "  - $KERNEL_SRC/sm8550-modules"
    echo ""
    echo "Continuing with available modules..."
fi

echo "AnyKernel module preparation completed."

# =========================
# Copy kernel image
# =========================
section "Copying kernel image"

KERNEL_IMAGE="$OUT_DIR/arch/arm64/boot/Image.gz"
if [[ -f "$KERNEL_IMAGE" ]]; then
    cp "$KERNEL_IMAGE" "$ANYKERNEL_DIR/"
    echo "? Copied: Image.gz"
else
    echo "? Error: Image.gz not found at $KERNEL_IMAGE"
    exit 1
fi

# =========================
# Package AnyKernel zip
# =========================
section "Packaging flashable zip"

cd $ANYKERNEL_DIR/..
# Remove old zips
rm -f "Lineage-kernel-${TARGET}-"*.zip

ZIPNAME="Lineage-kernel-${TARGET}-$(date +%Y%m%d-%H%M).zip"
cd anykernel
zip -r9 ../$ZIPNAME * -x .git* README.md *placeholder
cd ..

echo "Flashable zip created: $ZIPNAME"

