#!/usr/bin/env bash
#
# smartos-illumos.workspace's illumos-workspace on an illumos-joyent checkout, as a developer builds it in place: env
# writes the checkout's illumos.sh, the build's own (../pkgs/smartos-illumos/illumos-env.nix) with the checkout, the
# proto area given and its commit (GATE joyent_<commit>, -dirty with changes) in place of the build's, and extracts the
# closed binaries into it, leaving its tracked files as they are; bldenv runs a command under bldenv with the build's
# tools on PATH and, before the tools stage is built, the bootstrap dmake as MAKE; a directory that is not an
# illumos-joyent checkout is refused. (nightly, the whole build, is left to a build by hand: it takes most of an hour.)
#
# usage: illumos-workspace.sh CHECKOUT PKGS   (CHECKOUT: a git clone of illumos-joyent for testing, written to where
#                                              its .gitignore ignores, and, when clean, one tracked file changed and
#                                              put back; PKGS: a file evaluating to smartos.nix's set)

set -uo pipefail

checkout=$(cd "${1:?usage: $0 CHECKOUT PKGS}" && pwd)
pkgsFile=${2:?usage: $0 CHECKOUT PKGS}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

pass=0 fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }
ev() { nix eval --impure --raw --expr "let pkgs = import $pkgsFile; in $1" 2>/dev/null; }

if w=$(nix-build --no-out-link -E "(import $pkgsFile).smartos-illumos.workspace" 2>"$tmp/build.err"); then
    ok "smartos-illumos.workspace builds"
else
    bad "smartos-illumos.workspace does not build"; sed 's/^/    /' "$tmp/build.err"; echo "$pass passed, $fail failed"; exit 1
fi
iw=$w/bin/illumos-workspace

root=$tmp/proto
before=$(git -C "$checkout" status --porcelain --untracked-files=no)
beforeNew=$(git -C "$checkout" status --porcelain | grep '^??')
if "$iw" "$checkout" "$root" env >"$tmp/env.log" 2>&1; then
    ok "env succeeds"
else
    bad "env: $(tail -5 "$tmp/env.log")"
fi

rev=$(git -C "$checkout" rev-parse HEAD)
[ -z "$before" ] || rev=$rev-dirty
# illumos.sh as bldenv reads it (it sources the file, without -u)
( set +u; cd "$checkout" && . ./illumos.sh && printf '%s\n' "GATE=$GATE" "CODEMGR_WS=$CODEMGR_WS" "ROOT=$ROOT" \
    "PARENT_ROOT=$PARENT_ROOT" "ADJUNCT_PROTO=$ADJUNCT_PROTO" "JAVA_ROOT=$JAVA_ROOT" "PRIMARY_CC=$PRIMARY_CC" \
    "MAX_JOBS=$MAX_JOBS" "RELEASE_DATE=$RELEASE_DATE" ) >"$tmp/vars" 2>"$tmp/vars.err"
v() { sed -n "s/^$1=//p" "$tmp/vars"; }
[ "$(v GATE)" = "joyent_$rev" ] && ok "GATE is joyent_ and the checkout's commit" || bad "GATE $(v GATE), not joyent_$rev"
[ "$(v CODEMGR_WS)" = "$checkout" ] && [ "$(v ROOT)" = "$root" ] && [ "$(v PARENT_ROOT)" = "$root" ] &&
    ok "the workspace is the checkout, ROOT the proto area given" ||
    bad "CODEMGR_WS $(v CODEMGR_WS), ROOT $(v ROOT), PARENT_ROOT $(v PARENT_ROOT)"
[ "$(v ADJUNCT_PROTO)" = "$(ev 'pkgs.smartos-strap.proto.outPath')" ] && [ -d "$(v JAVA_ROOT)" ] &&
    [ -x "$(v PRIMARY_CC | cut -d, -f2)" ] &&
    ok "proto.strap, the compiler and the JDK are the build's" ||
    bad "ADJUNCT_PROTO $(v ADJUNCT_PROTO), JAVA_ROOT $(v JAVA_ROOT), PRIMARY_CC $(v PRIMARY_CC)"
[ "$(v MAX_JOBS)" -ge 1 ] 2>/dev/null && [ -n "$(v RELEASE_DATE)" ] && ok "MAX_JOBS and RELEASE_DATE are set" ||
    bad "MAX_JOBS $(v MAX_JOBS), RELEASE_DATE $(v RELEASE_DATE): $(cat "$tmp/vars.err")"

[ -d "$checkout/closed/root_i386-nd/kernel" ] && [ -d "$checkout/closed/root_i386/kernel" ] &&
    ok "the closed binaries are in the checkout (closed/)" || bad "no closed binaries in $checkout/closed"
[ "$(git -C "$checkout" status --porcelain --untracked-files=no)" = "$before" ] &&
    [ "$(git -C "$checkout" status --porcelain | grep '^??')" = "$beforeNew" ] &&
    ok "its tracked files are as they were, and what env wrote is ignored" ||
    bad "the checkout's status changed: $(git -C "$checkout" status --porcelain | head -5)"

if "$iw" "$checkout" "$root" bldenv 'echo "CWS=$CODEMGR_WS"; echo "MAKE=$MAKE"; command -v flex' >"$tmp/bldenv.log" 2>&1; then
    grep -qx "CWS=$checkout" "$tmp/bldenv.log" &&
        grep -qx "MAKE=$(ev 'pkgs.smartos-illumos.dmake-bootstrap.outPath')/bin/dmake" "$tmp/bldenv.log" &&
        grep -qx "$(ev 'pkgs.smartos-illumos.illumosEnv.flexGm4.outPath')/bin/flex" "$tmp/bldenv.log" &&
        ok "bldenv runs a command in the checkout's environment, with the bootstrap dmake and the build's tools" ||
        bad "bldenv's environment: $(cat "$tmp/bldenv.log")"
else
    bad "bldenv: $(tail -5 "$tmp/bldenv.log")"
fi

# with a tracked file changed (only in a clean checkout, and put back): GATE says -dirty
if [ -z "$before" ]; then
    f=$checkout/usr/src/cmd/ls/ls.c
    trap 'git -C "$checkout" checkout -q -- usr/src/cmd/ls/ls.c; rm -rf "$tmp"' EXIT
    echo "/* illumos-workspace.sh */" >>"$f"
    "$iw" "$checkout" "$root" env >"$tmp/env2.log" 2>&1
    git -C "$checkout" checkout -q -- usr/src/cmd/ls/ls.c
    grep -q "^GATE=\"joyent_$(git -C "$checkout" rev-parse HEAD)-dirty\";" "$checkout/illumos.sh" &&
        ok "with a tracked file changed, GATE is joyent_<commit>-dirty" ||
        bad "changed tree: $(grep '^GATE=' "$checkout/illumos.sh") $(tail -2 "$tmp/env2.log")"
fi

mkdir "$tmp/not-illumos"
if "$iw" "$tmp/not-illumos" "$root" env >"$tmp/refuse.log" 2>&1; then
    bad "env took a directory that is not an illumos-joyent checkout"
else
    grep -q "not an illumos-joyent checkout" "$tmp/refuse.log" && ok "a directory that is not a checkout is refused" ||
        bad "refusal: $(cat "$tmp/refuse.log")"
fi

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
