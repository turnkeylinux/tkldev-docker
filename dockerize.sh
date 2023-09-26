#!/bin/bash -e

info() { [[ -n "$quiet" ]] || echo "INFO: $@"; }
warn() { [[ -n "$quiet" ]] || echo "WARN: $@" >&2; }
fatal() { echo "FATAL: $@" >&2; exit 1; }

usage() {
    cat <<EOF
Syntax: $(basename $0) [-h|--help] [-i|--iso ISO | -r|--rootfs ROOTFS] [-n|--name NAME]

Args::

    -i|--iso ISO        Convert ISO (iso file that contains squashfs) to docker
    -r|--rootfs ROOTFS  Convert ROOTFS (dir) to docker

Options::

    -n|--name NAME      Explicit NAME for container (otherwise will guess, or
                        fall back to random string)
    -d|--deck           When using -r|--rootfs, instead of copying rootFS, deck it
                        before applying changes (requires 'deck' executable)
    -q|--quiet          Supress all messages, except fatal errors. Will output
                        name (to stdout) on exit if successful
    -h|--help           Display this help and exit

Env::

    DOCKER              docker/podman executable; if not set, will default to docker
                        and fall back to podman (and error if neither found)
    DEBUG               Enable verbose output, useful for debugging

Note: To ensure correct filesystem permissions are maintained, this script must
      run with root privileges (i.e. as root or with sudo)

EOF
    if [[ "$#" -ne 0 ]]; then
        echo "FATAL: $@"
        exit 1
    fi
    exit
}

[[ -z "$DEBUG" ]] || set -x

TMP=$(mktemp --tmpdir -d tkl-dockerize.XXXXXXXXXX)
[[ -n "$DEBUG" ]] || trap "rm -rf $TMP" EXIT INT

unset iso rootfs name deck quiet deps local_rootfs msg DOCKER_ARG
while [[ $# -ge 1 ]]; do
    case $1 in
        -i|--iso)
            shift
            iso=$1;;
        -r|--rootfs)
            shift
            rootfs=$1;;
        -n|--name)
            shift
            name=$1;;
        -d|--deck)
            deck=true;;
        -q|--quiet)
            DOCKER_ARG="--quiet"
            quiet=true;;
        -h|--help)
            usage;;
        *)
            usage "Unknown argument: $1";;
    esac
    shift
done

unpack_iso() {
    local iso=$1
    local isoroot="$TMP/isoroot"

    mkdir "$isoroot"
    mount -o loop,ro "$iso" "$TMP/isoroot"
    unsquashfs -q -n -no-exit-code -d "$TMP/squashfs-root" "$isoroot/live/10root.squashfs"
    umount "$isoroot"
    rmdir "$isoroot"

    echo "$TMP/squashfs-root"
}

cp_rootfs() {
    local rootfs=$1
    cp -Ra "$rootfs" $TMP/rootfs-root
    echo "$TMP/rootfs-root"
}

deck_rootfs() {
    local rootfs=$1
    if deck --isdeck "$rootfs"; then
        if ! deck --ismounted "$rootfs"; then
            deck "$rootfs"
        fi
        echo "$rootfs"
    else
        deck "$rootfs" "$TMP/deck-root"
        echo "$TMP/deck-root"
    fi
}

[[ $(id -u) -eq 0 ]] || fatal "Must be run as root; please re-run with sudo"
deps="sed"
if [[ -n "$iso" ]] && [[ -n "$rootfs" ]]; then
    fatal "Can't use both -i|--iso ISO and -r|--rootfs ROOTFS"
elif [[ -z "$iso" ]] && [[ -z "$rootfs" ]]; then
    fatal "Must specify either -i|--iso ISO or -r|--rootfs ROOTFS"
elif [[ -n "$iso" ]]; then
    [[ -f "$iso" ]] || fatal "ISO file $iso not found"
    [[ -z "$deck" ]] || warn "-d|--deck set but using iso as source - ignoring"
    if [[ -z "$name" ]]; then
        if echo "$iso" | grep -q '/turnkey-tkldev'; then
            name="$(echo "$(basename "$iso")" | cut -d'-' -f2)"
        else
            name="$(basename "$iso" .iso)"
        fi
    fi
    command_array=(unpack_iso "$iso")
    msg="Imported $appname from iso: $iso"
    deps="$deps unsquashfs"
