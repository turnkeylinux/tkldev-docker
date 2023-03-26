# NOTE

This is a tool for internal use.

It is not ready for general purpose use yet. Please do not file issues if it doesn't work.

Using TKLDev in a VM or on bare metal and running appliances in a VM or on bare metal is the only supported way to build and run built appliances for now.

# tkl-dockerize

This is a generic script to turn TurnKey Linux .iso images into Docker images.

For TKLDev to run properly, it needs to be running with a non-overlayfs mount at the .deck of whatever appliances you intend to build (or upper in the filesystem, e. g. at `/turnkey/fab/products` which allows you to persist products across TKLDev versions).

Moreover, to simulate "normal" startup via spawning systemd, some filesystems need to be mounted inside the container.  TKLDev needs the `SYS_ADMIN` capability to be added because `deck` wants to use `mount` which is not permitted unless this capability is present. However, for appliance products, if the proper filesystems are mounted when starting the container, the container itself need not be privileged.

Therefore:

```shell
$ sudo ./dockerize.sh /path/to/turnkey-tkldev-17.1-bullseye-amd64.iso
$ docker run -it --name tkldev --cap-add=SYS_ADMIN -v ~/products:/turnkey/fab/products --tmpfs /tmp --tmpfs /run --tmpfs /run/lock -v /sys/fs/cgroup:/sys/fs/cgroup tkl/tkldev 
$ docker exec -it tkldev bash
# turnkey-init
```

And after using the TKLDev instance created above to build products as usual:

```shell
$ mv product.iso core.iso # so the script knows what it's dealing with
$ sudo ./dockerize.sh core.iso
$ docker run -it --tmpfs /tmp --tmpfs /run -v /sys/fs/cgroup:/sys/fs/cgroup:ro tkl/core
$ docker run --rm -it --tmpfs /tmp --tmpfs /run --tmpfs /run/lock -v /sys/fs/cgroup:/sys/fs/cgroup -v /sys/fs/cgroup/systemd:/sys/fs/cgroup/systemd tkl/core
```

TODO: Improve the systemd experience

TODO: Drop some privileges?
