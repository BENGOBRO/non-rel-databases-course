#!/usr/bin/env bash
# Скачивает пакеты OpenSearch и Grafana на управляющую машину (с докачкой и проверкой sha512)
# и раскладывает их по ВМ в /var/cache/nrdb-lab, откуда их ставит Ansible.
#   ./fetch-artifacts.sh            скачать и загрузить на ВМ
#   ./fetch-artifacts.sh download   только скачать
#   ./fetch-artifacts.sh upload     только загрузить на ВМ
set -euo pipefail
cd "$(dirname "$0")"

VERSION=3.8.0
ARCH=arm64
SSH_USER=ubuntu
REMOTE_DIR=/var/cache/nrdb-lab
BASE=https://artifacts.opensearch.org/releases/bundle

OS_DEB="opensearch-$VERSION-linux-$ARCH.deb"
OSD_DEB="opensearch-dashboards-$VERSION-linux-$ARCH.deb"
EXPORTER_ZIP="prometheus-exporter-$VERSION.0.zip"
GRAFANA_DEB="grafana_13.3.1_42849527790_linux_$ARCH.deb"
MUSL_DEB="musl_1.2.4-2_$ARCH.deb"

mkdir -p artifacts

# с докачкой; медленное или оборванное соединение перезапускается
fetch() {
    local url=$1 file="artifacts/${1##*/}" size have try
    size=$(curl -4 -fsSLI --retry 10 --retry-all-errors "$url" | tr -d '\r' | awk 'tolower($1) == "content-length:" {n = $2} END {print n}')
    for try in $(seq 1 300); do
        have=$(stat -f %z "$file" 2>/dev/null || stat -c %s "$file" 2>/dev/null || echo 0)
        if [[ "$have" -ge "$size" ]]; then
            return 0
        fi
        echo "  попытка $try: есть $((have / 1048576)) из $((size / 1048576)) МБ"
        curl -4 -fL -C - --connect-timeout 15 --speed-limit 100000 --speed-time 20 \
            --progress-bar -o "$file" "$url" || sleep 3
    done
    echo "не удалось скачать $url" >&2
    return 1
}

verify() {
    local file=$1 url=$2 want got
    want=$(curl -4 -fsSL --retry 10 --retry-all-errors "$url.sha512" | awk '{print $1}')
    got=$(shasum -a 512 "artifacts/$file" | awk '{print $1}')
    if [[ "$want" != "$got" ]]; then
        echo "sha512 не совпадает: $file - удалите файл и запустите снова" >&2
        return 1
    fi
    echo "  sha512 ok: $file"
}

# sha256 пакета Grafana берётся из индекса её apt-репозитория
verify_grafana() {
    local want got
    want=$(curl -4 -fsSL --retry 10 --retry-all-errors "https://apt.grafana.com/dists/stable/main/binary-$ARCH/Packages" \
        | awk -v f="pool/main/g/grafana/$GRAFANA_DEB" '$1 == "Filename:" {hit = ($2 == f)} hit && $1 == "SHA256:" {print $2; hit = 0}')
    got=$(shasum -a 256 "artifacts/$GRAFANA_DEB" | awk '{print $1}')
    if [[ -z "$want" || "$want" != "$got" ]]; then
        echo "sha256 не совпадает: $GRAFANA_DEB - удалите файл и запустите снова" >&2
        return 1
    fi
    echo "  sha256 ok: $GRAFANA_DEB"
}

download() {
    echo "== $OS_DEB"
    fetch "$BASE/opensearch/$VERSION/$OS_DEB"
    verify "$OS_DEB" "$BASE/opensearch/$VERSION/$OS_DEB"
    echo "== $OSD_DEB"
    fetch "$BASE/opensearch-dashboards/$VERSION/$OSD_DEB"
    verify "$OSD_DEB" "$BASE/opensearch-dashboards/$VERSION/$OSD_DEB"
    echo "== $EXPORTER_ZIP"
    fetch "https://github.com/opensearch-project/opensearch-prometheus-exporter/releases/download/$VERSION.0/$EXPORTER_ZIP"
    unzip -tq "artifacts/$EXPORTER_ZIP"
    echo "== $GRAFANA_DEB"
    fetch "https://apt.grafana.com/pool/main/g/grafana/$GRAFANA_DEB"
    verify_grafana
    echo "== $MUSL_DEB"
    fetch "http://ports.ubuntu.com/ubuntu-ports/pool/universe/m/musl/$MUSL_DEB"
    ar t "artifacts/$MUSL_DEB" > /dev/null
}

# адреса ВМ берутся из инвентаря Ansible
hosts_of() {
    ansible-inventory --list | python3 -c '
import json, sys
inv = json.load(sys.stdin)
def hosts(group):
    g = inv.get(group, {})
    out = list(g.get("hosts", []))
    for child in g.get("children", []):
        out += hosts(child)
    return out
for h in hosts(sys.argv[1]):
    print(inv["_meta"]["hostvars"][h]["ansible_host"])' "$1"
}

push() {
    local ip=$1
    shift
    local ssh_opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
    echo "== $ip: $*"
    ssh "${ssh_opts[@]}" "$SSH_USER@$ip" "sudo mkdir -p $REMOTE_DIR && sudo chown $SSH_USER $REMOTE_DIR"
    local f
    for f in "$@"; do
        rsync -e "ssh ${ssh_opts[*]}" --partial --progress --size-only "artifacts/$f" "$SSH_USER@$ip:$REMOTE_DIR/$f"
    done
    ssh "${ssh_opts[@]}" "$SSH_USER@$ip" "sudo chown -R root:root $REMOTE_DIR && sudo chmod 644 $REMOTE_DIR/* && ls -la $REMOTE_DIR"
}

upload() {
    local ip
    for ip in $(hosts_of opensearch); do
        push "$ip" "$OS_DEB" "$EXPORTER_ZIP"
    done
    for ip in $(hosts_of ops); do
        push "$ip" "$OSD_DEB" "$GRAFANA_DEB" "$MUSL_DEB"
    done
}

case "${1:-all}" in
    download) download ;;
    upload) upload ;;
    all) download; upload ;;
    *) echo "usage: $0 [download|upload]" >&2; exit 2 ;;
esac
echo "готово"
