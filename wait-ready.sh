#!/bin/bash

CONT_ID="$1"
MAX_COUNT=${MAX_COUNT:-40}

if [[ -z $CONT_ID ]]; then
    echo "usage: $0 <container-id>" >&2
    exit 1
fi

COM=

if command -v docker; then
    COM=docker
elif command -v podman; then
    COM=podman
else
    echo "requires either docker or podman" >&2
    exit 1
fi

count=0
while true; do
    if ((count > $MAX_COUNT)); then
        echo "didn't start in time" >&2
        exit 1
    fi
    ((count++))
    if "$COM" exec "$("$COM" ps | grep tkl/ | cut -d' ' -f1)" grep 'run completed' /var/log/inithooks.log; then
        exit 0
    fi
    echo "-"
    sleep 10
done
