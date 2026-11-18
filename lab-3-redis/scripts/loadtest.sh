#!/usr/bin/env bash
# Нагрузочный прогон: ./scripts/loadtest.sh <имя> <cache on|off> <целевой RPS> <удержание>
# Пример: ./scripts/loadtest.sh cache on 2000 2m
set -euo pipefail
cd "$(dirname "$0")/.."
name=$1 mode=$2 rps=$3 hold=$4

if [[ $mode == off ]]; then
  CACHE_ENABLED=false docker compose up -d --wait app >/dev/null 2>&1
else
  CACHE_ENABLED=true docker compose up -d --wait app >/dev/null 2>&1
  [[ ${COLD:-1} == 1 ]] && docker compose restart redis >/dev/null 2>&1   # холодный кэш
fi
sleep 10

mkdir -p loadtest/results
date -u +%FT%TZ > "loadtest/results/$name.start"
docker compose --profile loadtest run --rm -e TARGET_RPS="$rps" -e HOLD="$hold" -e SUMMARY="$name" \
  k6 run -q -o experimental-prometheus-rw --tag testid="$name" /scripts/catalog.js \
  2>&1 | grep -v 'level=warning' | tee "loadtest/results/$name.txt" || true
date -u +%FT%TZ > "loadtest/results/$name.end"
