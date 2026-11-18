"""Каталог товаров: API поверх PostgreSQL с кэшем Redis (cache-aside)."""

import asyncio
import logging
import os
import random
import secrets
import time
from contextlib import asynccontextmanager

import asyncpg
import orjson
import redis.asyncio as redis
from fastapi import FastAPI, HTTPException, Request, Response
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Gauge, Histogram, generate_latest
from pydantic import BaseModel, Field

DATABASE_URL = os.environ["DATABASE_URL"]
REDIS_URL = os.environ["REDIS_URL"]
CACHE_ENABLED = os.environ.get("CACHE_ENABLED", "true").lower() == "true"
PRODUCT_TTL = int(os.environ.get("PRODUCT_TTL", "300"))
CATEGORY_TTL = int(os.environ.get("CATEGORY_TTL", "60"))
NEGATIVE_TTL = int(os.environ.get("NEGATIVE_TTL", "30"))
TTL_JITTER = float(os.environ.get("TTL_JITTER", "0.1"))
DB_POOL_SIZE = int(os.environ.get("DB_POOL_SIZE", "10"))
REDIS_TIMEOUT = float(os.environ.get("REDIS_TIMEOUT", "0.25"))
REDIS_RETRY_AFTER = float(os.environ.get("REDIS_RETRY_AFTER", "2"))
REDIS_POOL_SIZE = int(os.environ.get("REDIS_POOL_SIZE", "100"))
REDIS_FAILURE_THRESHOLD = int(os.environ.get("REDIS_FAILURE_THRESHOLD", "5"))
LOCK_TTL_MS = 3000
LOCK_WAIT = 1.0

NOT_FOUND = b"\x00none"

log = logging.getLogger("catalog")

LATENCY_BUCKETS = (0.0005, 0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5)

HTTP_REQUESTS = Counter("app_http_requests_total", "HTTP requests", ["method", "route", "status"])
HTTP_LATENCY = Histogram(
    "app_http_request_duration_seconds", "HTTP request latency", ["route", "cache"], buckets=LATENCY_BUCKETS
)
CACHE_REQUESTS = Counter("app_cache_requests_total", "Cache lookups", ["entity", "result"])
CACHE_ERRORS = Counter("app_cache_errors_total", "Redis errors (request served from DB)", ["op", "error"])
CACHE_INVALIDATIONS = Counter("app_cache_invalidations_total", "Keys removed after writes")
LOCK_WAITS = Counter("app_cache_lock_waits_total", "Requests that waited for another loader", ["outcome"])
REDIS_LATENCY = Histogram(
    "app_redis_command_duration_seconds", "Redis command latency seen by app", ["command"], buckets=LATENCY_BUCKETS
)
DB_LATENCY = Histogram("app_db_query_duration_seconds", "DB query latency", ["query"], buckets=LATENCY_BUCKETS)
CACHE_MODE = Gauge("app_cache_enabled", "1 if cache is enabled")
DB_POOL = Gauge("app_db_pool_connections", "DB pool connections", ["state"])

PRODUCT_SQL = """
SELECT p.id, p.name, p.description, p.price::float8 AS price, p.stock, p.updated_at,
       json_build_object('id', c.id, 'name', c.name) AS category,
       json_build_object('count', s.cnt, 'avg', s.avg,
                         'histogram', json_build_array(s.r1, s.r2, s.r3, s.r4, s.r5)) AS rating,
       (SELECT coalesce(json_agg(t), '[]')
          FROM (SELECT author, rating, body, created_at
                  FROM reviews WHERE product_id = p.id
                 ORDER BY created_at DESC LIMIT 5) AS t) AS latest_reviews
  FROM products p
  JOIN categories c ON c.id = p.category_id
 CROSS JOIN LATERAL (
       SELECT count(*) AS cnt, round(avg(rating), 2)::float8 AS avg,
              count(*) FILTER (WHERE rating = 1) AS r1, count(*) FILTER (WHERE rating = 2) AS r2,
              count(*) FILTER (WHERE rating = 3) AS r3, count(*) FILTER (WHERE rating = 4) AS r4,
              count(*) FILTER (WHERE rating = 5) AS r5
         FROM reviews WHERE product_id = p.id) AS s
 WHERE p.id = $1
"""

CATEGORY_TOP_SQL = """
SELECT p.id, p.name, p.price::float8 AS price,
       round(avg(r.rating), 2)::float8 AS rating, count(*) AS reviews
  FROM products p
  JOIN reviews r ON r.product_id = p.id
 WHERE p.category_id = $1
 GROUP BY p.id
 ORDER BY rating DESC, reviews DESC, p.id
 LIMIT 20
"""

