#!/bin/bash -e

info() { echo "INFO: $@"; }
fatal() { echo "FATAL: $@" >&2; exit 1; }

usage() {
    cat <<EOF
Syntax: $(basename $0) [-h|--help] [-i|--iso ISO | -r|--rootfs ROOTFS] [-n|--name NAME]

Args::

    -i|--iso ISO        Convert ISO (iso file that contains squashfs) to docker
    -r|--rootfs ROOTFS  Convert ROOTFS (dir) to docker

Options::

    -n|--name NAME      Use NAME for reulsting container (rather than guessing)
    -h|--help           Display this help and exit

Env::

    DOCKER              docker/podman binary; if not set, will default to docker and
                        fall back to podman (and error if neither found)
    DEBUG               Enable verbose output, useful for debugging

Note: To ensure correct filesystem permissions are maintained, this script must
      run with root privileges (i.e. as root or with sudo)

EOF
    if [[ "$#" -ne 0 ]]; then
        echo "FATAL: $@"
        exit 1
    fi
}

[[ -z "$DEBUG" ]] || set -x

unset iso rootfs name deps local_rootfs msg
while [[ $# -ge 1 ]]; do
    case $1 in
        -i|--iso)
            shift
            iso=$1
            shift;;
        -r|--rootfs)
            shift
            rootfs=$1
            shift;;
        -n|--name)
            shift
            name=$1
            shift;;
        -h|--help)
            usage;;
        *)
            usage "Unknown argument: $1";;
    esac
done

unpack_iso() {
    local iso=$1
    local name=$2
    [[ -n "$DEBUG" ]] || trap 'rm -rf squashfs-root 10root.squashfs' EXIT INT

    # FIXME this is kind of weird
    if [[ "$name" = 'core' ]]; then
        isoinfo -i "$iso" -x '/live/10root.squ;1' > 10root.squashfs
    else
        isoinfo -i "$iso" -x '/LIVE/10ROOT.SQUASHFS;1' > 10root.squashfs
    fi
    unsquashfs -no-exit-code 10root.squashfs
    echo "squashfs-root"
}

cp_rootfs() {
    local rootfs=$1
    local name=$2
    [[ -n "$DEBUG" ]] || trap 'rm -rf rootfs-root' EXIT INT

    cp -Ra "$rootfs" rootfs-root
    echo "rootfs-root"
}

[[ $(id -u) -eq 0 ]] || fatal "Must be run as root; please re-run with sudo"

deps="sed"
if [[ -n "$iso" ]] && [[ -n "$rootfs" ]]; then
    fatal "Can't use both -i|--iso ISO and -r|--rootfs ROOTFS"
elif [[ -n "$iso" ]]; then
    [[ -f "$iso" ]] || fatal "ISO file $iso not found"
    if echo "$iso" | grep -q '/turnkey-tkldev'; then
        name="$(echo "$(basename "$iso")" | cut -d'-' -f2)"
    else
        name="$(basename "$iso" .iso)"
    fi
    info "Please wait while the iso is unpacked"
    local_rootfs=$(unpack_iso "$iso" "$name")
    msg="Imported from iso squashfs: $iso"
    deps="$deps isoinfo unsquashfs"
elif [[ -n "$rootfs" ]]; then
    [[ -d "$rootfs" ]] || fatal "Rootfs dir $rootfs not found"
    rootfs=$(realpath "$rootfs")
    if [[ "$rootfs" == "/turnkey/fab/products/"*"build/root."* ]]; then
        name=$(sed -E "s|/turnkey/fab/products/([a-z0-9-]+)/build/root.*|\1|" <<<"$rootfs")
    else
        name=$(mcookie)
        warning "Name can not be determined, using random string, alternatively re-run with -n|--name"
    fi
    info "Please wait while the rootfs is copied"
    local_rootfs=$(cp_rootfs "$rootfs" "$name")
    msg="Imported from rootfs: $rootfs"
    deps="fab"
else
    fatal "Must give either -i|--iso ISO or -r|--rootfs ROOTFS"
fi

missing=''
DOCKER=$(grep -w "docker\|podman" <<<$DOCKER)
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
for dep in $deps; do
    which "$dep" >/dev/null || missing="$missing $dep"
done
[[ -z "$missing" ]] || fatal "Missing dependencies: $missing"

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
        ln -sf $_file $local_rootfs/etc/systemd/system/basic.target.wants/$(basname $_file)
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

info "Please wait while docker container (named tkl/$name) is created"
tar -C "$local_rootfs" -czf - . | $DOCKER import \
    -c 'ENTRYPOINT ["/sbin/init"]' \
    -m "$msg" \
    - \
    "tkl/$name"
