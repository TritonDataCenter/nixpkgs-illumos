# github-act-runner: a GitHub Actions self-hosted runner in Go (github.com/ChristopherHX/github-act-runner), which runs
# on illumos where GitHub's own runner (.NET) does not. Built as upstream builds its release binaries, illumos/amd64
# among them: without cgo, the version given by -X main.version.
{
  lib,
  buildGoModule,
  fetchFromGitHub,
}:

buildGoModule (finalAttrs: {
  pname = "github-act-runner";
  version = "0.13.0";

  src = fetchFromGitHub {
    owner = "ChristopherHX";
    repo = "github-act-runner";
    tag = "v${finalAttrs.version}";
    hash = "sha256-Bcpaw3tVCkpxMmjxKTxu1H3amlawbIS0UdH0+qWEv18=";
  };

  vendorHash = "sha256-JS+8A6/JiIctCFzZQl1GqfSGv5yZT64++0BgYC8sulE=";

  env.CGO_ENABLED = 0;
  ldflags = [ "-X main.version=${finalAttrs.version}" ];

  meta = {
    description = "GitHub Actions self-hosted runner written in Go";
    homepage = "https://github.com/ChristopherHX/github-act-runner";
    license = lib.licenses.mit;
    mainProgram = "github-act-runner";
  };
})
