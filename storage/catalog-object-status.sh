#!/bin/sh
set -eu
# Diagnostic HEAD with catalog credentials. Only the HTTP status is printed.
case "${1:-}" in catalog/*) ;; *) exit 1 ;; esac
printf 'user = "%s:%s"\n' "$CATALOG_S3_ACCESS_KEY_ID" "$CATALOG_S3_SECRET_ACCESS_KEY" |
    curl --config - --noproxy '*' --silent --show-error --max-time 10 --head \
        --aws-sigv4 'aws:amz:us-east-1:s3' --output /dev/null --write-out '%{http_code}' \
        "http://localhost:8333/balaio-media/$1"
