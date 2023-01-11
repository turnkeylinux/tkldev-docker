#!/bin/bash
# this needs to be run via sudo to preserve filesystem permissions
set -ex

if [[ -z "$1" ]]; then
    echo 'No .iso filename supplied, exiting'
    exit 1
fi

for i in isoinfo unsquashfs sed docker; do
    which "$i" >/dev/null || { echo "$i is missing, cannot run!"; exit 1; }
done

ISO="$1"
shift
if echo "$ISO" | grep -q '/turnkey-tkldev'; then
    NAME="$(echo "$(basename "$ISO")" | cut -d'-' -f2)"
else
    NAME="$(basename "$ISO" .iso)"
fi

trap 'rm -rf squashfs-root 10root.squashfs' EXIT INT

# FIXME this is kind of weird
if [[ "$NAME" = 'core' ]]; then
    isoinfo -i "$ISO" -x '/live/10root.squ;1' > 10root.squashfs
else
    isoinfo -i "$ISO" -x '/LIVE/10ROOT.SQUASHFS;1' > 10root.squashfs
fi

unsquashfs -no-exit-code 10root.squashfs

cp inithooks.conf squashfs-root/etc/inithooks.conf

tar -C squashfs-root -czf - . | docker import \
    -c 'ENTRYPOINT ["/sbin/init"]' \
    -m 'Imported from .iso squashfs' \
    - \
    "tkl/$NAME"
