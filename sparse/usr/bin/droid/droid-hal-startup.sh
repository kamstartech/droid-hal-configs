#!/bin/sh
# droid-hal-startup.sh — Android 15 hwcomposer-ready startup for SailfishOS
# Ensures APEX, linkerconfig, and display HAL are up before notifying systemd.

LOGF=/var/log/droid-hal-debug.log
log() { echo "$(date '+%H:%M:%S') startup: $*" >> $LOGF; echo "droid-hal-startup: $*" > /dev/kmsg 2>/dev/null; }

_SF=/run/droid-hal-invocation
if [ -f "$_SF" ]; then _N=$(( $(cat "$_SF") + 1 )); else _N=1; fi
echo "$_N" > "$_SF" 2>/dev/null
if [ "$_N" -eq 1 ]; then log "=== INVOCATION #1 ==="; else log "=== INVOCATION #$_N ==="; fi

echo 0 > /proc/sys/kernel/printk_ratelimit 2>/dev/null
echo 7 > /proc/sys/kernel/printk 2>/dev/null

mkdir -p /dev/socket
chmod 0755 /dev/socket

# Ensure SELinux is permissive (hybris init has no sepolicy loading)
echo 0 > /sys/fs/selinux/enforce 2>/dev/null && log "SELinux set to permissive" || log "SELinux permissive failed"

# Android 15 APEX: bionic libs must be available for HAL processes
if ! mountpoint -q /apex 2>/dev/null; then
    mkdir -p /apex
    mount -t tmpfs -o mode=0755,size=32m tmpfs /apex && log "Mounted tmpfs on /apex"
fi
if [ ! -x /apex/com.android.runtime/bin/linker64 ] && [ -f /system/bin/bootstrap/linker64 ]; then
    mkdir -p /apex/com.android.runtime/bin /apex/com.android.runtime/lib64/bionic /apex/com.android.runtime/lib/bionic
    for b in linker64 linker; do
        src="/system/bin/bootstrap/$b"
        [ -f "$src" ] && cp "$src" "/apex/com.android.runtime/bin/$b"
    done
    for f in libc.so libm.so libdl.so libdl_android.so; do
        src="/system/lib64/bootstrap/$f"
        [ -f "$src" ] && cp "$src" "/apex/com.android.runtime/lib64/bionic/$f" && ln -sf "bionic/$f" "/apex/com.android.runtime/lib64/$f"
        src="/system/lib/bootstrap/$f"
        [ -f "$src" ] && cp "$src" "/apex/com.android.runtime/lib/bionic/$f" && ln -sf "bionic/$f" "/apex/com.android.runtime/lib/$f"
    done
    log "APEX runtime populated"
fi

# linkerconfig: Android 15 HALs need vendor+system search paths
if [ ! -f /linkerconfig/ld.config.txt ] || [ "$(stat -c %s /linkerconfig/ld.config.txt 2>/dev/null || echo 0)" -lt 500 ]; then
    mkdir -p /linkerconfig
    cat > /linkerconfig/ld.config.txt <<'LDCFG'
dir.system = /system/bin
dir.vendor = /vendor/bin

[system]
additional.namespaces = default
namespace.default.isolated = false
namespace.default.search.paths = /system/lib64/bootstrap:/system/lib64:/system/lib64/hw:/system_ext/lib64:/product/lib64:/odm/lib64:/apex/com.android.runtime/lib64
namespace.default.permitted.paths = /system:/vendor:/system_ext:/product:/odm:/apex:/data

[vendor]
additional.namespaces = default
namespace.default.isolated = false
namespace.default.search.paths = /vendor/lib64:/vendor/lib64/hw:/system/lib64/bootstrap:/system/lib64:/system/lib64/hw:/system_ext/lib64:/product/lib64:/odm/lib64:/apex/com.android.runtime/lib64
namespace.default.permitted.paths = /system:/vendor:/system_ext:/product:/odm:/apex:/data
LDCFG
    log "linkerconfig regenerated"
fi

# Ensure /data exists for HAL services that expect Android data paths
if ! mountpoint -q /data 2>/dev/null; then
    mkdir -p /data
    mount -t tmpfs -o mode=0755,size=64m tmpfs /data && log "Mounted tmpfs on /data"
fi

# Log firmware partition status before init starts
log "Firmware partitions: firmware_mnt=$(mountpoint -q /vendor/firmware_mnt && echo ok || echo FAIL) dsp=$(mountpoint -q /vendor/dsp && echo ok || echo FAIL) persist=$(mountpoint -q /mnt/vendor/persist && echo ok || echo FAIL) bt_fw=$(mountpoint -q /vendor/bt_firmware && echo ok || echo FAIL)"

# Fallback: mount firmware partitions if systemd units failed
if ! mountpoint -q /vendor/firmware_mnt 2>/dev/null; then
    mkdir -p /vendor/firmware_mnt
    mount -t vfat -o ro,shortname=lower,uid=1000,gid=1000,dmask=227,fmask=337 /dev/sde46 /vendor/firmware_mnt 2>/dev/null && log "FALLBACK: mounted /vendor/firmware_mnt" || log "FALLBACK: /vendor/firmware_mnt mount failed"
fi
if ! mountpoint -q /vendor/dsp 2>/dev/null; then
    mkdir -p /vendor/dsp
    mount -t ext4 -o ro,nosuid,nodev,barrier=1 /dev/sde44 /vendor/dsp 2>/dev/null && log "FALLBACK: mounted /vendor/dsp" || log "FALLBACK: /vendor/dsp mount failed"
