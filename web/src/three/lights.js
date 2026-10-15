// Light fixtures: a small model, the real three.js light(s) it drives and the
// animation that eases both towards the device state.
import * as THREE from 'three';
import { box, cyl, mat, at } from './kit.js';

const STOPS = [
  [2200, new THREE.Color('#ff9438')],
  [3000, new THREE.Color('#ffbd7a')],
  [4200, new THREE.Color('#ffe2c2')],
  [6500, new THREE.Color('#dfe9ff')],
];

export function tempToColor(kelvin, out = new THREE.Color()) {
  const k = Math.min(6500, Math.max(2200, kelvin));
  for (let i = 0; i < STOPS.length - 1; i++) {
    const [k0, c0] = STOPS[i];
    const [k1, c1] = STOPS[i + 1];
    if (k <= k1) return out.copy(c0).lerp(c1, (k - k0) / (k1 - k0));
  }
  return out.copy(STOPS[STOPS.length - 1][1]);
}

export function lightColor(state, out = new THREE.Color()) {
  return state.color ? out.set(state.color) : tempToColor(state.temp, out);
}

const DARK = '#23262e';

function glowMaterial() {
  return new THREE.MeshStandardMaterial({ color: '#8d8f96', roughness: 0.6, emissive: '#000000', emissiveIntensity: 1 });
}

function spot(intensity, y) {
  const light = new THREE.SpotLight(0xffffff, 0, 0, 1.2, 0.75, 2);
  light.position.set(0, y, 0);
  light.target.position.set(0, y - 1, 0);
  light.castShadow = true;
  light.shadow.mapSize.set(1024, 1024);
  light.shadow.camera.near = 0.15;
  light.shadow.camera.far = 9;
  light.shadow.bias = -0.0006;
  light.shadow.normalBias = 0.03;
  light.shadow.radius = 5;
  light.userData.max = intensity;
  return light;
}

function point(intensity, y, { shadow = true, distance = 0, x = 0, z = 0 } = {}) {
  const light = new THREE.PointLight(0xffffff, 0, distance, 2);
  light.position.set(x, y, z);
  if (shadow) {
    light.castShadow = true;
    light.shadow.mapSize.set(512, 512);
    light.shadow.camera.near = 0.08;
    light.shadow.camera.far = 9;
    light.shadow.bias = -0.003;
    light.shadow.normalBias = 0.03;
    light.shadow.radius = 4;
  }
  light.userData.max = intensity;
  return light;
}

