#! /bin/bash
set -euo pipefail

OPENSSL_BIN="${OPENSSL_BIN:-openssl}"

# 进入当前目录
cd $(dirname $0)/..
mkdir -p cert
cd cert

rm -f ca.key ca.crt ca.srl \
    server.key server.csr server.crt server.ext \
    client.key client.csr client.crt client.ext \
    fullchain.crt index.txt ocsp.der ech.pem

# ca key and cert
"${OPENSSL_BIN}" genrsa -out ca.key 4096
"${OPENSSL_BIN}" req -new -x509 -days 3650 -sha256 \
    -key ca.key \
    -out ca.crt \
    -set_serial 1 \
    -subj "/C=CN/ST=Beijing/L=Beijing/O=CA/OU=IT/CN=127.0.0.1" \
    -addext "subjectAltName=DNS:localhost,DNS:127.0.0.1,IP:127.0.0.1"

# server key and cert
"${OPENSSL_BIN}" genrsa -out server.key 4096
"${OPENSSL_BIN}" req -new -key server.key -out server.csr -subj "/C=CN/ST=Beijing/L=Beijing/O=Server/OU=IT/CN=127.0.0.1" -addext "subjectAltName=DNS:localhost,DNS:127.0.0.1,IP:127.0.0.1"
cat > server.ext <<'EOF'
basicConstraints=CA:FALSE
subjectAltName=DNS:localhost,DNS:127.0.0.1,IP:127.0.0.1
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
EOF
"${OPENSSL_BIN}" x509 -req -sha256 -days 3650 \
    -in server.csr \
    -CA ca.crt \
    -CAkey ca.key \
    -set_serial 2 \
    -extfile server.ext \
    -out server.crt

# client key and cert
"${OPENSSL_BIN}" genrsa -out client.key 4096
"${OPENSSL_BIN}" req -new -key client.key -out client.csr -subj "/C=CN/ST=Beijing/L=Beijing/O=Client/OU=IT/CN=127.0.0.1" -addext "subjectAltName=DNS:localhost,DNS:127.0.0.1,IP:127.0.0.1"
cat > client.ext <<'EOF'
basicConstraints=CA:FALSE
subjectAltName=DNS:localhost,DNS:127.0.0.1,IP:127.0.0.1
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=clientAuth
EOF
"${OPENSSL_BIN}" x509 -req -sha256 -days 3650 \
    -in client.csr \
    -CA ca.crt \
    -CAkey ca.key \
    -set_serial 3 \
    -extfile client.ext \
    -out client.crt

# full chain
cat server.crt ca.crt > fullchain.crt

# OCSP stapling response (DER)
serial=$("${OPENSSL_BIN}" x509 -in server.crt -noout -serial | cut -d= -f2)
notafter=$("${OPENSSL_BIN}" x509 -in server.crt -noout -enddate | cut -d= -f2)
expires=$(date -u -d "$notafter" +%y%m%d%H%M%SZ)

# index.txt format:
# <status>\t<expiry>\t<revocation>\t<serial>\t<filename>\t<subject>
printf 'V\t%s\t\t%s\tunknown\t/CN=127.0.0.1\n' "$expires" "$serial" > index.txt
"${OPENSSL_BIN}" ocsp \
    -index index.txt \
    -rsigner ca.crt \
    -rkey ca.key \
    -CA ca.crt \
    -issuer ca.crt \
    -cert server.crt \
    -respout ocsp.der \
    -ndays 7

# ECH key material (requires ech-enabled openssl binary)
if ! "${OPENSSL_BIN}" ech -help >/dev/null 2>&1; then
    echo "error: '${OPENSSL_BIN}' does not support 'ech' command. Set OPENSSL_BIN to an ech-enabled openssl binary." >&2
    exit 1
fi

"${OPENSSL_BIN}" ech \
    -public_name "localhost" \
    -out ech.pem
