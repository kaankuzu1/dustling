#!/usr/bin/env bash
# Makes the certificate that signs every Dustling release. Run it once, not per release.
#
#   DUSTLING_SIGNING_P12_PASSWORD=... scripts/make-signing-certificate.sh [--rotate] <out-dir>
#
# Writes, in <out-dir>, dustling-signing.p12: the private key and certificate. It is the only copy
# of the key, so keep it somewhere safe (a password manager) and never in this repository. The
# script refuses an <out-dir> inside the repository.
# Writes, in App/Signing/, release-certificate.pem (the public certificate) and
# release-certificate.sha1 (its SHA-1). Commit those two: build-dmg.sh refuses to sign with any
# other certificate.
# Prints the two `gh secret set` commands that give the release workflow the key.
#
# --rotate  Replace an existing certificate. Every user then has to turn Full Disk Access on again
#           once, because macOS ties that permission to the certificate. See App/Signing/README.md.
#
# Why a certificate of our own: macOS remembers Full Disk Access by the app's "designated
# requirement". An ad hoc signature makes that the build's own hash, so every update loses the
# permission. Signed with one certificate, it is `identifier "app.dustling.Dustling" and
# certificate leaf = H"<sha1>"`, which every later build satisfies.
#
# Needs openssl. The DUSTLING_SIGNING_CERT_DIR environment variable (a folder to write the .pem and
# .sha1 into instead of App/Signing) exists for tests only.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
CERT_DIR="${DUSTLING_SIGNING_CERT_DIR:-$ROOT/App/Signing}"  # tests only: keeps a trial run away from the real files

fail() { echo "error: $*" >&2; exit 1; }

ROTATE=0
OUT_DIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --rotate) ROTATE=1; shift ;;
    -h|--help) sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "error: unknown argument: $1" >&2; exit 64 ;;
    *) [[ -z "$OUT_DIR" ]] || fail "only one output folder, please"; OUT_DIR="$1"; shift ;;
  esac
done
[[ -n "$OUT_DIR" ]] || { echo "usage: DUSTLING_SIGNING_P12_PASSWORD=... $0 [--rotate] <out-dir>" >&2; exit 64; }
[[ -n "${DUSTLING_SIGNING_P12_PASSWORD:-}" ]] || fail "set DUSTLING_SIGNING_P12_PASSWORD to the password that protects the key file"
command -v openssl >/dev/null || fail "openssl is missing"

mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd -P)"
if [[ "$OUT_DIR/" == "$ROOT"/* ]] || git -C "$OUT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  rmdir "$OUT_DIR" 2>/dev/null || true
  fail "the key must stay out of any git repository; pick a folder outside $ROOT"
fi

P12="$OUT_DIR/dustling-signing.p12"
PEM="$CERT_DIR/release-certificate.pem"
SHA1_FILE="$CERT_DIR/release-certificate.sha1"
[[ ! -e "$P12" ]] || fail "$P12 already exists; move it away first"
if [[ ( -e "$PEM" || -e "$SHA1_FILE" ) && $ROTATE -eq 0 ]]; then
  fail "a release certificate already exists. Replacing it makes every user turn Full Disk Access on again; if that's what you want, pass --rotate"
fi

WORK="$(mktemp -d -t dustling-cert)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/openssl.cnf" <<'CNF'
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = Dustling Release Signing
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

openssl req -x509 -newkey rsa:3072 -nodes -days 7300 -sha256 \
  -config "$WORK/openssl.cnf" -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2> "$WORK/openssl.log" \
  || { cat "$WORK/openssl.log" >&2; fail "openssl couldn't make the certificate"; }
# The password goes through the environment, not the command line, where `ps` could show it.
export P12_PASSWORD="$DUSTLING_SIGNING_P12_PASSWORD"
# The old PBE-SHA1-3DES encryption is what an older macOS `security` can import; openssl 3's
# default (AES) isn't readable there.
openssl pkcs12 -export -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -name "Dustling Release Signing" -passout env:P12_PASSWORD -out "$WORK/dustling-signing.p12"

SHA1="$(openssl x509 -in "$WORK/cert.pem" -outform DER | openssl dgst -sha1 -r | cut -d ' ' -f1 | tr 'A-F' 'a-f')"
[[ "$SHA1" =~ ^[0-9a-f]{40}$ ]] || fail "couldn't work out the certificate's SHA-1"

mkdir -p "$CERT_DIR"
install -m 600 "$WORK/dustling-signing.p12" "$P12"
cp "$WORK/cert.pem" "$PEM"
echo "$SHA1" > "$SHA1_FILE"

echo "Made $P12 (keep it safe: it is the only copy of the key)."
echo "Wrote $PEM"
echo "Wrote $SHA1_FILE ($SHA1)"
echo
echo "Give the release workflow the key (the second command asks for the password):"
echo "  base64 < '$P12' | gh secret set DUSTLING_SIGNING_P12_BASE64"
echo "  gh secret set DUSTLING_SIGNING_P12_PASSWORD"
echo
echo "Then commit App/Signing/release-certificate.pem and release-certificate.sha1."
if [[ $ROTATE -eq 1 ]]; then
  echo
  echo "This replaced the old certificate: every user must turn Full Disk Access on again once after updating."
fi
