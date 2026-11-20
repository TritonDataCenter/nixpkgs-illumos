#!/usr/bin/env bash
#
# zone/system.nix's extraPackages: a zone's own packages join its system profile, and an SMF manifest one carries at
# lib/svc/manifest/site/ is in the profile where zone/illumos-rebuild imports it; without them the profile is the
# one it was.
#
# usage: system-extra-packages.sh /etc/nixos/pkgs.nix

set -uo pipefail

pkgsFile=${1:?usage: $0 /path/to/pkgs.nix}
top="$(cd "$(dirname "$0")/.." && pwd)"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

pass=0 fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

cat >"$tmp/system.nix" <<NIX
let
  pkgs = import $pkgsFile;
  smf = import $top/zone/smf-lib.nix { inherit pkgs; };
  extra = smf.mkSmfManifestBundle {
    manifests = [
      (smf.mkSmfManifest {
        name = "extra-packages-test";
        category = "site";
        description = "extraPackages test";
        start.exec = "/usr/bin/true";
        duration = "transient";
      })
    ];
  };
in
{
  withExtra = import $top/zone/system.nix { inherit pkgs; extraPackages = [ extra pkgs.hello ]; };
  without = import $top/zone/system.nix { inherit pkgs; };
  empty = import $top/zone/system.nix { inherit pkgs; extraPackages = [ ]; };
}
NIX

if sys=$(nix-build --no-out-link "$tmp/system.nix" -A withExtra 2>"$tmp/build.err"); then
    ok "a system profile with extraPackages builds"
else
    bad "a system profile with extraPackages does not build"; sed 's/^/    /' "$tmp/build.err"; exit 1
fi

[ -f "$sys/lib/svc/manifest/site/extra-packages-test.xml" ] &&
    grep -q "name='site/extra-packages-test'" "$sys/lib/svc/manifest/site/extra-packages-test.xml" &&
    ok "an extra package's SMF manifest is in the profile's lib/svc/manifest/site/" ||
    bad "no extra-packages-test.xml in $sys/lib/svc/manifest/site/: $(ls "$sys/lib/svc/manifest/site/" 2>&1)"

[ -f "$sys/lib/svc/manifest/site/nix-daemon.xml" ] && ok "nix-daemon's manifest is still there" ||
    bad "nix-daemon.xml is gone"

"$sys/bin/hello" >"$tmp/hello" 2>&1 && grep -q "Hello, world!" "$tmp/hello" &&
    ok "an extra package's programs are in the profile's bin/" || bad "hello: $(cat "$tmp/hello")"

drv() { nix-instantiate "$tmp/system.nix" -A "$1" 2>/dev/null; }
[ -n "$(drv without)" ] && [ "$(drv without)" = "$(drv empty)" ] &&
    ok "no extraPackages and an empty list are the same profile" || bad "without: $(drv without), empty: $(drv empty)"

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
