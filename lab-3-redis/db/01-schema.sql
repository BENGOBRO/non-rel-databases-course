-- Основная БД каталога: категории, товары, отзывы.
CREATE TABLE categories (
    id   integer PRIMARY KEY,
    name text    NOT NULL
);

CREATE TABLE products (
    id          integer PRIMARY KEY,
    category_id integer       NOT NULL REFERENCES categories (id),
    name        text          NOT NULL,
    description text          NOT NULL,
    price       numeric(10,2) NOT NULL,
    stock       integer       NOT NULL,
    updated_at  timestamptz   NOT NULL DEFAULT now()
);
CREATE INDEX products_category_idx ON products (category_id);

CREATE TABLE reviews (
    id         bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    product_id integer     NOT NULL REFERENCES products (id),
    rating     smallint    NOT NULL CHECK (rating BETWEEN 1 AND 5),
    author     text        NOT NULL,
    body       text        NOT NULL,
    created_at timestamptz NOT NULL
);
CREATE INDEX reviews_product_created_idx ON reviews (product_id, created_at DESC);
