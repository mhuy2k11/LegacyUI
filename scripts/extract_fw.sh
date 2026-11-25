#!/usr/bin/env bash
#
# Copyright (C) 2023 Salvo Giangreco
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#

# shellcheck disable=SC2162

set -e

# [
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="${SRC_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
OUT_DIR="${OUT_DIR:-$SRC_DIR/out}"
ODIN_DIR="${ODIN_DIR:-$OUT_DIR/odin}"
FW_DIR="${FW_DIR:-$OUT_DIR/fw}"
WORK_DIR="${WORK_DIR:-$OUT_DIR/work_dir}"
TOOLS_DIR="${TOOLS_DIR:-$OUT_DIR/tools/bin}"
export PATH="$TOOLS_DIR:$PATH"
[ -f "$OUT_DIR/config.sh" ] && { set -a; source "$OUT_DIR/config.sh"; set +a; }

GET_LATEST_FIRMWARE()
{
    curl -s --retry 5 --retry-delay 5 "https://fota-cloud-dn.ospserver.net/firmware/$REGION/$MODEL/version.xml" \
        | grep latest | sed 's/^[^>]*>//' | sed 's/<.*//'
}

GET_IMG_FS_TYPE()
{
    if [[ "$(xxd -p -l "2" --skip "1080" "$1" 2>/dev/null)" == "53ef" ]]; then
        echo "ext4"
    elif [[ "$(xxd -p -l "4" --skip "1024" "$1" 2>/dev/null)" == "1020f5f2" ]]; then
        echo "f2fs"
    elif [[ "$(xxd -p -l "4" --skip "1024" "$1" 2>/dev/null)" == "e2e1f5e0" ]]; then
        echo "erofs"
    else
        echo "unknown"
    fi
}

EXTRACT_KERNEL_BINARIES()
{
    local PDR
    PDR="$(pwd)"

    local FILES="boot.img.lz4 dtbo.img.lz4 init_boot.img.lz4 vendor_boot.img.lz4"

    echo "- Extracting kernel binaries..."
    cd "$FW_DIR/${MODEL}_${REGION}"
    for file in $FILES
    do
        [ -f "${file%.lz4}" ] && continue
        tar tf "$AP_TAR" "$file" &>/dev/null || continue
        echo "Extracting ${file%.lz4}"
        tar xf "$AP_TAR" "$file" && lz4 -d -q -f --rm "$file" "${file%.lz4}"
    done

    cd "$PDR"
}

