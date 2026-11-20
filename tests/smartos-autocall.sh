#!/usr/bin/env bash
#
# smartos.nix as its header and build-smartos use it, without arguments (nix-build smartos.nix -A ATTR, which calls it
# with none), and with one given as nix-build gives them (--arg): both evaluate, the same.
#
# usage: smartos-autocall.sh   (nix on PATH; evaluation only)

set -uo pipefail

top="$(cd "$(dirname "$0")/.." && pwd)"

pass=0 fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

if a=$(nix-instantiate "$top/smartos.nix" -A smartos-live.builderTools 2>&1); then
    ok "nix-instantiate smartos.nix -A ATTR, with no arguments"
else
    bad "smartos.nix with no arguments: $(echo "$a" | tail -2)"
fi
if b=$(nix-instantiate "$top/smartos.nix" -A smartos-live.builderTools --arg config '{ }' 2>&1) && [ "$a" = "$b" ]; then
    ok "and with --arg config, the same"
else
    bad "smartos.nix with --arg config: $(echo "$b" | tail -2)"
fi

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
