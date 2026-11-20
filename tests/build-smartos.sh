#!/usr/bin/env bash
#
# ../build-smartos on a throwaway repository standing in for the overlay (build-smartos copied in), with a fake
# nix-build first on PATH: it records its arguments and makes the result build-smartos asked for (-o), with fake
# build-image and build-usb that record theirs and make what the real ones make (OUTPUT/platform-STAMP with
# root.password; OUTPUT/platform-STAMP.usb.gz). Checks: a clean tree builds the default flavor from the repository's
# smartos.nix into the output directory given, image then USB image, and says what it made; --flavor debug and
# --pkgs FILE reach nix-build; a changed tracked file still builds, and is said to be dirty; an untracked file stops
# it before anything is built, and an ignored one does not; with --checkout DIR, DIR's state is the one told and its
# untracked files refuse; --arg NAME EXPR, repeated, reaches nix-build; --illumos-proto DIR and --proto DIR reach
# build-image;
# a failing build-image stops it before
# build-usb; a
# flavor that is not one, or a stray argument, is refused.
#
# usage: build-smartos.sh   (as root, as build-smartos needs; git on PATH)

set -uo pipefail

top="$(cd "$(dirname "$0")/.." && pwd)"
tmp=$(mktemp -d)
# leave $tmp first, as illumos' rm does not remove the current directory
trap 'cd / && rm -rf "$tmp"' EXIT

pass=0 fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

export GIT_CONFIG_GLOBAL=/dev/null GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# the fakes: $tmp/calls gets a line per call, "nix-build ARGS", "build-image ARGS", "build-usb ARGS"; FAKE_IMAGE_FAIL
# makes build-image fail
mkdir -p "$tmp/bin" "$tmp/tools/bin"
cat >"$tmp/tools/bin/build-image" <<EOF
#!/bin/bash
echo "build-image \$*" >>$tmp/calls
case "\$1" in --illumos-proto|--proto) shift 2 ;; esac
[ -z "\${FAKE_IMAGE_FAIL:-}" ] || { echo "build-image: it failed" >&2; exit 1; }
echo "build-image: build stamp 20261005T120000Z"
mkdir -p "\$1/platform-20261005T120000Z"
echo secret >"\$1/platform-20261005T120000Z/root.password"
EOF
cat >"$tmp/tools/bin/build-usb" <<EOF
#!/bin/bash
echo "build-usb \$*" >>$tmp/calls
touch "\$2/\$(basename "\$1").usb.gz"
EOF
cat >"$tmp/bin/nix-build" <<EOF
#!/bin/bash
echo "nix-build \$*" >>$tmp/calls
while [ \$# -gt 0 ]; do
    case \$1 in
        -o) ln -sfn $tmp/tools "\$2"; echo $tmp/tools; shift 2 ;;
        *) shift ;;
    esac
done
EOF
chmod +x "$tmp/bin/nix-build" "$tmp/tools/bin/build-image" "$tmp/tools/bin/build-usb"
export PATH="$tmp/bin:$PATH"

# the overlay
git init -q -b main "$tmp/repo"
cd "$tmp/repo"
cp "$top/build-smartos" .
echo '{ }: { }' >smartos.nix
echo 'scratch/' >.gitignore
git add -A
git commit -q -m start

# run NAME ARGS...: build-smartos ARGS, its output in $tmp/NAME.out, the fakes' calls in $tmp/NAME.calls
run() {
    local name=$1
    shift
    rm -f "$tmp/calls"
    ./build-smartos "$@" >"$tmp/$name.out" 2>&1
    local rc=$?
    touch "$tmp/calls"
    mv "$tmp/calls" "$tmp/$name.calls"
    return $rc
}
show() { sed 's/^/    /' "$tmp/$1.out" "$tmp/$1.calls"; }

