#!/usr/bin/env bash
#
# cache/push.sh end to end, into a scratch directory under DIR on Manta that it removes afterwards: a derivation made
# for the test (built by /bin/sh, so its build closure is itself alone), pushed with a throwaway signing key, is
# substituted from the cache's https URL into an empty store that trusts that key alone (and refused by one that
# trusts another key); everything its build used is in the cache too; and a second push uploads nothing.
#
# usage: cache-push.sh DIR   (DIR world-readable, e.g. /USER/public; on an illumos host with Nix, as root; MANTA_URL,
#                              MANTA_USER, MANTA_KEY_ID and an agent holding the key; python3 and curl on PATH)

set -uo pipefail

dir=${1:?usage: $0 DIR}
top="$(cd "$(dirname "$0")/.." && pwd)"
tmp=$(mktemp -d)
remote=$dir/cache-push-test-$$-$(date +%s)
url="${MANTA_URL%/}$remote"
cleanup() {
	local f
	for f in $(python3 -I "$top/cache/mupload.py" --ls "$remote/nar" 2>/dev/null); do
		python3 -I "$top/cache/mupload.py" --rm "$remote/nar/$f" >/dev/null 2>&1
	done
	for f in $(python3 -I "$top/cache/mupload.py" --ls "$remote" 2>/dev/null); do
		python3 -I "$top/cache/mupload.py" --rm "$remote/${f%/}" >/dev/null 2>&1
	done
	python3 -I "$top/cache/mupload.py" --rm "$remote" >/dev/null 2>&1
	rm -rf "$tmp"
}
trap cleanup EXIT

pass=0 fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

nix key generate-secret --key-name cache-push-test >"$tmp/key.sec"
nix key convert-secret-to-public <"$tmp/key.sec" >"$tmp/key.pub"
cat >"$tmp/t.nix" <<EOF
derivation {
  name = "cache-push-test-$$-$(date +%s)";
  system = builtins.currentSystem;
  builder = "/bin/sh";
  args = [ "-c" "echo pushed >\$out" ];
}
EOF
out=$(nix-build "$tmp/t.nix" --no-out-link 2>/dev/null) || { echo "FAIL: cannot build the test derivation"; exit 1; }

if CACHE_SECRET_KEY=$tmp/key.sec CACHE_DIR=$tmp/cache bash "$top/cache/push.sh" "$remote" "$tmp/t.nix" >"$tmp/push.log" 2>&1; then
	ok "push.sh pushes"
else
	bad "push.sh: $(tail -5 "$tmp/push.log")"
fi

pub=$(cat "$tmp/key.pub")
if nix copy --from "$url" --to "$tmp/store" --trusted-public-keys "$pub" "$out" >"$tmp/copy.log" 2>&1 &&
	[ "$(cat "$tmp/store$out")" = pushed ]; then
	ok "the output substitutes from $url, signed by the key"
else
	bad "substitution: $(tail -3 "$tmp/copy.log")"
fi

other=$(nix key generate-secret --key-name other | nix key convert-secret-to-public)
if ! nix copy --from "$url" --to "$tmp/store2" --trusted-public-keys "$other" "$out" >/dev/null 2>&1; then
	ok "a store trusting another key refuses it"
else
	bad "a store trusting another key took it"
fi

drv=$(nix-instantiate "$tmp/t.nix" 2>/dev/null)
missing=0
for p in $(nix-store -qR --include-outputs "$drv" | grep -v '\.drv$'); do
	curl -sfI "$url/$(basename "$p" | cut -c1-32).narinfo" >/dev/null || missing=$((missing + 1))
done
[ "$missing" = 0 ] && ok "everything the build used is in the cache" || bad "$missing paths of the build closure are not in the cache"

if CACHE_SECRET_KEY=$tmp/key.sec CACHE_DIR=$tmp/cache bash "$top/cache/push.sh" "$remote" "$tmp/t.nix" >"$tmp/push2.log" 2>&1 &&
	grep -q "skip [0-9]* failed 0" "$tmp/push2.log" && ! grep -q "uploaded" "$tmp/push2.log"; then
	ok "a second push succeeds and uploads nothing"
else
	bad "a second push: $(tail -3 "$tmp/push2.log")"
fi

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
