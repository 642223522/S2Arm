// Imports a game package made by the Windows CLI (`S2Arm package <key>`): an uncompressed POSIX/PAX tar holding
// ready.json, game/... and the program directory. The file comes from the system picker (phone storage, e.g. a
// download); entries are streamed into files/games/.import-<stamp> and the folder is published by renaming it,
// exactly like the HDC import path. Nothing outside that folder is written; unsafe paths abort the import.
import { fileIo as fs, statfs } from '@kit.CoreFileKit';
import { str } from '../ui/Strings';

const BLOCK: number = 512;
const CHUNK: number = 8 * 1024 * 1024;

export interface ImportProgress { files: number; bytes: number; total: number; }
export interface ImportResult { key: string; files: number; bytes: number; }
interface ImportManifest { key?: string; }

// One logical stream over the package parts (S2Arm splits large packages into name.tar.001, .002, ...),
// read in file-name order as if they were concatenated.
class Part { fd: number; start: number; size: number; constructor(fd: number, start: number, size: number) { this.fd = fd; this.start = start; this.size = size; } }
class Reader {
  pos: number = 0; size: number;
  private parts: Part[];
  private buf: ArrayBuffer = new ArrayBuffer(CHUNK);
  private start: number = 0; private end: number = 0; private base: number = 0;
  constructor(parts: Part[], size: number) { this.parts = parts; this.size = size; }
  private async readAt(offset: number, into: ArrayBuffer, length: number): Promise<number> {
    for (const p of this.parts) {
      if (offset >= p.start && offset < p.start + p.size) {
        return await fs.read(p.fd, into, { offset: offset - p.start, length: Math.min(length, p.start + p.size - offset) });
      }
    }
    return 0;
  }
  // Returns a view of exactly n bytes (n <= CHUNK) starting at the current position.
  async take(n: number): Promise<Uint8Array> {
    if (n > CHUNK) throw new Error('tar block larger than the read buffer');
    if (this.end - this.start < n) {
      const keep = this.end - this.start;
      const fresh = new ArrayBuffer(CHUNK);
      if (keep > 0) new Uint8Array(fresh).set(new Uint8Array(this.buf, this.start, keep));
      this.buf = fresh; this.base += this.start; this.start = 0; this.end = keep;
      while (this.end < n) {
        // fs.read fills a buffer from its start; read into a scratch buffer and copy it behind the kept bytes.
        const room = CHUNK - this.end;
        const scratch = new ArrayBuffer(room);
        const got = await this.readAt(this.base + this.end, scratch, room);
        if (got <= 0) throw new Error(str($r('app.string.package_truncated')));
        new Uint8Array(this.buf).set(new Uint8Array(scratch, 0, got), this.end);
        this.end += got;
      }
    }
    const view = new Uint8Array(this.buf, this.start, n);
    this.start += n; this.pos += n;
    return view;
  }
}

function text(b: Uint8Array, off: number, len: number): string {
  let end = off;
  while (end < off + len && b[end] !== 0) end++;
  let s = '';
  for (let i = off; i < end; i++) s += String.fromCharCode(b[i]);
  return s;
}
function octal(b: Uint8Array, off: number, len: number): number {
  if ((b[off] & 0x80) !== 0) { // GNU base-256
    let v = 0;
    for (let i = off + 1; i < off + len; i++) v = v * 256 + b[i];
    return v;
  }
  const t = text(b, off, len).trim();
  return t.length > 0 ? parseInt(t, 8) : 0;
}
function utf8(b: Uint8Array): string {
  let out = ''; let i = 0;
  while (i < b.length) {
    const c = b[i++];
    if (c < 0x80) out += String.fromCharCode(c);
    else if (c < 0xE0) out += String.fromCharCode(((c & 0x1F) << 6) | (b[i++] & 0x3F));
    else if (c < 0xF0) out += String.fromCharCode(((c & 0x0F) << 12) | ((b[i++] & 0x3F) << 6) | (b[i++] & 0x3F));
    else {
      const cp = ((c & 0x07) << 18) | ((b[i++] & 0x3F) << 12) | ((b[i++] & 0x3F) << 6) | (b[i++] & 0x3F);
      const u = cp - 0x10000; out += String.fromCharCode(0xD800 + (u >> 10), 0xDC00 + (u & 0x3FF));
    }
  }
  return out;
}
function pax(b: Uint8Array): Map<string, string> {
  const map = new Map<string, string>(); let i = 0;
  while (i < b.length) {
    let sp = i; while (sp < b.length && b[sp] !== 0x20) sp++;
    const len = parseInt(utf8(b.subarray(i, sp)), 10);
    if (!(len > 0) || i + len > b.length) break;
    const record = utf8(b.subarray(sp + 1, i + len - 1));
    const eq = record.indexOf('=');
    if (eq > 0) map.set(record.substring(0, eq), record.substring(eq + 1));
    i += len;
  }
  return map;
}
function safe(path: string): string {
  const parts = path.split('/').filter((p: string) => p.length > 0 && p !== '.');
  if (parts.length === 0 || path.startsWith('/') || parts.some((p: string) => p === '..' || p.indexOf('\\') >= 0))
    throw new Error(str($r('app.string.package_unsafe_path'), path));
  return parts.join('/');
}

function baseName(uri: string): string {
  const s = decodeURIComponent(uri);
  return s.substring(s.lastIndexOf('/') + 1);
}

