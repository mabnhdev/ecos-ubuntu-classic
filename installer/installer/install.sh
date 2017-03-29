#!/bin/sh

#  Copyright (C) 2014-2015 Curt Brune <curt@cumulusnetworks.com>
#  Copyright (C) 2014,2015,2016 david_yang <david_yang@accton.com>
#
#  SPDX-License-Identifier:     GPL-2.0

set -e
set -x

cd $(dirname $0)
. ./machine.conf

echo "Demo Installer: platform: $platform"

# Install demo on same block device as ONIE
blk_dev=$(blkid | grep ONIE-BOOT | awk '{print $1}' |  sed -e 's/[1-9][0-9]*:.*$//' | sed -e 's/\([0-9]\)\(p\)/\1/' | head -n 1)

[ -b "$blk_dev" ] || {
    echo "Error: Unable to determine block device of ONIE install"
    exit 1
}

# The build system prepares this script by replacing %%DEMO-TYPE%%
# with "OS" or "DIAG".
demo_type="OS"

demo_volume_label="ECOS"

# auto-detect whether BIOS or UEFI
if [ -d "/sys/firmware/efi/efivars" ] ; then
    firmware="uefi"
else
    firmware="bios"
fi

# determine ONIE partition type
onie_partition_type=$(onie-sysinfo -t)
# demo partition size in MB
demo_part_size=8192
if [ "$firmware" = "uefi" ] ; then
    create_demo_partition="create_demo_uefi_partition"
elif [ "$onie_partition_type" = "gpt" ] ; then
    create_demo_partition="create_demo_gpt_partition"
elif [ "$onie_partition_type" = "msdos" ] ; then
    create_demo_partition="create_demo_msdos_partition"
else
    echo "ERROR: Unsupported partition type: $onie_partition_type"
    exit 1
fi

# Creates a new partition for the DEMO OS.
# 
# arg $1 -- base block device
#
# Returns the created partition number in $demo_part
demo_part=
create_demo_gpt_partition()
{
    blk_dev="$1"

    # Delete all non-ONIE partitions
    part=1
    last_part=$(sgdisk -p $blk_dev | tail -n 1 | awk '{print $1}')
    while [ "$part" -le "$last_part" ] ; do
        info=$(sgdisk -i $part $blk_dev)
        case "$info" in
            *"does not exist"*|*"GRUB-BOOT"*|*"ONIE-BOOT"*)
                ;;
            *)
                echo "Deleting partition $part on $blk_dev"
                sgdisk -d $part $blk_dev || {
                    echo "Error: Unable to delete partition $part on $blk_dev"
                    exit 1
                }
                partprobe
                ;;
        esac
        part=`expr $part + 1`
    done

    # Find next available partition
    last_part=$(sgdisk -p $blk_dev | tail -n 1 | awk '{print $1}')
    demo_part=$(( $last_part + 1 ))

    # Create new partition
    echo "Creating new demo partition ${blk_dev}$demo_part ..."

    if [ "$demo_type" = "DIAG" ] ; then
        # set the GPT 'system partition' attribute bit for the DIAG
        # partition.
        attr_bitmask="0x1"
    else
        attr_bitmask="0x0"
    fi
    sgdisk --new=${demo_part}::+${demo_part_size}MB \
        --attributes=${demo_part}:=:$attr_bitmask \
        --change-name=${demo_part}:$demo_volume_label $blk_dev || {
        echo "Error: Unable to create partition $demo_part on $blk_dev"
        exit 1
    }
    partprobe
}

