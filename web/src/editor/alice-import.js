// "Build my home from Alice": turns the rooms and devices of a Yandex smart home into a
// plan — a room for every Yandex room, a lamp for every light, socket and switch, an AC
// on a wall for every air conditioner — each one already linked to its real device.
// The rooms start as same-size boxes in a grid; their real shape is the user's to draw.

const ROOM = 3.6;     // a new room's width and depth, in metres
const PER_ROW = 3;
const fix = (v) => Math.round(v * 1000) / 1000;
const snap = (v) => fix(Math.round(v / 0.05) * 0.05);

// What a lamp is, from what it is called in Alice.
const LAMP_TYPES = [
  ['strip', ['лента', 'подсвет', 'strip', 'led']],
  ['floor', ['торшер', 'напольн', 'floor']],
  ['table', ['настольн', 'ночник', 'прикроват', 'бра', 'table', 'desk', 'bedside']],
  ['spots', ['спот', 'точечн', 'spot']],
  ['pendant', ['подвес', 'pendant', 'над столом']],
];
export function lampType(name) {
  const n = (name || '').toLowerCase();
  return LAMP_TYPES.find(([, words]) => words.some((w) => n.includes(w)))?.[0] || 'ceiling';
}

const ROOM_ALIASES = [
  ['коридор', 'прихож', 'холл', 'hall', 'entr'],
  ['ванн', 'санузел', 'туалет', 'bath', 'toilet'],
  ['кухн', 'kitchen'],
  ['комнат', 'гостин', 'спальн', 'зал', 'living', 'bedroom'],
  ['балкон', 'лоджи', 'balcony'],
  ['кладов', 'гардероб', 'closet'],
];

const slug = (s) => (s || 'room').toLowerCase()
  .replace(/[^a-zа-яё0-9]+/gi, '-').replace(/^-|-$/g, '') || 'room';

/**
 * Adds the Yandex devices `devices` (the editor's list, service "yandex") to `doc`.
 * `replace` starts from an empty plan; otherwise rooms are matched by name, devices already
 * linked are left where they are, and only what is missing is added.
 * Returns { doc, rooms, lights, acs } — the new plan and how many of each were added.
 */
export function importAlice(source, devices, { replace = false } = {}) {
  const doc = replace
    ? { ...structuredClone(source), rooms: [], lights: [], acs: [], furniture: [], openings: [], scenes: [] }
    : structuredClone(source);
  for (const key of ['rooms', 'lights', 'acs', 'furniture', 'openings', 'scenes']) doc[key] ||= [];
  const yandex = devices.filter((d) => d.service === 'yandex');
  const ids = new Set([...doc.rooms, ...doc.lights, ...doc.acs, ...doc.scenes].map((x) => x.id));
  const uniqueId = (base) => {
    let id = base;
    for (let i = 2; ids.has(id); i++) id = `${base}${i}`;
    ids.add(id);
    return id;
  };
  const linked = new Set([...doc.lights, ...doc.acs].map((d) => (d.link ? `${d.link.service}|${d.link.id}` : null)).filter(Boolean));
  const added = { rooms: 0, lights: 0, acs: 0 };

  // Rooms: one per Yandex room that has something to show, matched by name.
  const byName = new Map(doc.rooms.map((r) => [r.name.trim().toLowerCase(), r]));
  // Alice calls a room whatever its owner typed: "Прихожая" is the plan's "Коридор".
  const alias = (key) => {
    const group = ROOM_ALIASES.find((g) => g.some((w) => key.includes(w)));
    return group && doc.rooms.find((r) => group.some((w) => r.name.toLowerCase().includes(w)));
  };
  let slot = 0;
  const startX = doc.rooms.length ? Math.max(...doc.rooms.map((r) => r.rect[0] + r.rect[2])) + 1 : 0;
  const roomFor = (name) => {
    const title = name || 'Без комнаты';
    const key = title.trim().toLowerCase();
    if (byName.has(key)) return byName.get(key);
    const similar = !replace && name ? alias(key) : null;
    if (similar) { byName.set(key, similar); return similar; }
    const col = slot % PER_ROW, row = Math.floor(slot / PER_ROW);
    slot++;
    const room = { id: uniqueId(slug(title)), name: title, rect: [fix(startX + col * ROOM), fix(row * ROOM), ROOM, ROOM], floor: 'oak' };
    doc.rooms.push(room);
    byName.set(key, room);
    added.rooms++;
    return room;
  };

  // Lamps, sockets and switches: the first in the middle of the room, the others around it.
  const AROUND = [[0.25, 0.25], [0.75, 0.25], [0.25, 0.75], [0.75, 0.75], [0.5, 0.25], [0.5, 0.75], [0.25, 0.5], [0.75, 0.5]];
  const spot = (room) => {
    const [x, z, w, d] = room.rect;
    const k = doc.lights.filter((l) => l.room === room.id).length;
    const [fx, fz] = k === 0 ? [0.5, 0.5] : AROUND[(k - 1) % AROUND.length];
    return [snap(x + w * fx), snap(z + d * fz)];
  };

  for (const d of yandex.filter((x) => x.kind === 'light')) {
    if (linked.has(`yandex|${d.id}`)) continue;
    const room = roomFor(d.room);
    doc.lights.push({
      id: uniqueId(`${room.id}.${slug(d.name)}`), name: d.name, room: room.id, type: lampType(d.name),
      pos: spot(room), capabilities: [...(d.capabilities || [])], link: { service: 'yandex', id: d.id },
    });
    added.lights++;
  }

  // Air conditioners: on a free wall, high up; a thermometer in the same room reports its room.
  const sensors = yandex.filter((x) => x.kind === 'sensor');
  for (const d of yandex.filter((x) => x.kind === 'ac')) {
    if (linked.has(`yandex|${d.id}`)) continue;
    const room = roomFor(d.room);
    const [x, z, w] = room.rect;
    const ac = {
      id: uniqueId(`${room.id}.ac`), name: d.name, room: room.id, wall: 'north',
      pos: [snap(x + w / 2), fix(z)], y: 2.2, link: { service: 'yandex', id: d.id },
    };
    if (d.min != null) { ac.min = Math.round(d.min); ac.max = Math.round(d.max); }
    // The AC's own thermometer when it has one, otherwise a sensor in the same room.
    const own = sensors.find((s) => s.id === `${d.id}#temperature`);
    const near = own || sensors.find((s) => s.room && s.room === d.room);
    if (near) ac.sensor = { service: 'yandex', id: near.id };
    doc.acs.push(ac);
    added.acs++;
  }

  if (!doc.scenes.length) {
    doc.scenes.push(
      { id: uniqueId('all-on'), name: 'Весь свет', icon: 'sun', lights: { '*': { on: true } } },
      { id: uniqueId('all-off'), name: 'Выключить всё', icon: 'moon', lights: { '*': { on: false } } },
    );
  }
  if (replace && yandex.length) doc.name = doc.name && doc.name !== 'Home' ? doc.name : 'Мой дом';
  if (!doc.rooms.length) doc.rooms.push({ id: 'room', name: 'Комната', rect: [0, 0, ROOM, ROOM], floor: 'oak' });
  return { doc, ...added };
}
