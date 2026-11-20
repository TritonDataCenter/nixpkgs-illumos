# smartos-live's src built in place, in a checkout, as a developer builds it incrementally: bin/smartos-src-workspace
# runs src's make in the checkout the way `gmake world` does (0-extra-stamp, then 0-livesrc-stamp), with the Nix
# build's compiler, strap and tools (./livesrc.nix's make flags) in place of pkgsrc's and the strap cache. Nothing
# of the checkout goes into the store.
#
#   smartos-src-workspace CHECKOUT proto   fill CHECKOUT/proto as src reads it: the illumos build's proto area (the
#                                          store's, unless the checkout has one of its own, from an illumos workspace:
#                                          ../smartos-illumos/workspace.nix), and over it illumos-extra's packages,
#                                          whole, as 0-extra-stamp installs them (again when they change)
#   smartos-src-workspace CHECKOUT build   proto, then `make` and `make install` in src and `make install` in man,
#                                          into CHECKOUT/proto
#
# As theirs, src reads and writes one proto area (DESTDIR), and its node add-ons' npm fetches what they need (nan
# from the npm registry, fs-ext from github, node's headers from nodejs.org), where the Nix build has them given;
# build.env is configure's, written when missing. src's Makefile runs node-gyp with /opt/local/bin/python2.7, pkgsrc's
# in their build zone: it must be there (smartos-src-workspace says how). The tools on PATH are the Nix build's (GNU
# make as make, coreutils, sed and the rest), then /usr/bin.
{
  lib,
  writeScriptBin,
  runtimeShell,
  gnumake,
  coreutils,
  gnused,
  gnugrep,
  gawk,
  findutils,
  diffutils,
  gnutar,
  gzip,
  perl,
  python27,
  gitMinimal,
  livesrc,
  illumosProto,
  extraPackages,
  strapProto,
  buildEnv,
}:

let
  extraList = lib.concatStringsSep " " (map toString extraPackages);
in
writeScriptBin "smartos-src-workspace" ''
  #!${runtimeShell}
  set -euo pipefail
  export PATH=${
    lib.makeBinPath [
      gnumake
      coreutils
      gnused
      gnugrep
      gawk
      findutils
      diffutils
      gnutar
      gzip
      perl
      python27
      gitMinimal
    ]
  }:/usr/bin:/usr/sbin:/sbin

  usage() { echo "usage: smartos-src-workspace CHECKOUT proto | build" >&2; exit 2; }
  [ $# = 2 ] || usage
  top=$(cd "$1" && pwd)
  action=$2
  if [ ! -f "$top/src/Makefile.defs" ] || [ ! -e "$top/.git" ]; then
    echo "smartos-src-workspace: $top is not a smartos-live checkout" >&2
    exit 1
  fi
  proto=$top/proto

  proto_() {
    mkdir -p "$proto"
    if [ ! -f "$proto/platform/i86pc/kernel/amd64/unix" ]; then
      echo "smartos-src-workspace: the illumos build's proto area into $proto"
      cp -r ${illumosProto}/. "$proto/"
      chmod -R u+w "$proto"
    fi
    if [ "$(cat "$proto/.nix-extra" 2>/dev/null)" != "${extraList}" ]; then
      echo "smartos-src-workspace: illumos-extra's packages into $proto"
      for p in ${extraList}; do
        cp -r "$p"/. "$proto/"
      done
      chmod -R u+w "$proto"
      echo "${extraList}" >"$proto/.nix-extra"
    fi
  }

  python_() {
    /opt/local/bin/python2.7 -c 'import platform' 2>/dev/null && return
    cat >&2 <<EOF
  smartos-src-workspace: there is no /opt/local/bin/python2.7, which src's Makefile runs node-gyp with (pkgsrc's in
  their build zone). Make it the Nix build's, e.g.:
    mkdir -p /opt/local/bin && nix-store --add-root /opt/local/python2.7 -r ${livesrc.pythonForNodeGyp} &&
    ln -sf /opt/local/python2.7/bin/python2.7 /opt/local/bin/python2.7
  EOF
    exit 1
  }

  case $action in
    proto)
      proto_
      ;;
    build)
      python_
      proto_
      [ -e "$top/build.env" ] || cp ${buildEnv} "$top/build.env"
      # npm's prefix as theirs has it (their node's /usr/node/0.10, not the strap's store path): npm makes
      # $DESTDIR$prefix
      export npm_config_prefix=/usr/node/0.10
      jobs=''${MAX_JOBS:-$(/usr/sbin/psrinfo | wc -l | tr -d ' ')}
      cd "$top/src"
      make -j"$jobs" ${toString (livesrc.makeFlagsWith [ "DESTDIR=$proto" ])}
      make ${toString (livesrc.makeFlagsWith [ "DESTDIR=$proto" ])} install
      cd "$top/man"
      make DESTDIR="$proto" install \
        RONNJS="${strapProto}/usr/node/0.10/bin/node $top/tools/ronnjs/bin/ronn.js"
      ;;
    *)
      usage
      ;;
  esac
''
