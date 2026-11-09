// Учебные базы shop, library, university. Существующая база не трогается.
const K = Math.max(1, parseInt(process.env.SCALE || "1"));
let seed = 42;                                   // детерминированный ГПСЧ (mulberry32)
const rnd  = () => { seed = (seed + 0x6D2B79F5) | 0; let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
  t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t; return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
const pick = a => a[Math.floor(rnd() * a.length)];
const int  = (a, b) => a + Math.floor(rnd() * (b - a + 1));
const day  = 86400000, now = Date.now();

function prepare(name) {
  const d = db.getSiblingDB(name);
  if (d.getCollectionNames().length > 0) { print(`${name}: exists`); return null; }
  return d;
}
function batchInsert(coll, n, gen) {
  for (let i = 0; i < n; i += 1000) {
    const docs = [];
    for (let j = i; j < Math.min(n, i + 1000); j++) docs.push(gen(j));
    coll.insertMany(docs, { ordered: false });
  }
}
const cities = ["Москва","Санкт-Петербург","Казань","Новосибирск","Екатеринбург","Нижний Новгород","Самара"];
const first  = ["Иван","Анна","Пётр","Мария","Алексей","Ольга","Дмитрий","Елена","Сергей","Наталья"];
const last   = ["Иванов","Смирнов","Кузнецов","Попов","Васильев","Петров","Соколов","Михайлов"];

// ---------------- shop
let d = prepare("shop");
if (d) {
  const cats = ["electronics","books","clothes","home","sport","toys"];
  batchInsert(d.customers, 1000 * K, i => ({ _id: i + 1, name: `${pick(first)} ${pick(last)}`,
    email: `user${i + 1}@example.com`, city: pick(cities), registered: new Date(now - int(1, 900) * day),
    vip: rnd() < 0.1 }));
  batchInsert(d.products, 200 * K, i => ({ _id: i + 1, sku: `SKU-${String(i + 1).padStart(5, "0")}`,
    title: `Товар ${i + 1}`, category: pick(cats), price: int(100, 50000), stock: int(0, 500) }));
  batchInsert(d.orders, 5000 * K, i => {
    const items = Array.from({ length: int(1, 4) }, () => ({ product_id: int(1, 200 * K), qty: int(1, 3), price: int(100, 50000) }));
    return { _id: i + 1, customer_id: int(1, 1000 * K), created: new Date(now - int(0, 365) * day),
      status: pick(["new","paid","shipped","delivered","cancelled"]), items,
      total: items.reduce((s, x) => s + x.qty * x.price, 0) };
  });
  d.customers.createIndex({ email: 1 }, { unique: true });
  d.orders.createIndex({ customer_id: 1, created: -1 });
  d.orders.createIndex({ status: 1 });
  d.products.createIndex({ category: 1, price: 1 });
  print(`created shop: customers=${d.customers.countDocuments()}, products=${d.products.countDocuments()}, orders=${d.orders.countDocuments()}`);
}

// ---------------- library
d = prepare("library");
if (d) {
  const genres = ["роман","поэзия","фантастика","детектив","научная","история"];
  batchInsert(d.authors, 100 * K, i => ({ _id: i + 1, name: `${pick(first)} ${pick(last)}`, born: int(1800, 1990) }));
  batchInsert(d.books, 1000 * K, i => ({ _id: i + 1, isbn: `978-5-${int(1000, 9999)}-${String(i).padStart(5, "0")}`,
    title: `Книга №${i + 1}`, author_id: int(1, 100 * K), genre: pick(genres), year: int(1850, 2025), copies: int(1, 10) }));
  batchInsert(d.loans, 3000 * K, i => { const issued = now - int(0, 200) * day;
    return { _id: i + 1, book_id: int(1, 1000 * K), reader: `${pick(first)} ${pick(last)}`,
      issued: new Date(issued), returned: rnd() < 0.7 ? new Date(issued + int(1, 30) * day) : null }; });
  d.books.createIndex({ isbn: 1 }, { unique: true });
  d.books.createIndex({ author_id: 1 });
  d.loans.createIndex({ book_id: 1, issued: -1 });
  print(`created library: authors=${d.authors.countDocuments()}, books=${d.books.countDocuments()}, loans=${d.loans.countDocuments()}`);
}

// ---------------- university
d = prepare("university");
if (d) {
  const faculties = ["ФИТ","Физфак","Мехмат","Экономический","Гуманитарный"];
  batchInsert(d.students, 2000 * K, i => ({ _id: i + 1, name: `${pick(first)} ${pick(last)}`,
    faculty: pick(faculties), year: int(1, 4), group: `${int(1, 4)}${int(10, 99)}`, gpa: Math.round((3 + rnd() * 2) * 100) / 100 }));
  batchInsert(d.courses, 50, i => ({ _id: i + 1, code: `CS${100 + i}`, title: `Дисциплина ${i + 1}`, credits: int(2, 6) }));
  batchInsert(d.enrollments, 8000 * K, i => ({ student_id: int(1, 2000 * K), course_id: int(1, 50),
    semester: pick(["2025-осень","2026-весна","2026-осень"]), grade: pick([2, 3, 3, 4, 4, 4, 5, 5]) }));
  d.students.createIndex({ faculty: 1, year: 1 });
  d.enrollments.createIndex({ student_id: 1, course_id: 1 });
  print(`created university: students=${d.students.countDocuments()}, courses=${d.courses.countDocuments()}, enrollments=${d.enrollments.countDocuments()}`);
}
quit(0);
