#! /bin/bash
set -euo pipefail

OPENSSL_BIN="${OPENSSL_BIN:-openssl}"
CERT_START_DATE="${CERT_START_DATE:-20260101000000Z}"
CERT_END_DATE="${CERT_END_DATE:-20360101000000Z}"

# 进入当前目录
cd $(dirname $0)/..
mkdir -p cert
cd cert

rm -rf demoCA
rm -f ca.key ca.crt ca.srl \
    ca.csr openssl-ca.cnf demoCA-serial \
    server.key server.csr server.crt server.ext \
    client.key client.csr client.crt client.ext \
    fullchain.crt index.txt ocsp.der ech.pem

mkdir -p demoCA/newcerts
: > demoCA/index.txt
echo 1000 > demoCA/serial

cat > openssl-ca.cnf <<'EOF'
[ ca ]
default_ca = CA_default

[ CA_default ]
dir = ./demoCA
new_certs_dir = $dir/newcerts
database = $dir/index.txt
serial = $dir/serial
private_key = ./ca.key
certificate = ./ca.crt
default_md = sha256
default_days = 3650
unique_subject = no
email_in_dn = no
rand_serial = no
policy = policy_loose
copy_extensions = copy

[ policy_loose ]
countryName = optional
stateOrProvinceName = optional
localityName = optional
organizationName = optional
organizationalUnitName = optional
commonName = supplied

[ v3_ca ]
basicConstraints = critical,CA:TRUE
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
subjectAltName = DNS:localhost,DNS:127.0.0.1,IP:127.0.0.1

[ v3_server ]
basicConstraints = CA:FALSE
subjectAltName = DNS:localhost,DNS:127.0.0.1,IP:127.0.0.1
keyUsage = digitalSignature,keyEncipherment
extendedKeyUsage = serverAuth

[ v3_client ]
basicConstraints = CA:FALSE
subjectAltName = DNS:localhost,DNS:127.0.0.1,IP:127.0.0.1
keyUsage = digitalSignature,keyEncipherment
extendedKeyUsage = clientAuth
EOF

# ca key and cert
"${OPENSSL_BIN}" genrsa -out ca.key 4096
"${OPENSSL_BIN}" req -new -sha256 \
    -key ca.key \
    -out ca.csr \
    -subj "/C=CN/ST=Beijing/L=Beijing/O=CA/OU=IT/CN=127.0.0.1"
"${OPENSSL_BIN}" ca -selfsign -batch \
    -config openssl-ca.cnf \
    -in ca.csr \
    -out ca.crt \
    -extensions v3_ca \
    -startdate "${CERT_START_DATE}" \
    -enddate "${CERT_END_DATE}"

# server key and cert
"${OPENSSL_BIN}" genrsa -out server.key 4096
"${OPENSSL_BIN}" req -new -key server.key -out server.csr -subj "/C=CN/ST=Beijing/L=Beijing/O=Server/OU=IT/CN=127.0.0.1" -addext "subjectAltName=DNS:localhost,DNS:127.0.0.1,IP:127.0.0.1"
"${OPENSSL_BIN}" ca -batch \
    -config openssl-ca.cnf \
    -in server.csr \
    -out server.crt \
    -extensions v3_server \
    -startdate "${CERT_START_DATE}" \
    -enddate "${CERT_END_DATE}"

# client key and cert
"${OPENSSL_BIN}" genrsa -out client.key 4096
"${OPENSSL_BIN}" req -new -key client.key -out client.csr -subj "/C=CN/ST=Beijing/L=Beijing/O=Client/OU=IT/CN=127.0.0.1" -addext "subjectAltName=DNS:localhost,DNS:127.0.0.1,IP:127.0.0.1"
"${OPENSSL_BIN}" ca -batch \
    -config openssl-ca.cnf \
    -in client.csr \
    -out client.crt \
    -extensions v3_client \
    -startdate "${CERT_START_DATE}" \
    -enddate "${CERT_END_DATE}"

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
