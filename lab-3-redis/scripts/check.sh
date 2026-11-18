#!/usr/bin/env bash
# Проверка стенда: контейнеры, настройки Redis, ACL, права в PostgreSQL, мониторинг.
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a

fail=0
pad() { local n=$((44 - ${#1})); ((n < 1)) && n=1; printf '  %s%*s%s' "$1" "$n" '' "$2"; }
ok()  { pad "$1" "$2"; echo; }
bad() { pad "$1" "$2"; echo '  <-- FAIL'; fail=1; }

rcli() { # rcli <user|-> <password> <command...>
  local user=$1 pass=$2; shift 2
  if [[ $user == - ]]; then
    docker compose exec -T redis redis-cli --no-auth-warning "$@" 2>&1
  else
    docker compose exec -T redis redis-cli --no-auth-warning --user "$user" --pass "$pass" "$@" 2>&1
  fi
}

echo "== Контейнеры"
docker compose ps --format '{{.Service}}|{{.Status}}' | sort -u -t'|' -k1,1 | while IFS='|' read -r svc status; do
  ok "$svc" "$status"
done
unhealthy=$(docker compose ps --format '{{.Status}}' | grep -cvE '^Up' || true)
[[ $unhealthy -eq 0 ]] || bad "не запущено контейнеров" "$unhealthy"

echo "== Redis"
ok "версия" "$(rcli admin "$REDIS_ADMIN_PASSWORD" INFO server | grep -E '^redis_version' | tr -d '\r')"
for p in maxmemory maxmemory-policy save appendonly; do
  v=$(rcli admin "$REDIS_ADMIN_PASSWORD" CONFIG GET $p | tail -1 | tr -d '\r')
  ok "$p" "${v:-\"\" (снимки RDB выключены)}"
done
ok "пользователи" "$(rcli admin "$REDIS_ADMIN_PASSWORD" ACL USERS | tr '\n' ' ')"

echo "== Матрица доступа Redis (+ разрешено, - отклонено)"
check_acl() { # check_acl <описание> <ожидание + или -> <user> <pass> <command...>
  local desc=$1 expect=$2 user=$3 pass=$4; shift 4
  local out; out=$(rcli "$user" "$pass" "$@" | head -1 | tr -d '\r')
  local got=+
  [[ $out == *NOPERM* || $out == *NOAUTH* || $out == *WRONGPASS* || $out == *"no permissions"* ]] && got=-
  local label="[${user/#-/default}] $desc"
  if [[ $got == "$expect" ]]; then ok "$label" "$got ${out:0:40}"; else bad "$label" "$got ${out:0:40}"; fi
}
check_acl "SET product:check"            + app      "$REDIS_APP_PASSWORD" SET product:check 1 EX 5
check_acl "GET product:check"            + app      "$REDIS_APP_PASSWORD" GET product:check
check_acl "SET session:1 (чужой префикс)" - app     "$REDIS_APP_PASSWORD" SET session:1 x
check_acl "KEYS *"                       - app      "$REDIS_APP_PASSWORD" KEYS '*'
check_acl "FLUSHALL"                     - app      "$REDIS_APP_PASSWORD" FLUSHALL
check_acl "CONFIG SET maxmemory"         - app      "$REDIS_APP_PASSWORD" CONFIG SET maxmemory 1gb
check_acl "INFO"                         + exporter "$REDIS_EXPORTER_PASSWORD" INFO memory
check_acl "CONFIG GET maxmemory"         + exporter "$REDIS_EXPORTER_PASSWORD" CONFIG GET maxmemory
check_acl "GET product:check"            - exporter "$REDIS_EXPORTER_PASSWORD" GET product:check
check_acl "CONFIG SET maxmemory"         - exporter "$REDIS_EXPORTER_PASSWORD" CONFIG SET maxmemory 1gb
check_acl "GET без пароля (default)"     - -        - GET product:check
check_acl "неверный пароль"              - app      wrong-password PING
check_acl "ACL WHOAMI"                   + admin    "$REDIS_ADMIN_PASSWORD" ACL WHOAMI

echo "== Права в PostgreSQL (пользователь catalog_app)"
pg() { docker compose exec -T -e PGPASSWORD="$PG_APP_PASSWORD" postgres \
         psql -h 127.0.0.1 -U catalog_app -d catalog -tAc "$1" 2>&1 | head -1; }
check_pg() {
  local desc=$1 expect=$2 out; out=$(pg "$3")
  local got=+; [[ $out == *"permission denied"* ]] && got=-
  if [[ $got == "$expect" ]]; then ok "$desc" "$got ${out:0:40}"; else bad "$desc" "$got ${out:0:40}"; fi
}
check_pg "SELECT count(*) FROM reviews"        + "SELECT count(*) FROM reviews"
check_pg "UPDATE products SET stock"           + "BEGIN; UPDATE products SET stock = stock WHERE id = 1; ROLLBACK"
check_pg "UPDATE products SET name"            - "UPDATE products SET name = name WHERE id = 1"
check_pg "DELETE FROM reviews"                 - "DELETE FROM reviews WHERE id = 1"
check_pg "CREATE TABLE"                        - "CREATE TABLE t (x int)"

echo "== Приложение"
for i in $(seq 1 "${APP_REPLICAS:-2}"); do
  port=$(docker compose port --index "$i" app 8000 | cut -d: -f2)
  ok "реплика $i (127.0.0.1:$port) /health" "$(curl -s "http://127.0.0.1:$port/health")"
done

echo "== Мониторинг"
targets=$(curl -s http://127.0.0.1:9090/api/v1/targets | python3 -c '
import json, sys
t = json.load(sys.stdin)["data"]["activeTargets"]
print(" ".join("{}={}".format(x["labels"]["job"], x["health"]) for x in t))
print(sum(x["health"] != "up" for x in t))')
down=$(tail -1 <<<"$targets")
[[ $down -eq 0 ]] && ok "цели Prometheus" "$(head -1 <<<"$targets")" || bad "цели Prometheus" "$(head -1 <<<"$targets")"
ok "правила алертов" "$(curl -s http://127.0.0.1:9090/api/v1/rules | python3 -c '
import json, sys
g = json.load(sys.stdin)["data"]["groups"]
r = [x for grp in g for x in grp["rules"]]
print(len(r), "правил,", "firing:", [x["name"] for x in r if x["state"] == "firing"] or "нет")')"
ok "Grafana" "$(curl -s http://127.0.0.1:3000/api/health | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["database"], d["version"])')"
ok "дашборд" "$(curl -s -u "admin:$GRAFANA_ADMIN_PASSWORD" http://127.0.0.1:3000/api/dashboards/uid/redis-cache \
  | python3 -c 'import json,sys; d=json.load(sys.stdin)["dashboard"]; print(d["title"], "-", sum(p["type"]!="row" for p in d["panels"]), "панелей")')"

exit $fail
