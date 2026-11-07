#!/bin/sh
# nextcloud-webdav.sh — per-user WebDAV mounts for the DigUp server
# (docs/implementation/stage-12-integrations.md §11.7, the WebDAV deployment shape).
#
# WHAT THIS DOES: mounts each Nextcloud user's own WebDAV view
# (<nextcloud>/remote.php/dav/files/<user>/) READ-ONLY on the DigUp server machine, one
# mount per user under <base>/<user>/. Every file under <base>/<user>/ is, by
# construction, a file THAT user can see in Nextcloud (own files + shares + groupfolders)
# — the mount is the ACL. The DigUp server indexes the mount tree read-only; the
# digup_nextcloud app must be set to mapping mode "webdav" with this same base path.
#
# RUN AS ROOT on the DIGUP SERVER machine (the machine with the GPU — not the Nextcloud
# machine; Nextcloud's built-in WebDAV endpoint is the share, it needs no setup at all).
#
# SETUP (once per machine):
#   sudo apt install -y davfs2
#   # davfs2 resolves the mounted tree's owner via getpwuid (measured 2026-11-07:
#   # "can't read user data base" when DAV_UID has no passwd entry on THIS machine):
#   grep -q '^digup:' /etc/passwd || sudo useradd -r -u 990 -M -d /nonexistent digup
# PER USER: an app password (Nextcloud → Settings → Security → Create new app
#   password, or on the Nextcloud machine: occ user:add-app-password <user>).
#
# NOTE: the SHIPPED shape is the compose `dav` mount container (docker-compose.
# nextcloud.yml, --profile dav, stage-12 §11.7) — zero host steps. This script is the
# host-mount ALTERNATIVE for deployments that mount at the OS level (fstab/automount).
#
#   NEXTCLOUD_URL=https://nc.example.lan DAV_USERS="alice bob carol" \
#   DAV_APPPW_ALICE=... DAV_APPPW_BOB=... DAV_APPPW_CAROL=... \
#   sudo -E ./nextcloud-webdav.sh mount
#
#   -e NEXTCLOUD_URL  the Nextcloud base URL (https://… normally; http:// on a pilot)
#   -e DAV_USERS      space-separated Nextcloud user ids to mount
#   -e DAV_APPPW_<UID uppercase>  that user's app password  (one env per user)
#   -e DAV_BASE       mount root            (default /media/dav)
#   -e DAV_UID -e DAV_GID                 (default 990 990 — the server container's user)
#
# Mounts run as davfs2's "daemon" (user=daemon): davfs2 keys its per-mount cache +
# credentials by mount URL + run uid, and a service mount under http needs a system
# account (measured: a plain login uid dies "can't read user data base" unless its
# davfs2 config home exists). The per-user identity lives in the mount URL/path.
# If you mount through this script as a NON-root user, also mark your login user
# "system" in /etc/davfs2/davfs2.conf (davfs2.conf(5)).
#
# Then in deploy/: point the server stack at the mounts (compose header in
# docker-compose.nextcloud.yml, the WebDAV shape) with
#   DIGUP_SERVER_ROOTS=<DAV_BASE>/<user>:<DAV_BASE>/<user2>:…  (one root PER mounted
#   user — measured 2026-11-07: the engine's walk does not cross mount points, a walk
#   rooted AT each dav view works, one walk through <DAV_BASE> sees zero subtrees)
#   DIGUP_MEDIA_TARGET=<DAV_BASE>
#   DIGUP_MEDIA_BIND=<DAV_BASE>   DIGUP_NEXTCLOUD_INDEX_DIR=<an index folder for THIS layout>
# and set the app's settings (Administration settings → DigUp Search) to prefix
# <DAV_BASE> and mapping mode "WebDAV mounts". Then RESTART the server container
# (a FUSE mount made after the container started is invisible to its bind) and index.
#
# Subcommands:
#   mount    (default) create mount dirs, register credentials, mount every user
#   check    per user: mounted? readable? file count visible
#   umount   unmount every user under DAV_BASE (then the server sees 0 files)
#   fstab    print the fstab lines that make the mounts boot-automounted
#            (_netdev,x-systemd.automount) — paste-ready, append to /etc/fstab
#
# Credentials land in root-owned /etc/davfs2/secrets (chmod 600), keyed by mount URL —
# davfs2's own mechanism. Idempotent: re-running updates entries, skips live mounts.
# The mounts are read-only at the mount itself (ro): this machine cannot write through
# them, so the Nextcloud files are safe from this box by construction, not by convention.

set -eu

