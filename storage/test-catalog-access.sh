#!/bin/sh
set -eu
endpoint=${CATALOG_S3_ENDPOINT:-http://seaweedfs:8333}
work=$(mktemp -d /tmp/pi175.XXXXXX)
run=$(cat /proc/sys/kernel/random/uuid)
catalog="/balaio-media/catalog/diagnostics/pi175-$run.txt"
profile="/balaio-media/profile/diagnostics/pi175-$run.txt"
community="/balaio-media/community/diagnostics/pi175-$run.txt"
created_catalog=false
created_profile=false
created_community=false
attempted_bucket=false
denied_bucket="/pi175-denied-$run"
printf 'PI-175 non-sensitive diagnostic %s\n' "$run" > "$work/payload"

request() {
    role=$1
    method=$2
    path=$3
    if [ "$role" = admin ]; then
        key=$AWS_ACCESS_KEY_ID
        secret=$AWS_SECRET_ACCESS_KEY
    else
        key=$CATALOG_S3_ACCESS_KEY_ID
        secret=$CATALOG_S3_SECRET_ACCESS_KEY
    fi
    key=$(printf '%s' "$key" | sed 's/\\/\\\\/g; s/"/\\"/g')
    secret=$(printf '%s' "$secret" | sed 's/\\/\\\\/g; s/"/\\"/g')
    case "$method" in
        HEAD) set -- --head ;;
        PUT) set -- --request PUT --data-binary "@$work/payload" ;;
        *) set -- --request "$method" ;;
    esac
    printf 'user = "%s:%s"\n' "$key" "$secret" |
        curl --config - --noproxy '*' --silent --max-time 10 \
            --aws-sigv4 'aws:amz:us-east-1:s3' --output "$work/response" \
            --write-out '%{http_code}' "$@" "$endpoint$path" 2>/dev/null
}

expect() {
    actual=$(request "$1" "$2" "$3") || { echo 'FAIL: S3 transport'; exit 1; }
    [ "$actual" = "$4" ] || { echo "FAIL: $1 $2 $3 HTTP $actual expected $4"; exit 1; }
    echo "PASS: $1 $2 $3 HTTP $actual"
}

cleanup() {
    failed=0
    for pending in "catalog:$created_catalog:$catalog" "profile:$created_profile:$profile" \
            "community:$created_community:$community"; do
        flag=${pending#*:}
        flag=${flag%%:*}
        path=${pending#*:*:}
        if [ "$flag" = true ]; then
            status=$(request admin DELETE "$path") || status=000
            [ "$status" = 204 ] || failed=1
        fi
    done
    if [ "$attempted_bucket" = true ]; then
        status=$(request admin DELETE "$denied_bucket") || status=000
        case "$status" in 204|404) ;; *) failed=1 ;; esac
    fi
    rm -rf "$work"
    if [ "$failed" = 1 ]; then
        echo "FAIL: diagnostic cleanup incomplete, run $run"
        return 1
    fi
    echo 'PASS: unique diagnostic objects removed'
}
trap cleanup EXIT

created_catalog=true
expect catalog PUT "$catalog" 200
expect catalog GET "$catalog" 200
cmp "$work/payload" "$work/response" >/dev/null
echo 'PASS: catalog downloaded bytes identical'
expect catalog HEAD "$catalog" 200
expect catalog GET "$catalog?acl" 403
expect catalog PUT "$catalog?acl" 403
expect catalog DELETE "$catalog" 204
created_catalog=false

created_profile=true
expect admin PUT "$profile" 200
created_community=true
expect admin PUT "$community" 200
for path in "$profile" "$community"; do
    for method in GET PUT DELETE; do
        expect catalog "$method" "$path" 403
    done
    expect admin GET "$path" 200
    cmp "$work/payload" "$work/response" >/dev/null
done
expect catalog GET "/balaio-media/catalog-other/pi175-$run.txt" 403
expect catalog GET '/balaio-media?list-type=2&prefix=catalog%2F' 403
expect catalog GET '/balaio-media?policy' 403
attempted_bucket=true
expect catalog PUT "$denied_bucket" 403
status=$(curl --noproxy '*' --silent --max-time 10 --output /dev/null --write-out '%{http_code}' \
    "$endpoint/balaio-media/catalog/diagnostics/pi175-anonimo-$run.txt" 2>/dev/null) || status=000
[ "$status" = 403 ] || { echo "FAIL: anonymous GET HTTP $status expected 403"; exit 1; }
echo 'PASS: anonymous GET HTTP 403'
expect catalog GET '/' 200
grep -Eq '<Buckets[[:space:]]*/>|<Buckets>[[:space:]]*</Buckets>' "$work/response"
echo 'PASS: approved SeaweedFS 4.53 exception, ListBuckets contains no buckets'