// Each fixture: { parts: Mesh[], glow: Mesh[] (emissive when on), lights: Light[], hit: [w, h, d, y] }
const fixtures = {
  ceiling(cfg, H) {
    const y = cfg.y ?? H - 0.14;
    return {
      parts: [at(cyl(0.012, 0.012, H - y - 0.05, mat(DARK), 8), 0, y + 0.05, 0)],
      glow: [at(cyl(0.27, 0.27, 0.055, glowMaterial(), 40), 0, y, 0)],
      lights: [spot(cfg.intensity ?? 20, y - 0.02)],
      hit: [0.75, 0.5, 0.75, y],
    };
  },

  pendant(cfg, H) {
    const y = cfg.y ?? 1.8;
    const globe = new THREE.Mesh(new THREE.SphereGeometry(0.17, 32, 20), glowMaterial());
    globe.position.set(0, y, 0);
    return {
      parts: [
        at(cyl(0.006, 0.006, H - y - 0.15, mat(DARK), 6), 0, y + 0.15, 0),
        at(cyl(0.04, 0.05, 0.05, mat(DARK, { rough: 0.4, metal: 0.6 }), 16), 0, y + 0.14, 0),
      ],
      glow: [globe],
      lights: [spot(cfg.intensity ?? 9, y - 0.05)],
      hit: [0.6, 0.7, 0.6, y],
    };
  },

  spots(cfg, H) {
    const y = cfg.y ?? H - 0.16;
    const glow = [-0.32, 0, 0.32].map((x) => at(cyl(0.055, 0.045, 0.1, glowMaterial(), 20), x, y - 0.06, 0));
    return {
      parts: [at(box(0.95, 0.03, 0.05, mat(DARK, { rough: 0.5 }), { r: 0.01 }), 0, y + 0.05, 0)],
      glow,
      lights: [spot(cfg.intensity ?? 20, y - 0.08)],
      hit: [1.1, 0.45, 0.5, y],
    };
  },

  floor(cfg) {
    const shade = cyl(0.14, 0.19, 0.3, glowMaterial(), 32);
    return {
      parts: [
        at(cyl(0.15, 0.16, 0.025, mat(DARK, { rough: 0.4, metal: 0.5 })), 0, 0, 0),
        at(cyl(0.011, 0.011, 1.3, mat(DARK, { rough: 0.4, metal: 0.5 }), 8), 0, 0.02, 0),
      ],
      glow: [at(shade, 0, 1.28, 0)],
      lights: [point(cfg.intensity ?? 3.4, 1.46)],
      hit: [0.6, 1.7, 0.6, 0.85],
    };
  },

  table(cfg) {
    const y = cfg.y ?? 0.5;
    return {
      parts: [
        at(cyl(0.065, 0.075, 0.02, mat(DARK, { rough: 0.4, metal: 0.5 })), 0, y, 0),
        at(cyl(0.01, 0.01, 0.18, mat(DARK, { rough: 0.4, metal: 0.5 }), 8), 0, y + 0.02, 0),
      ],
      glow: [at(cyl(0.085, 0.125, 0.17, glowMaterial(), 28), 0, y + 0.18, 0)],
      lights: [point(cfg.intensity ?? 1.5, y + 0.3)],
      hit: [0.5, 0.6, 0.5, y + 0.2],
    };
  },

  strip(cfg, H) {
    if (cfg.localPath) return cove(cfg, H);
    const y = cfg.y ?? 1;
    const length = cfg.length ?? 1;
    const n = Math.max(1, Math.round(length / 1.0));
    const lights = [];
    for (let i = 0; i < n; i++) {
      const x = -length / 2 + (length / n) * (i + 0.5);
      lights.push(point((cfg.intensity ?? 1.6) / n, y, { shadow: false, distance: 3.2, x, z: 0.05 }));
    }
    return {
      parts: [],
      glow: [at(box(length, 0.022, 0.022, glowMaterial(), { r: 0.008 }), 0, y - 0.011, 0)],
      lights,
      hit: [length + 0.2, 0.4, 0.4, y],
    };
  },
};

// A strip along a path (around the ceiling of a room): a thin glowing line on every
// segment and a soft light every metre or so, without shadows.
function cove(cfg, H) {
  const y = cfg.y ?? H - 0.04;
  const glow = [];
  const lights = [];
  const pts = cfg.localPath;
  let total = 0;
  for (let i = 0; i < pts.length - 1; i++) total += Math.hypot(pts[i + 1][0] - pts[i][0], pts[i + 1][1] - pts[i][1]);
  const n = Math.max(2, Math.min(10, Math.round(total / 1.4)));
  let minX = Infinity, maxX = -Infinity, minZ = Infinity, maxZ = -Infinity;
  for (let i = 0; i < pts.length - 1; i++) {
    const [ax, az] = pts[i], [bx, bz] = pts[i + 1];
    const len = Math.hypot(bx - ax, bz - az);
    if (len < 0.01) continue;
    const seg = at(box(len, 0.022, 0.022, glowMaterial(), { r: 0.008 }), (ax + bx) / 2, y - 0.011, (az + bz) / 2);
    seg.rotation.y = -Math.atan2(bz - az, bx - ax);
    glow.push(seg);
    minX = Math.min(minX, ax, bx); maxX = Math.max(maxX, ax, bx); minZ = Math.min(minZ, az, bz); maxZ = Math.max(maxZ, az, bz);
  }
  // Lights spread evenly along the whole path.
  for (let k = 0; k < n; k++) {
    let d = (total / n) * (k + 0.5);
    for (let i = 0; i < pts.length - 1; i++) {
      const [ax, az] = pts[i], [bx, bz] = pts[i + 1];
      const len = Math.hypot(bx - ax, bz - az);
      if (d <= len) {
        const t = len ? d / len : 0;
        // A little in from the wall, so the glow washes the ceiling and the walls.
        const cx = (minX + maxX) / 2, cz = (minZ + maxZ) / 2;
        const x = ax + (bx - ax) * t, z = az + (bz - az) * t;
        const lx = x + Math.sign(cx - x) * 0.15, lz = z + Math.sign(cz - z) * 0.15;
        lights.push(point(((cfg.intensity ?? 1.6) * Math.max(1, total / 4)) / n, y - 0.08, { shadow: false, distance: 3.6, x: lx, z: lz }));
        break;
      }
      d -= len;
    }
  }
  return {
    parts: [],
    glow,
    lights,
    hit: [Math.max(0.4, maxX - minX), 0.3, Math.max(0.4, maxZ - minZ), y],
    hitAt: [(minX + maxX) / 2, (minZ + maxZ) / 2],
  };
}

