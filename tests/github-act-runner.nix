# github-act-runner (pkgs/github-act-runner): it runs, says its version, has the commands a self-hosted runner is
# configured and run with, and is an illumos build of the pinned release without cgo, as upstream builds it.
#   nix-build tests/github-act-runner.nix --arg pkgs 'import ./smartos.nix { }'
{ pkgs }:

let
  runner = pkgs.github-act-runner;
in
pkgs.runCommand "github-act-runner-check"
  {
    nativeBuildInputs = [
      runner
      pkgs.go
    ];
  }
  ''
    github-act-runner --version | tee version
    grep -qx 'github-act-runner version ${runner.version}' version

    github-act-runner --help >help
    for c in configure run remove worker svc; do
      grep -qE "^  $c " help || { echo "no $c command:"; cat help; exit 1; }
    done

    go version -m ${runner}/bin/github-act-runner | tee buildinfo
    grep -qE '^\s+build\s+GOOS=illumos$' buildinfo
    grep -qE '^\s+build\s+CGO_ENABLED=0$' buildinfo
    grep -qE '^\s+mod\s+github.com/ChristopherHX/github-act-runner\s' buildinfo
    touch $out
  ''