UPDATE_SQL = """
UPDATE products
   SET price = coalesce($2, price), stock = coalesce($3, stock), updated_at = now()
 WHERE id = $1
RETURNING category_id
"""


class CacheError(Exception):
    """Redis недоступен или выключен: запрос обслуживается из PostgreSQL."""


class Cache:
    """Обёртка над Redis: метрики, таймауты и обход кэша, пока Redis недоступен.

    Одиночная ошибка (например, таймаут под нагрузкой) влияет только на текущий
    запрос. Кэш отключается на REDIS_RETRY_AFTER секунд лишь после
    REDIS_FAILURE_THRESHOLD ошибок подряд — иначе случайный таймаут переводил бы
    весь трафик реплики в PostgreSQL, который такой поток не выдерживает.
    """

    def __init__(self, url: str):
        # Пул с ожиданием: при всплеске запрос ждёт свободное соединение,
        # а не получает ошибку «Too many connections» и не уходит в БД.
        pool = redis.BlockingConnectionPool.from_url(
            url,
            max_connections=REDIS_POOL_SIZE,
            timeout=REDIS_TIMEOUT,
            socket_timeout=REDIS_TIMEOUT,
            socket_connect_timeout=REDIS_TIMEOUT,
            client_name="catalog-app",
        )
        self.client = redis.Redis(connection_pool=pool)
        self.down_until = 0.0
        self.failures = 0

    @property
    def available(self) -> bool:
        return CACHE_ENABLED and time.monotonic() >= self.down_until

    async def call(self, command: str, *args, **kwargs):
        if not self.available:
            raise CacheError("cache disabled or temporarily bypassed")
        start = time.perf_counter()
        try:
            result = await getattr(self.client, command)(*args, **kwargs)
            self.failures = 0
            return result
        except (redis.RedisError, OSError, asyncio.TimeoutError) as exc:
            CACHE_ERRORS.labels(command, type(exc).__name__).inc()
            self.failures += 1
            if self.failures >= REDIS_FAILURE_THRESHOLD and self.available:
                log.warning("redis %s failed %d times in a row (%r); bypassing cache for %.0fs",
                            command, self.failures, exc, REDIS_RETRY_AFTER)
                self.down_until = time.monotonic() + REDIS_RETRY_AFTER
            raise CacheError from exc
        finally:
            REDIS_LATENCY.labels(command).observe(time.perf_counter() - start)


def ttl_with_jitter(ttl: int) -> int:
    """Разброс TTL, чтобы ключи, записанные одновременно, не истекали одновременно."""
    return max(1, round(ttl * random.uniform(1 - TTL_JITTER, 1 + TTL_JITTER)))


async def fetch_from_db(query_name: str, sql: str, *args):
    start = time.perf_counter()
    try:
        async with app.state.db.acquire() as conn:
            if query_name == "category_top":
                rows = await conn.fetch(sql, *args)
                return orjson.dumps([dict(r) for r in rows]) if rows else None
            row = await conn.fetchrow(sql, *args)
            return orjson.dumps(dict(row)) if row else None
    finally:
        DB_LATENCY.labels(query_name).observe(time.perf_counter() - start)


async def get_or_load(request: Request, entity: str, key: str, ttl: int, loader) -> bytes | None:
    """Cache-aside: Redis -> (блокировка от лавины промахов) -> PostgreSQL -> Redis.

    Любая ошибка Redis не ломает запрос: данные берутся из PostgreSQL (bypass).
    """
    cache: Cache = app.state.cache
    try:
        cached = await cache.call("get", key)
        if cached is not None:
            request.state.cache = "hit"
            CACHE_REQUESTS.labels(entity, "hit").inc()
            return None if cached == NOT_FOUND else cached

        request.state.cache = "miss"
        CACHE_REQUESTS.labels(entity, "miss").inc()
        lock_key = f"lock:{key}"
        got_lock = await cache.call("set", lock_key, secrets.token_hex(8), nx=True, px=LOCK_TTL_MS)
        if not got_lock:
            # Данные уже загружает другой запрос — ждём, пока он положит их в кэш.
            deadline = time.monotonic() + LOCK_WAIT
            while time.monotonic() < deadline:
                await asyncio.sleep(0.01)
                cached = await cache.call("get", key)
                if cached is not None:
                    LOCK_WAITS.labels("served_from_cache").inc()
                    return None if cached == NOT_FOUND else cached
            LOCK_WAITS.labels("timeout").inc()
    except CacheError:
        request.state.cache = "bypass"
        CACHE_REQUESTS.labels(entity, "bypass").inc()
        return await loader()

    value = await loader()
    try:
        if value is None:
            await cache.call("set", key, NOT_FOUND, ex=NEGATIVE_TTL)
        else:
            await cache.call("set", key, value, ex=ttl_with_jitter(ttl))
        if got_lock:
            await cache.call("delete", lock_key)
    except CacheError:
        pass  # значение не сохранилось в кэше — следующий запрос снова сходит в БД
    return value


