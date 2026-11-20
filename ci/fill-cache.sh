#!/usr/bin/env bash
#
# fill-cache.sh: build what the binary cache serves from this checkout and push it, and everything its build used,
# to the cache on Manta (../cache/README.md): what the CI zone's runner does for each push
# (../.github/workflows/cache.yml). Run it as the runner user in that zone to do the same by hand.
#
# What it builds: smartos-live's builder tools (the toolchains and stages a SmartOS build needs, from the pins),
# github-act-runner and go. It signs with the cache's key and uploads as the Manta sub-user nix_cache_ci, both from
# KEYS (default /var/lib/github-act-runner/keys: cache-nshalman-manta-1.sec, nix-cache-ci and nix-cache-ci.pub),
# in an ssh agent of its own.

set -euo pipefail

top="$(cd "$(dirname "$0")/.." && pwd)"
keys=${KEYS:-/var/lib/github-act-runner/keys}
expr="let p = import $top/smartos.nix { }; in [ p.smartos-live.builderTools p.github-act-runner p.go ]"

echo "fill-cache.sh: building"
nix-build --no-out-link -E "$expr"

# cache/mupload.py needs python3, which the zone has only from Nix
python=$(nix-build --no-out-link -E "(import $top/smartos.nix { }).python3")
export PATH=$python/bin:$PATH

eval "$(ssh-agent -s)" >/dev/null
trap 'ssh-agent -k >/dev/null' EXIT
ssh-add -q "$keys/nix-cache-ci"
export MANTA_URL=https://us-central.manta.mnx.io MANTA_USER=nshalman MANTA_SUBUSER=nix_cache_ci
MANTA_KEY_ID=$(ssh-keygen -l -E md5 -f "$keys/nix-cache-ci.pub" | awk '{ print $2 }')
export MANTA_KEY_ID=${MANTA_KEY_ID#MD5:}

echo "fill-cache.sh: pushing"
CACHE_SECRET_KEY=$keys/cache-nshalman-manta-1.sec bash "$top/cache/push.sh" /nshalman/public/nix-cache -E "$expr"
