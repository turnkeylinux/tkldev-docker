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

# preseed inithooks
cp inithooks.conf squashfs-root/etc/inithooks.conf
# do not start confconsole on login
sed -i '/autostart/s|once|false|' squashfs-root/etc/confconsole/confconsole.conf
# redirect inithooks output
sed -i '/REDIRECT_OUTPUT/s|false|true|' squashfs-root/etc/default/inithooks
# do not configure networking (docker does it)
sed -i '/CONFIGURE_INTERFACES/{s|#||;s|yes|no|}' squashfs-root/etc/default/networking
# do not run traditional tty8 inithooks
rm squashfs-root/etc/systemd/system/multi-user.target.wants/inithooks.service
# create docker-specific inithooks service
# TODO organize this in a better way
cat > squashfs-root/lib/systemd/system/inithooks-docker.service <<'EOF'
[Unit]
Description=inithooks-docker: firstboot and everyboot initialization scripts (docker)
Before=container-getty@1.service
ConditionKernelCommandLine=!noinithooks
ConditionPathExists=/.dockerenv

[Service]
Type=oneshot
EnvironmentFile=/etc/default/inithooks
ExecStart=/bin/sh -c '${INITHOOKS_PATH}/run'
StandardOutput=journal+console
StandardError=journal+console
SyslogIdentifier=inithooks

[Install]
WantedBy=basic.target
EOF
# manually enable docker-specific inithooks service
ln -sf /lib/systemd/system/inithooks-docker.service squashfs-root/etc/systemd/system/basic.target.wants/inithooks-docker.service
# disable hostname manipulation (envvar clash with docker)
chmod -x squashfs-root/usr/lib/inithooks/firstboot.d/09hostname

tar -C squashfs-root -czf - . | docker import \
    -c 'ENTRYPOINT ["/sbin/init"]' \
    -m 'Imported from .iso squashfs' \
    - \
    "tkl/$NAME"
