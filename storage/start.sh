#!/bin/sh
set -eu
export LC_ALL=C

fail() {
    echo 'SeaweedFS bloqueado: credenciais S3 ou certificados locais ausentes/invalidos. Consulte docs/storage-local.md.' >&2
    exit 1
}

# No fallback to anonymous mode, even when bypassing Compose interpolation.
# Restrict characters so credentials can also be passed to curl via stdin safely.
case "${AWS_ACCESS_KEY_ID:-}" in ''|*[!A-Za-z0-9_-]*) fail ;; esac
case "${AWS_SECRET_ACCESS_KEY:-}" in ''|*[!\ -~]*) fail ;; esac
[ "${#AWS_ACCESS_KEY_ID}" -ge 20 ] || fail
[ "${#AWS_ACCESS_KEY_ID}" -le 128 ] || fail
[ "${#AWS_SECRET_ACCESS_KEY}" -ge 40 ] || fail
[ "${#AWS_SECRET_ACCESS_KEY}" -le 256 ] || fail

# Storage is optional in develop. PI-213 recovery/CT-14 fixtures can carry only
# the administrator. A configured consumer must have a complete independent pair.
profile_identity=false
if [ -n "${MEDIA_S3_ACCESS_KEY_ID:-}${MEDIA_S3_SECRET_ACCESS_KEY:-}" ]; then
    case "${MEDIA_S3_ACCESS_KEY_ID:-}" in ''|*[!A-Za-z0-9_-]*) fail ;; esac
    case "${MEDIA_S3_SECRET_ACCESS_KEY:-}" in ''|*[!\ -~]*) fail ;; esac
    [ "${#MEDIA_S3_ACCESS_KEY_ID}" -ge 20 ] && [ "${#MEDIA_S3_ACCESS_KEY_ID}" -le 128 ] || fail
    [ "${#MEDIA_S3_SECRET_ACCESS_KEY}" -ge 40 ] && [ "${#MEDIA_S3_SECRET_ACCESS_KEY}" -le 256 ] || fail
    [ "$MEDIA_S3_ACCESS_KEY_ID" != "$AWS_ACCESS_KEY_ID" ] || fail
    [ "$MEDIA_S3_SECRET_ACCESS_KEY" != "$AWS_SECRET_ACCESS_KEY" ] || fail
    [ -s /opt/balaio/storage/profile-s3-policy.json ] || fail
    profile_identity=true
fi

for file in ca.crt tls.crt tls.key; do
    [ -f "/run/seaweedfs/$file" ] && [ -s "/run/seaweedfs/$file" ] && [ -r "/run/seaweedfs/$file" ] || fail
done

[ "$#" -gt 0 ] && [ "$1" = mini ] || fail
shift
for argument in "$@"; do
    case "$argument" in -s3.config*|-s3=false) fail ;; -*) ;; *) fail ;; esac
done

# SeaweedFS 4.53 logs the access key when using AWS env fallback. Build a
# deterministic, valid JSON config in tmpfs instead, then remove the fallback
# variables from weed's environment. Docker exec/healthcheck retain Config.Env.
access=$(printf '%s' "$AWS_ACCESS_KEY_ID" | sed 's/\\/\\\\/g; s/"/\\"/g')
secret=$(printf '%s' "$AWS_SECRET_ACCESS_KEY" | sed 's/\\/\\\\/g; s/"/\\"/g')
umask 077
config=$(mktemp /tmp/balaio-s3.XXXXXX)
printf '{"identities":[{"name":"balaio-local-admin","credentials":[{"accessKey":"%s","secretKey":"%s"}],"actions":["Admin"]}' \
    "$access" "$secret" > "$config"
if [ "$profile_identity" = true ]; then
    profile_access=$(printf '%s' "$MEDIA_S3_ACCESS_KEY_ID" | sed 's/\\/\\\\/g; s/"/\\"/g')
    profile_secret=$(printf '%s' "$MEDIA_S3_SECRET_ACCESS_KEY" | sed 's/\\/\\\\/g; s/"/\\"/g')
    policy=$(tr -d '\r\n' < /opt/balaio/storage/profile-s3-policy.json | sed 's/\\/\\\\/g; s/"/\\"/g')
    printf ',{"name":"balaio-profile-service","credentials":[{"accessKey":"%s","secretKey":"%s"}],"policyNames":["balaio-profile-media"]}],"policies":[{"name":"balaio-profile-media","content":"%s"}]}\n' \
        "$profile_access" "$profile_secret" "$policy" >> "$config"
else
    printf ']}\n' >> "$config"
fi
chown seaweed:seaweed "$config"
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY MEDIA_S3_ACCESS_KEY_ID MEDIA_S3_SECRET_ACCESS_KEY
unset access secret profile_access profile_secret policy

# The official entrypoint fixes /data ownership and drops to the seaweed user.
# TLS parse/validation errors must remain fatal in weed; never add a plaintext fallback.
exec /entrypoint.sh mini "-s3.config=$config" "$@"
