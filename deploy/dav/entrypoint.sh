#!/bin/sh
# dav mount entrypoint (the dav/Dockerfile image): keep every listed user's dav view
# mounted READ-ONLY at /mnt/dav/<uid>/, self-healing. Compose env (docker-compose.nextcloud.yml):
#
#   NEXTCLOUD_URL  the Nextcloud base URL (http://nextcloud inside the compose network)
#   DAV_USERS      space-separated user ids
#   DAV_APPPW      space-separated "user:app-password" pairs (occ user:add-app-password <user>)
#   DAV_UID/DAV_GID  owner of the mounted tree (default 990 = the server container's user)
#   DAV_CA         optional: PEM text of a trusted self-signed server certificate (https)
#
# Credentials go to the container's /etc/davfs2/secrets (root, 600) — they ride the
# compose env chain, never a host file. Graceful stop unmounts everything (trap).
set -eu

BASE=/mnt/dav
UID_M="${DAV_UID:-990}"
GID_M="${DAV_GID:-990}"
SECRETS=/etc/davfs2/secrets

[ -n "${NEXTCLOUD_URL:-}" ] || { echo "FAIL NEXTCLOUD_URL is required"; exit 1; }
[ -n "${DAV_USERS:-}" ]     || { echo "FAIL DAV_USERS is required"; exit 1; }
[ -n "${DAV_APPPW:-}" ]     || { echo "FAIL DAV_APPPW is required (user:app-password pairs)"; exit 1; }

url_of() { echo "${NEXTCLOUD_URL%/}/remote.php/dav/files/$1/"; }
pw_of() { for p in $DAV_APPPW; do [ "${p%%:*}" = "$1" ] && { echo "${p#*:}"; return; }; done; }

cleanup() {
	for u in $DAV_USERS; do umount "$BASE/$u" 2>/dev/null || true; done
	echo "OK all dav views unmounted (graceful stop)"
	exit 0
}
trap cleanup TERM INT

# credentials: rebuild the secrets file from the pairs on every boot (600, root)
tmp=$(mktemp)
for u in $DAV_USERS; do
	pw=$(pw_of "$u" || true)
	[ -n "$pw" ] || { echo "FAIL no app password pair for user '$u' in DAV_APPPW"; exit 1; }
	echo "$(url_of "$u") $u $pw" >>"$tmp"
done
mkdir -p /etc/davfs2/certs
cat "$tmp" >"$SECRETS"; rm -f "$tmp"; chmod 600 "$SECRETS"

# self-signed https: the operator pastes the server cert (PEM) — davfs2's own trust knob
if [ -n "${DAV_CA:-}" ]; then
	printf '%s\n' "$DAV_CA" >/etc/davfs2/certs/trusted.pem
	chmod 600 /etc/davfs2/certs/trusted.pem
	printf '%s\n' "trust_server_cert trusted.pem" >>/etc/davfs2/davfs2.conf
fi

mkdir -p "$BASE"
echo "dav mount helper up: users='$DAV_USERS' base=$BASE owner=$UID_M:$GID_M ro"

while :; do
	for u in $DAV_USERS; do
		d="$BASE/$u"
		mkdir -p "$d"
		mountpoint -q "$d" && continue
		if mount -t davfs "$(url_of "$u")" "$d" \
			-o "ro,uid=$UID_M,gid=$GID_M,dir_mode=0750,file_mode=0640,noninteractive"; then
			echo "OK mounted $u ($(url_of "$u") -> $d, ro, uid $UID_M)"
		else
			echo "WARN mount failed for $u — retrying in 30 s (Nextcloud reachable? app password?)"
		fi
	done
	sleep 30
done