// Several fixtures driven as one lamp (a relay with nine spots): one model per point,
// shadows only from the first so the scene stays fast.
function group(cfg, H, build) {
  const all = { parts: [], glow: [], lights: [], hit: null };
  let minX = Infinity, maxX = -Infinity, minZ = Infinity, maxZ = -Infinity;
  cfg.localPoints.forEach(([x, z], i) => {
    const f = build(cfg, H);
    for (const m of [...f.parts, ...f.glow]) { m.position.x += x; m.position.z += z; }
    for (const l of f.lights) {
      l.position.x += x; l.position.z += z;
      if (l.target) { l.target.position.x += x; l.target.position.z += z; }
      if (i > 0) l.castShadow = false;
      l.userData.max *= 0.75;
    }
    all.parts.push(...f.parts);
    all.glow.push(...f.glow);
    all.lights.push(...f.lights);
    all.hit ||= f.hit;
    minX = Math.min(minX, x); maxX = Math.max(maxX, x); minZ = Math.min(minZ, z); maxZ = Math.max(maxZ, z);
  });
  const [w, h, d, y] = all.hit;
  all.hit = [maxX - minX + w, h, maxZ - minZ + d, y];
  all.hitAt = [(minX + maxX) / 2, (minZ + maxZ) / 2];
  return all;
}

/** Absolute plan points → the lamp group's own frame (it sits at `pos`, turned by `rot`). */
function toLocal(cfg, points) {
  const a = THREE.MathUtils.degToRad(cfg.rot || 0);
  const c = Math.cos(a), s = Math.sin(a);
  return points.map(([x, z]) => {
    const dx = x - cfg.pos[0], dz = z - cfg.pos[1];
    // undo the group's rotation about Y (three.js: x' = x cos + z sin, z' = -x sin + z cos)
    return [dx * c - dz * s, dx * s + dz * c];
  });
}

const tmp = new THREE.Color();

