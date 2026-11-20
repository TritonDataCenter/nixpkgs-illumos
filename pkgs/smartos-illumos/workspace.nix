# illumos-joyent built in place, in a checkout, as a developer builds it incrementally: bin/illumos-workspace gives a
# checkout the build's environment, illumos.sh (./illumos-env.nix, with the nightly's lines: ./nightly.nix) naming
# the same proto.strap, compiler and tools as the build's steps, and runs bldenv and nightly in it the way
# smartos-live's tools/build_illumos does. Nothing of the checkout goes into the store.
#
#   illumos-workspace CHECKOUT ROOT env              write CHECKOUT/illumos.sh, extract the closed binaries
#   illumos-workspace CHECKOUT ROOT bldenv [COMMAND] env, then COMMAND (a shell without one) under bldenv, in the
#                                                    current directory when it is in CHECKOUT
#   illumos-workspace CHECKOUT ROOT nightly          env, then `dmake setup` and the tools, and nightly
#
# ROOT is the proto area (smartos-live's proto). GATE is joyent_<commit>, -dirty when tracked files have changed;
# RELEASE_DATE and the build stamp (ROOT/buildstamp, written when missing) are the time of the build, as theirs; the
# jobs are MAX_JOBS, or the processors. Before the tools stage is built, MAKE is the bootstrap dmake, as theirs is
# pkgsrc's; after, illumos.sh's default, the tools' own. What the build's steps do to their copy only so that the
# build is the same from one run to the next (./libdtrace-dof-uarg.patch, libslp's IMPLVERS, the tools' perl lines)
# is not done to the checkout; its tools' perl scripts run the build host's /usr/bin/perl, which must have
# XML::Parser (./nightly.nix says how), as the build's nightly needs.
{
  lib,
  writeScriptBin,
  runtimeShell,
  gitMinimal,
  gnutar,
  bzip2,
  coreutils,
  illumosEnv,
  nightly,
  dmake-bootstrap,
  closedBins,
  closedBinsNd,
}:

writeScriptBin "illumos-workspace" ''
  #!${runtimeShell}
  set -euo pipefail
  export PATH=${
    lib.makeBinPath [
      gitMinimal
      gnutar
      bzip2
      coreutils
    ]
  }:/usr/bin:/usr/sbin

  usage() { echo "usage: illumos-workspace CHECKOUT ROOT env | bldenv [COMMAND] | nightly" >&2; exit 2; }
  [ $# -ge 3 ] || usage
  here=$PWD
  ws=$(cd "$1" && pwd)
  root=$2
  action=$3
  shift 3
  if [ ! -x "$ws/usr/src/tools/scripts/bldenv" ] || [ ! -e "$ws/.git" ]; then
    echo "illumos-workspace: $ws is not an illumos-joyent checkout (a git clone of github.com/TritonDataCenter/illumos-joyent)" >&2
    exit 1
  fi
  mkdir -p "$root"
  root=$(cd "$root" && pwd)

  env_() {
    gate=$(git -C "$ws" rev-parse HEAD)
    git -C "$ws" diff --quiet HEAD -- || gate=$gate-dirty
    jobs=''${MAX_JOBS:-$(/usr/sbin/psrinfo | wc -l | tr -d ' ')}
    release_date=$(LC_ALL=C TZ=UTC /usr/bin/date '+%B %Y')
    lprefix=$(echo "$ws" | tr / _)
    cat >"$ws/illumos.sh" <<EOF
  ${illumosEnv.illumosSh {
    gate = "$gate";
    root = "$root";
    jobs = "$jobs";
    releaseDate = "$release_date";
    inherit (nightly) extraEnv;
  }}EOF
    # configure's fetch_closed
    if [ ! -d "$ws/closed/root_i386-nd" ] || [ ! -d "$ws/closed/root_i386" ]; then
      (cd "$ws" && tar xpjf ${closedBins} && tar xpjf ${closedBinsNd})
    fi
    mkdir -p "$ws/log"
  }

  perl_() {
    /usr/bin/perl -MXML::Parser -e 1 2>/dev/null && return
    cat >&2 <<EOF
  illumos-workspace: the build host's /usr/bin/perl does not run, or has no XML::Parser. On SmartOS it is a link to
  /opt/local/bin/perl; make that the build's perl, e.g.:
    mkdir -p /opt/local/bin && nix-store --add-root /opt/local/perl -r ${illumosEnv.perlXml} &&
    ln -sf /opt/local/perl/bin/perl /opt/local/bin/perl
  EOF
    exit 1
  }

  # bldenv illumos.sh COMMAND, from a user's shell (no CC, CXX or the like), with the build's tools after bldenv's PATH
  # and MAKE (if given) as build_illumos sets it
  bldenv_() {
    make=$1
    cmd=$2
    cd "$ws"
    env -i HOME="$HOME" TERM="''${TERM:-dumb}" PATH=/usr/bin:/usr/sbin SHELL=/usr/bin/bash ''${make:+MAKE=$make} \
      /usr/bin/ksh93 ./usr/src/tools/scripts/bldenv illumos.sh \
      "export PATH=\"\$PATH:${illumosEnv.toolPath}\" && $cmd"
  }

  toolsDmake=$ws/usr/src/tools/proto/root_i386-nd/opt/onbld/bin/i386/dmake
  case $action in
    env)
      env_
      ;;
    bldenv)
      env_
      perl_
      make=
      [ -x "$toolsDmake" ] || make=${dmake-bootstrap}/bin/dmake
      case $here/ in "$ws"/*) dir=$here ;; *) dir=$ws ;; esac
      bldenv_ "$make" "cd $(printf %q "$dir") && ''${1:-exec /usr/bin/bash -i}"
      ;;
    nightly)
      env_
      perl_
      [ -s "$root/buildstamp" ] || TZ=UTC date '+%Y%m%dT%H%M%SZ' >"$root/buildstamp"
      echo "==> Building illumos ($(cat "$root/buildstamp")) in $ws"
      bldenv_ ${dmake-bootstrap}/bin/dmake 'cd $CODEMGR_WS/usr/src && dmake setup && cd tools && dmake install'
      cd "$ws"
      status=0
      env -i HOME="$HOME" TERM="''${TERM:-dumb}" SHELL=/usr/bin/bash BANNER_YEAR="$(TZ=UTC date +%Y)" \
        PATH=/opt/onbld/bin:/sbin:/usr/sbin:/usr/bin:/usr/ccs/bin:/opt/SUNWspro/bin:${illumosEnv.toolPath} \
        ./usr/src/tools/scripts/nightly illumos.sh || status=$?
      if [ $status -ne 0 ]; then
        log=$ws/log/$(ls -1t "$ws/log" | head -n1)
        echo "illumos-workspace: nightly failed; see $log/mail_msg and $log/nightly.log" >&2
      fi
      exit $status
      ;;
    *)
      usage
      ;;
  esac
''
