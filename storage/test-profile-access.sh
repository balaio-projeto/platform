#!/bin/sh
set -eu
endpoint=${MEDIA_S3_ENDPOINT:-http://seaweedfs:8333}
work=$(mktemp -d /tmp/pi214.XXXXXX)
run=$(cat /proc/sys/kernel/random/uuid)
profile="/balaio-media/profile/diagnostics/pi214-$run.txt"
catalog="/balaio-media/catalog/diagnostics/pi214-$run.txt"
community="/balaio-media/community/diagnostics/pi214-$run.txt"
created_profile=false
created_catalog=false
created_community=false
attempted_bucket=false
denied_bucket="/pi214-denied-$run"
printf 'PI-214 non-sensitive diagnostic %s\n' "$run" > "$work/payload"

request() {
    role=$1
    method=$2
    path=$3
    if [ "$role" = admin ]; then
        key=$AWS_ACCESS_KEY_ID
        secret=$AWS_SECRET_ACCESS_KEY
    else
        key=$MEDIA_S3_ACCESS_KEY_ID
        secret=$MEDIA_S3_SECRET_ACCESS_KEY
    fi
    key=$(printf '%s' "$key" | sed 's/\\/\\\\/g; s/"/\\"/g')
    secret=$(printf '%s' "$secret" | sed 's/\\/\\\\/g; s/"/\\"/g')
    set -- --request "$method"
    if [ "$method" = PUT ]; then
        set -- "$@" --data-binary "@$work/payload"
    fi
    printf 'user = "%s:%s"\n' "$key" "$secret" |
        curl --config - --noproxy '*' --silent --max-time 10 \
            --aws-sigv4 'aws:amz:us-east-1:s3' --output "$work/response" \
            --write-out '%{http_code}' "$@" "$endpoint$path" 2>/dev/null
}

expect() {
    actual=$(request "$1" "$2" "$3") || { echo 'FAIL: S3 transport'; exit 1; }
    [ "$actual" = "$4" ] || { echo "FAIL: $2 $3 HTTP $actual expected $4"; exit 1; }
    echo "PASS: $2 $3 HTTP $actual"
}

cleanup() {
    failed=0
    if [ "$created_profile" = true ]; then
        status=$(request admin DELETE "$profile") || status=000
        [ "$status" = 204 ] || failed=1
    fi
    if [ "$created_catalog" = true ]; then
        status=$(request admin DELETE "$catalog") || status=000
        [ "$status" = 204 ] || failed=1
    fi
    if [ "$created_community" = true ]; then
        status=$(request admin DELETE "$community") || status=000
        [ "$status" = 204 ] || failed=1
    fi
    if [ "$attempted_bucket" = true ]; then
        status=$(request admin DELETE "$denied_bucket") || status=000
        case "$status" in 204|404) ;; *) failed=1 ;; esac
    fi
    if [ "$failed" = 1 ]; then
        echo "FAIL: diagnostic cleanup incomplete, run $run"
        return 1
    fi
    echo 'PASS: unique diagnostic objects removed'
}
trap cleanup EXIT

# Register intent before PUT so a transport interruption still triggers cleanup.
created_profile=true
expect profile PUT "$profile" 200
expect profile GET "$profile" 200
cmp "$work/payload" "$work/response" >/dev/null
echo 'PASS: profile downloaded bytes identical'
expect profile GET "$profile?acl" 403
expect profile PUT "$profile?acl" 403
expect profile DELETE "$profile" 204
created_profile=false

created_catalog=true
expect admin PUT "$catalog" 200
created_community=true
expect admin PUT "$community" 200
for path in "$catalog" "$community"; do
    for method in GET PUT DELETE; do
        expect profile "$method" "$path" 403
    done
    expect admin GET "$path" 200
    cmp "$work/payload" "$work/response" >/dev/null
done
expect profile GET "/balaio-media/profile-other/pi214-$run.txt" 403
expect profile GET '/balaio-media?list-type=2&prefix=profile%2F' 403
expect profile GET '/balaio-media?policy' 403
# Destructive bucket/policy denials were proven on isolated tmpfs fixtures.
# On the main storage, only a unique disposable bucket may be targeted.
attempted_bucket=true
expect profile PUT "$denied_bucket" 403
expect profile GET "$catalog?acl" 403
expect profile GET '/' 200
grep -Eq '<Buckets[[:space:]]*/>|<Buckets>[[:space:]]*</Buckets>' "$work/response"
echo 'PASS: approved SeaweedFS 4.53 exception, ListBuckets contains no buckets'
