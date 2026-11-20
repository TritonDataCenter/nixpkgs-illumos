# The part of smartos-live's tree that tools/build_live runs from (it finds the tree by its own path): build_live and
# tools/lib/build_common.sh, the tools it runs at their places, and proto, from which it reads the build stamp and
# which its checks and DEBUG kernel test look at (the illumos build's proto area).
#
# What build_live makes in the mounted image without needing root is made by Nix here, and installed by the tools it
# runs for it, in place of theirs: tools/smf_import and tools/build_seeds install the SMF repository and the
# joyent-minimal seed (smfRepository, smfSeed: owned as their scripts leave them), tools/build_etcrelease prints
# the platform's gitstatus.json (-g; platformGitstatus) and etc/release for the image's build stamp (-v), which
# build_live writes in. Its whatis step, which runs the illumos tools' man -w itself, installs the whatis databases
# instead (./build-live-whatis.patch). Its root password's hash may be given (BI_ROOT_HASH, a release's;
# ./build-live-hash.patch) rather than made with a salt of its own. tools/tzcheck is ./tzcheck-store.sh around
# theirs: the proto area is in the store, which keeps no hard links.
#
# build_live writes its log in the tree (log/), so it is run from a writable directory of links to this one.
#
# With fromImage, for an image of a proto area outside the store (build-image --proto, --illumos-proto: a checkout
# built in place), those steps are theirs, run as root on the mounted image, so that they see what the image has
# rather than the Nix build's stages: smf_import and build_seeds are their scripts (smfTree's, with the illumos tools'
# svccfg), whatis is the illumos tools' man -w (build_live's own step, unpatched), and there is no proto.boot (build-usb
# lays it out from the proto area).
{
  lib,
  runCommand,
  smartosLive,
  illumosProto,
  liveTools,
  smfRepository,
  smfSeed,
  platformGitstatus,
  whatis,
  bootProto,
  pigz,
  smfTree,
  smartos-illumos,
  fromImage ? false,
}:

runCommand "smartos-live-${if fromImage then "image-" else ""}workspace" { } (
  ''
    mkdir -p $out/tools/lib $out/tools/builder $out/tools/tzcheck $out/tools/ucodecheck
    cp ${smartosLive}/tools/build_live $out/tools/
    chmod u+w $out/tools/build_live
  ''
  + lib.optionalString (!fromImage) ''
    patch $out/tools/build_live ${./build-live-whatis.patch}
  ''
  + ''
    patch $out/tools/build_live ${./build-live-hash.patch}
  ''
  + (
    if fromImage then
      ''
        # the illumos tools build_live runs man -w from, and smf_import's and build_seeds' svccfg
        mkdir -p $out/projects/illumos/usr/src/tools/proto
        ln -s ${smartos-illumos.tools} $out/projects/illumos/usr/src/tools/proto/root_i386-nd
      ''
    else
      ''
        substituteInPlace $out/tools/build_live --subst-var-by whatis ${whatis}
      ''
  )
  + ''
    cp ${smartosLive}/tools/lib/build_common.sh $out/tools/lib/
    ln -s ${liveTools}/tools/builder/builder $out/tools/builder/builder
    ln -s ${liveTools}/tools/ucodecheck/ucodecheck $out/tools/ucodecheck/ucodecheck
    ln -s ${liveTools}/tools/cryptpass $out/tools/cryptpass
    substitute ${./tzcheck-store.sh} $out/tools/tzcheck/tzcheck --subst-var-by tzcheck ${liveTools}/tools/tzcheck/tzcheck
    chmod +x $out/tools/tzcheck/tzcheck

    # what tools/build_boot_image (`gmake usb`, build-usb) takes from the tree: its script, patched to take extra
    # loader variables and to compress with nixpkgs' pigz (./build-boot-image.patch), format_image and proto.boot
    cp ${smartosLive}/tools/build_boot_image $out/tools/
    chmod u+w $out/tools/build_boot_image
    patch $out/tools/build_boot_image ${./build-boot-image.patch}
    substituteInPlace $out/tools/build_boot_image --subst-var-by pigz ${pigz}/bin/pigz
    mkdir -p $out/tools/format_image
    ln -s ${liveTools}/tools/format_image/format_image $out/tools/format_image/format_image
  ''
  + lib.optionalString (!fromImage) ''
    ln -s ${bootProto} $out/proto.boot
  ''
  + "\n"
  + (
    if fromImage then
      ''
        cat >$out/tools/smf_import <<'EOF'
        #!/bin/bash
        # smf_import ROOT: the global zone's SMF repository, imported from ROOT's manifests by their smf_import
        # (smfTree's), as theirs leaves it
        set -euo pipefail
        bash ${smfTree}/tools/smf_import "$1"
        chown root:root "$1/etc/svc/repository.db"
        chmod 600 "$1/etc/svc/repository.db"
        EOF
        cat >$out/tools/build_seeds <<'EOF'
        #!/bin/bash
        # build_seeds ROOT: joyent-minimal's seed repository, from ROOT's manifests by their build_seeds (smfTree's), as
        # theirs leaves it
        set -euo pipefail
        tmp=$(mktemp -d)
        trap 'rm -rf "$tmp"' EXIT
        mkdir "$tmp/tmp"
        PKG_INSTALL_ROOT=$tmp PATH=${smfTree}/bin:$PATH bash ${smfTree}/tools/build_seeds "$1"
        r=usr/lib/brand/joyent-minimal/repository.db
        chmod 444 "$1/$r"
        chown root:root "$1/$r"
        EOF
      ''
    else
      ''
        cat >$out/tools/smf_import <<'EOF'
        #!/bin/bash
        # smf_import ROOT: the global zone's SMF repository, made by Nix (smartos-live smfRepository), as theirs leaves it
        set -euo pipefail
        cp ${smfRepository}/etc/svc/repository.db "$1/etc/svc/repository.db"
        chown root:root "$1/etc/svc/repository.db"
        chmod 600 "$1/etc/svc/repository.db"
        EOF
        cat >$out/tools/build_seeds <<'EOF'
        #!/bin/bash
        # build_seeds ROOT: joyent-minimal's seed repository, made by Nix (smartos-live smfSeed), as theirs leaves it
        set -euo pipefail
        r=usr/lib/brand/joyent-minimal/repository.db
        cp ${smfSeed}/$r "$1/$r"
        chmod 444 "$1/$r"
        chown root:root "$1/$r"
        EOF
      ''
  )
  + ''
    cat >$out/tools/build_etcrelease <<'EOF'
    #!/bin/bash
    # build_etcrelease -g | -v BUILDSTAMP: the platform's gitstatus.json, made by Nix (smartos-live platformGitstatus:
    # the pins' entries and the overlay's, not checkouts'), and etc/release for BUILDSTAMP, the stamp the image step
    # chose (smartos-live etc-release.sh)
    set -euo pipefail
    case "''${1:-}" in
      -g) cat ${platformGitstatus} ;;
      -v) bash ${./etc-release.sh} "''${2:?usage: build_etcrelease -v BUILDSTAMP}" ${platformGitstatus} ;;
      *) echo "usage: build_etcrelease -g | -v BUILDSTAMP" >&2; exit 2 ;;
    esac
    EOF
    chmod +x $out/tools/smf_import $out/tools/build_seeds $out/tools/build_etcrelease

    ln -s ${illumosProto} $out/proto
  ''
)