out=$tmp/out
if run clean "$out" &&
    [ "$(cat "$tmp/clean.calls")" = "nix-build $tmp/repo/smartos.nix -A smartos-live.builderTools -o $out/builder-tools-default
build-image $out
build-usb $out/platform-20261005T120000Z $out" ] &&
    grep -q "20261005T120000Z" "$tmp/clean.out" && grep -q "clean" "$tmp/clean.out" &&
    grep -qF "$out/platform-20261005T120000Z.usb.gz" "$tmp/clean.out" &&
    grep -qF "$out/platform-20261005T120000Z/root.password" "$tmp/clean.out"; then
    ok "a clean tree: builder tools, image, USB image, and what was made"
else
    bad "a clean tree"; show clean
fi

if run debug --flavor debug "$out" &&
    grep -qx "nix-build $tmp/repo/smartos.nix -A smartos-live-debug.builderTools -o $out/builder-tools-debug" \
        "$tmp/debug.calls"; then
    ok "--flavor debug builds smartos-live-debug's"
else
    bad "--flavor debug"; show debug
fi

if run pkgs --pkgs /some/pkgs.nix "$out" &&
    grep -qx "nix-build /some/pkgs.nix -A smartos-live.builderTools -o $out/builder-tools-default" "$tmp/pkgs.calls"; then
    ok "--pkgs FILE is the package set nix-build builds from"
else
    bad "--pkgs FILE"; show pkgs
fi

echo changed >>smartos.nix
if run dirty "$out" && grep -q "build-usb" "$tmp/dirty.calls" && grep -q "dirty" "$tmp/dirty.out"; then
    ok "a changed tracked file: built, and said to be dirty"
else
    bad "a changed tracked file"; show dirty
fi
git checkout -q -- smartos.nix

echo new >untracked.nix
if ! run untracked "$out" && [ ! -s "$tmp/untracked.calls" ] && grep -q "untracked.nix" "$tmp/untracked.out"; then
    ok "an untracked file: refused, naming it, before anything is built"
else
    bad "an untracked file"; show untracked
fi
rm untracked.nix

mkdir scratch && echo x >scratch/ignored
if run ignored "$out" && grep -q "build-usb" "$tmp/ignored.calls"; then
    ok "an ignored file: built"
else
    bad "an ignored file"; show ignored
fi
rm -r scratch

if run args --arg illumos /some/illumos --arg other '{ }' "$out" &&
    grep -qxF "nix-build $tmp/repo/smartos.nix -A smartos-live.builderTools -o $out/builder-tools-default --arg illumos /some/illumos --arg other { }" "$tmp/args.calls"; then
    ok "--arg NAME EXPR, repeated, reaches nix-build"
else
    bad "--arg NAME EXPR"; show args
fi
if ! run argshort --arg illumos && [ ! -s "$tmp/argshort.calls" ] && grep -q usage "$tmp/argshort.out"; then
    ok "--arg without its EXPR: refused"
else
    bad "--arg without its EXPR"; show argshort
fi

# --illumos-proto DIR: an incremental build's proto area, which build-image takes in place of the store's, said
mkdir -p "$tmp/proto"
if run iproto --illumos-proto "$tmp/proto" "$out" &&
    grep -qxF "build-image --illumos-proto $tmp/proto $out" "$tmp/iproto.calls" && grep -q "build-usb" "$tmp/iproto.calls" &&
    grep -q "illumos from $tmp/proto" "$tmp/iproto.out"; then
    ok "--illumos-proto DIR reaches build-image, and is said"
else
    bad "--illumos-proto"; show iproto
fi
if run wproto --proto "$tmp/proto" "$out" &&
    grep -qxF "build-image --proto $tmp/proto $out" "$tmp/wproto.calls" && grep -q "everything but local from $tmp/proto" "$tmp/wproto.out"; then
    ok "--proto DIR reaches build-image, and is said"
else
    bad "--proto"; show wproto
fi
if ! run iprotoshort --illumos-proto && [ ! -s "$tmp/iprotoshort.calls" ] && grep -q usage "$tmp/iprotoshort.out"; then
    ok "--illumos-proto without its DIR: refused"
else
    bad "--illumos-proto without its DIR"; show iprotoshort
fi

# --checkout: another repository (smartos-live's, when it is the entry point) is the one whose state is told
git init -q -b main "$tmp/other"
echo x >"$tmp/other/f" && git -C "$tmp/other" add f && git -C "$tmp/other" commit -q -m start
echo changed >>smartos.nix
if run checkout --checkout "$tmp/other" "$out" && grep -q "build-usb" "$tmp/checkout.calls" &&
    grep -qF "clean checkout ($tmp/other)" "$tmp/checkout.out"; then
    ok "--checkout DIR: DIR's state is told (clean), not the overlay's (dirty)"
else
    bad "--checkout DIR's state"; show checkout
fi
git checkout -q -- smartos.nix
echo new >"$tmp/other/untracked.c"
if ! run checkoutuntracked --checkout "$tmp/other" "$out" && [ ! -s "$tmp/checkoutuntracked.calls" ] &&
    grep -q "untracked.c" "$tmp/checkoutuntracked.out"; then
    ok "--checkout DIR: an untracked file in DIR is refused before anything is built"
else
    bad "--checkout DIR's untracked file"; show checkoutuntracked
fi
rm "$tmp/other/untracked.c"

if ! FAKE_IMAGE_FAIL=1 run imagefail "$out" && grep -q "build-image" "$tmp/imagefail.calls" &&
    ! grep -q "build-usb" "$tmp/imagefail.calls"; then
    ok "build-image failing: stopped before build-usb"
else
    bad "build-image failing"; show imagefail
fi

if ! run badflavor --flavor gcc99 "$out" && [ ! -s "$tmp/badflavor.calls" ] && grep -q usage "$tmp/badflavor.out"; then
    ok "an unknown flavor: refused"
else
    bad "an unknown flavor"; show badflavor
fi

if ! run stray "$out" extra && [ ! -s "$tmp/stray.calls" ] && grep -q usage "$tmp/stray.out"; then
    ok "a stray argument: refused"
else
    bad "a stray argument"; show stray
fi

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
