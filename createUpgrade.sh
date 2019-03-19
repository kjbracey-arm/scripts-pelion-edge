#!/bin/bash

# TODO: add settings section to group all the hardcoded paths and values

# Mount a partition inside a .wic file (or any image file flashable with dd)
# Params:
#    1 - .wic file name (with path if needed)
#    2 - partition number [1-based] (leave blank to list partitions)
#    3 - mount point (full path to where the partition will be mounted; will be created if it doesn't exist)
#    4 - [optional] partition type (auto detected if not specified)
# To unmount: sudo umount /path/to/mount/point
mount_wic_partition() {
    local wic_file="$1"
    local partition_number="$2"
    local mount_point="$3"
    local partition_type="$4"
    local partition_info start_sector=0 sector_count=0

    [ -z "${wic_file}" ] && {
        echo >&2 "Usage: mount_wic_partition <wic_file> [<partition_number> <mount_point> [partition_type]]"
        return 2
    }

    [ -f "${wic_file}" ] || {
        echo >&2 "Can't access image file ${wic_file}"
        return 1
    }

    [ -z "${partition_number}" ] && {
        fdisk -lu "${wic_file}"
        return 0
    }

    [ -z "${mount_point}" ] && {
        echo >&2 "You must specify a mount point"
        return 3
    }

    partition_info=$(sfdisk -d "${wic_file}" | grep ': start=' | grep "${partition_number} : start" | head -1)
    [ -z "${partition_info}" ] && {
        echo >&2 "Partition ${partition_number} not found"
        return 4
    }

    start_sector=$(echo "${partition_info}" | cut -d , -f 1 | cut -d = -f 2)
    sector_count=$(echo "${partition_info}" | cut -d , -f 2 | cut -d = -f 2)
    [ -z "${partition_type}" ] && {
        partition_type=$(echo "${partition_info}" | cut -d , -f 3 | cut -d = -f 2)
        case "$partition_type" in
            c) partition_type=vfat;;
            83) partition_type=ext4;;
            *) echo "Unsupported partition type: ${partition_type}"
               echo "${partition_info}"
               return 5
        esac
    }

    mkdir -p "${mount_point}"
    sudo mount -o loop,ro,offset=$((512*${start_sector})),sizelimit=$((512*${sector_count})) -t ${partition_type} "${wic_file}" "${mount_point}"
}

# Convenience/symmetry function
# Params:
#    1 - mount point (or /dev name)
umount_wic_partition() {
    sudo umount "$1"
}

# Look up partition name for a given number, according to our standard partitioning scheme
# Params:
#    1 - partition number
partition_name() {
    case "$1" in
        1) echo "boot";;
        2) echo "factory";;
        3) echo "upgrade";;
        4) echo "extended";;
        5) echo "user";;
        6) echo "userdata";;
        *) echo "$1"; echo >&2 "Unsupported partition number: $1";;
    esac
}

# Look up tarball name for a given partition number
# Params:
#    1 - partition number
tarball_name() {
    case "$1" in
        1) echo "boot";;
        2) echo "upgrade";;
        5) echo "user";;
        6) echo "userdata";;
        *) echo "$1"; echo >&2 "Bad tarball partition: $1";;
    esac
}

# Generate diff and create tarball (and its md5) between one partition of two given images
# Params:
#    1 - old image file name
#    2 - new image file name
#    3 - partition number
#    4 - [optional] temporary directory for packing/unpacking files [default: TMPDIR, fallback current directory]
# Assumptions: workdir/pack exists and is used for the output tarball+md5
diff_partition() {
    local wic_old="$1"
    local wic_new="$2"
    local partition="$3"
    local workdir="${4:-${TMPDIR:-$(pwd)}}"
    local tarname="$(tarball_name $partition)"

    mount_wic_partition "$wic_old" "$partition" "$workdir/old" || return 1
    mount_wic_partition "$wic_new" "$partition" "$workdir/new" || {
        umount_wic_partition "$workdir/old"
        return 2
    }

    # TODO: this does not handle removed files (i.e. old files that aren't supposed to be there anymore will not be marked in any way)
    sudo rsync -rclkWpg "--compare-dest=$workdir/old/" "$workdir/new/" "$workdir/diff"

    # TODO: the versions mechanism is wedged in the diff process. Clean up by separating into its own function (though that will require a remount).
    [ $partition -eq 2 -a -f $workdir/new/wigwag/etc/versions.json ] && \
        cp "$workdir/new/wigwag/etc/versions.json" "$workdir/field/upgradeversions.json"

    umount_wic_partition "$workdir/old"
    umount_wic_partition "$workdir/new"

    # Remove files in blacklist if there is one
    [ -f upgradeBlacklist.txt ] && grep -v '^#\|^$' upgradeBlacklist.txt | while read f; do
        # TODO: add safety check to prevent the blacklist from accidentally escaping workdir
        rm -f "$workdir/diff/$f" 2>/dev/null
    done

    # TODO: Why are we using both .gz and .xz? Settle for one of them (hint: .xz is suboptimal for tight embedded systems, because it requires large amounts of RAM)
    tar -cJf "$workdir/pack/$tarname.tar.xz" -C "$workdir/diff" .
    md5sum "$workdir/pack/$tarname.tar.xz" > "$workdir/pack/$tarname.tar.xz.md5"

    rm -rf "$workdir/old" "$workdir/new" "$workdir/diff"
}

