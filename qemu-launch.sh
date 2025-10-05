#!/bin/bash

# Enhanced QEMU Launcher
PROFILES_DIR="$HOME/.config/qemu-launch"
PROFILES_FILE="$PROFILES_DIR/profiles.json"

# --- Advanced disk settings ---
declare -a DISKS=()         # Array: disk path
declare -a DISK_IFS=()      # Array: interface (sata, virtio, scsi)
declare -a DISK_CACHE=()    # Array: cache (none, writeback, writethrough)
declare -a DISK_FMT=()      # Array: format (qcow2, raw, auto)

# For backward compatibility with profiles
disk=""

# --- UI helpers ---
highlight() { tput bold; tput setaf 2; echo -n "$1"; tput sgr0; }
error_msg() { tput setaf 1; echo "$1"; tput sgr0; }
info_msg() { tput setaf 4; echo "$1"; tput sgr0; }
success_msg() { tput setaf 2; echo "$1"; tput sgr0; }

# --- Snapshot management ---
snapshot_menu() {
    # Determine disk for snapshots
    local snap_disk=""
    if [[ ${#DISKS[@]} -gt 0 ]]; then
        snap_disk="${DISKS[0]}"
    elif [[ -n "$disk" ]]; then
        snap_disk="$disk"
    fi

    if [[ -z "$snap_disk" ]]; then
        error_msg "No disk selected for snapshot operations!"
        sleep 1
        return
    fi

    if ! qemu-img info "$snap_disk" | grep -q 'file format: qcow2'; then
        error_msg "Snapshots are supported only for qcow2 disks!"
        sleep 1
        return
    fi

    while true; do
        clear
        highlight "🗂 Snapshot management for disk: $snap_disk"
        echo
        echo "----------------------------------------"
        highlight "1. 📸 Create snapshot"; echo "   - Create a new snapshot of the disk"
        highlight "2. 🗑 Delete snapshot"; echo "   - Remove an existing snapshot"
        highlight "3. 🔄 Load from snapshot"; echo "   - Set snapshot to load on next VM start"
        highlight "4. 🌳 View snapshot tree"; echo "   - Show all snapshots for this disk"
        highlight "5. ⬅️  Back"
        echo
        read -n1 -p "$(highlight 'Select action: ')" snap_choice; echo
        case $snap_choice in
            1)
                info_msg "Creating a new snapshot. Please enter a name."
                read -p "Enter new snapshot name: " snap_name
                if [[ -z "$snap_name" ]]; then
                    error_msg "Name not specified!"
                    sleep 1
                    continue
                fi
                info_msg "Creating snapshot '$snap_name'..."
                if qemu-img snapshot -c "$snap_name" "$snap_disk"; then
                    success_msg "Snapshot '$snap_name' created!"
                else
                    error_msg "Snapshot creation error!"
                fi
                sleep 1
                ;;
            2)
                mapfile -t snaps < <(qemu-img snapshot -l "$snap_disk" | awk 'NR>2 {print $2}')
                if [[ ${#snaps[@]} -eq 0 ]]; then
                    error_msg "No snapshots to delete!"
                    sleep 1
                    continue
                fi
                info_msg "Existing snapshots:"
                select del_snap in "${snaps[@]}" "Back"; do
                    if [[ "$REPLY" -le ${#snaps[@]} ]]; then
                        info_msg "Deleting snapshot '$del_snap'..."
                        if qemu-img snapshot -d "$del_snap" "$snap_disk"; then
                            success_msg "Snapshot '$del_snap' deleted!"
                        else
                            error_msg "Snapshot deletion error!"
                        fi
                        sleep 1
                        break
                    elif [[ "$REPLY" -eq $((${#snaps[@]}+1)) ]]; then
                        break
                    else
                        error_msg "Invalid choice!"
                    fi
                done
                ;;
            3)
                mapfile -t snaps < <(qemu-img snapshot -l "$snap_disk" | awk 'NR>2 {print $2}')
                if [[ ${#snaps[@]} -eq 0 ]]; then
                    error_msg "No snapshots to load!"
                    sleep 1
                    continue
                fi
                info_msg "Existing snapshots:"
                select load_snap in "${snaps[@]}" "Back"; do
                    if [[ "$REPLY" -le ${#snaps[@]} ]]; then
                        export QEMU_SNAPSHOT_LOAD="$load_snap"
                        success_msg "Snapshot '$load_snap' will be loaded on next run."
                        sleep 1
                        break
                    elif [[ "$REPLY" -eq $((${#snaps[@]}+1)) ]]; then
                        break
                    else
                        error_msg "Invalid choice!"
                    fi
                done
                ;;
            4)
                info_msg "Snapshot tree:"
                qemu-img snapshot -l "$snap_disk"
                echo
                read -p "Press Enter to continue..."
                ;;
            5) break ;;
            *) error_msg "Invalid choice!"; sleep 1 ;;
        esac
    done
}

select_file() {
    echo >&2
    echo >&2 "$1"
    find . -type f -iname "$2" 2>/dev/null | fzf --height 40% --reverse --prompt="Select file (Enter): "
}

show_settings() {
    clear
    highlight "⚙ QEMU Launcher - Current settings"
    echo
    echo "----------------------------------------"
    if [[ ${#DISKS[@]} -gt 0 ]]; then
        if [[ ${#DISKS[@]} -eq 1 ]]; then
            highlight "1. 💾 Disk:"; echo " ${DISKS[0]} [${DISK_IFS[0]:-virtio}, cache=${DISK_CACHE[0]:-none}]"
        else
            for i in "${!DISKS[@]}"; do
                highlight "1.$((i+1)). 💾 Disk:"; echo " ${DISKS[$i]} [${DISK_IFS[$i]:-virtio}, cache=${DISK_CACHE[$i]:-none}]"
            done
        fi
    else
        highlight "1. 💾 Disk:"; echo "      ${disk:-not selected}"
    fi
    highlight "2. ⚙ Advanced disk settings"
    echo
    highlight "3. 📀 ISO/IMG:"; echo "   ${iso:-not selected}"
    highlight "4. 🧠 RAM:"; echo "       ${ram:-2G}"
    highlight "5. ⚡ CPU cores:"; echo " ${cores:-2}"
    highlight "6. 🔌 Firmware:"; echo "  ${firmware:-BIOS}"
    highlight "7. 🌐 Network:"; echo "   ${net_info:-not configured}"
    highlight "8. 💻 Accel:"; echo "     ${kvm:-yes}"
    highlight "9. 🔌 USB:"; echo "      ${usb_info:-not selected}"
    highlight "A. 🧩 Arch:"; echo "     ${qemu_bin:-qemu-system-x86_64}"
    highlight "S. 🗂 Snapshots"; echo
    highlight "P. 📁 Profiles:"; echo "  ${profile:-not selected}"

    echo "----------------------------------------"
    highlight "0. 🚀 Start VM"; echo
    highlight "Q. ❌ Exit"; echo
    echo
}

load_profile() {
    if [[ ! -f "$PROFILES_FILE" ]]; then
        error_msg "profiles.json file not found!"
        sleep 1
        return
    fi
    profiles=()
    while IFS= read -r; do
        profiles+=("$REPLY")
    done < <(jq -r 'keys[]' "$PROFILES_FILE")
    
    if [[ ${#profiles[@]} -eq 0 ]]; then
        error_msg "No saved profiles!"
        sleep 1
        return
    fi
    info_msg "Available profiles:"
    select p in "${profiles[@]}" "Back"; do
        if [[ "$REPLY" -le ${#profiles[@]} ]]; then
            profile="$p"
            info_msg "Loading profile '$p'..."
            mapfile -t DISKS < <(jq -r --arg p "$p" '.[$p].disks[]?.path' "$PROFILES_FILE" 2>/dev/null)
            mapfile -t DISK_IFS < <(jq -r --arg p "$p" '.[$p].disks[]?.iface' "$PROFILES_FILE" 2>/dev/null)
            mapfile -t DISK_CACHE < <(jq -r --arg p "$p" '.[$p].disks[]?.cache' "$PROFILES_FILE" 2>/dev/null)
            mapfile -t DISK_FMT < <(jq -r --arg p "$p" '.[$p].disks[]?.format' "$PROFILES_FILE" 2>/dev/null)
            disk=$(jq -r --arg p "$p" '.[$p].disk // empty' "$PROFILES_FILE")
            iso=$(jq -r --arg p "$p" '.[$p].iso // empty' "$PROFILES_FILE")
            ram=$(jq -r --arg p "$p" '.[$p].ram // empty' "$PROFILES_FILE")
            cores=$(jq -r --arg p "$p" '.[$p].cores // empty' "$PROFILES_FILE")
            firmware=$(jq -r --arg p "$p" '.[$p].firmware // empty' "$PROFILES_FILE")
            net_info=$(jq -r --arg p "$p" '.[$p].net_info // empty' "$PROFILES_FILE")
            kvm=$(jq -r --arg p "$p" '.[$p].kvm // empty' "$PROFILES_FILE")
            usb_info=$(jq -r --arg p "$p" '.[$p].usb_info // empty' "$PROFILES_FILE")
            qemu_bin=$(jq -r --arg p "$p" '.[$p].qemu_bin // empty' "$PROFILES_FILE")

            success_msg "Profile '$p' loaded!"
            sleep 1
            break
        elif [[ "$REPLY" -eq $((${#profiles[@]}+1)) ]]; then
            break
        else
            error_msg "Invalid choice!"
        fi
    done
}

save_profile() {
    read -p "Profile name: " pname
    [[ -z "$pname" ]] && error_msg "Name not specified!" && sleep 1 && return
    
    mkdir -p "$PROFILES_DIR"
    [[ ! -f "$PROFILES_FILE" ]] && echo '{}' > "$PROFILES_FILE"

    local disks_json="[]"
    for i in "${!DISKS[@]}"; do
        local dpath="${DISKS[$i]}"
        local dif="${DISK_IFS[$i]:-virtio}"
        local dcache="${DISK_CACHE[$i]:-none}"
        local dformat="${DISK_FMT[$i]:-auto}"
        disks_json=$(jq \
            --arg path "$dpath" \
            --arg iface "$dif" \
            --arg cache "$dcache" \
            --arg format "$dformat" \
            '. += [{"path":$path,"iface":$iface,"cache":$cache,"format":$format}]' \
            <<< "$disks_json")
    done

    jq \
      --arg p "$pname" \
      --arg disk "$disk" \
      --arg iso "$iso" \
      --arg ram "$ram" \
      --arg cores "$cores" \
      --arg firmware "$firmware" \
      --arg net_info "$net_info" \
      --arg kvm "$kvm" \
      --arg usb_info "$usb_info" \
      --arg qemu_bin "${qemu_bin}" \
      --argjson disks "$disks_json" \
      '.[$p] = {disk: $disk, disks: $disks, iso: $iso, ram: $ram, cores: $cores, firmware: $firmware, net_info: $net_info, kvm: $kvm, usb_info: $usb_info, qemu_bin: $qemu_bin}' \
      "$PROFILES_FILE" > "${PROFILES_FILE}.tmp"
    
    mv "${PROFILES_FILE}.tmp" "$PROFILES_FILE"
    success_msg "Profile '$pname' saved!"
    sleep 1
}

find_image_file() {
    local prompt="$1"
    local pattern="$2"
    local search_dirs=()
    if [[ -n "$3" ]]; then
        search_dirs=("$3")
    else
        search_dirs=("./disk_img" "./" "$HOME/ISO" "$HOME/Downloads")
    fi
    local found_files=()
    for dir in "${search_dirs[@]}"; do
        [[ -d "$dir" ]] || continue
        if [[ "$pattern" == *"|"* ]]; then
            IFS='|' read -r -a patterns <<< "$pattern"
            for pat in "${patterns[@]}"; do
                while IFS= read -r -d '' file; do
                    found_files+=("$file")
                done < <(find "$dir" -maxdepth 2 -type f -iname "$pat" -print0 2>/dev/null)
            done
        else
        while IFS= read -r -d '' file; do
            found_files+=("$file")
        done < <(find "$dir" -maxdepth 2 -type f -iname "$pattern" -print0 2>/dev/null)
        fi
    done
    if [[ ${#found_files[@]} -eq 0 ]]; then
        { error_msg "No $pattern files found in selected folders!"; } 1>&2
        sleep 1
        return 1
    fi
    { info_msg "Select a file (fzf):"; } 1>&2
    local selection
    selection=$(printf '%s\n' "${found_files[@]}" | fzf --height 40% --reverse --prompt="File ▶ ")
    if [[ -n "$selection" ]]; then
        { success_msg "Selected file: $selection"; } 1>&2
        echo "$selection"
            return 0
    else
            return 1
        fi
}

get_usb_bus_addr() {
    dev="$1"
    vid=$(udevadm info --query=all --name="$dev" | grep ID_VENDOR_ID= | cut -d= -f2)
    pid=$(udevadm info --query=all --name="$dev" | grep ID_MODEL_ID= | cut -d= -f2)
    [[ -z "$vid" || -z "$pid" ]] && return 1
    lsusb_line=$(lsusb | grep "$vid:$pid" | head -n1)
    [[ -z "$lsusb_line" ]] && return 1
    bus=$(echo "$lsusb_line" | awk '{print $2}' | sed 's/^0*//')
    addr=$(echo "$lsusb_line" | awk '{print $4}' | sed 's/://;s/^0*//')
    echo "$bus:$addr"
    return 0
}

select_usb_devices() {
    local devices=()
    while IFS= read -r line; do
        if [[ $line =~ ([0-9a-fA-F]{4}):([0-9a-fA-F]{4}) ]]; then
            vid="${BASH_REMATCH[1]}"
            pid="${BASH_REMATCH[2]}"
            desc=$(echo "$line" | sed 's/^.*[0-9a-fA-F]\{4\}:[0-9a-fA-F]\{4\} //')
            bus=$(echo "$line" | awk '{print $2}')
            devnum=$(echo "$line" | awk '{print $4}' | sed 's/://')
            devices+=("${vid}:${pid}|${desc}|${bus}|${devnum}")
        fi
    done < <(lsusb)

    if [[ ${#devices[@]} -eq 0 ]]; then
        error_msg "No USB devices found!"
        sleep 1
        return
    fi

    info_msg "Select USB devices (space to select, Enter to confirm):"
    selected_devices=()
    select device in "${devices[@]}" "Done"; do
        case $device in
            "Done")
                break
                ;;
            *)
                if [[ -n $device ]]; then
                    selected_devices+=("$device")
                    success_msg "Selected: $(echo "$device" | cut -d'|' -f2)"
                else
                    error_msg "Invalid choice!"
                fi
                ;;
        esac
    done

    if [[ ${#selected_devices[@]} -eq 0 ]]; then
        usb_info="not selected"
        USB_ARGS=()
        return
    fi

    USB_ARGS=()
    usb_info=""
    usb_added_usbhost=0
    for device in "${selected_devices[@]}"; do
        vid_pid=$(echo "$device" | cut -d'|' -f1)
        desc=$(echo "$device" | cut -d'|' -f2)
        bus=$(echo "$device" | cut -d'|' -f3)
        devnum=$(echo "$device" | cut -d'|' -f4)
        vid=$(echo "$vid_pid" | cut -d':' -f1)
        pid=$(echo "$vid_pid" | cut -d':' -f2)

        device_path=$(find /dev/disk/by-id/ -name "*${vid}*-${pid}*" 2>/dev/null | head -n1)
        if [[ -n "$device_path" ]]; then
            USB_ARGS+=("-drive" "file=${device_path},format=raw,if=none,id=usb_drive_${vid}_${pid}")
            USB_ARGS+=("-device" "ide-hd,drive=usb_drive_${vid}_${pid}")
            success_msg "USB storage attached as SATA device: $desc"
        else
            if [[ $usb_added_usbhost -eq 0 ]]; then
                USB_ARGS+=("-device" "qemu-xhci")
                usb_added_usbhost=1
            fi
            if [[ -n "$bus" && -n "$devnum" ]]; then
                bus_dec=$((10#$bus))
                devnum_dec=$((10#$devnum))
                USB_ARGS+=("-device" "usb-host,hostbus=${bus_dec},hostaddr=${devnum_dec}")
                success_msg "USB device passed through via usb-host (bus $bus_dec, addr $devnum_dec): $desc"
            else
                USB_ARGS+=("-device" "usb-host,vendorid=0x${vid},productid=0x${pid}")
                success_msg "USB device passed through via usb-host (vid/pid): $desc"
            fi
        fi

        if [[ -z "$usb_info" ]]; then
            usb_info="$desc"
        else
            usb_info="$usb_info, $desc"
        fi
    done
}

# --- Advanced disk settings ---
advanced_disks_menu() {
    while true; do
        clear
        highlight "⚙ Advanced disk settings"
        echo
        echo "----------------------------------------"
        if [[ ${#DISKS[@]} -eq 0 ]]; then
            info_msg "No disks added."
        else
            for i in "${!DISKS[@]}"; do
                if [[ $i -eq 0 ]]; then
                    highlight "$((i+1)). ${DISKS[$i]} [interface: ${DISK_IFS[$i]:-virtio}, cache: ${DISK_CACHE[$i]:-none}, format: ${DISK_FMT[$i]:-auto}]"
                else
                    echo "$((i+1)). ${DISKS[$i]} [interface: ${DISK_IFS[$i]:-virtio}, cache: ${DISK_CACHE[$i]:-none}, format: ${DISK_FMT[$i]:-auto}]"
                fi
            done
        fi
        echo "----------------------------------------"
        highlight "A. ➕ Add disk"; echo
        highlight "E. ✏️  Edit disk"; echo
        highlight "D. ➖ Delete disk"; echo
        highlight "B. ⬅️  Back"; echo
        echo
        read -n1 -p "$(highlight 'Select action: ')" adisk_choice; echo
        case $adisk_choice in
            A|a)
                while true; do
                    echo
                    info_msg "Select disk addition method:"
                    highlight "1. Create new virtual disk"
                    highlight "2. Select existing file"
                    highlight "3. Enter path manually (e.g., /dev/sdb)"
                    highlight "4. Back"
                    read -p "Your choice [1-4]: " add_disk_method
                    case $add_disk_method in
                        1)
                            info_msg "Creating new virtual disk."
                            read -p "Disk name [myvm.qcow2]: " newdisk
                            newdisk=${newdisk:-myvm.qcow2}
                            read -p "Size [10G]: " size
                            size=${size:-10G}
                            info_msg "Running: qemu-img create -f qcow2 \"$newdisk\" \"$size\""
                            qemu-img create -f qcow2 "$newdisk" "$size"
                            newdisk=$(realpath "$newdisk")
                            newformat="qcow2"
                            break
                            ;;
                        2)
                            read -p "Specify directory to search? (Enter for default): " user_disk_dir
                            if [[ -n "$user_disk_dir" && -d "$user_disk_dir" ]]; then
                                newdisk=$(find_image_file "🔍 Search disk:" "*.qcow2" "$user_disk_dir")
                                [[ -z "$newdisk" ]] && newdisk=$(find_image_file "🔍 Search disk:" "*.img" "$user_disk_dir")
                                [[ -z "$newdisk" ]] && newdisk=$(find_image_file "🔍 Search disk:" "*.raw" "$user_disk_dir")
                            else
                                newdisk=$(find_image_file "🔍 Search disk:" "*.qcow2")
                                [[ -z "$newdisk" ]] && newdisk=$(find_image_file "🔍 Search disk:" "*.img")
                                [[ -z "$newdisk" ]] && newdisk=$(find_image_file "🔍 Search disk:" "*.raw")
                            fi
                            if [[ -n "$newdisk" ]]; then
                                newdisk=$(realpath "$newdisk")
                                ext="${newdisk##*.}"
                                case "$ext" in
                                    qcow2) newformat="qcow2" ;;
                                    img) newformat="raw" ;;
                                    raw) newformat="raw" ;;
                                    *) newformat="auto" ;;
                                esac
                            fi
                            break
                            ;;
                        3)
                            info_msg "Physical devices list:"
                            lsblk -d -o NAME,SIZE,MODEL
                            read -p "Enter device path (e.g., /dev/sdb): " newdisk
                            if [[ -z "$newdisk" ]]; then
                                error_msg "Path not specified!"
                                sleep 1
                                continue
                            fi
                            if [[ ! -b "$newdisk" ]]; then
                                error_msg "⚠ Warning: $newdisk is not a block device!"
                                read -p "Add anyway? [y/N]: " confirm_add
                                [[ ! "$confirm_add" =~ ^[yY]$ ]] && continue
                            fi
                            newformat="raw"
                            break
                            ;;
                        4)
                            newdisk=""
                            break
                            ;;
                        *)
                            error_msg "Invalid choice!"
                            ;;
                    esac
                done
                [[ -z "$newdisk" ]] && continue
                PS3="Disk interface: "
                select newif in "virtio" "sata" "scsi"; do
                    [[ -n "$newif" ]] && break
                done
                PS3="Caching: "
                select newcache in "none" "writeback" "writethrough"; do
                    [[ -n "$newcache" ]] && break
                done
                DISKS+=("$newdisk")
                DISK_IFS+=("$newif")
                DISK_CACHE+=("$newcache")
                DISK_FMT+=("${newformat:-auto}")
                success_msg "Disk added: $newdisk"
                ;;
            E|e)
                if [[ ${#DISKS[@]} -eq 0 ]]; then error_msg "No disks to edit!"; sleep 1; continue; fi
                read -p "Enter disk number to edit: " editnum
                ((editnum--))
                [[ $editnum -ge 0 && $editnum -lt ${#DISKS[@]} ]] || { error_msg "Invalid number!"; sleep 1; continue; }
                info_msg "Editing disk: ${DISKS[$editnum]}"
                PS3="Disk interface [${DISK_IFS[$editnum]}]: "
                select newif in "virtio" "sata" "scsi"; do
                    [[ -n "$newif" ]] && break
                done
                PS3="Caching [${DISK_CACHE[$editnum]}]: "
                select newcache in "none" "writeback" "writethrough"; do
                    [[ -n "$newcache" ]] && break
                done
                DISK_IFS[$editnum]="$newif"
                DISK_CACHE[$editnum]="$newcache"
                success_msg "Disk updated: ${DISKS[$editnum]}"
                ;;
            D|d)
                if [[ ${#DISKS[@]} -eq 0 ]]; then error_msg "No disks to delete!"; sleep 1; continue; fi
                read -p "Enter disk number to delete: " delnum
                ((delnum--))
                [[ $delnum -ge 0 && $delnum -lt ${#DISKS[@]} ]] || { error_msg "Invalid number!"; sleep 1; continue; }
                info_msg "Deleting disk: ${DISKS[$delnum]}"
                unset "DISKS[$delnum]"
                unset "DISK_IFS[$delnum]"
                unset "DISK_CACHE[$delnum]"
                unset "DISK_FMT[$delnum]"
                DISKS=("${DISKS[@]}")
                DISK_IFS=("${DISK_IFS[@]}")
                DISK_CACHE=("${DISK_CACHE[@]}")
                DISK_FMT=("${DISK_FMT[@]}")
                success_msg "Disk deleted."
                ;;
            B|b) break ;;
            *) error_msg "Invalid choice!"; sleep 1 ;;
        esac
    done
}

while true; do
    show_settings
    read -n1 -p "$(highlight '➤ Select item (0-10, A, S, P, Q): ')" choice; echo
    case $choice in
        A|a)
            clear
            info_msg "Detecting available QEMU system binaries..."
            mapfile -t ARCH_CANDIDATES < <(compgen -c | grep -E '^qemu-system-' | sort -u)
            if [[ ${#ARCH_CANDIDATES[@]} -eq 0 ]]; then
                error_msg "No qemu-system-* binaries found in PATH!"
                sleep 1
            else
                info_msg "Select architecture binary (fzf):"
                sel=$(printf '%s\n' "${ARCH_CANDIDATES[@]}" | fzf --height 40% --reverse --prompt="QEMU ▶ ")
                if [[ -n "$sel" ]]; then
                    qemu_bin="$sel"
                    success_msg "Selected: $qemu_bin"
                    sleep 1
                fi
            fi
            ;;
        S|s)
            snapshot_menu
            ;;
        P|p)
            clear
            highlight "1. Load profile"; echo
            highlight "2. Save current as profile"; echo
            highlight "3. Back"; echo
            echo
            read -p "$(highlight 'Select action: ')" pchoice
            case $pchoice in
                1) load_profile ;;
                2) save_profile ;;
                3) ;;
                *) error_msg "Invalid choice!"; sleep 1 ;;
            esac
            ;;
        1)
            clear
            while true; do
                echo
                info_msg "Select main disk addition method:"
                highlight "1. Create new disk"; echo
                highlight "2. Select existing"; echo
                highlight "3. Enter path manually (e.g., /dev/sdb)"; echo
                highlight "4. Back"; echo
                read -p "Your choice [1-4]: " main_disk_method
                case $main_disk_method in
                    1)
                        info_msg "Creating new disk."
                        read -p "Disk name [myvm.qcow2]: " disk
                        disk=${disk:-myvm.qcow2}
                        read -p "Size [10G]: " size
                        size=${size:-10G}
                        info_msg "Running: qemu-img create -f qcow2 \"$disk\" \"$size\""
                        qemu-img create -f qcow2 "$disk" "$size"
                        disk=$(realpath "$disk")
                        DISKS=("$disk")
                        DISK_IFS=("virtio")
                        DISK_CACHE=("none")
                        DISK_FMT=("qcow2")
                        success_msg "Disk created and selected: $disk"
                        break
                        ;;
                    2)
                        read -p "Specify directory to search? (Enter for default): " user_disk_dir
                        if [[ -n "$user_disk_dir" && -d "$user_disk_dir" ]]; then
                            disk=$(find_image_file "🔍 Search disk:" "*.qcow2" "$user_disk_dir")
                            [[ -z "$disk" ]] && disk=$(find_image_file "🔍 Search disk:" "*.img" "$user_disk_dir")
                            [[ -z "$disk" ]] && disk=$(find_image_file "🔍 Search disk:" "*.raw" "$user_disk_dir")
                        else
                            disk=$(find_image_file "🔍 Search disk:" "*.qcow2")
                            [[ -z "$disk" ]] && disk=$(find_image_file "🔍 Search disk:" "*.img")
                            [[ -z "$disk" ]] && disk=$(find_image_file "🔍 Search disk:" "*.raw")
                        fi
                        if [[ -n "$disk" ]]; then
                            disk=$(realpath "$disk")
                            ext="${disk##*.}"
                            case "$ext" in
                                qcow2) dformat="qcow2" ;;
                                img) dformat="raw" ;;
                                raw) dformat="raw" ;;
                                *) dformat="auto" ;;
                            esac
                            DISKS=("$disk")
                            DISK_IFS=("virtio")
                            DISK_CACHE=("none")
                            DISK_FMT=("$dformat")
                            success_msg "Disk selected: $disk"
                        else
                            error_msg "Disk not selected!"
                        fi
                        break
                        ;;
                    3)
                        info_msg "Physical devices list:"
                        lsblk -d -o NAME,SIZE,MODEL
                        read -p "Enter device path (e.g., /dev/sdb): " disk
                        if [[ -z "$disk" ]]; then
                            error_msg "Path not specified!"
                            sleep 1
                            continue
                        fi
                        if [[ ! -b "$disk" ]]; then
                            error_msg "⚠ Warning: $disk is not a block device!"
                            read -p "Add anyway? [y/N]: " confirm_add
                            [[ ! "$confirm_add" =~ ^[yY]$ ]] && continue
                        fi
                        DISKS=("$disk")
                        DISK_IFS=("virtio")
                        DISK_CACHE=("none")
                        DISK_FMT=("raw")
                        success_msg "Physical disk selected: $disk"
                        break
                        ;;
                    4) break ;;
                    *) error_msg "Invalid choice!" ;;
                esac
            done
            ;;
        2)
            advanced_disks_menu
            ;;
        3)
            clear
            read -p "Specify directory to search for ISO/IMG? (Enter for default): " user_iso_dir
            if [[ -n "$user_iso_dir" && -d "$user_iso_dir" ]]; then
                iso=$(find_image_file "" "*.iso|*.img" "$user_iso_dir")
            else
                iso=$(find_image_file "" "*.iso|*.img")
            fi
            if [[ -n "$iso" ]]; then
                iso=$(realpath "$iso")
                success_msg "ISO/IMG selected: $iso"
            else
                error_msg "ISO/IMG not selected!"
            fi
            ;;
        4) 
            clear
            read -p "🧠 RAM size [2G]: " ram ;;
        5)
            clear
            read -p "⚡ Number of CPU cores [2]: " cores ;;

        6) 
            clear
            PS3="🔌 Select firmware: "
            select firmware in "BIOS" "UEFI" "Back"; do
                case $REPLY in 1|2) break ;; 3) firmware=""; break ;; *) ;; esac
            done ;;
        7) 
            clear
            PS3="🌐 Select network type: "
            options=("User (NAT)" "Tap" "No network" "Back")
            select opt in "${options[@]}"; do
                case $REPLY in
                    1) 
                        net_info="NAT with port forwarding"
                        NET_ARG="-net user,hostfwd=tcp::2222-:22 -net nic"
                        success_msg "Network set: NAT with port forwarding"
                        break ;;
                    2) 
                        net_info="Tap (advanced)"
                        NET_ARG="-net nic -net tap,ifname=tap0,script=no"
                        success_msg "Network set: Tap (advanced)"
                        break ;;
                    3) 
                        net_info="No network"
                        NET_ARG="-net none"
                        success_msg "Network set: No network"
                        break ;;
                    4) break ;;
                    *) error_msg "Invalid option!" ;;
                esac
            done ;;
        8) 
            clear
            read -p "💻 Use KVM? [Y/n]: " kvm_choice
            [[ "$kvm_choice" =~ [nN] ]] && kvm="no" || kvm="yes"
            info_msg "KVM acceleration: $kvm"
            ;;
        9) 
            clear
            select_usb_devices
            ;;
        0)
            clear
            highlight "🚀 Preparing to launch..."
            [[ -z "$ram" ]] && ram="2G"
            [[ -z "$cores" ]] && cores=2
            declare -a CMD=(
                "sudo"
                "${qemu_bin:-qemu-system-x86_64}"
                "-m" "$ram"
                "-smp" "$cores"
            )
            if [[ ${#DISKS[@]} -gt 0 ]]; then
                for i in "${!DISKS[@]}"; do
                    dpath="${DISKS[$i]}"
                    dif="${DISK_IFS[$i]:-virtio}"
                    dcache="${DISK_CACHE[$i]:-none}"
                    dformat="${DISK_FMT[$i]:-auto}"
                    if [[ "$dformat" == "auto" ]]; then
                        ext="${dpath##*.}"
                        case "$ext" in
                            qcow2) dformat="qcow2" ;;
                            img) dformat="raw" ;;
                            raw) dformat="raw" ;;
                            *) dformat="qcow2" ;;
                        esac
                    fi
                    did="disk$((i+1))"
                    CMD+=("-drive" "file=$dpath,if=$dif,cache=$dcache,format=$dformat,index=$i,id=$did")
                done
            elif [[ -n "$disk" ]]; then
                CMD+=("-hda" "${disk}")
            fi
            [[ -n "$iso" ]] && CMD+=("-cdrom" "$iso")
            if [[ "$firmware" == "UEFI" ]]; then
                OVMF_PATH="/usr/share/edk2-ovmf/x64/OVMF.4m.fd"
                [[ -f "$OVMF_PATH" ]] && {
                    CMD+=(
                        "-drive" "if=pflash,format=raw,readonly=on,file=$OVMF_PATH"
                    )
                } || error_msg "⚠  OVMF not found! Using BIOS"
            fi
            [[ -n "$NET_ARG" ]] && IFS=' ' read -ra NET <<< "$NET_ARG" && CMD+=("${NET[@]}")
            [[ "$kvm" == "yes" ]] && grep -q -E "vmx|svm" /proc/cpuinfo && CMD+=("-enable-kvm")
            CMD+=("${USB_ARGS[@]}")
            CMD+=(
                "-boot" "menu=on"
                "-name" "QEMU_VM"
            )
            if [[ -n "$QEMU_SNAPSHOT_LOAD" ]]; then
                if [[ ${#DISKS[@]} -gt 0 ]]; then
                    CMD+=("-loadvm" "$QEMU_SNAPSHOT_LOAD")
                    info_msg "Snapshot will be loaded: $QEMU_SNAPSHOT_LOAD"
                fi
                unset QEMU_SNAPSHOT_LOAD
            fi
            highlight "🔧 Launch command:"
            printf "%s " "${CMD[@]}"
            echo -e "\n"
            if read -p "$(highlight '▶ Start VM? [Y/n]: ')" launch && [[ ! "$launch" =~ [nN] ]]; then
                info_msg "Launching QEMU VM..."
                "${CMD[@]}"
                exit 0
            else
                info_msg "VM launch cancelled."
            fi ;;
        Q|q) 
            clear
            highlight "👋 Exiting QEMU Launcher"
            sleep 1
            exit 0 ;;
        *) 
            error_msg "⚠ Invalid choice!" 
            sleep 1 ;;
    esac
done