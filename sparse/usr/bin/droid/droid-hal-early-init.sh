#!/bin/bash
# droid-hal-early-init.sh — minimal early setup before droid-hal-startup.sh
# Android 15 hwcomposer: ensure nothing blocks HAL processes.

LOGF=/var/log/droid-hal-debug.log
log() { echo "$(date '+%H:%M:%S') early-init: $*" >> $LOGF; }

log "droid-hal-early-init running"

# Android 15 linker config: bind-mount hybris version if available
if [ -f /usr/libexec/droid-hybris/system/etc/ld.config.33.txt ] && ! grep -q hybris /system/etc/ld.config.33.txt 2>/dev/null; then
    mount -o bind /usr/libexec/droid-hybris/system/etc/ld.config.33.txt /system/etc/ld.config.33.txt 2>/dev/null && log "Bound ld.config.33.txt"
fi

log "early-init done"
