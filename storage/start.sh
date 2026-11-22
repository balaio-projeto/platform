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
if [ -n "${CATALOG_S3_ACCESS_KEY_ID:-}${CATALOG_S3_SECRET_ACCESS_KEY:-}" ]; then
    case "${CATALOG_S3_ACCESS_KEY_ID:-}" in ''|*[!A-Za-z0-9_-]*) fail ;; esac
    case "${CATALOG_S3_SECRET_ACCESS_KEY:-}" in ''|*[!A-Za-z0-9_-]*) fail ;; esac
    [ "${#CATALOG_S3_ACCESS_KEY_ID}" -ge 20 ] && [ "${#CATALOG_S3_ACCESS_KEY_ID}" -le 128 ] || fail
    [ "${#CATALOG_S3_SECRET_ACCESS_KEY}" -ge 40 ] && [ "${#CATALOG_S3_SECRET_ACCESS_KEY}" -le 256 ] || fail
    [ "$CATALOG_S3_ACCESS_KEY_ID" != "$AWS_ACCESS_KEY_ID" ] || fail
    [ "$CATALOG_S3_SECRET_ACCESS_KEY" != "$AWS_SECRET_ACCESS_KEY" ] || fail
    printf ',{"name":"balaio-catalog","credentials":[{"accessKey":"%s","secretKey":"%s"}],"actions":["Read:balaio-media/catalog/*","Write:balaio-media/catalog/*"]}' \
        "$CATALOG_S3_ACCESS_KEY_ID" "$CATALOG_S3_SECRET_ACCESS_KEY" >> "$config"
fi
printf ']}\n' >> "$config"
chown seaweed:seaweed "$config"
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY CATALOG_S3_ACCESS_KEY_ID CATALOG_S3_SECRET_ACCESS_KEY access secret

# The official entrypoint fixes /data ownership and drops to the seaweed user.
# TLS parse/validation errors must remain fatal in weed; never add a plaintext fallback.
exec /entrypoint.sh mini "-s3.config=$config" "$@"
