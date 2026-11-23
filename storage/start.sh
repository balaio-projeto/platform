#!/bin/sh
set -eu
export LC_ALL=C

fail() {
    echo 'SeaweedFS bloqueado: credenciais S3 ou certificados locais ausentes/invalidos. Consulte storage/docs/storage-local.md.' >&2
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
require_consumer_pair() {
    case "$1" in ''|*[!A-Za-z0-9_-]*) fail ;; esac
    case "$2" in ''|*[!\ -~]*) fail ;; esac
    [ "${#1}" -ge 20 ] && [ "${#1}" -le 128 ] || fail
    [ "${#2}" -ge 40 ] && [ "${#2}" -le 256 ] || fail
    [ "$1" != "$AWS_ACCESS_KEY_ID" ] || fail
    [ "$2" != "$AWS_SECRET_ACCESS_KEY" ] || fail
}

profile_identity=false
if [ -n "${MEDIA_S3_ACCESS_KEY_ID:-}${MEDIA_S3_SECRET_ACCESS_KEY:-}" ]; then
    require_consumer_pair "${MEDIA_S3_ACCESS_KEY_ID:-}" "${MEDIA_S3_SECRET_ACCESS_KEY:-}"
    [ -s /opt/balaio/storage/profile-s3-policy.json ] || fail
    profile_identity=true
fi
catalog_identity=false
if [ -n "${CATALOG_S3_ACCESS_KEY_ID:-}${CATALOG_S3_SECRET_ACCESS_KEY:-}" ]; then
    require_consumer_pair "${CATALOG_S3_ACCESS_KEY_ID:-}" "${CATALOG_S3_SECRET_ACCESS_KEY:-}"
    if [ "$profile_identity" = true ]; then
        [ "$CATALOG_S3_ACCESS_KEY_ID" != "$MEDIA_S3_ACCESS_KEY_ID" ] || fail
        [ "$CATALOG_S3_SECRET_ACCESS_KEY" != "$MEDIA_S3_SECRET_ACCESS_KEY" ] || fail
    fi
    [ -s /opt/balaio/storage/catalog-s3-policy.json ] || fail
    catalog_identity=true
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
json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}
consumer_identity() {
    printf ',{"name":"%s","credentials":[{"accessKey":"%s","secretKey":"%s"}],"policyNames":["%s"]}' \
        "$1" "$(json_escape "$3")" "$(json_escape "$4")" "$2"
}
consumer_policy() {
    printf '{"name":"%s","content":"%s"}' "$1" "$(tr -d '\r\n' < "$2" | sed 's/\\/\\\\/g; s/"/\\"/g')"
}
umask 077
config=$(mktemp /tmp/balaio-s3.XXXXXX)
policies=''
{
    printf '{"identities":[{"name":"balaio-local-admin","credentials":[{"accessKey":"%s","secretKey":"%s"}],"actions":["Admin"]}' \
        "$(json_escape "$AWS_ACCESS_KEY_ID")" "$(json_escape "$AWS_SECRET_ACCESS_KEY")"
    if [ "$profile_identity" = true ]; then
        consumer_identity balaio-profile-service balaio-profile-media "$MEDIA_S3_ACCESS_KEY_ID" "$MEDIA_S3_SECRET_ACCESS_KEY"
    fi
    if [ "$catalog_identity" = true ]; then
        consumer_identity balaio-catalog balaio-catalog-media "$CATALOG_S3_ACCESS_KEY_ID" "$CATALOG_S3_SECRET_ACCESS_KEY"
    fi
    printf ']'
} > "$config"
if [ "$profile_identity" = true ]; then
    policies=$(consumer_policy balaio-profile-media /opt/balaio/storage/profile-s3-policy.json)
fi
if [ "$catalog_identity" = true ]; then
    policies="${policies:+$policies,}$(consumer_policy balaio-catalog-media /opt/balaio/storage/catalog-s3-policy.json)"
fi
if [ -n "$policies" ]; then
    printf ',"policies":[%s]}\n' "$policies" >> "$config"
else
    printf '}\n' >> "$config"
fi
chown seaweed:seaweed "$config"
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY MEDIA_S3_ACCESS_KEY_ID MEDIA_S3_SECRET_ACCESS_KEY
unset CATALOG_S3_ACCESS_KEY_ID CATALOG_S3_SECRET_ACCESS_KEY policies

# The official entrypoint fixes /data ownership and drops to the seaweed user.
# TLS parse/validation errors must remain fatal in weed; never add a plaintext fallback.
exec /entrypoint.sh mini "-s3.config=$config" "$@"
