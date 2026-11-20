# illumos as SmartOS builds it: illumos-joyent, built with SmartOS's proto.strap (../smartos-strap) the way
# smartos-live's tools/build_illumos builds it.
{
  lib,
  newScope,
  applyPatches,
  fetchFromGitHub,
  fetchurl,
  # an illumos-joyent checkout to build in place of the pinned commit: its tracked files as they are (changes
  # included, untracked files not), named by its commit (<commit>-dirty with changes) and that commit's time
  checkout ? null,
}:

let
  pin = (import ../../pins)."illumos-joyent";
  local =
    if checkout == null then
      null
    else if !builtins.pathExists (checkout + "/.git") then
      throw "smartos-illumos: ${toString checkout} is not a git checkout; build from a git clone (the build is named by its commit, and only its tracked files are built)"
    else
      import ../smartos-live/identity.nix { src = checkout; };
  pinned = fetchFromGitHub {
    inherit (pin)
      owner
      repo
      rev
      hash
      ;
  };
  # the checkout's tree (after its identity, which refuses a tree that is not a git checkout); the pinned fetch itself
  # when it is the same tree, so that the derivations built from it are the pinned build's, not equal copies
  tree =
    let
      fetched = builtins.seq local (builtins.fetchGit checkout);
    in
    if fetched.outPath == pinned.outPath then
      pinned
    else
      {
        name = "source";
        inherit (fetched) outPath;
        inherit (local) rev;
      };
in
lib.makeScope newScope (self: {
  # illumos-joyent, SmartOS's illumos (smartos-live's projects/illumos), at a master commit of 2026-09-11 (an
  # illumos-gate merge). Pinned in ../../pins, and bumped deliberately. With the patches below, each with the
  # reason in its header; src.rev stays the pinned commit's (GATE, the illumos idents). A checkout's tree, as
  # builtins.fetchGit has it, is the pinned archive's at the pinned commit (the same store path), so a clean checkout
  # there changes nothing.
  src = applyPatches {
    src = if checkout == null then pinned else tree;
    patches = [
      # dtrace -G objects the same each run under ASLR; not yet in illumos-gate (./libdtrace-dof-uarg.md)
      ./libdtrace-dof-uarg.patch
    ];
  };

  # the pinned commit's time as a UTC date (../../pins/utc.nix): the build's date, where illumos and smartos-live
  # take one from the clock
  commitTime = import ../../pins/utc.nix (if local == null then pin.date else local.date);

  # the checkout's identity (kind, rev, date: ../smartos-live/identity.nix), or null for the pinned commit
  checkoutIdentity = local;

  # A make to build make with: the gate's tools stage builds its own dmake with dmake.
  dmake-bootstrap = self.callPackage ./dmake-bootstrap.nix { };

  # illumos' closed binaries, debug and non-debug, which smartos-live's configure (fetch_closed) extracts into the tree
  # (./setup.nix): opaque binaries, taken as they are (smartos-live default.configure-build, ON_CLOSED_BINS_URL and
  # ON_CLOSED_BINS_ND_URL)
  closedBins = fetchurl {
    url = "https://us-central.manta.mnx.io/Joyent_Dev/public/releng/illumos/on-closed-bins.i386.tar.bz2";
    sha256 = "0dc5x63j2jsdks99jds484xwckxlyvvxyjvfb1icl7a8x2n2ps0q";
  };
  closedBinsNd = fetchurl {
    url = "https://us-central.manta.mnx.io/Joyent_Dev/public/releng/illumos/on-closed-bins-nd.i386.tar.bz2";
    sha256 = "0mpzsaqhih96w2zk8ly4gknqjmx4726ms9k926hacawp4kma2g6s";
  };

  # illumos.sh and the pieces it names (./illumos-env.nix)
  illumosEnv = self.callPackage ./illumos-env.nix { };

  # a step of the build as tools/build_illumos runs it (bldenv illumos.sh)
  mkBldenvStep = self.callPackage ./bldenv.nix { };

  # the tools stage, with SmartOS's proto.strap from this repo
  tools = self.callPackage ./tools.nix { };

  # the rest of `dmake setup`: closed binaries, headers and mapfiles into the proto area
  setup = self.callPackage ./setup.nix { };

  # the AST message tools the nightly builds the AST libraries' message catalogs with
  msgcc = self.callPackage ./msgcc.nix { };

  # the nightly build: the proto area
  nightly = self.callPackage ./nightly.nix { };

  # bin/illumos-workspace: a checkout built in place with the build's environment, as a developer builds it
  # incrementally (./workspace.nix)
  workspace = self.callPackage ./workspace.nix { };
})
