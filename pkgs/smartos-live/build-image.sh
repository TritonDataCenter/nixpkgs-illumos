#!/bin/bash
#
# build-image [--illumos-proto DIR | --proto DIR] OUTPUT-DIR [ROOT-PASSWORD]: SmartOS's platform image, made as
# smartos-live's `gmake live` makes it (tools/build_live), from what Nix built: the manifest (@manifest@), the stages'
# outputs as builder's search directories (@searchDirs@, then the illumos build's proto area, @illumosProto@) and the
# workspace build_live runs from (@workspace@). Needs root, lofi and UFS mounts: a zone with the builder brand (its lofi
# devices) and fs_allowed including ufs, or the global zone.
#
# --illumos-proto DIR takes the proto area DIR, an incremental build's (smartos-illumos.workspace), in place of the
# illumos build's: its files, its kernel and its motd and issue, beneath the other stages' as the illumos build's
# are. What is in DIR is not a Nix output, so the image is stamped as a dirty tree's (the time it is made), with a
# root password of its own. The manifest and the rest are the Nix build's, made against the illumos build's proto
# area: a file DIR has that the manifest does not list is not in the image.
#
# --proto DIR takes DIR as a whole proto area, as smartos-live's own build has one (a checkout's, built in place:
# illumos, illumos-extra's packages and src, smartos-live.srcWorkspace): in place of the src, illumos-extra and
# illumos stages, beneath projects/local's (@localDir@), which their build installs last. Stamped likewise.
#
# The build stamp follows the overlay's checkout (./identity.nix, ./stage-image.sh): a clean tree's is its commit's
# time, a dirty one's the time the image is made, its last digit the flavor's (@flavorDigit@).
#
# The root password is ROOT-PASSWORD; or, for a clean tree, the last release's, with its hash
# (release/release.json, made once when the release was cut: every image of the commit has the same /etc/shadow);
# or one made here (theirs by pkgsrc's pwgen -B -c -n 16). build_live writes it beside the image (root.password).
# PATH is theirs (/usr/bin, /usr/sbin, /sbin, then what they take from pkgsrc: md5sum and gtar, here nixpkgs'
# coreutils and GNU tar).

set -euo pipefail

export PATH=/usr/bin:/usr/sbin:/sbin:@extraPath@

usage() {
    echo "usage: $0 [--illumos-proto DIR | --proto DIR] OUTPUT-DIR [ROOT-PASSWORD]" >&2
    exit 2
}
identity=@identity@
illumos_proto=@illumosProto@
above="@searchDirs@"
case "${1:-}" in
    --illumos-proto | --proto)
        [ $# -ge 2 ] || usage
        if [ "$1" = --proto ]; then
            [ -f "$2/platform/i86pc/kernel/amd64/unix" ] || { echo "build-image: $2 is not a proto area" >&2; exit 1; }
            above="@localDir@"
            what="everything but projects/local"
        else
            [ -f "$2/platform/i86pc/kernel/amd64/unix" ] ||
                { echo "build-image: $2 is not an illumos proto area" >&2; exit 1; }
            what=illumos
        fi
        illumos_proto=$(cd "$2" && pwd)
        shift 2
        identity=$(mktemp)
        printf 'kind=dirty\nrev=\nstamp=\npassword=\nhash=\n' >"$identity"
        echo "build-image: $what from $illumos_proto, stamped as dirty"
        ;;
esac
[ $# -ge 1 ] || usage
out=$1
password=${2:-}
release_password= release_hash=
while IFS='=' read -r key value; do
    case $key in
        password) release_password=$value ;;
        hash) release_hash=$value ;;
    esac
done <"$identity"
if [ -z "$password" ] && [ -n "$release_hash" ]; then
    password=$release_password
    export BI_ROOT_HASH=$release_hash
    echo "build-image: the release's root password and hash"
elif [ -z "$password" ]; then
    # 16 letters and digits, none easily mistaken for another
    password=$(head -c 4096 /dev/urandom | LC_ALL=C tr -dc 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789')
    password=${password:0:16}
    [ ${#password} = 16 ]
fi

# build_live finds its tree by its own path and writes its log in log/ there: a directory of links to the workspace,
# with log/ in OUTPUT-DIR
ws=$(mktemp -d)
trap 'rm -rf "$ws"; [ "$identity" = @identity@ ] || rm -f "$identity"' EXIT
for f in @workspace@/*; do
    [ "${f##*/}" = proto ] || ln -s "$f" "$ws/"
done
mkdir -p "$out/log"
ln -s "$(cd "$out" && pwd)/log" "$ws/log"

# The platform's build stamp, from the overlay's identity (@identity@, or a dirty one; ./stage-image.sh): the proto
# area build_live reads it from, and the files with it in (the kernel's uname -v, motd, issue) in a search directory
# of their own, ahead of the others, as builder takes each file from the first that has it
stamp=$(ILLUMOS_PROTO=$illumos_proto stage-image "$identity" "$ws/stage" @flavorDigit@)
echo "build-image: build stamp $stamp"
ln -s "$ws/stage/proto" "$ws/proto"

"$ws/tools/build_live" -m @manifest@ -o "$out" -p "$password" "$ws/stage/stamped" $above "$illumos_proto"
