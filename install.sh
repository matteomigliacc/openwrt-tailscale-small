#!/bin/sh
# Install or update the size-reduced Tailscale bundle on OpenWrt.
# Run on the router: sh install.sh /tmp/tailscale-<version>-<arch>.tar.gz
set -e

BUNDLE=${1:?usage: sh install.sh /tmp/tailscale-<version>-<arch>.tar.gz}
# JFFS2 misbehaves when completely full; keep some space free.
RESERVE_KB=256

rm -rf /tmp/tsroot && mkdir /tmp/tsroot
tar -xzf "$BUNDLE" -C /tmp/tsroot

new_kb=$(( $(wc -c < /tmp/tsroot/usr/sbin/tailscaled) / 1024 + 1 ))
old_kb=0
[ -f /usr/sbin/tailscaled ] && old_kb=$(( $(wc -c < /usr/sbin/tailscaled) / 1024 ))
free_kb=$(df -k /overlay | awk 'NR==2 {print $4}')
if [ $((free_kb + old_kb)) -lt $((new_kb + RESERVE_KB)) ]; then
	echo "Not enough space: need $((new_kb + RESERVE_KB))K, have $((free_kb + old_kb))K" >&2
	rm -rf /tmp/tsroot
	exit 1
fi

# Updating: stop the old daemon and delete its binary first to free the space.
[ -x /etc/init.d/tailscale ] && /etc/init.d/tailscale stop || true
rm -f /usr/sbin/tailscaled

cp /tmp/tsroot/usr/sbin/tailscaled /usr/sbin/tailscaled
ln -sf tailscaled /usr/sbin/tailscale
cp /tmp/tsroot/etc/init.d/tailscale /etc/init.d/tailscale
[ -f /etc/config/tailscale ] || cp /tmp/tsroot/etc/config/tailscale /etc/config/tailscale
mkdir -p /etc/tailscale
rm -rf /tmp/tsroot
# update.sh ships next to install.sh in releases
if [ -f "$(dirname "$0")/update.sh" ]; then
	cp "$(dirname "$0")/update.sh" /usr/sbin/tailscale-update
	chmod 755 /usr/sbin/tailscale-update
fi

# Keep the manual install across firmware upgrades (/etc/config is kept anyway).
for f in /usr/sbin/tailscaled /usr/sbin/tailscale /usr/sbin/tailscale-update /etc/init.d/tailscale /etc/rc.d/S80tailscale /etc/tailscale/; do
	grep -qxF "$f" /etc/sysupgrade.conf || echo "$f" >> /etc/sysupgrade.conf
done

# Network interface + firewall zone so tailnet traffic may reach the LAN.
reload=0
if ! uci -q get network.tailscale >/dev/null; then
	uci set network.tailscale=interface
	uci set network.tailscale.proto='none'
	uci set network.tailscale.device='tailscale0'
	uci commit network
	reload=1
fi
if ! uci show firewall | grep -q "name='tailscale'"; then
	z=$(uci add firewall zone)
	uci set firewall.$z.name='tailscale'
	uci set firewall.$z.input='ACCEPT'
	uci set firewall.$z.output='ACCEPT'
	uci set firewall.$z.forward='ACCEPT'
	uci add_list firewall.$z.network='tailscale'
	f=$(uci add firewall forwarding)
	uci set firewall.$f.src='tailscale'
	uci set firewall.$f.dest='lan'
	f=$(uci add firewall forwarding)
	uci set firewall.$f.src='lan'
	uci set firewall.$f.dest='tailscale'
	uci commit firewall
	reload=1
fi

/etc/init.d/tailscale enable
/etc/init.d/tailscale start
if [ "$reload" = 1 ]; then
	sleep 5
	/etc/init.d/network reload
	/etc/init.d/firewall reload
fi

tailscale version | head -1
df -h /overlay
if [ ! -s /etc/tailscale/tailscaled.state ]; then
	echo "First install - now run: tailscale up --advertise-routes=<lan-subnet> --accept-dns=false"
fi
