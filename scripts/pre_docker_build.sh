#!/bin/bash

docker build -f Dockerfile-afl -t libaflnet-afl:1.0.0 --build-arg MAKE_OPT="-j" .
docker build -f Dockerfile-rust -t libaflnet-rust:1.0.0 .