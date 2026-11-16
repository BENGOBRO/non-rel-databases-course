// Рабочая нагрузка на учебную базу shop. Запускается playbooks/load.yml
// в нескольких параллельных процессах mongosh. Параметры — через окружение:
//   PHASE    write | read | scan | mixed
//   DURATION длительность в секундах
//   WORKER   номер процесса (для разнообразия случайных чисел)
const E = process.env;
const PHASE = E.PHASE || "mixed";
const until = Date.now() + Number(E.DURATION || 60) * 1000;
const d = db.getSiblingDB(E.LOAD_DB || "shop");

const nCust = d.customers.estimatedDocumentCount() || 1000;
const nProd = d.products.estimatedDocumentCount() || 200;
const cats = ["electronics", "books", "clothes", "home", "sport", "toys"];
const cities = ["Москва", "Санкт-Петербург", "Казань", "Новосибирск", "Екатеринбург"];
const r = (a, b) => a + Math.floor(Math.random() * (b - a + 1));
const pick = a => a[r(0, a.length - 1)];
const pad = "x".repeat(512);                    // «вес» документа, чтобы был виден трафик

const ops = {
  // ---- записи: вставки пачками, изменения остатков, удаление старых событий
  write() {
    const docs = [];
    for (let i = 0; i < 50; i++) docs.push({ ts: new Date(), worker: Number(E.WORKER), customer_id: r(1, nCust),
      type: pick(["view", "cart", "buy"]), product_id: r(1, nProd), payload: pad });
    d.load_events.insertMany(docs, { ordered: false });
    d.products.updateOne({ _id: r(1, nProd) }, { $inc: { stock: r(-2, 2) } });
    if (Math.random() < 0.05) d.load_events.deleteMany({ ts: { $lt: new Date(Date.now() - 60000) } });
  },
  // ---- чтения по индексам: быстрые точечные запросы
  read() {
    d.orders.find({ customer_id: r(1, nCust) }).sort({ created: -1 }).limit(20).toArray();
    d.products.find({ category: pick(cats), price: { $lt: r(1000, 50000) } }).limit(50).toArray();
    d.customers.findOne({ email: `user${r(1, nCust)}@example.com` });
  },
  // ---- «плохие» запросы без индекса: полный просмотр коллекции + агрегации
  scan() {
    d.orders.find({ total: { $gt: r(100000, 190000) } }).limit(10).toArray();       // нет индекса по total
    d.customers.countDocuments({ city: pick(cities), vip: true });                   // нет индекса по city
    d.orders.aggregate([{ $match: { status: pick(["paid", "shipped"]) } }, { $unwind: "$items" },
      { $group: { _id: "$items.product_id", qty: { $sum: "$items.qty" } } }, { $sort: { qty: -1 } }, { $limit: 5 }]).toArray();
  },
  mixed() {
    const x = Math.random();
    if (x < 0.5) ops.read(); else if (x < 0.85) ops.write(); else ops.scan();
  },
};

const fn = ops[PHASE] || ops.mixed;
let n = 0;
while (Date.now() < until) { fn(); n++; }
print(`worker ${E.WORKER}: phase=${PHASE}, iterations=${n}`);
