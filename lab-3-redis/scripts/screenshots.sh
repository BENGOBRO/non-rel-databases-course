#!/usr/bin/env bash
# Снимки дашборда Grafana через grafana-image-renderer и страницы целей Prometheus.
# ./scripts/screenshots.sh <префикс> <from ISO> <to ISO>
# Нужен запущенный renderer: docker compose --profile screenshots up -d renderer
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; source .env; set +a
prefix=$1
from=$(python3 -c "import datetime,sys; print(int(datetime.datetime.fromisoformat(sys.argv[1].replace('Z','+00:00')).timestamp()*1000))" "$2")
to=$(python3 -c "import datetime,sys; print(int(datetime.datetime.fromisoformat(sys.argv[1].replace('Z','+00:00')).timestamp()*1000))" "$3")

full="img/.$prefix-full.png"
curl -sf -u "admin:$GRAFANA_ADMIN_PASSWORD" -o "$full" \
  "http://127.0.0.1:3000/render/d/redis-cache/x?from=$from&to=$to&width=1600&height=3800&kiosk=true&tz=Europe/Moscow&timeout=90"

# Разрезать по строкам дашборда (нужен Pillow: PYTHON=/путь/к/python с pillow)
"${PYTHON:-python3}" - "$full" "$prefix" <<'PY'
import sys
from PIL import Image
full, prefix = sys.argv[1:]
img = Image.open(full)
for name, top, bottom in [("app", 0, 1515), ("redis", 1515, 2470), ("postgres", 2470, 3150)]:
    img.crop((0, top, img.width, bottom)).save(f"img/{prefix}-{name}.png", optimize=True)
PY
rm -f "$full"

if [[ ! -f img/prometheus-targets.png ]]; then
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --disable-gpu \
    --window-size=1400,820 --virtual-time-budget=8000 --hide-scrollbars \
    --screenshot="$PWD/img/prometheus-targets.png" "http://127.0.0.1:9090/targets" 2>/dev/null
fi
ls -la img/
