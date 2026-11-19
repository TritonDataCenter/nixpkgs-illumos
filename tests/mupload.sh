#!/usr/bin/env bash
#
# cache/mupload.py against Manta itself, in a scratch directory under DIR that it removes afterwards: files upload
# into directories it makes, nested; what is there already with the same size is skipped, and one that changed is
# uploaded again; --ls lists what is there; -n uploads nothing; a key the agent does not hold, and a PUT Manta refuses
# (a directory of another account), fail with a non-zero exit, and the rest still upload.
#
# usage: mupload.sh DIR   (e.g. /USER/stor; MANTA_URL, MANTA_USER, MANTA_KEY_ID and an ssh agent holding the key, as
#                          for mupload.py; python3 and curl on PATH)

set -uo pipefail

dir=${1:?usage: $0 DIR}
top="$(cd "$(dirname "$0")/.." && pwd)"
m() { python3 -I "$top/cache/mupload.py" "$@"; }
tmp=$(mktemp -d)
remote=$dir/mupload-test-$$-$(date +%s)
cleanup() {
	# children first: Manta removes only empty directories
	for p in "$remote/a/b/two" "$remote/one" "$remote/a/b" "$remote/a" "$remote"; do m --rm "$p" >/dev/null 2>&1; done
	rm -rf "$tmp"
}
trap cleanup EXIT

pass=0 fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

mkdir -p "$tmp/src/a/b"
echo one >"$tmp/src/one"
echo two >"$tmp/src/a/b/two"

out=$(m "$tmp/src" "$remote" one a/b/two 2>&1)
[ "$out" = "uploaded 2 failed 0" ] && [ "$(m --ls "$remote/a/b" 2>&1)" = two ] &&
	ok "files upload into directories made for them, nested" || bad "upload: $out; ls: $(m --ls "$remote/a/b" 2>&1)"

out=$(m "$tmp/src" "$remote" one a/b/two 2>&1)
[ "$out" = "skip 2 failed 0" ] && ok "what is there with the same size is skipped" || bad "rerun: $out"

echo "two, longer" >"$tmp/src/a/b/two"
out=$(m -n "$tmp/src" "$remote" one a/b/two 2>&1)
[ "$out" = "skip 1 would upload 1 failed 0" ] && ok "-n says what would upload and uploads nothing" || bad "-n: $out"
out=$(m "$tmp/src" "$remote" one a/b/two 2>&1)
[ "$out" = "skip 1 uploaded 1 failed 0" ] && ok "a changed file is uploaded again" || bad "changed file: $out"

got=$(MANTA_KEY_ID=00:11:22:33:44:55:66:77:88:99:aa:bb:cc:dd:ee:ff m --ls "$remote" 2>&1); rc=$?
[ $rc -ne 0 ] && echo "$got" | grep -q "not in the ssh agent" && ok "a key the agent does not hold: refused, non-zero" ||
	bad "unknown key: rc $rc, $got"

out=$(m "$tmp/src" /nobody-at-all/public/mupload-test one 2>&1); rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q "failed 1" && ok "a PUT Manta refuses: counted as failed, non-zero" ||
	bad "refused PUT: rc $rc, $out"

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
