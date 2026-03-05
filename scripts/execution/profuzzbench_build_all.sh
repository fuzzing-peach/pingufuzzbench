#!/bin/bash

#export NO_CACHE="--no-cache"
#export MAKE_OPT="-j4"

cd $PFBENCH
cd subjects/FTP/LightFTP
docker build --progress=plain . -t lightftp --build-arg MAKE_OPT $NO_CACHE
docker build --progress=plain . -t lightftp-stateafl -f Dockerfile-stateafl --build-arg MAKE_OPT $NO_CACHE

cd $PFBENCH
cd subjects/FTP/BFTPD
docker build --progress=plain . -t bftpd --build-arg MAKE_OPT $NO_CACHE
docker build --progress=plain . -t bftpd-stateafl -f Dockerfile-stateafl --build-arg MAKE_OPT $NO_CACHE

cd $PFBENCH
cd subjects/FTP/ProFTPD
docker build --progress=plain . -t proftpd --build-arg MAKE_OPT $NO_CACHE
docker build --progress=plain . -t proftpd-stateafl -f Dockerfile-stateafl --build-arg MAKE_OPT $NO_CACHE

cd $PFBENCH
cd subjects/FTP/PureFTPD
docker build --progress=plain . -t pure-ftpd --build-arg MAKE_OPT $NO_CACHE
docker build --progress=plain . -t pure-ftpd-stateafl -f Dockerfile-stateafl --build-arg MAKE_OPT $NO_CACHE

cd $PFBENCH
cd subjects/SMTP/Exim
docker build --progress=plain . -t exim --build-arg MAKE_OPT $NO_CACHE
docker build --progress=plain . -t exim-stateafl -f Dockerfile-stateafl --build-arg MAKE_OPT $NO_CACHE

cd $PFBENCH
cd subjects/DNS/Dnsmasq
docker build --progress=plain . -t dnsmasq --build-arg MAKE_OPT $NO_CACHE
docker build --progress=plain . -t dnsmasq-stateafl -f Dockerfile-stateafl --build-arg MAKE_OPT $NO_CACHE

cd $PFBENCH
cd subjects/RTSP/Live555
docker build --progress=plain . -t live555 --build-arg MAKE_OPT $NO_CACHE
docker build --progress=plain . -t live555-stateafl -f Dockerfile-stateafl --build-arg MAKE_OPT $NO_CACHE

cd $PFBENCH
cd subjects/SIP/Kamailio
docker build --progress=plain . -t kamailio --build-arg MAKE_OPT $NO_CACHE
docker build --progress=plain . -t kamailio-stateafl -f Dockerfile-stateafl --build-arg MAKE_OPT $NO_CACHE

cd $PFBENCH
cd subjects/SSH/OpenSSH
docker build --progress=plain . -t openssh --build-arg MAKE_OPT $NO_CACHE
docker build --progress=plain . -t openssh-stateafl -f Dockerfile-stateafl --build-arg MAKE_OPT $NO_CACHE

cd $PFBENCH
cd subjects/TLS/OpenSSL
docker build --progress=plain . -t openssl --build-arg MAKE_OPT $NO_CACHE
docker build --progress=plain . -t openssl-stateafl -f Dockerfile-stateafl --build-arg MAKE_OPT $NO_CACHE

cd $PFBENCH
cd subjects/DTLS/TinyDTLS
docker build --progress=plain . -t tinydtls --build-arg MAKE_OPT $NO_CACHE
docker build --progress=plain . -t tinydtls-stateafl -f Dockerfile-stateafl --build-arg MAKE_OPT $NO_CACHE

cd $PFBENCH
cd subjects/DICOM/Dcmtk
docker build --progress=plain . -t dcmtk --build-arg MAKE_OPT $NO_CACHE
docker build --progress=plain . -t dcmtk-stateafl -f Dockerfile-stateafl --build-arg MAKE_OPT $NO_CACHE

cd $PFBENCH
cd subjects/DAAP/forked-daapd
docker build --progress=plain . -t forked-daapd --build-arg MAKE_OPT $NO_CACHE
docker build --progress=plain . -t forked-daapd-stateafl -f Dockerfile-stateafl --build-arg MAKE_OPT $NO_CACHE

