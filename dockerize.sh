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
    local name=$2
    # FIXME this is kind of weird
    if [[ "$name" = 'core' ]]; then
        isoinfo -i "$iso" -x '/live/10root.squ;1' > $TMP/10root.squashfs
    else
        isoinfo -i "$iso" -x '/LIVE/10ROOT.SQUASHFS;1' > $TMP/10root.squashfs
    fi
    unsquashfs -q -n -no-exit-code -d $TMP/squashfs-root $TMP/10root.squashfs
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
    command_array=(unpack_iso "$iso" "$name")
    msg="Imported $appname from iso: $iso"
    deps="$deps isoinfo unsquashfs"
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

missing=''
# ensure that DOCKER can only be docker or podman
DOCKER=$(grep -w "docker\|podman" <<<$DOCKER) || true
if [[ -z "$DOCKER" ]]; then
    if which docker >/dev/null; then
        export DOCKER=docker
    elif which podman >/dev/null; then
        export DOCKER=podman
    else
        missing="docker|podman"
    fi
else
    if ! which $DOCKER >/dev/null; then
        missing="$DOCKER"
    fi
fi

for dep in $deps; do
    which "$dep" >/dev/null || missing="$missing $dep"
done
[[ -z "$missing" ]] || fatal "Missing dependencies: $missing"

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
    cat > $local_rootfs/etc/lib/systemd/system/inithooks-docker.service <<'EOF'
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
tar -C "$local_rootfs" -czf - . | $DOCKER import $DOCKER_ARG \
    -c 'ENTRYPOINT ["/sbin/init"]' \
    -m "$msg" \
    - \
    "tkl/$name"
info "Successfully created container:"
echo "tkl/$name"
