#!/bin/sh
# Build a size-reduced Tailscale for OpenWrt and bundle it with the
# OpenWrt init script and config.
#
# Usage: ./build.sh <version> [goarch]
#   ./build.sh 1.102.4          # arm64 (e.g. MediaTek Filogic, Cudy WR3000)
#   GOMIPS=softfloat ./build.sh 1.102.4 mips
set -eu

VERSION=${1:?usage: $0 <version> [goarch]}
GOARCH=${2:-arm64}
# Minimal feature set that works as an OpenWrt subnet router
# (from the OpenWrt wiki guide for storage-constrained devices).
FEATURES=osrouter,cli,unixsocketidentity,netstack,ipnbus,health,gro,listenrawdisco,portlist,advertiseroutes,useroutes

ROOT=$(cd "$(dirname "$0")" && pwd)
SRC=$ROOT/build/tailscale-$VERSION
STAGE=$ROOT/build/stage-$VERSION-$GOARCH
BUNDLE=$ROOT/dist/tailscale-$VERSION-$GOARCH.tar.gz

command -v upx >/dev/null || { echo "upx not found (brew install upx)" >&2; exit 1; }

if [ ! -d "$SRC" ]; then
	git clone --quiet --depth 1 --branch "v$VERSION" \
		https://github.com/tailscale/tailscale.git "$SRC"
fi

cd "$SRC"
eval "$(TS_USE_TOOLCHAIN=1 ./build_dist.sh shellvars)"
TAGS=$(./tool/go run ./cmd/featuretags --min --add="$FEATURES")
env GOOS=linux GOARCH="$GOARCH" CGO_ENABLED=0 ./tool/go build \
	-o tailscaled -tags "$TAGS" -trimpath \
	-ldflags="-s -w -X tailscale.com/version.longStamp=$VERSION_LONG -X tailscale.com/version.shortStamp=$VERSION_SHORT" \
	./cmd/tailscaled

rm -rf "$STAGE"
mkdir -p "$STAGE/usr/sbin" "$STAGE/etc/init.d" "$STAGE/etc/config" "$ROOT/dist"
cp tailscaled "$STAGE/usr/sbin/tailscaled"
upx -q --lzma --best "$STAGE/usr/sbin/tailscaled" >/dev/null
upx -q -t "$STAGE/usr/sbin/tailscaled" >/dev/null
ln -s tailscaled "$STAGE/usr/sbin/tailscale"
install -m 755 "$ROOT/files/tailscale.init" "$STAGE/etc/init.d/tailscale"
install -m 644 "$ROOT/files/tailscale.conf" "$STAGE/etc/config/tailscale"

if tar --version 2>/dev/null | grep -q bsdtar; then
	OWNER="--uid 0 --gid 0"
else
	OWNER="--owner=0 --group=0"
fi
# shellcheck disable=SC2086
COPYFILE_DISABLE=1 tar $OWNER -czf "$BUNDLE" -C "$STAGE" usr etc

echo "raw:    $(wc -c < tailscaled) bytes"
echo "packed: $(wc -c < "$STAGE/usr/sbin/tailscaled") bytes"
echo "bundle: $BUNDLE"
