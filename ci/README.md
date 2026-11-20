# The CI zone

`snow-nix-ci` (a zone from the nixpkgs-illumos zone image on snow) keeps the binary cache on Manta
(`../cache/README.md`) filled: for each push to `main` or `wip/release-20261023` of
TritonDataCenter/nixpkgs-illumos, and for manual runs, `../.github/workflows/cache.yml` runs `./fill-cache.sh` on it,
which builds what the cache serves (smartos-live's builder tools, smartos-illumos' workspace, github-act-runner, go)
and pushes everything their build used.

## The runner

[github-act-runner](https://github.com/ChristopherHX/github-act-runner) (`../pkgs/github-act-runner`), registered to
the repository TritonDataCenter/nixpkgs-illumos only (a repository runner: no other repository of the organization
can use it), with one label, `nixpkgs-illumos-cache`, and none of the default ones (`--no-default-labels`), so only a
job that asks for that label runs on it. It runs jobs on the zone itself, as the unprivileged user `runner`, whom Nix
does not trust.

What is declared: the SMF service `application/github-act-runner` (`./runner.nix`), in the zone's
`/etc/nixos/system.nix` through `extraPackages`, applied with `illumos-rebuild switch`. What is made by hand, once:

```sh
mkdir -p /var/lib
useradd -m -d /var/lib/github-act-runner -s /bin/bash -c "GitHub Actions runner" runner
passwd -N runner; chmod 700 /var/lib/github-act-runner
# a registration token for the repository, valid an hour:
#   gh api -X POST repos/TritonDataCenter/nixpkgs-illumos/actions/runners/registration-token --jq .token
runner=$(nix-build --no-out-link -E '(import /etc/nixos/pkgs.nix).github-act-runner')/bin/github-act-runner
su - runner -c "$runner configure --unattended --url https://github.com/TritonDataCenter/nixpkgs-illumos \
  --token TOKEN --name snow-nix-ci --labels nixpkgs-illumos-cache --no-default-labels"
chmod 600 /var/lib/github-act-runner/settings.json   # the runner's credentials; configure leaves it readable
```

and the keys, in `/var/lib/github-act-runner/keys` (mode 700, files 600, owned by `runner`):
`cache-nshalman-manta-1.sec` (the cache's signing key) and `nix-cache-ci`, `nix-cache-ci.pub` (the Manta sub-user's
key); where they are kept is in `../cache/README.md`.

## Who can reach the keys

Anyone who can push to TritonDataCenter/nixpkgs-illumos: a branch can carry a workflow that asks for the runner's
label, and its steps run as `runner`. Pull requests from forks of outside contributors wait for approval
(`all_external_contributors`). Before the cache or the zone image is offered beyond that set of people, the keys
should move to GitHub environment secrets limited to these branches, the runner become ephemeral, and the signing key
be rotated.

## By hand

As `runner`, with the service's PATH:

```sh
su - runner -c 'export PATH=/nix/var/nix/profiles/default/bin:/usr/bin:/usr/sbin; cd CHECKOUT && bash ci/fill-cache.sh'
```
