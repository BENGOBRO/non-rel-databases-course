// Счётчики serverStatus для сводки по фазе нагрузки
const s = db.serverStatus(), q = s.metrics.queryExecutor;
print(JSON.stringify({
  insert: Number(s.opcounters.insert), query: Number(s.opcounters.query),
  update: Number(s.opcounters.update), delete: Number(s.opcounters.delete),
  scannedObjects: Number(q.scannedObjects), collscans: Number(q.collectionScans.total),
  returned: Number(s.metrics.document.returned),
  readLatUs: Number(s.opLatencies.reads.latency), readOps: Number(s.opLatencies.reads.ops),
}));