fi
if ! mountpoint -q /mnt/vendor/persist 2>/dev/null; then
    mkdir -p /mnt/vendor/persist
    mount -t ext4 -o nosuid,nodev,barrier=1 /dev/sda15 /mnt/vendor/persist 2>/dev/null && log "FALLBACK: mounted /mnt/vendor/persist" || log "FALLBACK: /mnt/vendor/persist mount failed"
fi
if ! mountpoint -q /vendor/bt_firmware 2>/dev/null; then
    mkdir -p /vendor/bt_firmware
    mount -t vfat -o ro,shortname=lower,uid=1002,gid=3002,dmask=227,fmask=337 /dev/sde24 /vendor/bt_firmware 2>/dev/null && log "FALLBACK: mounted /vendor/bt_firmware" || log "FALLBACK: /vendor/bt_firmware mount failed"
fi

# Patch init.rc for hybris: remove reboot_on_failure, suppress logd, etc.
mount -o remount,rw / 2>/dev/null
patch_rc() {
    local orig="$1" tmp
    [ -f "$orig" ] || return 0
    tmp=$(mktemp -t hybris-rc.XXXXXX) || return 1
    sed -e '/reboot_on_failure/d' \
        -e '/[[:space:]]start logd$/d' \
        -e '/[[:space:]]start logd-reinit$/d' \
        -e '/[[:space:]]exec_start bpfloader$/d' \
        -e '/exec.*vdc.*checkpoint/d' \
        -e '/exec.*vdc.*keymaster/d' \
        -e '/[[:space:]]class_start main$/d' \
        -e '/[[:space:]]class_start late_start$/d' \
        -e '/trigger zygote-start/d' \
        "$orig" > "$tmp"
    mount --bind "$tmp" "$orig" 2>/dev/null && log "Patched $(basename $orig)"
}
patch_rc /system/etc/init/hw/init.rc
patch_rc /system/etc/init/logd.rc

# Patch display HAL RC: remove surfaceflinger onrestart, override service
patch_display_hal() {
    local orig="$1" tmp
    [ -f "$orig" ] || return 0
    tmp=$(mktemp -t hybris-rc.XXXXXX) || return 1
    sed -e '/onrestart.*surfaceflinger/d' \
        -e '/task_profiles/d' \
        -e 's/class hal animation/class hal/' \
        "$orig" > "$tmp"
    mount --bind "$tmp" "$orig" 2>/dev/null && log "Patched display HAL $(basename $orig)"
}
patch_display_hal /vendor/etc/init/android.hardware.graphics.composer@2.3-service.rc
patch_display_hal /vendor/etc/init/vendor.qti.hardware.display.allocator@1.0-service.rc
patch_display_hal /vendor/etc/init/vendor.display.color@1.0-service.rc

# Audio HAL service: remove task_profiles and audioserver onrestart to prevent init issues
patch_audio_hal() {
    local orig="$1" tmp
    [ -f "$orig" ] || return 0
    tmp=$(mktemp -t hybris-rc.XXXXXX) || return 1
    sed -e '/task_profiles/d' \
        -e '/onrestart restart audioserver/d' \
        "$orig" > "$tmp"
    mount --bind "$tmp" "$orig" 2>/dev/null && log "Patched audio HAL $(basename $orig)"
}
patch_audio_hal /vendor/etc/init/android.hardware.audio.service.rc

# Stub Android services that would seize graphics hardware
STUB=/tmp/hybris-stub
echo '#!/bin/sh' > $STUB
echo 'exit 0' >> $STUB
chmod 755 $STUB
for tgt in /system/bin/surfaceflinger /system/bin/bootanimation /system/bin/vdc; do
    [ -x "$tgt" ] && mount --bind $STUB "$tgt" 2>/dev/null && log "Stubbed $(basename $tgt)"
done

# Clean stale init state
[ -e /dev/kmsg_debug ] && rm -f /dev/kmsg_debug
[ -d /dev/__properties__ ] && rm -rf /dev/__properties__
touch /dev/.coldboot_done

export LD_LIBRARY_PATH=

log "Starting droid-hal-init..."
/sbin/droid-hal-init >> $LOGF 2>&1 &
INIT_PID=$!
log "droid-hal-init PID=$INIT_PID"

# Wait for critical HAL services before telling systemd we're ready.
# Lipstick needs HWComposer to be available via binder.
log "Waiting for hwservicemanager..."
for i in $(seq 1 30); do
    if pgrep -f hwservicemanager >/dev/null 2>&1; then
        log "hwservicemanager detected"
        break
    fi
    sleep 1
done

# Explicitly start HAL services that were disabled by class_start main removal.
# Audio and vibrator are in class main/late_start, so they don't auto-start.
for svc in vendor.audio-hal vendor.qti.vibrator; do
    if [ -x /system/bin/setprop ]; then
        /system/bin/setprop ctl.start "$svc" 2>/dev/null && log "Started $svc via setprop"
    elif [ -x /vendor/bin/setprop ]; then
        /vendor/bin/setprop ctl.start "$svc" 2>/dev/null && log "Started $svc via setprop"
    else
        log "setprop not found, cannot start $svc"
    fi
done

log "Waiting for HWC2 service..."
hwc2_found=false
for i in $(seq 1 30); do
    if pgrep -f android.hardware.graphics.composer >/dev/null 2>&1; then
        log "HWC2 service detected after ${i}s"
        hwc2_found=true
        break
    fi
    if [ $((i % 5)) -eq 0 ]; then
        log "HWC2 still not detected after ${i}s"
    fi
    sleep 1
done

if [ "$hwc2_found" = false ]; then
    log "WARN: HWC2 service NOT detected after 30s"
fi

sleep 2
systemd-notify --ready 2>/dev/null && log "Sent sd_notify READY"

wait $INIT_PID
INIT_RET=$?
log "droid-hal-init EXITED code=$INIT_RET"
