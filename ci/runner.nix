# The CI zone's GitHub Actions runner as an SMF service, for zone/system.nix's extraPackages: github-act-runner run,
# as the unprivileged user runner, from its home, where `github-act-runner configure` left its registration
# (settings.json). run: steps execute on the zone itself, with bash from the system profile, which is first on PATH.
# The user, its home and the registration are made by hand (./README.md).
{ pkgs }:

let
  smf = import ../zone/smf-lib.nix { inherit pkgs; };
  home = "/var/lib/github-act-runner";
  start = pkgs.writeScript "github-act-runner-start" ''
    #!/bin/sh
    cd ${home} || exit 1
    exec ${pkgs.github-act-runner}/bin/github-act-runner run
  '';
in
smf.mkSmfManifestBundle {
  name = "github-act-runner-service";
  manifests = [
    (smf.mkSmfManifest {
      name = "github-act-runner";
      description = "GitHub Actions runner (github-act-runner)";
      documentation = {
        name = "github-act-runner";
        uri = "https://github.com/ChristopherHX/github-act-runner";
      };
      dependencies = [
        {
          name = "filesystem-local";
          fmri = "svc:/system/filesystem/local";
        }
        {
          name = "multi-user-server";
          fmri = "svc:/milestone/multi-user-server";
        }
        {
          name = "nix-daemon";
          fmri = "svc:/application/nix-daemon";
        }
      ];
      start = {
        exec = "${start}";
        user = "runner";
        group = "other";
        environment = {
          HOME = home;
          PATH = "/nix/var/nix/profiles/default/bin:/usr/bin:/usr/sbin";
        };
      };
      duration = "child";
      ignoreError = "core,signal";
    })
  ];
}