create_demo_msdos_partition()
{
    blk_dev="$1"

    # See if demo partition already exists -- look for the filesystem
    # label.
    part_info="$(blkid | grep $demo_volume_label | awk -F: '{print $1}')"
    if [ -n "$part_info" ] ; then
        # delete existing partition
        demo_part="$(echo -n $part_info | sed -e s#${blk_dev}##)"
        parted -s $blk_dev rm $demo_part || {
            echo "Error: Unable to delete partition $demo_part on $blk_dev"
            exit 1
        }
        partprobe
    fi

    # Find next available partition
    last_part_info="$(parted -s -m $blk_dev unit s print | tail -n 1)"
    last_part_num="$(echo -n $last_part_info | awk -F: '{print $1}')"
    last_part_end="$(echo -n $last_part_info | awk -F: '{print $3}')"
    # Remove trailing 's'
    last_part_end=${last_part_end%s}
    demo_part=$(( $last_part_num + 1 ))
    demo_part_start=$(( $last_part_end + 1 ))
    # sectors_per_mb = (1024 * 1024) / 512 = 2048
    sectors_per_mb=2048
    demo_part_end=$(( $demo_part_start + ( $demo_part_size * $sectors_per_mb ) - 1 ))

    # Create new partition
    echo "Creating new demo partition ${blk_dev}$demo_part ..."
    parted -s --align optimal $blk_dev unit s \
      mkpart primary $demo_part_start $demo_part_end set $demo_part boot on || {
        echo "ERROR: Problems creating demo msdos partition $demo_part on: $blk_dev"
        exit 1
    }
    partprobe

}

