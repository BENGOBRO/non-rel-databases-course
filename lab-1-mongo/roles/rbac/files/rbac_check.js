// Пробует операции от имени текущего пользователя: + разрешено, - запрещено, ? другая ошибка
const E = process.env;
const t = fn => {
  try { fn(); return "+"; }
  catch (e) { return (e.code === 13 || /not authorized|Unauthorized/.test(e.message)) ? "-" : "?"; }
};
const row = (name, cells) => name.padEnd(14) + cells.map(c => c.padEnd(8)).join("");

print(row("collection", ["find", "insert", "update", "remove"]));
E.CHECK_COLLS.split(" ").filter(Boolean).forEach(c => {
  const col = db.getCollection(c);
  print(row(c, [
    t(() => col.findOne()),
    t(() => col.insertOne({ _rbac_check: true })),
    t(() => col.updateOne({ _rbac_check: true }, { $set: { checked: new Date() } })),
    t(() => col.deleteMany({ _rbac_check: true })),
  ]));
});
print(`db level: listCollections ${t(() => db.getCollectionNames())}  dbStats ${t(() => db.stats())}`);
