#! /bin/bash

# 进入当前目录
cd $(dirname $0)/..
mkdir -p cert
cd cert

# ca key and cert
openssl genrsa -out ca.key 4096
openssl req -new -x509 -days 3650 -key ca.key -out ca.crt -subj "/C=CN/ST=Beijing/L=Beijing/O=CA/OU=IT/CN=127.0.0.1" -addext "subjectAltName=DNS:localhost,DNS:127.0.0.1,IP:127.0.0.1"

# server key and cert
openssl genrsa -out server.key 4096
openssl req -new -key server.key -out server.csr -subj "/C=CN/ST=Beijing/L=Beijing/O=Server/OU=IT/CN=127.0.0.1" -addext "subjectAltName=DNS:localhost,DNS:127.0.0.1,IP:127.0.0.1"
openssl x509 -req -sha256 -days 3650 -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out server.crt 

# full chain
cat server.crt ca.crt > fullchain.crt