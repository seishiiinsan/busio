// Sonde des sources de données Libellus (Zenbus + GTFS data.gouv).
// Usage : node probe.mjs  (écrit un résumé lisible sur stdout)
import protobuf from 'protobufjs';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { execSync } from 'node:child_process';

const ALIAS = process.env.ZENBUS_ALIAS ?? 'castres';
const OUT = 'probe-out';
mkdirSync(OUT, { recursive: true });

const zroot = protobuf.parse(readFileSync(new URL('./zenbus.proto', import.meta.url), 'utf8')).root;
const StaticMessage = zroot.lookupType('zenbus_realtime.StaticMessage');
const LiveMessage = zroot.lookupType('zenbus_realtime.LiveMessage');
const rtroot = protobuf.parse(readFileSync(new URL('./gtfs-realtime.proto', import.meta.url), 'utf8')).root;
const FeedMessage = rtroot.lookupType('transit_realtime.FeedMessage');

const toObj = (T, buf) => T.toObject(T.decode(buf), { longs: String, enums: String, defaults: false, oneofs: true });
const j = (o, n = 2000) => JSON.stringify(o).slice(0, n);

async function get(url, name) {
  const t0 = Date.now();
  const res = await fetch(url, { headers: { 'User-Agent': 'Busio-probe/1.0' } });
  const buf = Buffer.from(await res.arrayBuffer());
  console.log(`\n### GET ${url}\n    -> ${res.status} ${res.headers.get('content-type')} ${buf.length} bytes in ${Date.now() - t0} ms`);
  if (name) writeFileSync(`${OUT}/${name}`, buf);
  return { res, buf };
}

function section(t) { console.log(`\n==================== ${t} ====================`); }

// ---------- Zenbus static ----------
section('ZENBUS STATIC');
const st = await get(`https://zenbus.net/publicapp/static-data?alias=${ALIAS}`, 'static.bin');
if (!st.res.ok) { console.log(st.buf.toString().slice(0, 500)); process.exit(1); }
const S = toObj(StaticMessage, st.buf);
console.log('keys', Object.keys(S), 'version', S.version, 'resource', j(S.resource));
console.log(`lines=${S.line?.length} itineraries=${S.itinerary?.length} shapes=${S.shape?.length} missions=${S.mission?.length} stops=${S.stop?.length}`);
for (const l of S.line ?? []) console.log('LINE', j(l, 400));
for (const it of S.itinerary ?? []) console.log('ITIN', it.itineraryId, 'line', it.lineId, JSON.stringify(it.name), 'stopRefs', it.stopRef?.length, 'first', j(it.stopRef?.[0], 80), 'last', j(it.stopRef?.at(-1), 80));
for (const sh of (S.shape ?? []).slice(0, 3)) {
  console.log('SHAPE', sh.shapeId, 'itin', sh.itineraryId, 'anchors', sh.anchor?.length, 'pathOneof', sh.pathOneof, 'points', sh.points?.point?.length, 'segments', sh.segments?.shapeReference?.length);
  console.log('   anchors[0..4]', j(sh.anchor?.slice(0, 5), 800));
  console.log('   anchors[-2..]', j(sh.anchor?.slice(-2), 400));
}
console.log('SHAPE itineraries', j((S.shape ?? []).map(s => [s.shapeId, s.itineraryId, s.anchor?.length, s.points?.point?.length ?? 0]), 4000));
for (const m of (S.mission ?? []).slice(0, 3)) console.log('MISSION', j(m, 600));
for (const s of (S.stop ?? []).slice(0, 12)) console.log('STOP', j(s, 400));
const names = new Map();
for (const s of S.stop ?? []) names.set(s.name, (names.get(s.name) ?? 0) + 1);
console.log('distinct stop names', names.size, 'locationTypes', j([...new Set((S.stop ?? []).map(s => s.locationType ?? 'default'))]));
console.log('stops w/ parent', (S.stop ?? []).filter(s => s.parentId || s.parent).length, 'stops w/ code', (S.stop ?? []).filter(s => s.code).length);
console.log('sample names', j([...names.keys()].slice(0, 80), 3000));

