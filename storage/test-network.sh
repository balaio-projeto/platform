#!/bin/sh
set -eu
S3_HEALTH_ENDPOINT=http://seaweedfs:8333 /bin/sh /opt/balaio/storage/healthcheck.sh
echo 'CT-10 PASS: signed S3 from a separate Docker container; anonymous request denied'

# This test container receives ONLY the public CA, never a TLS client key.
for port in 9333 9340 8888 19333 19340 18888 18333; do
    code=$(curl --noproxy '*' --silent --max-time 3 --output /dev/null \
        --cacert /run/seaweedfs/ca.crt --write-out '%{http_code}' \
        "https://seaweedfs:$port/" 2>/dev/null) && exit 1
    [ "$code" = 000 ] || exit 1
    echo "CT-11 PASS: port $port refuses TLS access without client certificate"
done
for port in 7333 8181 9101 12535 22535 23646 33646; do
    code=$(curl --noproxy '*' --silent --max-time 2 --output /dev/null \
        --write-out '%{http_code}' "http://seaweedfs:$port/" 2>/dev/null) && exit 1
    [ "$code" = 000 ] || exit 1
    echo "CT-11 PASS: optional/admin port $port inaccessible from Docker network"
done