# Package the difference into the correct tarball schema
# Params:
#    1 - [optional] temporary directory for packing/unpacking files [default: TMPDIR, fallback current directory]
#    2 - [optional] tag
# Assumptions: workdir/pack exists and is the location of individual partition diffs (tarball+md5 each)
packageDiff() {
    local workdir="${1:-${TMPDIR:-$(pwd)}}"
    local tag="$2"

    tar -czf "$workdir/field/upgrade.tar.gz" -C "$workdir/pack" .
    outtar="field-upgradeupdate.tar.gz"
    [ -n "${tag}" ] && outtar="${tag}-${outtar}"
    md5sum "$workdir/field/upgrade.tar.gz" > "$workdir/field/upgrade.tar.gz.md5"
    tar -czf "$outtar" -C "$workdir/field" .
    echo "Field upgrade output to $outtar"
}

# Setup temporary working space
#
setupTemp() {
    # TODO: make TMPDIR a parameter, not a global variable
    TMPDIR=$(mktemp -d)
    mkdir -p $TMPDIR/pack
    mkdir -p $TMPDIR/field
    touch $TMPDIR/field/upgradeversions.json
    cp upgrade-scripts/upgrade.sh $TMPDIR/field
    cp upgrade-scripts/install.sh $TMPDIR/field
    cp upgrade-scripts/post-install.sh $TMPDIR/field
}

# Unmount partitions and remove temp files
# Params:
#    1 - [optional] temporary directory for packing/unpacking files [default: TMPDIR; for safety reasons, there is no fallback]
cleanup() {
    local workdir="${1:-${TMPDIR}}"
    # TODO: to avoid clobbering existing files if workdir was not a fresh directory: instead of rm -rf workdir, remove only pack/ and field/, then use rmdir
    [ -n "$workdir" ] && rm -rf "$workdir"
}
        
# Main function 
# Takes two input wic files and produces a tarball of their difference that can
# be used in the field upgrade process
# Params:
#     1 - oldwic: .wic file of the base or factory build to be upgraded
#     2 - newwic: .wic file of the new or upgrade build
#     3 - tag:    optional text tag to be prepended to the output tarball
# Output:
#     <tag>-field-upgradeupdate.tar.gz
main() {
    local oldwic="$1"
    local newwic="$2"
    local tag="$3"

    # TODO: Right now, commands run as sudo (e.g. rsync) create files with root as owner, thus requiring pretty much the entire remaining script to be run as root as well. Fix it.
    # TODO: Add the ability to handle .wic.gz files?

    # Ensure we are running as root
    [ $(id -u) -ne 0 ] && { 
        echo >&2 "Please run as root"
        return 2
    }

    [ -f "${oldwic}" ] && [ -f "${newwic}" ] || {
        echo >&2 "Usage: sudo createUpgrade.sh <old_wic_file> <new_wic_file> [upgrade_tag]"
        return 2
    }

    [ -f upgrade-scripts/upgrade.sh ] || {
        echo >&2 "Please run within a checkout of scripts-gateway-ww repo."
        echo >&2 "./upgrade-scripts/upgrade.sh needs to exist in the current directory"
        return 2
    }

    # Create tmp working space
    setupTemp

    # Diff each partition - not all at the same time, to minimize usage of the loopback devices
    for p in 1 2 5 6; do
        diff_partition "$oldwic" "$newwic" $p
    done

    # Package diffs
    packageDiff "$TMPDIR" "$tag"

    # Cleanup the temp working space
    cleanup
}

main "$@"
