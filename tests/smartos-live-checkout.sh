#!/usr/bin/env bash
#
# smartos.nix with a smartos-live checkout (smartosLiveCheckout), as smartos-live's own default.nix gives it, by
# evaluation (only gitstatus.json is built, to be read): on a throwaway clone of the CHECKOUT given, at its commit,
#   - smartos-live's tree is the checkout's: its tracked files, with deps/eng (the submodule's place, empty, as in
#     GitHub's archive of a commit), so a change to a tracked file reaches the stages built from it;
#   - the build's identity is the checkout's: clean at its commit (that commit, its time as the stamp), dirty with a
#     changed tracked file;
#   - gitstatus.json's smartos-live entry is the checkout's commit, and the platform's names no nixpkgs-illumos
#     commit (smartos-live is what was checked out);
#   - without smartosLiveCheckout, smartos-live is the pinned commit.
#
# usage: smartos-live-checkout.sh PKGS-ARGS CHECKOUT
#   PKGS-ARGS: a Nix expression for smartos.nix's arguments, e.g. '{ nixpkgs = /work/nixpkgs; }' or '{ }'
#   CHECKOUT: a smartos-live clone (left as it is; the test clones it)

set -uo pipefail

pkgsArgs=${1:?usage: $0 PKGS-ARGS CHECKOUT}
src=${2:?usage: $0 PKGS-ARGS CHECKOUT}
top="$(cd "$(dirname "$0")/.." && pwd)"
tmp=$(mktemp -d)
trap 'cd / && rm -rf "$tmp"' EXIT

pass=0 fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git clone -q --no-local "$src" "$tmp/sl" || { echo "FAIL: cannot clone $src"; exit 1; }
co=$tmp/sl
rev=$(git -C "$co" rev-parse HEAD)
stamp=$(TZ=UTC git -C "$co" log -1 --date=format-local:%Y%m%dT%H%M%SZ --format=%cd)

# ev EXPR: the string EXPR evaluates to, with live, the smartos-live scope from the checkout, and pinned, without it;
# evb EXPR: a boolean's, as true or false
ev() {
	nix eval --raw --impure --expr "
	  let
	    args = $pkgsArgs;
	    live = (import $top/smartos.nix (args // { smartosLiveCheckout = $co; })).smartos-live;
	    pinned = (import $top/smartos.nix args).smartos-live;
	  in $1" 2>"$tmp/eval.log"
}
evb() { ev "if ($1) then \"true\" else \"false\""; }

got=$(evb 'builtins.pathExists "${live.smartosLive}/tools/build_live" && builtins.pathExists "${live.smartosLive}/deps/eng" && !(builtins.pathExists "${live.smartosLive}/.git")')
[ "$got" = true ] && ok "smartos-live's tree is the checkout's, with deps/eng and without .git" ||
	{ bad "smartos-live's tree: $got"; tail -3 "$tmp/eval.log"; }

got=$(ev 'with live.identity; "${kind} ${rev} ${stamp}"')
[ "$got" = "clean $rev $stamp" ] && ok "a clean checkout's identity: its commit and stamp ($stamp)" ||
	{ bad "clean identity: '$got', want 'clean $rev $stamp'"; tail -3 "$tmp/eval.log"; }

got=$(ev 'builtins.readFile live.platformGitstatus')
if echo "$got" | grep -A3 '"repo": "smartos-live"' | grep -F "\"rev\": \"$rev\"" >/dev/null &&
	! echo "$got" | grep -F '"repo": "nixpkgs-illumos"' >/dev/null; then
	ok "gitstatus.json names the checkout's commit for smartos-live, and no nixpkgs-illumos commit"
else
	bad "gitstatus.json: $got"; tail -3 "$tmp/eval.log"
fi

pin=$(ev 'pinned.pins.smartos-live.rev')
got=$(evb 'pinned.smartosLive == pinned.fetchPin "smartos-live"')
[ "$got" = true ] && [ -n "$pin" ] && ok "without a checkout, smartos-live is the pinned commit ($pin)" ||
	{ bad "without a checkout: $got"; tail -3 "$tmp/eval.log"; }

echo "# a change" >>"$co/tools/build_live"
got=$(ev 'with live.identity; "${kind} ${rev}"')
[ "$got" = "dirty $rev-dirty" ] && ok "a changed tracked file makes the identity dirty" ||
	{ bad "dirty identity: '$got', want 'dirty $rev-dirty'"; tail -3 "$tmp/eval.log"; }
got=$(ev 'builtins.readFile "${live.smartosLive}/tools/build_live"')
echo "$got" | grep -F "# a change" >/dev/null && ok "the change is in smartos-live's tree" ||
	{ bad "the change is not in smartos-live's tree"; tail -3 "$tmp/eval.log"; }

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
