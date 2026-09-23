# openwrt-tailscale-small

A size-reduced Tailscale build for OpenWrt routers with small flash, used on a
**Cudy WR3000 v1** (16 MB flash, OpenWrt 25.12) as a subnet router.

The official OpenWrt `tailscale` package is ~10 MB compressed / ~30 MB
installed, which does not fit on 16 MB-flash devices, not even when baked into
the firmware image with `owut`/ASU (the build server rejects it:
`20447236 > 15794176` bytes). This project follows the OpenWrt wiki method
([Installing Tailscale on storage constrained devices](https://openwrt.org/docs/guide-user/services/vpn/tailscale/start#installing_tailscale_on_storage_constrained_devices)):
compile Tailscale with only the features a router needs, strip it and pack it
with UPX.

| Build | Size |
|---|---|
| Official OpenWrt package (installed) | ~30 MB |
| Minimal feature set, stripped | ~16 MB |
| + UPX `--lzma --best` | **~4.2 MB** (1.102.4, arm64) |

## Requirements

On the build machine (macOS or Linux):

- `git`, `go` (the build uses Tailscale's own Go toolchain via `./tool/go`)
- `upx` 5.x (`brew install upx`) - UPX 3.96 produces broken MIPS binaries

On the router:

- `kmod-tun` and `ca-bundle` (dependencies of the official package)
- ~4.5 MB free on `/overlay` (`df -h /overlay`)
- ~60 MB free RAM (UPX unpacks the binary into memory, plus Tailscale's own usage)

## Build

```sh
./build.sh 1.102.4          # arm64 (MediaTek Filogic etc.)
GOMIPS=softfloat ./build.sh 1.102.4 mips
```

Output: `dist/tailscale-<version>-<arch>.tar.gz` containing
`/usr/sbin/tailscaled` (packed), the `tailscale` symlink, and the init
script/config from [openwrt/packages](https://github.com/openwrt/packages/tree/openwrt-25.12/net/tailscale/files)
(`files/`).

Check the router's architecture with `ubus call system board` or
`apk --print-arch` (`aarch64_cortex-a53` → `arm64`).

## Install / update

From the Mac (the router's dropbear has no SFTP, so `scp` needs `-O`):

```sh
scp -O dist/tailscale-1.102.4-arm64.tar.gz install.sh root@192.168.1.1:/tmp/
```

On the router:

```sh
sh /tmp/install.sh /tmp/tailscale-1.102.4-arm64.tar.gz
```

`install.sh` works for both first install and updates. It:

1. checks there is enough space (keeps 256 KB free, since JFFS2 misbehaves when full)
2. stops the running daemon and replaces the binary
3. adds the files to `/etc/sysupgrade.conf` so they survive firmware upgrades
4. creates a `tailscale` network interface and firewall zone (forwarding to/from `lan`) if missing
5. enables and starts the service

First install only, then log in via the printed URL:

```sh
tailscale up --advertise-routes=192.168.1.0/24 --accept-dns=false
```

In the [admin console](https://login.tailscale.com/admin/machines):

- approve the advertised route (Edit route settings)
- **disable key expiry**, or the router silently drops off after ~6 months

## Updating Tailscale

`apk upgrade` does **not** update this build.

### Automatic builds

[`.github/workflows/build.yml`](.github/workflows/build.yml) runs daily. When
[tailscale/tailscale](https://github.com/tailscale/tailscale/releases) has a
newer stable release than this repo, it builds it and publishes a release here
with `tailscale-arm64.tar.gz`, `install.sh`, `update.sh` and `SHA256SUMS`.
Watch this repo's releases (Watch → Custom → Releases) to get notified.
A specific version can be built via Actions → Build Tailscale → Run workflow.

GitHub disables scheduled workflows after 60 days without repo activity; it
emails a warning and can be re-enabled from the Actions tab.

### On the router

`install.sh` installs `update.sh` as `/usr/sbin/tailscale-update`. It compares
the running version with the latest release, downloads the bundle, verifies
the checksums, and runs `install.sh`:

```sh
tailscale-update
```

This is deliberately manual: writing 4 MB to a nearly full JFFS2 flash takes a
minute or two, and the router's Tailscale is offline meanwhile.

### Manual build

```sh
./build.sh <new-version>
scp -O dist/tailscale-<new-version>-arm64.tar.gz install.sh update.sh root@192.168.1.1:/tmp/
# on the router:
sh /tmp/install.sh /tmp/tailscale-<new-version>-arm64.tar.gz
```

## Features left out

The build uses `featuretags --min` plus
`osrouter,cli,unixsocketidentity,netstack,ipnbus,health,gro,listenrawdisco,portlist,advertiseroutes,useroutes`.
Notably missing:

- **Tailscale SSH** (also avoids TS-2026-009/010)
- **Tailnet Lock** - `tailscale up` prints "tailnet lock is not supported by
  this binary"; harmless unless Tailnet Lock is enabled on the tailnet
- exit node advertising, MagicDNS/DNS config, Taildrop, web client, iptables
  (OpenWrt 25.12 uses nftables, handled by `osrouter`)

Dropping `netstack`, `gro` or `portlist` saves almost nothing (<30 KB packed).

## Notes for this router (Cudy WR3000 v1)

To make room, the firmware was rebuilt without the 3.4 MB `nextdns` package
(NextDNS is configured on the clients and in Tailscale instead), with small
extras baked into the image so they don't use overlay space. The third-party
theme feed (`/etc/apk/repositories.d/customfeeds.list`) is rejected by the ASU
build server, so firmware upgrades temporarily comment it out:

```sh
F=/etc/apk/repositories.d/customfeeds.list
R=luci-theme-aurora,ppp,ppp-mod-pppoe,kmod-ppp,kmod-pppoe,kmod-pppox,kmod-slhc,collectd,collectd-mod-cpu,collectd-mod-interface,collectd-mod-iwinfo,collectd-mod-load,collectd-mod-memory,collectd-mod-network,collectd-mod-rrdtool,luci-app-statistics
sed -i 's|^\(.*eamonxg.*\)$|#\1|' $F && owut upgrade --remove $R; sed -i 's|^#\(.*eamonxg.*\)$|\1|' $F
# afterwards, reinstall the theme:
wget -qO- https://openwrt.eamonxg.fun/install.sh | PKGS="luci-theme-aurora" YES=1 sh
```

The image keeps `kmod-tun` (Tailscale), SQM, nlbwmon, Wake-on-LAN and
`luci-mod-rpc` (Home Assistant LuCI integration), and leaves out PPPoE (WAN is
DHCP) and the collectd graphs, saving ~500 KB. Run `owut check` with the
same flags first; if it reports a downgrade, look at it before adding
`--force`. The Tailscale files are restored from `/etc/sysupgrade.conf` after
the upgrade.

Only install packages with `apk add` if they are small: `/overlay` is ~5 MB
and Tailscale uses 4.1 MB of it. LuCI's Wake on LAN page offers an
"Install wakeonlan" button that pulls in Perl (several MB) and fills the
flash. Don't use it; `etherwake` is the built-in tool.

`tailscale up` warns that UDP GRO forwarding is suboptimal on `wan`; fixing it
needs `ethtool` (no space), and it only affects throughput.
