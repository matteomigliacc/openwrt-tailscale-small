#!/bin/sh
# Update Tailscale on the router from the latest release of this repo.
# Installed as /usr/sbin/tailscale-update by install.sh.
set -e

REPO=matteomigliacc/openwrt-tailscale-small
ARCH=arm64
BASE=https://github.com/$REPO/releases/latest/download

latest=$(wget -qO- "https://api.github.com/repos/$REPO/releases/latest" | jsonfilter -e '@.tag_name')
current=v$(tailscale version | head -1)
if [ -z "$latest" ]; then
	echo "Could not look up the latest release" >&2
	exit 1
fi
if [ "$latest" = "$current" ]; then
	echo "Already up to date ($current)"
	exit 0
fi
echo "Updating $current -> $latest"

rm -rf /tmp/ts-update && mkdir /tmp/ts-update && cd /tmp/ts-update
for f in "tailscale-$ARCH.tar.gz" install.sh update.sh SHA256SUMS; do
	wget -qO "$f" "$BASE/$f"
done
grep -E " (tailscale-$ARCH.tar.gz|install.sh|update.sh)\$" SHA256SUMS | sha256sum -c -

sh ./install.sh "/tmp/ts-update/tailscale-$ARCH.tar.gz"
cd / && rm -rf /tmp/ts-update