BASE="${DAV_BASE:-/media/dav}"
UID_RUN="${DAV_UID:-990}"
GID_RUN="${DAV_GID:-990}"
SECRETS=/etc/davfs2/secrets
CMD="${1:-mount}"

die() { echo "FAIL: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run this as root: sudo -E $0 $CMD"

need_env() { [ -n "${NEXTCLOUD_URL:-}" ] || die "NEXTCLOUD_URL is required (e.g. https://nc.example.lan)"; [ "${DAV_USERS:+set}" = set ] || die "DAV_USERS is required (space-separated user ids)"; }
url_of() { echo "${NEXTCLOUD_URL%/}/remote.php/dav/files/$1/"; }

check_davfs2() {
	command -v mount.davfs >/dev/null 2>&1 \
		|| die "davfs2 is not installed — sudo apt install -y davfs2"
}

secret_set() { # $1 url, $2 user, $3 password: replace/append the URL's line, keep 600
	mkdir -p /etc/davfs2
	touch "$SECRETS"; chmod 600 "$SECRETS"
	tmp=$(mktemp)
	grep -v "^$1[[:space:]]" "$SECRETS" >"$tmp" || true
	echo "$1 $2 $3" >>"$tmp"
	cat "$tmp" >"$SECRETS"; rm -f "$tmp"
	chmod 600 "$SECRETS"
}

do_mount() {
	check_davfs2
	mkdir -p "$BASE"
	for u in $DAV_USERS; do
		apppw_var="DAV_APPPW_$(printf '%s' "$u" | tr 'abcdefghijklmnopqrstuvwxyz' 'ABCDEFGHIJKLMNOPQRSTUVWXYZ')"
		apppw=$(printenv "$apppw_var" || true)
		[ -n "$apppw" ] || die "no app password for user '$u' — export $apppw_var=<app password> (create one: occ user:add-app-password $u)"
		url=$(url_of "$u")
		dir="$BASE/$u"
		mkdir -p "$dir"
		secret_set "$url" "$u" "$apppw"
		if mountpoint -q "$dir"; then
			echo "OK  $u already mounted at $dir"
			continue
		fi
		# ro = the Nextcloud files are un-writable through this mount; the uid/gid/
		# mode options put the tree in the server container's hands (uid 990) and
		# nobody else's (0640/0750); noninteractive keeps the script CI-friendly.
		# user=daemon: davfs2 keys its cache/secrets per Mount-point + Run-uid, not
		# per login user — the per-user identity lives in the mount URL/path, and
		# "daemon" is the account davfs2 accepts for a server-daemon mount (a plain
		# service uid with no home dies in its user-data-base preflight; a REAL user
		# is required over https, which this box's app passwords don't need here).
		mount -t davfs "$url" "$dir" \
			-o ro,user=daemon,uid="$UID_RUN",gid="$GID_RUN",dir_mode=0750,file_mode=0640,noninteractive
		echo "OK  mounted $u ($url -> $dir, ro, uid $UID_RUN)"
	done
	echo "NOTE restart the server container after (re)mounting: docker compose restart server"
	echo "NOTE app: prefix $BASE + mapping mode WebDAV; then index (POST /index, admin token)."
}

do_check() {
	for u in $DAV_USERS; do
		dir="$BASE/$u"
		if ! mountpoint -q "$dir"; then
			echo "FAIL $u: not mounted at $dir"
			continue
		fi
		n=$(find "$dir" -type f 2>/dev/null | wc -l)
		if [ "$n" -eq 0 ]; then
			echo "WARN $u: mounted, 0 files visible (app password stale? view empty?)"
		else
			echo "OK  $u: mounted, $n files visible"
		fi
	done
}

do_umount() {
	for u in $DAV_USERS; do
		if mountpoint -q "$BASE/$u"; then
			umount "$BASE/$u" && echo "OK  unmounted $u"
		else
			echo "OK  $u was not mounted"
		fi
	done
	echo "NOTE the server now sees 0 files under $BASE — Test connection says so;"
	echo "NOTE remount + 'docker compose restart server' to recover."
}

do_fstab() {
	echo "# Paste into /etc/fstab (append-only). Auto-mounts on first access after boot."
	for u in $DAV_USERS; do
		echo "$(url_of "$u") $BASE/$u davfs ro,_netdev,x-systemd.automount,uid=$UID_RUN,gid=$GID_RUN,dir_mode=0750,file_mode=0640 0 0"
	done
}

case "$CMD" in
	mount)  need_env; do_mount ;;
	check)  need_env; do_check ;;
	umount) need_env; do_umount ;;
	fstab)  need_env; do_fstab ;;
	*) die "unknown subcommand '$CMD' (mount|check|umount|fstab)" ;;
esac
