#!/usr/bin/env bash
#
# smartos.nix with an illumos-joyent checkout (illumosCheckout), by evaluation (only gitstatus.json is built, to be
# read): on a throwaway clone of the CHECKOUT given, which must be at the commit the pins name,
#   - a clean checkout at the pinned commit is the same tree as the pinned archive, so nothing changes: the nightly's
#     derivation is the pinned build's;
#   - the illumos build says which commit it is (GATE, joyent_<commit>) and gitstatus.json's illumos-joyent entry
#     names it;
#   - smartos-live's build stamp is left to the time of the build (a stamp names a build of the pins; this is not one
#     whatever smartos-live's state), while its identity is otherwise its own;
#   - a changed tracked file is built (it is in the tree, the commit is <commit>-dirty, the nightly is another);
#   - a tree that is not a git checkout is refused with a message saying so.
#
# usage: illumos-checkout.sh PKGS-ARGS CHECKOUT
#   PKGS-ARGS: a Nix expression for smartos.nix's arguments, e.g. '{ nixpkgs = /work/nixpkgs; }' or '{ }'
#   CHECKOUT: an illumos-joyent clone at the pinned commit (left as it is; the test clones it, shallow clones too)

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
git clone -q --no-local "file://$(cd "$src" && pwd)" "$tmp/il" || { echo "FAIL: cannot clone $src"; exit 1; }
co=$tmp/il
rev=$(git -C "$co" rev-parse HEAD)

# ev EXPR: the string EXPR evaluates to, with pkgs, the package set with the checkout, and pinned, without it
ev() {
	nix eval --raw --impure --expr "
	  let
	    args = $pkgsArgs;
	    pkgs = import $top/smartos.nix (args // { illumosCheckout = $co; });
	    pinned = import $top/smartos.nix args;
	  in $1" 2>"$tmp/eval.log"
}

pin=$(ev 'pinned.smartos-illumos.src.rev')
[ "$pin" = "$rev" ] || { echo "FAIL: CHECKOUT is at $rev, the pins name $pin; give a clone at the pinned commit"; exit 1; }

got=$(ev 'if pkgs.smartos-illumos.nightly.drvPath == pinned.smartos-illumos.nightly.drvPath then "same" else "differs"')
[ "$got" = same ] && ok "a clean checkout at the pinned commit changes nothing (the nightly's derivation is the pinned one's)" ||
	{ bad "a clean checkout at the pinned commit: the nightly's derivation $got"; tail -3 "$tmp/eval.log"; }

got=$(ev 'pkgs.smartos-illumos.src.rev')
[ "$got" = "$rev" ] && ok "the illumos build names the checkout's commit (GATE joyent_$rev)" ||
	{ bad "illumos src.rev: '$got', want $rev"; tail -3 "$tmp/eval.log"; }

got=$(ev 'builtins.readFile pkgs.smartos-live.platformGitstatus' | grep -A4 '"repo": "illumos-joyent"')
echo "$got" | grep -F "\"rev\": \"$rev\"" >/dev/null && ok "gitstatus.json's illumos-joyent entry names the checkout's commit" ||
	{ bad "illumos-joyent entry: '$got'"; tail -3 "$tmp/eval.log"; }

got=$(ev 'with pkgs.smartos-live.identity; "stamp=${toString stamp} kind=${kind} same-rev=${if rev == pinned.smartos-live.identity.rev then "yes" else "no"}"')
[ "$got" = "stamp= kind=$(ev 'pinned.smartos-live.identity.kind') same-rev=yes" ] &&
	ok "smartos-live's stamp is left to the build's time; its identity is otherwise its own" ||
	{ bad "smartos-live identity with an illumos checkout: '$got'"; tail -3 "$tmp/eval.log"; }

mkdir "$tmp/nogit" && git -C "$co" archive HEAD usr/src/Makefile | (cd "$tmp/nogit" && tar xf - 2>/dev/null)
got=$(nix eval --raw --impure --expr "(import $top/smartos.nix ($pkgsArgs // { illumosCheckout = $tmp/nogit; })).smartos-illumos.src.outPath" 2>&1)
echo "$got" | grep -F "is not a git checkout" >/dev/null &&
	ok "a tree that is not a git checkout is refused, saying so" || bad "a tree without .git: $(echo "$got" | tail -3)"

echo "# a change" >>"$co/usr/src/Makefile"
got=$(ev 'pkgs.smartos-illumos.src.rev')
[ "$got" = "$rev-dirty" ] && ok "a changed tracked file: the commit is $rev-dirty" ||
	{ bad "dirty src.rev: '$got', want $rev-dirty"; tail -3 "$tmp/eval.log"; }
got=$(ev 'if pkgs.smartos-illumos.nightly.drvPath == pinned.smartos-illumos.nightly.drvPath then "same" else "differs"')
[ "$got" = differs ] && ok "a changed tracked file: the nightly is another derivation" ||
	{ bad "a changed tracked file: the nightly's derivation is $got"; tail -3 "$tmp/eval.log"; }
got=$(ev 'builtins.readFile "${pkgs.smartos-illumos.src.src}/usr/src/Makefile"')
echo "$got" | grep -F "# a change" >/dev/null && ok "a changed tracked file: the change is in the tree" ||
	{ bad "the change is not in the illumos tree"; tail -3 "$tmp/eval.log"; }

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