async def init_connection(conn: asyncpg.Connection):
    await conn.set_type_codec("json", encoder=orjson.dumps, decoder=orjson.loads, schema="pg_catalog")


@asynccontextmanager
async def lifespan(_: FastAPI):
    app.state.db = await asyncpg.create_pool(
        DATABASE_URL, min_size=DB_POOL_SIZE, max_size=DB_POOL_SIZE, init=init_connection
    )
    app.state.cache = Cache(REDIS_URL)
    CACHE_MODE.set(1 if CACHE_ENABLED else 0)
    DB_POOL.labels("total").set_function(lambda: app.state.db.get_size())
    DB_POOL.labels("idle").set_function(lambda: app.state.db.get_idle_size())
    yield
    await app.state.cache.client.aclose()
    await app.state.db.close()


app = FastAPI(title="Catalog API", lifespan=lifespan)


@app.middleware("http")
async def metrics_middleware(request: Request, call_next):
    if request.url.path in ("/metrics", "/health"):
        return await call_next(request)
    request.state.cache = "none"
    start = time.perf_counter()
    status = 500
    try:
        response = await call_next(request)
        status = response.status_code
        response.headers["X-Cache"] = request.state.cache.upper()
        return response
    finally:
        route = getattr(request.scope.get("route"), "path", "unmatched")
        HTTP_LATENCY.labels(route, request.state.cache).observe(time.perf_counter() - start)
        HTTP_REQUESTS.labels(request.method, route, str(status)).inc()


def json_response(body: bytes) -> Response:
    return Response(content=body, media_type="application/json")


@app.get("/products/{product_id}")
async def get_product(product_id: int, request: Request):
    body = await get_or_load(
        request, "product", f"product:{product_id}", PRODUCT_TTL,
        lambda: fetch_from_db("product", PRODUCT_SQL, product_id),
    )
    if body is None:
        raise HTTPException(404, "product not found")
    return json_response(body)


@app.get("/categories/{category_id}/top")
async def category_top(category_id: int, request: Request):
    body = await get_or_load(
        request, "category_top", f"category:{category_id}:top", CATEGORY_TTL,
        lambda: fetch_from_db("category_top", CATEGORY_TOP_SQL, category_id),
    )
    if body is None:
        raise HTTPException(404, "category not found")
    return json_response(body)


class ProductUpdate(BaseModel):
    price: float | None = Field(default=None, gt=0)
    stock: int | None = Field(default=None, ge=0)


@app.patch("/products/{product_id}")
async def update_product(product_id: int, update: ProductUpdate, request: Request):
    start = time.perf_counter()
    try:
        async with app.state.db.acquire() as conn:
            category_id = await conn.fetchval(UPDATE_SQL, product_id, update.price, update.stock)
    finally:
        DB_LATENCY.labels("update").observe(time.perf_counter() - start)
    if category_id is None:
        raise HTTPException(404, "product not found")
    # Инвалидация после записи в БД: следующий запрос прочитает свежие данные.
    # Топ категории показывает цену, но не остаток, поэтому сбрасывается только
    # при смене цены; иначе он обновляется по TTL (60 с).
    keys = [f"product:{product_id}"]
    if update.price is not None:
        keys.append(f"category:{category_id}:top")
    try:
        removed = await app.state.cache.call("unlink", *keys)
        CACHE_INVALIDATIONS.inc(removed)
    except CacheError:
        # Redis недоступен: устаревшая запись (если есть) истечёт по TTL.
        keys = []
    request.state.cache = "invalidate"
    return {"id": product_id, "invalidated": keys}


@app.get("/health")
async def health():
    db_ok = redis_ok = False
    try:
        async with app.state.db.acquire() as conn:
            db_ok = await conn.fetchval("SELECT 1") == 1
    except Exception:
        pass
    try:
        redis_ok = await app.state.cache.client.ping()
    except Exception:
        pass
    # Без Redis сервис продолжает работать (через БД), поэтому статус зависит только от БД.
    status = 200 if db_ok else 503
    return Response(
        orjson.dumps({"db": db_ok, "redis": redis_ok, "cache_enabled": CACHE_ENABLED}),
        status_code=status, media_type="application/json",
    )


@app.get("/metrics")
async def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)
