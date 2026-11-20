#!/usr/bin/env bash
#
# ci/runner.nix: the CI zone's github-act-runner service. Its manifest is at lib/svc/manifest/site/ for
# illumos-rebuild (via zone/system.nix's extraPackages) and `svccfg validate` accepts it; imported into a scratch
# repository, the service runs as the unprivileged runner user from the runner's home, with the profile's bin/ on
# PATH (run: steps take bash from there), after nix-daemon, as a child SMF restarts; and its start method starts
# github-act-runner there. Nothing touches the live SMF repository.
#
# usage: ci-runner.sh /etc/nixos/pkgs.nix

set -uo pipefail

pkgsFile=${1:?usage: $0 /path/to/pkgs.nix}
top="$(cd "$(dirname "$0")/.." && pwd)"
svccfg=/usr/sbin/svccfg
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

pass=0 fail=0
ok()  { echo "PASS: $1"; pass=$((pass+1)); }
bad() { echo "FAIL: $1"; fail=$((fail+1)); }

if out=$(nix-build --no-out-link -E "import $top/ci/runner.nix { pkgs = import $pkgsFile; }" 2>"$tmp/build.err"); then
    ok "ci/runner.nix builds"
else
    bad "ci/runner.nix does not build"; sed 's/^/    /' "$tmp/build.err"; echo "$pass passed, $fail failed"; exit 1
fi

m=$out/lib/svc/manifest/site/github-act-runner.xml
[ -f "$m" ] && ok "its manifest is at lib/svc/manifest/site/github-act-runner.xml" ||
    { bad "no manifest: $(ls -R "$out")"; echo "$pass passed, $fail failed"; exit 1; }

"$svccfg" validate "$m" 2>"$tmp/validate.err" && ok "svccfg validate accepts it" ||
    bad "svccfg validate: $(cat "$tmp/validate.err")"

export SVCCFG_REPOSITORY=$tmp/repo.db
"$svccfg" import "$m" 2>"$tmp/import.err" || bad "import: $(cat "$tmp/import.err")"
prop() { "$svccfg" -s application/github-act-runner listprop "$1" 2>/dev/null | awk '{ $1 = $2 = ""; sub(/^ +/, ""); print }'; }

[ "$(prop start/user)" = runner ] && [ "$(prop start/group)" = other ] &&
    ok "it runs as runner:other" || bad "user $(prop start/user), group $(prop start/group)"
[ "$(prop startd/duration)" = child ] && ok "SMF tracks it as a child" || bad "duration $(prop startd/duration)"
prop start/environment | grep -q '"HOME=/var/lib/github-act-runner"' &&
    prop start/environment | grep -q '"PATH=/nix/var/nix/profiles/default/bin:' &&
    ok "HOME is the runner's home and the profile's bin/ is first on PATH" || bad "environment: $(prop start/environment)"
"$svccfg" -s application/github-act-runner listpg 2>/dev/null | grep -q '^nix-daemon ' &&
    [ "$(prop nix-daemon/entities)" = svc:/application/nix-daemon ] &&
    ok "it depends on nix-daemon" || bad "dependencies: $("$svccfg" -s application/github-act-runner listpg 2>&1)"

start=$(prop start/exec)
script=${start%% *}
[ -x "$script" ] && grep -q '^cd /var/lib/github-act-runner' "$script" &&
    grep -qE "^exec /nix/store/[^ ]+-github-act-runner-[0-9.]+/bin/github-act-runner run$" "$script" &&
    ok "the start method runs github-act-runner from the runner's home" || bad "start $start: $(cat "$script" 2>&1)"

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