EXTRACT_CSC_PARTITIONS()
{
    local PDR
    PDR="$(pwd)"

    local FILES="prism.img.lz4 optics.img.lz4"

    echo "- Extracting CSC partitions..."
    cd "$FW_DIR/${MODEL}_${REGION}"
    for file in $FILES
    do
        local PART="${file%.img.lz4}"
        if [ -d "$PART" ] && [ -f "file_context-$PART" ] && [ -f "fs_config-$PART" ]; then
            echo "$PART is already extracted. Skipping..."
            continue
        fi

        if [ ! -f "${file%.lz4}" ]; then
            tar tf "$CSC_TAR" "$file" &>/dev/null || continue
            echo "Extracting $PART image..."
            tar xf "$CSC_TAR" "$file" && lz4 -d -q -f --rm "$file" "${file%.lz4}.sparse"
            simg2img "${file%.lz4}.sparse" "${file%.lz4}" && rm -f "${file%.lz4}.sparse"
        fi

        [ -d "tmp_out" ] && mountpoint -q "tmp_out" && sudo umount "tmp_out"
        mkdir -p "tmp_out"

        PREFIX="sudo"
        [ -d "$PART" ] && rm -rf "$PART"
        mkdir -p "$PART"
        $PREFIX mount -o ro "${file%.lz4}" "tmp_out"
        $PREFIX cp -a --preserve=all tmp_out/* "$PART"
        for i in $($PREFIX find "$PART"); do
           $PREFIX chown -h "$(whoami)":"$(whoami)" "$i"
        done
        [[ -e "$PART/lost+found" ]] && rm -rf "$PART/lost+found"

        echo "Generating fs_config/file_context for ${file%.lz4}"
        [ -f "file_context-$PART" ] && rm -f "file_context-$PART"
        [ -f "fs_config-$PART" ] && rm -f "fs_config-$PART"
        while read -r i; do
            {
                echo -n "$i "
                $PREFIX getfattr -n security.selinux --only-values -h "$i" 2>/dev/null || true
                echo ""
            } >> "file_context-$PART"

            case "$i" in
                *"run-as" | *"simpleperf_app_runner")
                    CAPABILITIES="0xc0"
                    ;;
                *)
                    CAPABILITIES="0x0"
                    ;;
            esac
            $PREFIX stat -c "%n %u %g %a capabilities=$CAPABILITIES" "$i" >> "fs_config-$PART"
        done <<< "$($PREFIX find "tmp_out")"

        sed -i "s/tmp_out/\/$PART/g" "file_context-$PART"
        sed -i "s/tmp_out / /g" "fs_config-$PART" \
            && sed -i "s/tmp_out/$PART/g" "fs_config-$PART"

        sed -i "s/\x0//g" "file_context-$PART" \
            && sed -i 's/\./\\./g' "file_context-$PART" \
            && sed -i 's/\+/\\+/g' "file_context-$PART" \
            && sed -i 's/\[/\\[/g' "file_context-$PART"

        $PREFIX umount "tmp_out"
        rm -f "${file%.lz4}"
        rm -rf "tmp_out"
    done

    cd "$PDR"
}

EXTRACT_OS_PARTITIONS()
{
    local PDR
    PDR="$(pwd)"

    echo "- Extracting OS partitions..."
    cd "$FW_DIR/${MODEL}_${REGION}"

    local COMMON_FOLDERS="odm product system vendor system_ext"

    # Detect dynamic partition naming (_a.img vs .img)
    local PARTITION_MASK=".img"
    if [ -f "system_a.img" ] || [ -f "system_b.img" ]; then
        PARTITION_MASK="_a.img"
    elif [ -f "lpdump" ] && grep -q "system_a" "lpdump"; then
        PARTITION_MASK="_a.img"
    fi

    local SHOULD_EXTRACT=false
    for folder in $COMMON_FOLDERS; do
        if [ ! -d "$folder" ] || [ ! -f "file_context-$folder" ] || [ ! -f "fs_config-$folder" ]; then
            SHOULD_EXTRACT=true
            break
        fi
    done

    if ! $SHOULD_EXTRACT; then
        echo "- OS partitions already fully extracted."
        cd "$PDR"
        return 0
    fi

    local SHOULD_EXTRACT_SUPER=false
    for folder in $COMMON_FOLDERS; do
        if [ ! -d "$folder" ] || [ ! -f "file_context-$folder" ] || [ ! -f "fs_config-$folder" ]; then
            if [ ! -f "$folder.img" ] && [ ! -f "${folder}_a.img" ]; then
                SHOULD_EXTRACT_SUPER=true
                break
            fi
        fi
    done

    if $SHOULD_EXTRACT_SUPER; then
        echo "Extracting super.img..."
        if [ ! -f "super.img" ] || [ "$(stat -c %s "super.img" 2>/dev/null || echo 0)" -lt 2000000000 ]; then
            rm -f "super.img"
            if [ ! -f "super.img.sparse" ]; then
                [ -f "super.img.lz4" ] || tar xf "$AP_TAR" "super.img.lz4"
                lz4 -d -q -f --rm "super.img.lz4" "super.img.sparse"
            fi
            echo "Converting super.img.sparse to raw super.img..."
            simg2img "super.img.sparse" "super.img" && rm -f "super.img.sparse"
        fi
        echo "Unpacking super.img..."
        { lpunpack "super.img" > /dev/null; } 2>&1
        lpdump "super.img" > "lpdump" && rm -f "super.img"
        rm -f "super.img.lz4" "super.img.sparse" 2>/dev/null || true

        if [ -f "system_a.img" ]; then
            echo "Dynamic Partitions Detected!"
            PARTITION_MASK="_a.img"
        fi
    fi

    [ -d "tmp_out" ] && mountpoint -q "tmp_out" && sudo umount "tmp_out"
    mkdir -p "tmp_out"

    for folder in $COMMON_FOLDERS; do
        local img="${folder}${PARTITION_MASK}"
        if [ ! -f "$img" ]; then
            if [ -f "${folder}.img" ]; then
                img="${folder}.img"
            elif [ -f "${folder}_a.img" ]; then
                img="${folder}_a.img"
            else
                if [ -d "$folder" ] && [ -f "file_context-$folder" ] && [ -f "fs_config-$folder" ]; then
                    echo "$folder is already extracted. Skipping..."
                    continue
                fi
                echo "ERROR: Partition image $img missing and $folder not extracted!"
                exit 1
            fi
        fi

        if [ -d "$folder" ] && [ -f "file_context-$folder" ] && [ -f "fs_config-$folder" ]; then
            echo "$folder already extracted. Skipping..."
            rm -f "$img"
            continue
        fi

        local FS_TYPE
        FS_TYPE="$(GET_IMG_FS_TYPE "$img")"
        echo "Extracting $img ($FS_TYPE) into $folder..."
        [ -d "$folder" ] && rm -rf "$folder"
        mkdir -p "$folder"

        PREFIX="sudo"
        case "$FS_TYPE" in
            "erofs" | "f2fs" | "ext4")
                $PREFIX mount -o ro "$img" "tmp_out"
                $PREFIX cp -a --preserve=all tmp_out/* "$folder"
                for i in $($PREFIX find "$folder"); do
                    $PREFIX chown -h "$(whoami)":"$(whoami)" "$i"
                done
                [[ -e "$folder/lost+found" ]] && rm -rf "$folder/lost+found"
                ;;
            *)
                echo "ERROR: Unknown filesystem '$FS_TYPE' for $img"
                exit 1
                ;;
        esac

        echo "Generating fs_config/file_context for $folder"
        [ -f "file_context-$folder" ] && rm -f "file_context-$folder"
        [ -f "fs_config-$folder" ] && rm -f "fs_config-$folder"
        while read -r i; do
            {
                echo -n "$i "
                $PREFIX getfattr -n security.selinux --only-values -h "$i" 2>/dev/null || true
                echo ""
            } >> "file_context-$folder"

            case "$i" in
                *"run-as" | *"simpleperf_app_runner")
                    CAPABILITIES="0xc0"
                    ;;
                *)
                    CAPABILITIES="0x0"
                    ;;
            esac
            $PREFIX stat -c "%n %u %g %a capabilities=$CAPABILITIES" "$i" >> "fs_config-$folder"
        done <<< "$($PREFIX find "tmp_out")"

        if [ "$folder" = "system" ]; then
            sed -i "s/tmp_out /\/ /g" "file_context-$folder" \
                && sed -i "s/tmp_out\//\//g" "file_context-$folder"
            sed -i "s/tmp_out / /g" "fs_config-$folder" \
                && sed -i "s/tmp_out\///g" "fs_config-$folder"
        else
            sed -i "s/tmp_out/\/$folder/g" "file_context-$folder"
            sed -i "s/tmp_out / /g" "fs_config-$folder" \
                && sed -i "s/tmp_out/$folder/g" "fs_config-$folder"
        fi
        sed -i "s/\x0//g" "file_context-$folder" \
            && sed -i 's/\./\\./g' "file_context-$folder" \
            && sed -i 's/\+/\\+/g' "file_context-$folder" \
            && sed -i 's/\[/\\[/g' "file_context-$folder"

        $PREFIX umount "tmp_out"
        rm -f "$img"
    done

    [ -d "tmp_out" ] && rm -rf "tmp_out"
    rm -f *_b.img 2>/dev/null || true

    cd "$PDR"
}

EXTRACT_AVB_BINARIES()
{
    local PDR
    PDR="$(pwd)"

    echo "- Extracting AVB binaries..."
    cd "$FW_DIR/${MODEL}_${REGION}"
    if [ ! -f "vbmeta.img" ] && tar tf "$BL_TAR" "vbmeta.img.lz4" &>/dev/null; then
        echo "Extracting vbmeta.img"
        tar xf "$BL_TAR" "vbmeta.img.lz4" && lz4 -d -q -f --rm "vbmeta.img.lz4" "vbmeta.img"
    fi
    if [ ! -f "vbmeta_patched.img" ] && [ -f "vbmeta.img" ]; then
        echo "Generating vbmeta_patched.img"
        cp --preserve=all "vbmeta.img" "vbmeta_patched.img"
        printf "\x03" | dd of="vbmeta_patched.img" bs=1 seek=123 count=1 conv=notrunc &> /dev/null
    fi

    cd "$PDR"
}

EXTRACT_ALL()
{
    BL_TAR=$(find "$ODIN_DIR/${MODEL}_${REGION}" -maxdepth 1 -name "BL*" -print -quit)
    CSC_TAR=$(find "$ODIN_DIR/${MODEL}_${REGION}" -maxdepth 1 -name "CSC*" -print -quit)
    AP_TAR=$(find "$ODIN_DIR/${MODEL}_${REGION}" -maxdepth 1 -name "AP*" -print -quit)

    mkdir -p "$FW_DIR/${MODEL}_${REGION}"
    EXTRACT_KERNEL_BINARIES
    EXTRACT_CSC_PARTITIONS
    EXTRACT_OS_PARTITIONS
    EXTRACT_AVB_BINARIES

    cp --preserve=all "$ODIN_DIR/${MODEL}_${REGION}/.downloaded" "$FW_DIR/${MODEL}_${REGION}/.extracted"

    echo ""
}

FIRMWARES=( "$SOURCE_FIRMWARE" )
if [ -n "${TARGET_FIRMWARE:-}" ]; then
    IFS=':' read -ra TF <<< "$TARGET_FIRMWARE"
    for i in "${TF[@]}"; do [ -n "$i" ] && FIRMWARES+=( "$i" ); done
fi
if [ -n "${SOURCE_EXTRA_FIRMWARES:-}" ]; then
    IFS=':' read -ra SEF <<< "$SOURCE_EXTRA_FIRMWARES"
    for i in "${SEF[@]}"; do [ -n "$i" ] && FIRMWARES+=( "$i" ); done
fi
if [ -n "${TARGET_EXTRA_FIRMWARES:-}" ]; then
    IFS=':' read -ra TEF <<< "$TARGET_EXTRA_FIRMWARES"
    for i in "${TEF[@]}"; do [ -n "$i" ] && FIRMWARES+=( "$i" ); done
fi

FORCE=false

while [ "$#" != 0 ]; do
    case "$1" in
        "-f" | "--force")
            FORCE=true
            ;;
        *)
            echo "Usage: extract_fw [options]"
            echo " -f, --force : Force firmware extraction"
            exit 1
            ;;
    esac
    shift
done

mkdir -p "$FW_DIR"

for i in "${FIRMWARES[@]}"; do
    MODEL=$(echo -n "$i" | cut -d "/" -f 1)
    REGION=$(echo -n "$i" | cut -d "/" -f 2)
    DIR="$ODIN_DIR/${MODEL}_${REGION}"

    echo "=== Checking $MODEL ($REGION) ==="

    if [ ! -d "$DIR" ]; then
        echo "ERROR: Missing firmware directory: $DIR"
        exit 1
    fi

    AP=$(find "$DIR" -maxdepth 1 -type f -name 'AP*' -print -quit)
    BL=$(find "$DIR" -maxdepth 1 -type f -name 'BL*' -print -quit)
    CSC=$(find "$DIR" -maxdepth 1 -type f -name 'CSC*' -print -quit)
    CP=$(find "$DIR" -maxdepth 1 -type f -name 'CP*' -print -quit)

    if [[ -z "$AP" || -z "$BL" || -z "$CSC" || -z "$CP" ]]; then
        echo "ERROR: Missing AP/BL/CSC/CP archive in $DIR"
        exit 1
    fi

    printf '%s/%s/%s' \
        "$(basename "$AP" | cut -d '_' -f 2)" \
        "$(basename "$CSC" | cut -d '_' -f 3)" \
        "$(basename "$CP" | cut -d '_' -f 2)" \
        > "$DIR/.downloaded"

    OUT="$FW_DIR/${MODEL}_${REGION}"

    if [ -f "$OUT/.extracted" ]; then
        if $FORCE || ! cmp -s "$DIR/.downloaded" "$OUT/.extracted"; then
            echo "Removing old extraction: $OUT"
            rm -rf "$OUT"
        else
            echo "$MODEL is already extracted. Skipping..."
            continue
        fi
    fi

    echo "Extracting $MODEL firmware..."
    EXTRACT_ALL
done

exit 0
