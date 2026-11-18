#!/bin/sh
# Собирает ACL-файл из паролей в окружении и запускает redis-server.
set -eu

: "${REDIS_ADMIN_PASSWORD:?}" "${REDIS_APP_PASSWORD:?}" "${REDIS_EXPORTER_PASSWORD:?}"

umask 077
cat > /data/users.acl <<EOF
user default off resetkeys resetchannels -@all
user admin on #$(printf %s "$REDIS_ADMIN_PASSWORD" | sha256sum | cut -d' ' -f1) ~* &* +@all
user app on #$(printf %s "$REDIS_APP_PASSWORD" | sha256sum | cut -d' ' -f1) resetchannels ~product:* ~category:* ~lock:* -@all +get +set +del +unlink +exists +ttl +ping +hello +auth +client|setname +client|setinfo
user exporter on #$(printf %s "$REDIS_EXPORTER_PASSWORD" | sha256sum | cut -d' ' -f1) resetkeys resetchannels -@all +ping +hello +auth +info +config|get +slowlog|get +slowlog|len +latency|latest +latency|histogram +client|list +client|setname +client|setinfo +dbsize +select +memory|stats +command|info
EOF
chown redis:redis /data/users.acl

exec docker-entrypoint.sh redis-server /usr/local/etc/redis/redis.conf
