#!/usr/bin/env bash
# Демонстрация работы кэша: промах/попадание, инвалидация, кэширование 404,
# защита от лавины промахов и работа при недоступном Redis.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a

port() { docker compose port --index "$1" app 8000 | cut -d: -f2; }
A="http://127.0.0.1:$(port 1)"
B="http://127.0.0.1:$(port 2)"
rcli() { docker compose exec -T redis redis-cli --no-auth-warning --user admin --pass "$REDIS_ADMIN_PASSWORD" "$@"; }
req() { # req <метод> <url> [тело] -> "код X-Cache время"
  local args=(-s -o /dev/null -D - -w 'code=%{http_code} time=%{time_total}s' -X "$1" "$2")
  [[ $# -gt 2 ]] && args+=(-H 'Content-Type: application/json' -d "$3")
  curl "${args[@]}" | tr -d '\r' | awk -F': ' 'tolower($1)=="x-cache"{c=$2} /^code=/{print $0, "X-Cache=" c}'
}
metric() { # сумма счётчика по обеим репликам
  { curl -s "$A/metrics"; curl -s "$B/metrics"; } | awk -v m="$1" 'index($0, m) == 1 {s += $NF} END {print s + 0}'
}

id=$((RANDOM % 40000 + 1))
echo "== 1. Cache-aside: товар $id"
rcli UNLINK "product:$id" >/dev/null
echo "  1-й запрос (реплика 1): $(req GET "$A/products/$id")"
echo "  2-й запрос (реплика 1): $(req GET "$A/products/$id")"
echo "  3-й запрос (реплика 2): $(req GET "$B/products/$id")"
echo "  ключ product:$id: TTL $(rcli TTL "product:$id") с, $(rcli MEMORY USAGE "product:$id") байт"

echo "== 2. Инвалидация при изменении"
echo "  цена до:      $(curl -s "$A/products/$id" | python3 -c 'import json,sys; print(json.load(sys.stdin)["price"])')"
echo "  PATCH:        $(curl -s -X PATCH -H 'Content-Type: application/json' -d '{"price": 999.99}' "$A/products/$id")"
echo "  ключ после:   EXISTS=$(rcli EXISTS "product:$id")"
echo "  GET (реплика 2): $(req GET "$B/products/$id"), цена $(curl -s "$B/products/$id" | python3 -c 'import json,sys; print(json.load(sys.stdin)["price"])')"

echo "== 3. Кэширование отсутствующих товаров"
missing=$((RANDOM + 100000))
echo "  1-й запрос: $(req GET "$A/products/$missing")"
echo "  2-й запрос: $(req GET "$A/products/$missing")"
echo "  ключ product:$missing: TTL $(rcli TTL "product:$missing") с"

echo "== 4. Лавина промахов: 200 одновременных запросов к холодному ключу"
cat=$((RANDOM % 40 + 1))
rcli UNLINK "category:$cat:top" >/dev/null
before=$(metric 'app_db_query_duration_seconds_count{query="category_top"}')
waits_before=$(metric 'app_cache_lock_waits_total{outcome="served_from_cache"}')
seq 200 | xargs -P 200 -I{} sh -c "if [ \$(({} % 2)) -eq 0 ]; then curl -s -o /dev/null $A/categories/$cat/top; else curl -s -o /dev/null $B/categories/$cat/top; fi"
after=$(metric 'app_db_query_duration_seconds_count{query="category_top"}')
echo "  запросов топа категории $cat в PostgreSQL: $((after - before)) на 200 HTTP-запросов"
echo "  дождались значения в кэше: $(( $(metric 'app_cache_lock_waits_total{outcome="served_from_cache"}') - waits_before ))"

echo "== 5. Отказ Redis"
errors_before=$(metric app_cache_errors_total)
docker compose stop redis >/dev/null 2>&1
sleep 1
for i in 1 2 3; do echo "  Redis остановлен, запрос $i: $(req GET "$A/products/$id")"; done
echo "  /health: $(curl -s "$A/health")"
echo "  ошибок Redis в приложении: $(( $(metric app_cache_errors_total) - errors_before ))"
docker compose start redis >/dev/null 2>&1
until rcli PING 2>/dev/null | grep -q PONG; do sleep 1; done
sleep 3  # после ошибки приложение 2 с не обращается к Redis
echo "  Redis запущен, запрос 1: $(req GET "$A/products/$id")"
echo "  Redis запущен, запрос 2: $(req GET "$A/products/$id")"
