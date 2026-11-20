# A step of illumos-joyent's build as smartos-live's tools/build_illumos runs it: a command run by
# `bldenv illumos.sh`, in a copy of the tree, with MAKE naming a dmake from the build host (dmake-bootstrap here).
#
# illumos.sh is written as smartos-live's configure writes it (generate_env), with this repo's pieces in place of
# its directories: proto.strap is smartos-strap.proto (ADJUNCT_PROTO, GNU_ROOT, GNUC_ROOT), the pkgsrc tools it
# names under /opt/local are nixpkgs' (FLEX, BISON, GM4, GNUXGETTEXT, PERL with XML::Parser, PYTHON3 3.12), and
# NATIVE_ADJUNCT, the prefix native tools build against (/opt/local there), joins the nixpkgs libraries they use:
# libxml2 (svccfg) and sqlite (smatch), and zlib's header alone (the ctf tools' libctf includes zlib.h but
# dlopen()s the platform's /usr/lib/libz.so.1; the platform's /usr/include has no zlib.h, and zlib's library is
# 64-bit where these tools are 32).
#
# From the build host, as for any illumos build: bldenv's ksh93, its PATH of /usr/bin, /usr/sbin and friends, the
# ELF tools illumos.sh names (/usr/bin/elfdump, nm, strip, ...), and the native tools' -I/usr/include.
#
# bldenv prints two messages that do no harm: "-L: unknown option" (smartos-live's NIGHTLY_OPTIONS has an L that
# bldenv's getopts does not know; it only acts on t and F) and newtask's refusal to move the build user into root's
# project.
{
  lib,
  stdenv,
  src,
  commitTime,
  dmake-bootstrap,
  illumosEnv,
}:

# DIR: where the command starts, under the tree (e.g. usr/src/tools); COMMAND: what bldenv runs there;
# installPhase and installCheckPhase for the step's output; extra: other derivation attributes.
# extraEnv: lines added to illumos.sh (each ending in a newline); afterBldenv: a command run in the tree after bldenv,
# as build_illumos runs nightly (environment assignments may lead it, as for env).
{
  pname,
  description,
  dir,
  command,
  installPhase,
  installCheckPhase,
  extraEnv ? "",
  afterBldenv ? null,
  extra ? { },
}:

let
  inherit (illumosEnv) perlXml nativeAdjunct toolPath;
in
stdenv.mkDerivation (
  {
    inherit pname;
    version = "0-unstable-${commitTime.date}";

    inherit src;

    # The step runs in the tree itself.
    unpackPhase = ''
      runHook preUnpack
      cp -r $src illumos
      chmod -R u+w illumos
      # The tools' perl scripts name /bin/perl or /usr/bin/perl, which on the platform link to /opt/local/bin/perl,
      # pkgsrc's perl in smartos-live's build zone; here that is perlXml. Those naming /usr/perl5/bin/perl keep the
      # platform's own perl 5.12. Only under usr/src/tools: scripts elsewhere are delivered with the system.
      grep -rlE '^#! ?(/bin/perl|/usr/bin/perl)( |$)' illumos/usr/src/tools | while IFS= read -r f; do
        sed -i -E '1s,^#! ?(/bin/perl|/usr/bin/perl)( |$),#!${perlXml}/bin/perl\2,' "$f"
      done
      runHook postUnpack
    '';

    dontConfigure = true;

    # the gate compiles with its own flag set, through cw; nixpkgs' hardening flags are not part of that
    hardeningDisable = [ "all" ];

    # The time the build's tools give for when they ran (gcc's __DATE__ and __TIME__, python's .pyc files, which
    # with it are checked by their sources' hashes, the archives normalized afterwards): the commit's, like
    # RELEASE_DATE, in place of the stdenv's 1980. It goes through the empty environments below.
    SOURCE_DATE_EPOCH = commitTime.seconds;

    buildPhase = ''
      runHook preBuild
      ws=$PWD/illumos
      mkdir -p proto

      # smartos-live configure's generate_env, as illumos.sh; GATE as build_illumos sets it, from the illumos-joyent
      # commit here rather than a build time. RELEASE_DATE, the month and year in every ELF file's illumos ident,
      # which bldenv and nightly otherwise take from the clock, is the commit's too. LOCKNAME as theirs, the build
      # user and the directory the build is in (theirs: the smartos-live checkout), so that two builds at once, as of
      # the default and debug nightlies, do not take the same lock; the user from id -un, as the platform has no
      # whoami (theirs is pkgsrc's).
      lprefix=$(echo $PWD | tr / _)
      cat >illumos/illumos.sh <<EOF
      ${illumosEnv.illumosSh {
        gate = src.rev or "unknown";
        root = "$PWD/proto";
        jobs = "\${NIX_BUILD_CORES:-1}";
        releaseDate = "${commitTime.monthName} ${toString commitTime.year}";
        inherit extraEnv;
      }}EOF

      # build_illumos: MAKE names the build host's dmake; the command runs with /opt/local/bin (here: nixpkgs' tools)
      # appended to bldenv's PATH. It runs from a user's shell with CC and CXX unset; here it gets no environment
      # beyond what that shell would have, because illumos.sh's MAKEFLAGS=ek lets the environment override the
      # makefiles' macros, and the stdenv exports CC=gcc, AR, NM, STRIP and more.
      cd illumos
      env -i HOME="$HOME" SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" PATH=/usr/bin:/usr/sbin SHELL=/usr/bin/bash MAKE=${dmake-bootstrap}/bin/dmake \
      /usr/bin/ksh93 ./usr/src/tools/scripts/bldenv illumos.sh \
        "cd \$CODEMGR_WS/${dir} && export PATH=\"\$PATH:${toolPath}\" && ${command}"
      ${lib.optionalString (afterBldenv != null) ''
        # build_illumos then unexports MAKE and runs nightly with this PATH (/opt/onbld/bin and /opt/SUNWspro/bin are
        # absent here)
        env -i HOME="$HOME" SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" PATH=/opt/onbld/bin:/sbin:/usr/sbin:/usr/bin:/usr/ccs/bin:/opt/SUNWspro/bin:${toolPath} \
          SHELL=/usr/bin/bash ${afterBldenv}
      ''}cd ..
      runHook postBuild
    '';

    inherit installPhase;

    doInstallCheck = true;
    inherit installCheckPhase;

    # illumos ELF: leave it as the link-editor wrote it.
    dontFixup = true;

    passthru = {
      inherit
        nativeAdjunct
        command
        perlXml
        extraEnv
        ;
    };

    meta = {
      inherit description;
      homepage = "https://github.com/TritonDataCenter/illumos-joyent";
      license = lib.licenses.cddl;
      platforms = lib.platforms.illumos;
    };
  }
  // extra
)
