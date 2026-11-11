#!/bin/sh
set -eu
endpoint=${S3_HEALTH_ENDPOINT:-http://127.0.0.1:8333}

# A signed HeadBucket exercises authentication, bucket readiness and filer metadata.
# Pass credentials through stdin, never argv, stdout, or healthcheck error output.
access=$(printf '%s' "$AWS_ACCESS_KEY_ID" | sed 's/\\/\\\\/g; s/"/\\"/g')
secret=$(printf '%s' "$AWS_SECRET_ACCESS_KEY" | sed 's/\\/\\\\/g; s/"/\\"/g')
printf 'user = "%s:%s"\n' "$access" "$secret" |
    curl --config - --noproxy '*' --silent --fail --max-time 5 \
        --aws-sigv4 'aws:amz:us-east-1:s3' \
        --head --output /dev/null "$endpoint/balaio-media" 2>/dev/null || exit 1

# Anonymous success is a failure, not a readiness signal.
status=$(curl --noproxy '*' --silent --max-time 3 --output /dev/null \
    --write-out '%{http_code}' "$endpoint/" 2>/dev/null) || exit 1
[ "$status" = 403 ] || exit 1