elif [[ -n "$rootfs" ]]; then
    [[ -d "$rootfs" ]] || fatal "Rootfs dir $rootfs not found"
    [[ -z "$deck" ]] || deps="$deps deck"
    rootfs=$(realpath "$rootfs")
    if [[ "$rootfs" == "/turnkey/fab/products/"*"build/root."* ]]; then
        name=$(sed -E "s|/turnkey/fab/products/([a-z0-9-]+)/build/root.*|\1|" <<<"$rootfs")
    else
        name=$(mcookie)
        warn "Name can not be determined, using random string, alternatively re-run with -n|--name"
    fi
    msg="Imported $appname from rootfs: $rootfs"
    if [[ -n "$deck" ]]; then
        info "Decking rootFS ($rootfs) rather than copying (-d|--deck given)"
        deps="fab deck"
        command_array=(deck_rootfs "$rootfs")
    else
        info "Please wait while the rootfs is copied"
        command_array=(cp_rootfs "$rootfs" "$name")
        deps="fab"
    fi
fi

missing=()

# sane default for unset $DOCKER

if [[ -n "$DOCKER" ]]; then
    which "$DOCKER" >/dev/null || missing+=("$DOCKER")
else
    for bin in docker podman; do
        if which "$bin" >/dev/null; then
            export DOCKER="$bin"
            break
        fi
    done
fi

[[ -n "$DOCKER" ]] || missing+=('docker|podman')

for dep in $deps; do
    which "$dep" >/dev/null || missing+=("$dep")
done

[[ "${#missing[@]}" -eq 0 ]] || fatal "Missing dependencies: ${missing[*]}"

# show relevant msg & run relevant command
info $msg
local_rootfs=$(${command_array[@]})

info "Patching local rootfs"
# preseed inithooks
cp $(dirname $(realpath $0))/inithooks.conf "$local_rootfs/etc/inithooks.conf"
# do not start confconsole on login
sed -i '/autostart/s|once|false|' "$local_rootfs/etc/confconsole/confconsole.conf"
# redirect inithooks output
sed -i '/REDIRECT_OUTPUT/s|false|true|' "$local_rootfs/etc/default/inithooks"
# do not configure networking (docker does it)
sed -i '/CONFIGURE_INTERFACES/{s|#||;s|yes|no|}' "$local_rootfs/etc/default/networking"

if [[ "$DOCKER" == "docker" ]]; then
    cat > $local_rootfs/etc/systemd/system/inithooks-docker.service <<'EOF'
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
    else
cat > $local_rootfs/etc/systemd/system/inithooks-podman.service <<'EOF'
[Unit]
Description=inithooks-podman: firstboot and everyboot initialization scripts (podman)
Before=console-getty.service
ConditionKernelCommandLine=!noinithooks
ConditionVirtualization=podman

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
fi

# manually enable docker/podman specific inithooks services
sysd=$local_rootfs/etc/systemd/system
for _file in $sysd/{inithooks-docker.service,inithooks-podman.service}; do
    if [[ -f "$_file" ]]; then
        ln -sf $_file $local_rootfs/etc/systemd/system/basic.target.wants/$(basename $_file)
    fi
done

# disable hostname manipulation (envvar clash with docker)
chmod -x "$local_rootfs/usr/lib/inithooks/firstboot.d/09hostname"

# manually (pre)set root password for troubleshooting when DEBUG set
if [[ -n "$DEBUG" ]] && which fab-chroot >/dev/null; then
    _password='turnkey'
    info "Setting password root: $_password"
    fab-chroot "$local_rootfs" "echo -e \"$_password\n$_password\" | passwd"
fi

# remove sockets to stop tar from whinging
find "$local_rootfs" -type s -exec rm {} \;

info "Please wait while docker container is created"
tar -C "$local_rootfs" -cf - . | $DOCKER import $DOCKER_ARG \
    -c 'ENTRYPOINT ["/sbin/init"]' \
    -m "$msg" \
    - \
    "tkl/$name"
info "Successfully created container:"
echo "tkl/$name"
