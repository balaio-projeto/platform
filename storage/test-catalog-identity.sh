#!/bin/sh
set -eu
# Only unique diagnostic objects are touched. Credentials never enter argv/output.
endpoint=http://localhost:8333
ready=false
for attempt in $(seq 1 30); do
    if /bin/sh /opt/balaio/storage/healthcheck.sh; then ready=true; break; fi
    sleep 1
done
[ "$ready" = true ] || { echo 'FAIL: storage not ready' >&2; exit 1; }
key="pi175-identity-$(date +%s)-$$"
payload="balaio-catalog-identity-$key"
request() {
    method=$1 path=$2 identity=$3
    shift 3
    if [ "$method" = HEAD ]; then set -- --head "$@"; fi
    if [ "$identity" = admin ]; then
        access=$AWS_ACCESS_KEY_ID secret=$AWS_SECRET_ACCESS_KEY
    else
        access=$CATALOG_S3_ACCESS_KEY_ID secret=$CATALOG_S3_SECRET_ACCESS_KEY
    fi
    access=$(printf '%s' "$access" | sed 's/\\/\\\\/g; s/"/\\"/g')
    secret=$(printf '%s' "$secret" | sed 's/\\/\\\\/g; s/"/\\"/g')
    printf 'user = "%s:%s"\n' "$access" "$secret" |
        curl --config - --noproxy '*' --silent --show-error --max-time 15 \
            --aws-sigv4 'aws:amz:us-east-1:s3' -X "$method" \
            --output /tmp/catalog-identity-body --write-out '%{http_code}' \
            "$endpoint$path" "$@" 2>/dev/null
}
# Drop function positional arguments before forwarding curl flags.
call() {
    method=$1 path=$2 identity=$3
    shift 3
    request "$method" "$path" "$identity" "$@"
}
require_status() {
    [ "$1" = "$2" ] || { echo "FAIL: $3 (HTTP $1)" >&2; exit 1; }
    echo "PASS: $3"
}
catalog_path="/balaio-media/catalog/diagnostics/$key.txt"
profile_path="/balaio-media/profile/diagnostics/$key.txt"
cleanup() {
    call DELETE "$catalog_path" admin >/dev/null || true
    call DELETE "$profile_path" admin >/dev/null || true
}
trap cleanup EXIT
require_status "$(call PUT "$profile_path" admin --data-binary "$payload")" 200 'admin fixture'
require_status "$(call PUT "$catalog_path" catalog --data-binary "$payload")" 200 'catalog PUT'
require_status "$(call GET "$catalog_path" catalog)" 200 'catalog GET'
[ "$(cat /tmp/catalog-identity-body)" = "$payload" ] || exit 1
require_status "$(call HEAD "$catalog_path" catalog)" 200 'catalog HEAD'
require_status "$(call GET "$profile_path" catalog)" 403 'profile GET denied'
require_status "$(call PUT "$profile_path" catalog --data-binary denied)" 403 'profile PUT denied'
require_status "$(call DELETE "$profile_path" catalog)" 403 'profile DELETE denied'
status=$(call GET / catalog)
if [ "$status" = 200 ]; then
    if grep -q '<Bucket>' /tmp/catalog-identity-body; then
        echo 'FAIL: ListBuckets exposed bucket names' >&2; exit 1
    fi
    echo 'PASS: ListBuckets returns no buckets'
else
    require_status "$status" 403 'ListBuckets denied'
fi
require_status "$(call GET /balaio-media catalog)" 403 'ListObjects denied'
require_status "$(call PUT "/pi175-denied-$key" catalog)" 403 'CreateBucket denied'
require_status "$(call GET /balaio-media/catalog-prefix-escape.txt catalog)" 403 'sibling prefix denied'
require_status "$(curl --noproxy '*' --silent --output /dev/null --write-out '%{http_code}' "$endpoint$catalog_path")" 403 'anonymous GET denied'
require_status "$(call DELETE "$catalog_path" catalog)" 204 'catalog DELETE'
