#!/usr/bin/env python3
"""Нагрузка на nginx: traffic.py <url> <секунд> <запросов в секунду>."""
import random
import sys
import threading
import time
import urllib.error
import urllib.request

base, duration, rps = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
PATHS = ["/", "/", "/", "/index.html", "/api/status", "/api/status", "/missing", "/admin"]
AGENTS = [
    "Mozilla/5.0 (X11; Linux x86_64) Firefox/131.0",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_6) Safari/605.1.15",
    "curl/8.5.0",
    "lab-traffic/1.0",
]
workers = max(2, min(64, rps // 5))
delay = workers / rps
stop = time.time() + duration
counts = {}
lock = threading.Lock()


def worker():
    while time.time() < stop:
        path = random.choice(PATHS) + "?page=%d" % random.randint(1, 500)
        req = urllib.request.Request(base + path, headers={"User-Agent": random.choice(AGENTS)})
        try:
            with urllib.request.urlopen(req, timeout=5) as resp:
                code = resp.status
                resp.read()
        except urllib.error.HTTPError as err:
            code = err.code
        except OSError:
            code = 0
        with lock:
            counts[code] = counts.get(code, 0) + 1
        time.sleep(delay)


threads = [threading.Thread(target=worker) for _ in range(workers)]
for t in threads:
    t.start()
for t in threads:
    t.join()
total = sum(counts.values())
print("%d requests in %d s (%.0f rps): %s" % (
    total, duration, total / duration, ", ".join("%s=%d" % kv for kv in sorted(counts.items()))))
