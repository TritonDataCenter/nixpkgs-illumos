# The Mozilla CA bundle as illumos-extra installs it for the platform (ca-certificates/Makefile): its verify target,
# cacert.pem against cacert.pem.sha256 (the platform's /usr/bin/digest) and against cacert.fingerprints
# (./mkfingerprints, which runs the platform's /usr/bin/openssl), then usr/share/ca-certificates/cacert.pem. The
# platform's etc/openssl/cert.pem link to it is the manifest's.
{ stdenv, illumosExtraSrc }:

stdenv.mkDerivation {
  pname = "smartos-extra-ca-certificates";
  version = "0-unstable-illumos-extra";

  src = illumosExtraSrc [ "ca-certificates" ];

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild
    cd ca-certificates
    read -r expected junk <cacert.pem.sha256
    actual=$(/usr/bin/digest -a sha256 cacert.pem)
    if [ "$expected" != "$actual" ]; then
      echo "cacert.pem: sha256 mismatch: expected $expected, actual $actual" >&2
      exit 1
    fi
    expected=$(cut -d' ' -f1 cacert.fingerprints)
    actual=$(sh ./mkfingerprints cacert.pem | cut -d' ' -f1)
    if [ -z "$actual" ] || [ "$expected" != "$actual" ]; then
      sh ./mkfingerprints cacert.pem | diff -u cacert.fingerprints - >&2
      echo "cacert.pem does not hold the certificates in cacert.fingerprints" >&2
      exit 1
    fi
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -D -m 0444 cacert.pem $out/usr/share/ca-certificates/cacert.pem
    runHook postInstall
  '';
}