// ---------- Zenbus live ----------
section('ZENBUS LIVE');
const itins = (S.itinerary ?? []);
const pick = itins.filter(i => {
  const l = (S.line ?? []).find(l => l.lineId === i.lineId);
  return /10/.test(l?.code ?? '') || /mazamet/i.test(i.name ?? '');
}).slice(0, 2).concat(itins.slice(0, 1));
let dumpedFull = false;
for (const it of pick) {
  const lv = await get(`https://zenbus.net/publicapp/poll?alias=${ALIAS}&itinerary=${it.itineraryId}`, `poll-${it.itineraryId}.bin`);
  const L = toObj(LiveMessage, lv.buf);
  console.log('itinerary', it.itineraryId, JSON.stringify(it.name), 'keys', Object.keys(L), 'version', L.version, 'proc', L.startProcessing, L.endProcessing);
  console.log('timetables', L.timetable?.length, 'tripColumns', L.tripColumn?.length, 'messages', L.messages?.length);
  for (const tt of L.timetable ?? []) {
    console.log(' TT id', tt.timetableId, 'itin', tt.itineraryId, 'yyyymmdd', tt.yyyymmdd, 'cal', j(tt.calPattern, 100), 'midnight', tt.midnight, 'columns', tt.column?.length);
    for (const c of (tt.column ?? []).slice(0, 2)) {
      const { aimed, estimactual, pos, ...rest } = c;
      console.log('   COL', j(rest, 900));
      console.log('     aimed', aimed?.length, j(aimed?.slice(0, 3), 600));
      console.log('     estimactual', estimactual?.length, j(estimactual?.slice(0, 3), 600));
      console.log('     pos', pos?.length, j(pos?.slice(-1), 300));
    }
    const withEst = (tt.column ?? []).filter(c => c.estimactual?.length);
    console.log('   columns with estimactual', withEst.length, 'jtfs', j([...new Set((tt.column ?? []).map(c => c.jtfsScheduleRelationshipDescriptor ?? '-'))]), 'status', j([...new Set((tt.column ?? []).map(c => c.tripStatus ?? '-'))]));
    if (withEst[0]) { const { aimed, estimactual, ...rest } = withEst[0]; console.log('   EST COL', j(rest, 900), '\n     est', j(estimactual, 1500), '\n     aimed', j(aimed, 1500)); }
  }
  for (const c of (L.tripColumn ?? []).slice(0, 3)) {
    const { aimed, estimactual, pos, timeline, posMatched, ...rest } = c;
    console.log(' TRIPCOL', j(rest, 1200));
    console.log('   aimed', aimed?.length, j(aimed, 1200));
    console.log('   estimactual', estimactual?.length, j(estimactual, 1500));
    console.log('   pos', pos?.length, j(pos?.slice(-2), 400), 'timeline', timeline?.length, 'posMatched', posMatched?.length);
  }
  for (const m of (L.messages ?? []).slice(0, 5)) console.log(' MSG', j(m, 800));
  if (!dumpedFull) { writeFileSync(`${OUT}/poll-${it.itineraryId}.json`, JSON.stringify(L, null, 1)); dumpedFull = true; }
}
// Sans itinéraire : renvoie-t-il tout le réseau ?
try {
  const all = await get(`https://zenbus.net/publicapp/poll?alias=${ALIAS}`, 'poll-all.bin');
  if (all.res.ok) { const A = toObj(LiveMessage, all.buf); console.log('poll(all): timetables', A.timetable?.length, 'tripColumns', A.tripColumn?.length, 'itins', j([...new Set((A.tripColumn ?? []).map(c => c.itineraryId))])); }
  else console.log(all.buf.toString().slice(0, 300));
} catch (e) { console.log('poll(all) error', e.message); }
try { const p = await get('https://zenbus.net/poll/cdn/zenbus.proto', 'zenbus-live.proto'); console.log('live proto lines', p.buf.toString().split('\n').length); } catch (e) { console.log(e.message); }

// ---------- Zenbus GTFS / GTFS-RT ----------
section('ZENBUS GTFS + GTFS-RT');
for (const ds of [ALIAS, 'castres-mazamet', 'libellus', 'castres-mazamet-libellus']) {
  try {
    const tu = await get(`https://zenbus.net/gtfs/rt/poll.proto?dataset=${ds}&file=tu`, `rt-tu-${ds}.bin`);
    if (tu.res.ok && tu.buf.length > 0) {
      const F = toObj(FeedMessage, tu.buf);
      console.log(' header', j(F.header), 'entities', F.entity?.length);
      for (const e of (F.entity ?? []).slice(0, 2)) console.log(' ENTITY', j(e, 1500));
    } else console.log(tu.buf.toString().slice(0, 200));
    const zs = await get(`https://zenbus.net/gtfs/static/download.zip?dataset=${ds}`, `gtfs-zenbus-${ds}.zip`);
    if (zs.res.ok && zs.buf.length > 1000) console.log(execSync(`unzip -l ${OUT}/gtfs-zenbus-${ds}.zip`).toString());
  } catch (e) { console.log('error', ds, e.message); }
}
const vp = await get(`https://zenbus.net/gtfs/rt/poll.proto?dataset=${ALIAS}&file=vp`);
if (vp.res.ok && vp.buf.length) { const F = toObj(FeedMessage, vp.buf); console.log(' VP entities', F.entity?.length, j(F.entity?.[0], 800)); }

// ---------- GTFS data.gouv ----------
section('GTFS DATA.GOUV');
const g = await get('https://www.data.gouv.fr/fr/datasets/r/70c9f936-129e-41f4-940a-8e6f272535d1', 'gtfs-datagouv.zip');
console.log('final url', g.res.url);
if (g.buf.length > 1000) {
  execSync(`rm -rf ${OUT}/g && mkdir -p ${OUT}/g && unzip -o -q ${OUT}/gtfs-datagouv.zip -d ${OUT}/g`);
  console.log(execSync(`unzip -l ${OUT}/gtfs-datagouv.zip`).toString());
  const show = (f, n) => { try { console.log(`--- ${f}\n` + execSync(`head -n ${n} ${OUT}/g/${f}; echo '...'; wc -l ${OUT}/g/${f}`).toString()); } catch { console.log(`(no ${f})`); } };
  show('agency.txt', 5); show('feed_info.txt', 5); show('routes.txt', 40); show('stops.txt', 15); show('trips.txt', 8);
  show('stop_times.txt', 8); show('calendar.txt', 30); show('calendar_dates.txt', 15); show('shapes.txt', 4); show('transfers.txt', 4);
  try { console.log('calendar_dates range', execSync(`cut -d, -f2 ${OUT}/g/calendar_dates.txt | sort | uniq | sed -n '2p;$p'`).toString()); } catch {}
}
// Même source que Zenbus ? Comparaison des noms d'arrêts.
console.log('\nzenbus stop codes sample', j((S.stop ?? []).slice(0, 20).map(s => [s.stopId, s.code, s.name]), 2000));
