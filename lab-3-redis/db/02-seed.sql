-- Тестовые данные: 40 категорий, 50 000 товаров, ~2 000 000 отзывов.
-- setseed делает набор одинаковым при каждом развёртывании.
SELECT setseed(0.42);

INSERT INTO categories (id, name)
SELECT g, 'Категория ' || g
FROM generate_series(1, 40) AS g;

INSERT INTO products (id, category_id, name, description, price, stock)
SELECT g,
       1 + (g % 40),
       'Товар ' || g,
       repeat('Описание товара ' || g || '. ', 8),
       round((100 + random() * 49900)::numeric, 2),
       (random() * 500)::int
FROM generate_series(1, 50000) AS g;

-- у каждого товара от 10 до 70 отзывов
INSERT INTO reviews (product_id, rating, author, body, created_at)
SELECT p.id,
       1 + floor(random() * 5)::int,
       'user' || floor(random() * 100000)::int,
       repeat('Отзыв о товаре ' || p.id || '. ', 3),
       now() - random() * interval '730 days'
FROM products AS p
CROSS JOIN LATERAL generate_series(1, 10 + (p.id * 7919) % 61) AS r;

ANALYZE;
