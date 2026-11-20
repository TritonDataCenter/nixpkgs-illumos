#!/usr/bin/env bash
#
# smartos-live.srcWorkspace's smartos-src-workspace on a smartos-live checkout, as a developer builds src in place:
# build fills the checkout's proto with the illumos build's proto area and illumos-extra's packages (the store's, as
# 0-extra-stamp installs them) and builds src and man into it: a C program (bootparams), node add-ons against
# illumos-extra's node (kstat), with what npm fetches (fs-ext by git, nan from the registry for dtrace-provider), and a
# man page made by ronn.js; the checkout's tracked files are as they were and what it made is ignored; a rebuild after
# a change to one source remakes that program; a directory that is not a smartos-live checkout is refused.
#
# usage: src-workspace.sh CHECKOUT PKGS   (CHECKOUT: a git clone of smartos-live for testing, its proto made and one
#                                          tracked file changed and put back; PKGS: a file evaluating to the package
#                                          set; /opt/local/bin/python2.7 there, as the tool asks; network for npm)

set -uo pipefail

checkout=$(cd "${1:?usage: $0 CHECKOUT PKGS}" && pwd)
pkgsFile=${2:?usage: $0 CHECKOUT PKGS}
tmp=$(mktemp -d)
trap 'git -C "$checkout" checkout -q -- src/bootparams.c 2>/dev/null; rm -rf "$tmp"' EXIT

pass=0 fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

if w=$(nix-build --no-out-link -E "(import $pkgsFile).smartos-live.srcWorkspace" 2>"$tmp/build.err"); then
    ok "smartos-live.srcWorkspace builds"
else
    bad "smartos-live.srcWorkspace does not build"; sed 's/^/    /' "$tmp/build.err"; echo "$pass passed, $fail failed"; exit 1
fi
sw=$w/bin/smartos-src-workspace

before=$(git -C "$checkout" status --porcelain)
if "$sw" "$checkout" build >"$tmp/build.log" 2>&1; then
    ok "build succeeds"
else
    bad "build: $(tail -15 "$tmp/build.log")"
fi

p=$checkout/proto
[ -f "$p/platform/i86pc/kernel/amd64/unix" ] && [ -f "$p/usr/include/expat.h" ] && [ -f "$p/usr/node/0.10/include/node/node.h" ] &&
    ok "proto has the illumos build's area and illumos-extra's packages, headers too" ||
    bad "proto: unix, expat.h, node.h: $(ls "$p" 2>&1 | head -5)"
missing=
for f in usr/bin/bootparams usr/node/0.10/node_modules/kstat.node \
    usr/node/0.10/node_modules/fs-ext/build/Release/fs-ext.node usr/fw/node_modules/DTraceProviderBindings.node \
    usr/share/man/man8/vmadm.8; do
    [ -s "$p/$f" ] || missing="$missing $f"
done
[ -z "$missing" ] && ok "src and man are built into proto: a program, node add-ons (npm's fetches too), a man page" ||
    bad "not in proto:$missing"
[ "$(git -C "$checkout" status --porcelain)" = "$before" ] &&
    ok "its tracked files are as they were, and what the build made is ignored" ||
    bad "the checkout's status changed: $(git -C "$checkout" status --porcelain | head -8)"

# a change to one source: only its program is made again
if [ -z "$before" ]; then
    cp "$p/usr/bin/bootparams" "$tmp/bootparams.before"
    perl -0pi -e 's/^(#include <err.h>\n)/$1static const char srcwsmark[] __attribute__((used)) = "src-workspace.sh mark";\n/m' \
        "$checkout/src/bootparams.c"
    git -C "$checkout" diff --quiet -- src/bootparams.c && bad "the change to bootparams.c did not apply"
    if "$sw" "$checkout" build >"$tmp/rebuild.log" 2>&1 && strings -a "$p/usr/bin/bootparams" | grep -q "src-workspace.sh mark" &&
        ! cmp -s "$tmp/bootparams.before" "$p/usr/bin/bootparams"; then
        ok "a change to bootparams.c: bootparams made again, with it"
    else
        bad "rebuild: $(tail -5 "$tmp/rebuild.log")"
    fi
    git -C "$checkout" checkout -q -- src/bootparams.c
fi

mkdir "$tmp/not-live"
if "$sw" "$tmp/not-live" build >"$tmp/refuse.log" 2>&1; then
    bad "build took a directory that is not a smartos-live checkout"
else
    grep -q "not a smartos-live checkout" "$tmp/refuse.log" && ok "a directory that is not a checkout is refused" ||
        bad "refusal: $(cat "$tmp/refuse.log")"
fi

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