# For UEFI systems, create a new partition for the DEMO OS.
#
# arg $1 -- base block device
#
# Returns the created partition number in $demo_part
create_demo_uefi_partition()
{
    create_demo_gpt_partition "$1"

    # erase any related EFI BootOrder variables from NVRAM.
    for b in $(efibootmgr | grep "$demo_volume_label" | awk '{ print $1 }') ; do
        local num=${b#Boot}
        # Remove trailing '*'
        num=${num%\*}
        efibootmgr -b $num -B > /dev/null 2>&1
    done
}

# Install legacy BIOS GRUB for DEMO OS
demo_install_grub()
{
    local demo_mnt="$1"
    local blk_dev="$2"

    # get running machine from conf file
    [ -r /etc/machine.conf ] && . /etc/machine.conf

    if [ "$onie_firmware" = "coreboot" ] ; then
        local grub_target="i386-coreboot"
        local core_img="$demo_mnt/grub/$grub_target/core.elf"
    else
        local grub_target="i386-pc"
        local core_img="$demo_mnt/grub/$grub_target/core.img"
    fi

    # keep grub loading ONIE page after installing diag.
    # So that it is not necessary to set "ONIE" as default boot
    # mode in diag's grub.cfg.
    if [ "$demo_type" = "DIAG" ] ; then
        # Install GRUB in the partition also.  This allows for
        # chainloading the DIAG image from another OS.
        #
        # We are installing GRUB in a partition, as opposed to the
        # MBR.  With this method block lists are used to refer to the
        # the core.img file.  The sector locations of core.img may
        # change whenever the file system in the partition is being
        # altered (files copied, deleted etc.). For more info, see
        # https://bugzilla.redhat.com/show_bug.cgi?id=728742 and
        # https://bugzilla.redhat.com/show_bug.cgi?id=730915.
        #
        # The workaround for this is to set the immutable flag on
        # /boot/grub/i386-pc/core.img using the chattr command so that
        # the sector locations of the core.img file in the disk is not
        # altered. The immutable flag on /boot/grub/i386-pc/core.img
        # needs to be set only if GRUB is installed to a partition
        # boot sector or a partitionless disk, not in case of
        # installation to MBR.

        # remove immutable flag if file exists during the update.
        [ -f "$core_img" ] && chattr -i $core_img

        grub_install_log=$(mktemp)
        grub-install --target="$grub_target" \
            --force --boot-directory="$demo_mnt" \
            --recheck "$demo_dev" > /$grub_install_log 2>&1 || {
            echo "ERROR: grub-install failed on: $demo_dev"
            cat $grub_install_log && rm -f $grub_install_log
            exit 1
        }
        rm -f $grub_install_log

        # restore immutable flag on the core.img file as discussed
        # above.
        [ -f "$core_img" ] && chattr +i $core_img

    else
        # Pretend we are a major distro and install GRUB into the MBR of
        # $blk_dev.
        grub-install --target="$grub_target" \
            --boot-directory="$demo_mnt" --recheck "$blk_dev" || {
            echo "ERROR: grub-install failed on: $blk_dev"
            exit 1
        }

    fi

}

# Install UEFI BIOS GRUB for DEMO OS
demo_install_uefi_grub()
{
    local demo_mnt="$1"
    local blk_dev="$2"

    # Look for the EFI system partition UUID on the same block device as
    # the ONIE-BOOT partition.
    local uefi_part=0
    for p in $(seq 8) ; do
        if sgdisk -i $p $blk_dev | grep -q C12A7328-F81F-11D2-BA4B-00A0C93EC93B ; then
            uefi_part=$p
            break
        fi
    done

    [ $uefi_part -eq 0 ] && {
        echo "ERROR: Unable to determine UEFI system partition"
        exit 1
    }

    grub_install_log=$(mktemp)
    grub-install \
        --no-nvram \
        --bootloader-id="$demo_volume_label" \
        --efi-directory="/boot/efi" \
        --boot-directory="$demo_mnt" \
        --recheck \
        "$blk_dev" > /$grub_install_log 2>&1 || {
        echo "ERROR: grub-install failed on: $blk_dev"
        cat $grub_install_log && rm -f $grub_install_log
        exit 1
    }
    rm -f $grub_install_log

    # Configure EFI NVRAM Boot variables.  --create also sets the
    # new boot number as active.
    efibootmgr --quiet --create \
        --label "$demo_volume_label" \
        --disk $blk_dev --part $uefi_part \
        --loader "/EFI/$demo_volume_label/grubx64.efi" || {
        echo "ERROR: efibootmgr failed to create new boot variable on: $blk_dev"
        exit 1
    }

    # keep grub loading ONIE page after installing diag.
    # So that it is not necessary to set "ONIE" as default boot
    # mode in diag's grub.cfg.
    if [ "$demo_type" = "DIAG" ] ; then
        boot_num=$(efibootmgr -v | grep "ONIE: " | grep ')/File(' | \
            tail -n 1 | awk '{ print $1 }' | sed -e 's/Boot//' -e 's/\*//')
        boot_order=$(efibootmgr | grep BootOrder: | awk '{ print $2 }' | \
            sed -e s/,$boot_num// -e s/$boot_num,// -e s/$boot_num//)
        if [ -n "$boot_order" ] ; then
            boot_order="${boot_num},$boot_order"
        else
            boot_order="$boot_num"
        fi
        efibootmgr --quiet --bootorder "$boot_order" || {
            echo "ERROR: efibootmgr failed to set new boot order"
            return 1
        }

    fi

}

eval $create_demo_partition $blk_dev
demo_dev=$(echo $blk_dev | sed -e 's/\(mmcblk[0-9]\)/\1p/')$demo_part
partprobe

# Create filesystem on demo partition with a label
mkfs.ext4 -L $demo_volume_label $demo_dev || {
    echo "Error: Unable to create file system on $demo_dev"
    exit 1
}

# Mount demo filesystem
demo_mnt=$(mktemp -d) || {
    echo "Error: Unable to create demo file system mount point"
    exit 1
}
mount -t ext4 -o defaults,rw $demo_dev $demo_mnt || {
    echo "Error: Unable to mount $demo_dev on $demo_mnt"
    exit 1
}

# Copy kernel and initramfs to demo file system
# cp demo.vmlinuz demo.initrd $demo_mnt
tar -C $demo_mnt -xf rootfs.tgz

# store installation log in demo file system
onie-support $demo_mnt

# The persistent ONIE directory location
onie_root_dir=/mnt/onie-boot/onie

# Set a few GRUB_xxx environment variables that will be picked up and
# used by the 50_onie_grub script.  This is similiar to what an OS
# would specify in /etc/default/grub.
#
# GRUB_SERIAL_COMMAND
# GRUB_CMDLINE_LINUX

[ -r ./platform.conf ] && . ./platform.conf

# import console config and linux cmdline
. $onie_root_dir/grub/grub-variables

# If ONIE supports boot command feeding,
# adds DEMO DIAG bootcmd to ONIE.
if grep -q 'ONIE_SUPPORT_BOOTCMD_FEEDING' $onie_root_dir/grub.d/50_onie_grub &&
    [ "$demo_type" = "DIAG" ] ; then
    cat <<EOF > $onie_root_dir/grub/diag-bootcmd.cfg
diag_menu="Demo $demo_type"
function diag_bootcmd {
  search --no-floppy --label --set=root $demo_volume_label
  echo    'Loading ECOS kernel ...'
  linux   /demo.vmlinuz $GRUB_CMDLINE_LINUX \$ONIE_EXTRA_CMDLINE_LINUX DEMO_TYPE=$demo_type
  echo    'Loading ONIE Demo $demo_type initial ramdisk ...'
  initrd  /demo.initrd
  boot
}
EOF

    # Update ONIE grub configuration -- use the grub fragment provided by the
    # ONIE distribution.
    $onie_root_dir/grub.d/50_onie_grub > /dev/null

else
    # Install a separate GRUB for DEMO DIAG or NOS
    # that supports GRUB chainload function.

    if [ "$firmware" = "uefi" ] ; then
        demo_install_uefi_grub "$demo_mnt" "$blk_dev"
    else
        demo_install_grub "$demo_mnt" "$blk_dev"
    fi

    # Create a minimal grub.cfg that allows for:
    #   - configure the serial console
    #   - allows for grub-reboot to work
    #   - a menu entry for the DEMO OS
    #   - menu entries for ONIE
    grub_cfg=$(mktemp)

    # Add common configuration, like the timeout and serial console.
    cat <<EOF > $grub_cfg
$GRUB_SERIAL_COMMAND
terminal_input $GRUB_TERMINAL_INPUT
terminal_output $GRUB_TERMINAL_OUTPUT

set timeout=5

EOF

    # Add any platform specific kernel command line arguments.  This sets
    # the $ONIE_EXTRA_CMDLINE_LINUX variable referenced above in
    # $GRUB_CMDLINE_LINUX.
    cat $onie_root_dir/grub/grub-extra.cfg >> $grub_cfg

    # Add the logic to support grub-reboot
    cat <<EOF >> $grub_cfg
if [ -s \$prefix/grubenv ]; then
  load_env
fi
if [ "\${next_entry}" ] ; then
   set default="\${next_entry}"
   set next_entry=
   save_env next_entry
fi

EOF

    # Add a menu entry for the ECOS
    for kernel in ${demo_mnt}/boot/vmlinu* ; do
        bootKernel="/$(printf ${kernel} | cut -f 4- -d '/')"
    done
    demo_grub_entry="ECOS (Ubuntu Classic)"
    cat <<EOF >> $grub_cfg
menuentry '$demo_grub_entry' {
        search --no-floppy --label --set=root $demo_volume_label
        echo    'Loading ECOS Ubuntu kernel ...'
        linux   ${bootKernel} $GRUB_CMDLINE_LINUX \$ONIE_EXTRA_CMDLINE_LINUX DEMO_TYPE=$demo_type init=/bin/systemd cloud-config-url=file:///boot/cloud.user-data root=${demo_dev} rw
}
EOF

    # Add menu entries for ONIE -- use the grub fragment provided by the
    # ONIE distribution.
    $onie_root_dir/grub.d/50_onie_grub >> $grub_cfg

    cp $grub_cfg $demo_mnt/grub/grub.cfg

fi

# clean up
umount $demo_mnt || {
    echo "Error: Problems umounting $demo_mnt"
}

cd /
