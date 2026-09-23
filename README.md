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

Watch the [security bulletins](https://tailscale.com/security-bulletins) - the
admin console also flags outdated nodes. Then:

```sh
git ls-remote --tags https://github.com/tailscale/tailscale.git 'v1.*' | tail
./build.sh <new-version>
scp -O dist/tailscale-<new-version>-arm64.tar.gz install.sh root@192.168.1.1:/tmp/
# on the router:
sh /tmp/install.sh /tmp/tailscale-<new-version>-arm64.tar.gz
```

`apk upgrade` does **not** update this build.

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
F=/etc/apk/repositories.d/customfeeds.list; sed -i 's|^\(.*eamonxg.*\)$|#\1|' $F && owut upgrade --remove luci-theme-aurora,luci-app-aurora-config,luci-theme-shadcn --add kmod-tun,luci-app-sqm,luci-app-nlbwmon,luci-app-wol --force; sed -i 's|^#\(.*eamonxg.*\)$|\1|' $F
```

`--force` only accepts the `luci-mod-dashboard` downgrade caused by that feed;
check `owut check` output first. The Tailscale files are restored from
`/etc/sysupgrade.conf` after the upgrade.

`tailscale up` warns that UDP GRO forwarding is suboptimal on `wan`; fixing it
needs `ethtool` (no space), and it only affects throughput.