export class LightUnit {
  constructor(cfg, H) {
    this.cfg = cfg;
    this.id = cfg.id;
    const build = fixtures[cfg.type];
    let f;
    if (cfg.path) f = build({ ...cfg, localPath: toLocal(cfg, cfg.path) }, H);
    else if (cfg.points) f = group({ ...cfg, localPoints: toLocal(cfg, cfg.points) }, H, build);
    else f = build(cfg, H);

    this.group = new THREE.Group();
    this.group.position.set(cfg.pos[0], 0, cfg.pos[1]);
    this.group.rotation.y = THREE.MathUtils.degToRad(cfg.rot || 0);

    this.model = new THREE.Group();
    this.pivotY = f.hit[3];
    this.model.position.y = this.pivotY;
    for (const m of [...f.parts, ...f.glow]) {
      m.position.y -= this.pivotY;
      m.castShadow = false;
      m.receiveShadow = false;
      this.model.add(m);
    }
    this.group.add(this.model);

    this.glow = f.glow.map((m) => m.material);
    this.lights = f.lights;
    for (const l of this.lights) {
      this.group.add(l);
      if (l.target) this.group.add(l.target);
    }

    const [hw, hh, hd, hy] = f.hit;
    this.hit = new THREE.Mesh(new THREE.BoxGeometry(hw, hh, hd), new THREE.MeshBasicMaterial());
    this.hit.position.set(f.hitAt?.[0] ?? 0, hy, f.hitAt?.[1] ?? 0);
    this.hit.visible = false;
    this.hit.userData = { kind: 'light', id: cfg.id };
    this.group.add(this.hit);

    this.level = 0;        // eased 0..1 output
    this.goal = 0;
    this.color = new THREE.Color('#ffbd7a');
    this.goalColor = this.color.clone();
    this.hover = 0;
    this.hoverGoal = 0;
    this.pulse = 0;
    this.delay = 0;
    this.write();
  }

  // Anchor used for tooltips.
  anchor(out) {
    return out.set(0, this.pivotY + 0.25, 0).applyMatrix4(this.group.matrixWorld);
  }

  apply(state, { instant = false, delay = 0 } = {}) {
    const dimmable = this.cfg.capabilities.includes('brightness');
    this.goal = state.on ? (dimmable ? state.brightness : 1) : 0;
    lightColor(state, this.goalColor);
    this.delay = delay;
    if (instant) {
      this.level = this.goal;
      this.color.copy(this.goalColor);
      this.write();
    } else if (this.level < 0.01) {
      this.color.copy(this.goalColor); // nothing visible yet: no need to fade the hue
    }
  }

  bump() { this.pulse = 1; }

  update(dt) {
    if (this.delay > 0) { this.delay -= dt; return true; }
    const k = 1 - Math.exp(-dt * (this.goal > this.level ? 7 : 5));
    const dl = this.goal - this.level;
    const dh = this.hoverGoal - this.hover;
    const dc = Math.abs(this.color.r - this.goalColor.r) + Math.abs(this.color.g - this.goalColor.g)
      + Math.abs(this.color.b - this.goalColor.b);
    const moving = Math.abs(dl) > 0.002 || Math.abs(dh) > 0.004 || dc > 0.004 || this.pulse > 0.004;
    if (!moving) {
      if (this.level !== this.goal || this.hover !== this.hoverGoal || this.pulse !== 0) {
        this.level = this.goal; this.hover = this.hoverGoal; this.pulse = 0;
        this.color.copy(this.goalColor);
        this.write();
        return true;
      }
      return false;
    }
    this.level += dl * k;
    this.hover += dh * (1 - Math.exp(-dt * 14));
    this.pulse *= Math.exp(-dt * 7);
    this.color.lerp(this.goalColor, 1 - Math.exp(-dt * 6));
    this.write();
    return true;
  }

  write() {
    const out = Math.pow(this.level, 1.5);
    for (const l of this.lights) {
      l.intensity = l.userData.max * out;
      l.color.copy(this.color);
    }
    // Lamp bodies stay faintly readable when off and hot enough to bloom when on.
    const e = this.level > 0.001 ? 0.8 + 1.7 * Math.pow(this.level, 0.7) : 0;
    for (const m of this.glow) {
      m.emissive.copy(this.color);
      m.emissiveIntensity = e + this.hover * 0.5;
      if (this.level < 0.001) m.emissive.copy(tmp.set('#5b6b93'));
      m.color.copy(tmp.set('#8d8f96')).lerp(this.color, Math.min(1, this.level * 2));
    }
    const s = 1 + this.hover * 0.14 + Math.sin(this.pulse * Math.PI) * 0.22;
    this.model.scale.setScalar(s);
  }
}
