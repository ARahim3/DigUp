# The dav mount helper (stage-12 §11.7, the WebDAV shape): davfs2 inside a container,
# so `docker compose --profile dav` sets the WebDAV mounts up behind the scenes — no
# host mount step, no fstab, no host secrets file, no sudo.
#
# privileged + /dev/fuse: davfs2 is a FUSE filesystem driver, and a FUSE mount inside a
# container needs the device and SYS_ADMIN (the standard fuse-in-container shape). The
# container's whole job is mounting the listed dav views at /mnt/dav/<uid> READ-ONLY with
# mount propagation; it serves nothing, binds nothing else.
FROM debian:bookworm-slim

# This box's LAN resolver hiccups for tens of seconds at times (AGENTS.md, measured):
# the bounded retry loop is the standing shape for every network step in this repo.
RUN for i in 1 2 3 4 5 6; do \
        DEBIAN_FRONTEND=noninteractive apt-get update && \
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
            davfs2 tini ca-certificates && break; \
        echo "apt failed (resolver hiccup?), retry $i"; sleep 10; \
    done && rm -rf /var/lib/apt/lists/*

# davfs2 resolves the mounted tree's owner via getpwuid/getgrgid (measured 2026-11-07:
# "can't read user data base" when the uid= owner has no passwd entry in the mounting
# environment). The tree's owner is the server container's user — 990 — so the image
# carries that identity. (Host-mount shape: the HOST needs the same entry — documented
# in nextcloud-webdav.sh.)
RUN groupadd -g 990 digup && useradd -r -u 990 -g 990 -M -d /nonexistent digup

# read-only indexer's davfs2 shape: locks are pointless (nothing writes), dir cache 30 s.
# buf_size 64: the measured 1.7.x read breakage on modern kernels ("reading directory:
# Invalid argument" = Launchpad #2129131, fixed upstream by raising the read buffer;
# this box's kernel 7.0 hits it with the 16 KiB default).
RUN printf 'use_locks 0\ndir_refresh 30\nbuf_size 64\n' >> /etc/davfs2/davfs2.conf

COPY entrypoint.sh /entrypoint.sh
RUN chmod 755 /entrypoint.sh

ENTRYPOINT ["/usr/bin/tini", "--", "/entrypoint.sh"]
