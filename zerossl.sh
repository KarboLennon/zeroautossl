#!/usr/bin/env bash
set -euo pipefail

ZAPI="https://api.zerossl.com"
OUT="./certs"
POLL_INTERVAL=8
POLL_MAX=60

err()  { echo "error: $*" >&2; exit 1; }
info() { echo ">> $*"; }
need() { command -v "$1" >/dev/null || err "butuh '$1' ter-install"; }
need openssl; need curl; need jq

echo "=============================="
echo "   ZeroSSL Auto SSL + cPanel  "
echo "=============================="
echo

read -rp  "Domain        : " PRIMARY
read -rsp "ZeroSSL key   : " API_KEY; echo
read -rp  "cPanel IP     : " CP_IP
read -rp  "cPanel user   : " CP_USER
read -rsp "cPanel token  : " CP_TOKEN; echo

echo
[ -n "$PRIMARY" ]  || err "domain kosong"
[ -n "$API_KEY" ]  || err "ZeroSSL key kosong"
[ -n "$CP_IP" ]    || err "IP kosong"
[ -n "$CP_USER" ]  || err "username kosong"
[ -n "$CP_TOKEN" ] || err "token kosong"

CP_HOST="$CP_IP:2083"
WORKDIR="$OUT/$PRIMARY"
mkdir -p "$WORKDIR"

KEY="$WORKDIR/privkey.pem"
CSR="$WORKDIR/request.csr"
CRT="$WORKDIR/certificate.crt"
CA="$WORKDIR/ca_bundle.crt"
FULL="$WORKDIR/fullchain.pem"

cpanel_api() {
  local mod="$1" fn="$2"; shift 2
  curl -sS --insecure \
    -H "Authorization: cpanel $CP_USER:$CP_TOKEN" \
    "https://$CP_HOST/execute/$mod/$fn" "$@"
}

# 1. Private key + CSR
if [ ! -f "$KEY" ]; then
  info "generate private key (RSA 2048)"
  openssl genrsa -out "$KEY" 2048 2>/dev/null
fi

info "generate CSR untuk: $PRIMARY"
CONF=$(mktemp)
cat >"$CONF" <<EOF
[req]
distinguished_name = dn
req_extensions = req_ext
prompt = no
[dn]
CN = $PRIMARY
[req_ext]
subjectAltName = DNS.1 = $PRIMARY
EOF
openssl req -new -key "$KEY" -out "$CSR" -config "$CONF"
rm -f "$CONF"
CSR_CONTENT=$(cat "$CSR")

# 2. Create order
info "bikin cert order di ZeroSSL"
CREATE=$(curl -sS -X POST \
  "$ZAPI/certificates?access_key=$API_KEY" \
  --data-urlencode "certificate_domains=$PRIMARY" \
  --data-urlencode "certificate_csr=$CSR_CONTENT" \
  --data-urlencode "certificate_validity_days=90")

echo "$CREATE" | jq -e '.id' >/dev/null 2>&1 || err "create gagal: $CREATE"
CERT_ID=$(echo "$CREATE" | jq -r '.id')
info "cert id: $CERT_ID"

# 3. Upload file validasi ke cPanel
FILE_URL=$(echo "$CREATE" | jq -r ".validation.other_methods[\"$PRIMARY\"].file_validation_url_http")
FILE_CONTENT=$(echo "$CREATE" | jq -r ".validation.other_methods[\"$PRIMARY\"].file_validation_content | join(\"\n\")")
FILE_NAME=$(basename "$FILE_URL")

TMPFILE=$(mktemp)
echo "$FILE_CONTENT" > "$TMPFILE"

info "upload file validasi ke cPanel"
cpanel_api Fileman mkdir -G \
  --data-urlencode "path=/public_html" \
  --data-urlencode "name=.well-known" >/dev/null || true
cpanel_api Fileman mkdir -G \
  --data-urlencode "path=/public_html/.well-known" \
  --data-urlencode "name=pki-validation" >/dev/null || true

RESP=$(cpanel_api Fileman upload_files \
  -F "dir=/public_html/.well-known/pki-validation" \
  -F "file-1=@$TMPFILE;filename=$FILE_NAME")
echo "$RESP" | jq -e '.status==1' >/dev/null || err "upload gagal: $RESP"
rm -f "$TMPFILE"
info "file ke-upload: /public_html/.well-known/pki-validation/$FILE_NAME"

info "cek file accessible"
HTTP_CODE=$(curl -sS -o /dev/null -w "%{http_code}" -L "$FILE_URL" || true)
[ "$HTTP_CODE" = "200" ] || info "warning: HTTP $HTTP_CODE (lanjut)"

# 4. Trigger validasi
info "trigger validasi"
curl -sS -X POST \
  "$ZAPI/certificates/$CERT_ID/challenges?access_key=$API_KEY" \
  --data-urlencode "validation_method=HTTP_CSR_HASH" >/dev/null

# 5. Poll
info "polling status"
for ((n=1; n<=POLL_MAX; n++)); do
  STATUS=$(curl -sS "$ZAPI/certificates/$CERT_ID?access_key=$API_KEY" | jq -r '.status')
  printf "  [%02d] status=%s\n" "$n" "$STATUS"
  case "$STATUS" in
    issued) break ;;
    cancelled|expired|revoked) err "cert state=$STATUS" ;;
  esac
  sleep "$POLL_INTERVAL"
done
[ "$STATUS" = "issued" ] || err "timeout nunggu issued"

# 6. Download
info "download cert"
BUNDLE=$(curl -sS "$ZAPI/certificates/$CERT_ID/download/return?access_key=$API_KEY")
echo "$BUNDLE" | jq -r '."certificate.crt"' > "$CRT"
echo "$BUNDLE" | jq -r '."ca_bundle.crt"' > "$CA"
cat "$CRT" "$CA" > "$FULL"

# 7. Install ke cPanel
info "install cert ke cPanel"
INSTALL_RESP=$(cpanel_api SSL install_ssl \
  --data-urlencode "domain=$PRIMARY" \
  --data-urlencode "cert=$(cat "$CRT")" \
  --data-urlencode "key=$(cat "$KEY")" \
  --data-urlencode "cabundle=$(cat "$CA")")
echo "$INSTALL_RESP" | jq -e '.status==1' >/dev/null || err "install gagal: $INSTALL_RESP"

echo
info "SELESAI. File tersimpan di:"
echo "  private key : $KEY"
echo "  cert        : $CRT"
echo "  ca bundle   : $CA"
echo "  fullchain   : $FULL"
