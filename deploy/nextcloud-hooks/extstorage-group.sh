#!/bin/sh
# Container-local fix for the extstorage bind: apache workers run as www-data and
# Apache calls initgroups() for the configured User, so the web process reads a
# group-restricted host tree only if www-data holds that group in the container's
# /etc/group. Create the group with the tree's gid (DIGUP_NEXTCLOUD_EXTSTORAGE_GID,
# default 1000) and add www-data to it. Nothing on the host tree changes.
gid="${DIGUP_NEXTCLOUD_EXTSTORAGE_GID:-1000}"
if ! getent group "$gid" >/dev/null; then
	groupadd -g "$gid" extstorage
fi
usermod -aG extstorage www-data 2>/dev/null || true
exit 0
