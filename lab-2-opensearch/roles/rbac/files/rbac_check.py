#!/usr/bin/env python3
"""Проверка ролевой модели: каждый пользователь реально выполняет запросы,
результат печатается матрицей (+ разрешено, - запрещено)."""
import base64
import datetime
import json
import ssl
import sys
import urllib.error
import urllib.request

url, ca, stream = sys.argv[1], sys.argv[2], sys.argv[3]
users = [u.split(":", 1) for u in sys.argv[4:]]
ctx = ssl.create_default_context(cafile=ca)
now = datetime.datetime.now(datetime.timezone.utc).isoformat()
doc = {"@timestamp": now, "method": "GET", "uri": "/rbac-check", "status": 200}
bulk = '{"create":{}}\n' + json.dumps(doc) + "\n"

CHECKS = [
    ("write " + stream, "POST", "/%s/_bulk" % stream, bulk),
    ("write other index", "POST", "/rbac-probe/_doc", json.dumps(doc)),
    ("read " + stream, "GET", "/%s/_search?size=1" % stream, None),
    ("read logs*", "GET", "/logs*/_search?size=1", None),
    ("read other index", "GET", "/rbac-probe/_search", None),
    ("delete logs docs", "POST", "/%s/_delete_by_query" % stream, '{"query":{"match_all":{}},"max_docs":1}'),
    ("prometheus metrics", "GET", "/_prometheus/metrics", None),
    ("cluster health", "GET", "/_cluster/health", None),
    ("nodes stats", "GET", "/_nodes/stats/jvm", None),
    ("cluster settings", "PUT", "/_cluster/settings", '{"transient":{"cluster.routing.rebalance.enable":"all"}}'),
    ("security api", "GET", "/_plugins/_security/api/internalusers", None),
]


def call(user, password, method, path, body):
    req = urllib.request.Request(url + path, method=method, data=body.encode() if body else None)
    token = base64.b64encode(("%s:%s" % (user, password)).encode()).decode()
    req.add_header("Authorization", "Basic " + token)
    ctype = "application/x-ndjson" if path.endswith("_bulk") else "application/json"
    req.add_header("Content-Type", ctype)
    try:
        with urllib.request.urlopen(req, context=ctx, timeout=30) as resp:
            text = resp.read().decode()
            if path.endswith("_bulk"):
                # bulk отвечает 200, отказ записан внутри ответа
                item = json.loads(text)["items"][0]["create"]
                return item["status"]
            return resp.status
    except urllib.error.HTTPError as err:
        return err.code


width = max(len(c[0]) for c in CHECKS)
print("%-*s  %s" % (width, "", "  ".join(u for u, _ in users)))
for name, method, path, body in CHECKS:
    cells = []
    for user, password in users:
        code = call(user, password, method, path, body)
        mark = "+" if code < 300 else "-"
        cells.append(("%s %d" % (mark, code)).ljust(len(user)))
    print("%-*s  %s" % (width, name, "  ".join(cells)))
