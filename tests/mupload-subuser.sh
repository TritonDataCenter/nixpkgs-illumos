#!/usr/bin/env bash
#
# cache/mupload.py as a Manta sub-user (MANTA_SUBUSER) whose role may write under CACHE (a directory tagged with that
# role) and nowhere else, as cache/README.md sets it up: in a scratch directory under CACHE it makes, the sub-user
# uploads, skips what is there, and replaces what it uploaded itself; it skips an object the account owner made there
# (the cache's existing NARs) but may not replace it; an upload by the owner leaves CACHE its role tag; the sub-user is
# refused a directory outside CACHE, and refused a delete; and its key is no key of the account itself. The account
# owner removes the scratch directories afterwards.
#
# usage: mupload-subuser.sh CACHE   (e.g. /USER/public/nix-cache; MANTA_URL, MANTA_USER, MANTA_KEY_ID and an agent at
#                                     SSH_AUTH_SOCK holding the account's key; MANTA_SUBUSER, and SUBUSER_KEY_ID in an
#                                     agent at SUBUSER_AUTH_SOCK; python3 on PATH)

set -uo pipefail

cache=${1:?usage: $0 CACHE}
: "${MANTA_SUBUSER:?}" "${SUBUSER_KEY_ID:?}" "${SUBUSER_AUTH_SOCK:?}"
top="$(cd "$(dirname "$0")/.." && pwd)"
owner() { env -u MANTA_SUBUSER python3 -I "$top/cache/mupload.py" "$@"; }
sub() { SSH_AUTH_SOCK=$SUBUSER_AUTH_SOCK MANTA_KEY_ID=$SUBUSER_KEY_ID python3 -I "$top/cache/mupload.py" "$@"; }
tmp=$(mktemp -d)
stamp=$$-$(date +%s)
remote=$cache/subuser-test-$stamp
outside=$(dirname "$cache")/subuser-test-$stamp
cleanup() {
	local d f
	for d in "$remote" "$outside"; do
		for f in $(owner --ls "$d" 2>/dev/null); do owner --rm "$d/$f" >/dev/null 2>&1; done
		owner --rm "$d" >/dev/null 2>&1
	done
	rm -rf "$tmp"
}
trap cleanup EXIT

pass=0 fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

echo one >"$tmp/one"
echo two >"$tmp/two"
echo owned >"$tmp/owned"

out=$(sub "$tmp" "$remote" one two 2>&1)
[ "$out" = "uploaded 2 failed 0" ] && ok "the sub-user uploads into a directory it makes under $cache" || bad "upload: $out"

out=$(sub "$tmp" "$remote" one two 2>&1)
[ "$out" = "skip 2 failed 0" ] && ok "the sub-user skips what it uploaded" || bad "rerun: $out"

echo "two, longer" >"$tmp/two"
out=$(sub "$tmp" "$remote" one two 2>&1)
[ "$out" = "skip 1 uploaded 1 failed 0" ] && ok "the sub-user replaces what it uploaded" || bad "replace: $out"

out=$(owner "$tmp" "$remote" owned 2>&1)
[ "$out" = "uploaded 1 failed 0" ] || bad "the owner's upload: $out"
echo three >"$tmp/three"
out=$(sub "$tmp" "$remote" three 2>&1)
[ "$out" = "uploaded 1 failed 0" ] && ok "an upload by the owner leaves the sub-user its role on $cache" ||
	bad "after the owner's upload: $out"
out=$(sub "$tmp" "$remote" owned 2>&1)
[ "$out" = "skip 1 failed 0" ] && ok "the sub-user skips an object the owner made" || bad "owner's object, same size: $out"
echo "owned, changed" >"$tmp/owned"
out=$(sub "$tmp" "$remote" owned 2>&1); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q "failed 1" && ok "the sub-user may not replace an object the owner made" ||
	bad "owner's object, changed: rc $rc, $out"

out=$(sub "$tmp" "$outside" one 2>&1); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q "failed 1" && ok "the sub-user is refused a directory outside $cache" ||
	bad "outside: rc $rc, $out"

out=$(sub --rm "$remote/one" 2>&1); rc=$?
[ $rc -ne 0 ] && [ "$(owner --ls "$remote" 2>&1 | grep -c '^one$')" = 1 ] && ok "the sub-user is refused a delete" ||
	bad "delete: rc $rc, $out"

out=$(env -u MANTA_SUBUSER SSH_AUTH_SOCK=$SUBUSER_AUTH_SOCK MANTA_KEY_ID=$SUBUSER_KEY_ID \
	python3 -I "$top/cache/mupload.py" "$tmp" "$remote" one 2>&1); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q ": 40[13] " && ok "its key is not a key of the account itself" ||
	bad "the key as the account's: rc $rc, $out"

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
