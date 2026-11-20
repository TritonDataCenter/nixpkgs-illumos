#!/usr/bin/env bash
#
# push.sh REMOTE-DIR NIX-BUILD-ARGS...: what `nix-instantiate NIX-BUILD-ARGS` names, and everything its build used (the
# outputs of its build closure that this store has, sources included), into the signed binary cache at REMOTE-DIR on
# Manta (e.g. /USER/public/nix-cache), so that a zone using the cache builds none of it.
#
# The paths are copied by `nix copy` into a binary cache in a local directory (CACHE_DIR, default /var/tmp/nix-cache,
# kept between runs), compressed with zstd and signed with the secret key in the file CACHE_SECRET_KEY; then
# ./mupload.py uploads the NARs, and only after them the narinfos and nix-cache-info, so the cache never names a NAR
# it lacks. What Manta has already is kept. Build first: what is not in this store is not pushed.
#
# Needs: nix, python3; MANTA_URL, MANTA_USER, MANTA_KEY_ID and an ssh agent holding that key, as for ./mupload.py.
# MUPLOAD_JOBS (default 16) uploads at once.

set -euo pipefail

usage() { echo "usage: $0 REMOTE-DIR NIX-BUILD-ARGS..." >&2; exit 2; }
[ $# -ge 2 ] || usage
remote=$1
shift
here="$(cd "$(dirname "$0")" && pwd)"
cache=${CACHE_DIR:-/var/tmp/nix-cache}
key=${CACHE_SECRET_KEY:?"CACHE_SECRET_KEY must name the file of the secret key that signs the cache"}
[ -r "$key" ] || { echo "push.sh: cannot read $key" >&2; exit 1; }

drvs=$(nix-instantiate "$@")
paths=$(nix-store -qR --include-outputs $drvs | grep -v '\.drv$' | while read -r p; do [ -e "$p" ] && echo "$p"; done)
echo "push.sh: $(echo "$paths" | wc -l | tr -d ' ') paths into $cache"
mkdir -p "$cache"
nix copy --no-check-sigs --to "file://$cache?compression=zstd&parallel-compression=true&secret-key=$key" $paths

cd "$cache"
# -k: what the cache has already stays (NARs are named by their hash; a narinfo there is a valid one for its path)
up() { python3 -I "$here/mupload.py" -j "${MUPLOAD_JOBS:-16}" -k "$cache" "$remote" "$@"; }
echo "push.sh: NARs to $remote"
up $(ls nar | sed 's|^|nar/|')
echo "push.sh: narinfos to $remote"
up nix-cache-info $(ls *.narinfo)