export async function importGamePackage(uris: string[], filesDir: string,
    progress: (p: ImportProgress) => void): Promise<ImportResult> {
  // Parts are concatenated in file-name order (xxx.tar.001, xxx.tar.002, ... or a single xxx.tar).
  const ordered = uris.slice().sort((a: string, b: string) => baseName(a) < baseName(b) ? -1 : baseName(a) > baseName(b) ? 1 : 0);
  const files0: fs.File[] = [];
  const parts: Part[] = [];
  let total = 0;
  for (const u of ordered) {
    const f = fs.openSync(u, fs.OpenMode.READ_ONLY);
    files0.push(f);
    const size = fs.statSync(f.fd).size;
    parts.push(new Part(f.fd, total, size));
    total += size;
  }
  const closeAll = () => { for (const f of files0) { try { fs.closeSync(f); } catch (e) { } } };
  const games = filesDir + '/games';
  if (!fs.accessSync(games)) fs.mkdirSync(games, true);
  const free = statfs.getFreeSizeSync(filesDir);
  if (free < total + 512 * 1024 * 1024) {
    closeAll();
    throw new Error(str($r('app.string.package_no_space'), (total / 1073741824).toFixed(1), (free / 1073741824).toFixed(1)));
  }
  const stamp = Date.now().toString(36);
  const temp = games + '/.import-' + stamp;
  fs.mkdirSync(temp, true);
  const reader = new Reader(parts, total);
  let files = 0; let written = 0; let longName = ''; let paxPath = ''; let paxSize = -1; let last = 0;
  try {
    while (reader.pos + BLOCK <= total) {
      const h = await reader.take(BLOCK);
      let empty = true;
      for (let i = 0; i < BLOCK; i++) if (h[i] !== 0) { empty = false; break; }
      if (empty) break;
      const type = String.fromCharCode(h[156] === 0 ? 0x30 : h[156]);
      let name = text(h, 0, 100);
      const prefix = text(h, 345, 155);
      if (prefix.length > 0) name = prefix + '/' + name;
      let size = octal(h, 124, 12);
      if (paxSize >= 0) { size = paxSize; }
      if (paxPath.length > 0) name = paxPath; else if (longName.length > 0) name = longName;
      const padded = Math.ceil(size / BLOCK) * BLOCK;
      if (type === 'x' || type === 'g' || type === 'L') {
        const data = new Uint8Array(size);
        let got = 0;
        while (got < size) { const n = Math.min(CHUNK, size - got); data.set(await reader.take(n), got); got += n; }
        if (padded > size) await reader.take(padded - size);
        if (type === 'x') { const m = pax(data); paxPath = m.get('path') ?? ''; paxSize = m.has('size') ? parseInt(m.get('size') as string, 10) : -1; }
        else if (type === 'L') longName = utf8(data.subarray(0, data.indexOf(0) >= 0 ? data.indexOf(0) : data.length));
        continue;
      }
      paxPath = ''; paxSize = -1; longName = '';
      const rel = safe(name);
      const dest = temp + '/' + rel;
      if (type === '5') { if (!fs.accessSync(dest)) fs.mkdirSync(dest, true); continue; }
      if (type !== '0') throw new Error(str($r('app.string.package_unsupported_entry'), type, rel));
      const slash = dest.lastIndexOf('/');
      const dir = dest.substring(0, slash);
      if (!fs.accessSync(dir)) fs.mkdirSync(dir, true);
      const out = fs.openSync(dest, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      try {
        let left = size;
        while (left > 0) {
          const n = Math.min(CHUNK, left);
          const view = await reader.take(n);
          let off = 0;
          while (off < n) off += await fs.write(out.fd, view.buffer.slice(view.byteOffset + off, view.byteOffset + n));
          left -= n; written += n;
          const now = Date.now();
          if (now - last > 400) { last = now; progress({ files: files, bytes: reader.pos, total: total }); }
        }
      } finally { fs.closeSync(out); }
      if (padded > size) await reader.take(padded - size);
      files++;
    }
    if (!fs.accessSync(temp + '/ready.json')) throw new Error(str($r('app.string.package_not_s2arm')));
    let key = '';
    if (fs.accessSync(temp + '/s2arm-import.json')) {
      const m = JSON.parse(fs.readTextSync(temp + '/s2arm-import.json')) as ImportManifest;
      key = typeof m.key === 'string' ? m.key : '';
    }
    if (!/^[a-z0-9][a-z0-9-]{0,63}$/.test(key)) throw new Error(str($r('app.string.package_missing_key')));
    const to = games + '/' + key;
    if (fs.accessSync(to)) throw new Error(str($r('app.string.package_exists'), key));
    fs.renameSync(temp, to);
    progress({ files: files, bytes: total, total: total });
    return { key: key, files: files, bytes: written };
  } catch (error) {
    // Keep nothing half-published: the temporary folder is removed, the source file is untouched.
    try { fs.rmdirSync(temp); } catch (cleanup) { }
    throw error as Error;
  } finally { closeAll(); }
}

// Public baseline uses the shared direct backend and original aspect ratio.
// Widening capabilities belong to the upstream preparation contract, not a local title list.
export function keepOriginalAspect(titleId: string): boolean { return true; }
export function allowTallScreen(titleId: string): boolean { return false; }
export function graphicsMode(filesDir: string, titleId: string): string { return 'direct'; }
export function setGraphicsMode(filesDir: string, titleId: string, mode: string): void {
  const dir = filesDir + '/states/' + titleId;
  if (!fs.accessSync(dir)) fs.mkdirSync(dir, true);
  const path = dir + '/graphics_mode';
  const f = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
  try { fs.writeSync(f.fd, mode + '\n'); } finally { fs.closeSync(f); }
}
