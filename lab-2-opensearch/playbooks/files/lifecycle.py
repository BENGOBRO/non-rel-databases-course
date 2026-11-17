#!/usr/bin/env python3
"""Состояние data stream: индексы, их размер, возраст, узел и шаг политики ISM."""
import base64
import json
import ssl
import sys
import time
import urllib.request

url, ca, user, password, stream = sys.argv[1:6]
ctx = ssl.create_default_context(cafile=ca)
auth = "Basic " + base64.b64encode(("%s:%s" % (user, password)).encode()).decode()


def get(path):
    req = urllib.request.Request(url + path, headers={"Authorization": auth})
    with urllib.request.urlopen(req, context=ctx, timeout=30) as resp:
        return json.loads(resp.read().decode())


pattern = ".ds-%s-*" % stream
ds = get("/_data_stream/" + stream)["data_streams"][0]
write_index = ds["indices"][-1]["index_name"]
indices = get("/_cat/indices/%s?format=json&bytes=b&h=index,health,docs.count,pri.store.size,creation.date,rep&expand_wildcards=all" % pattern)
shards = get("/_cat/shards/%s?format=json&h=index,prirep,state,node" % pattern)
attrs = {a["node"]: a["value"] for a in get("/_cat/nodeattrs?format=json&h=node,attr,value") if a["attr"] == "temp"}
explain = get("/_plugins/_ism/explain/" + pattern)
total = get("/%s/_count" % stream)["count"]

print("data stream %s: generation %d, %d indices, %d docs, write index %s" % (
    stream, ds["generation"], len(indices), total, write_index))
print("%-28s %-6s %6s %9s %5s %3s  %-34s %-7s %s" % (
    "INDEX", "HEALTH", "DOCS", "PRI SIZE", "AGE", "REP", "SHARDS ON", "STATE", "ISM STEP"))
now = time.time()
for idx in sorted(indices, key=lambda i: i["index"]):
    name = idx["index"]
    where = ", ".join(sorted(
        "%s(%s)%s" % (s["node"], attrs.get(s["node"], "?"), "" if s["state"] == "STARTED" else "*")
        for s in shards if s["index"] == name and s["node"]))
    ism = explain.get(name, {})
    state = (ism.get("state") or {}).get("name", "-")
    if ism.get("transition_to"):
        state = "->" + ism["transition_to"]
    step = "%s/%s" % ((ism.get("action") or {}).get("name", "-"), (ism.get("step") or {}).get("step_status", "-"))
    age = int(now - int(idx["creation.date"]) / 1000)
    print("%-28s %-6s %6s %8.1fK %4dm%02d %3s  %-34s %-7s %s%s" % (
        name, idx["health"], idx["docs.count"], int(idx["pri.store.size"] or 0) / 1024, age // 60, age % 60,
        idx["rep"], where, state, step, "  <- write" if name == write_index else ""))
