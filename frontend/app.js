// Frontend del módulo PAC. Mismo origen que la API (el ALB enruta /patients al backend),
// así no se necesita CORS. Todo dato se inserta con textContent: nunca innerHTML (anti-XSS).
'use strict';

const $ = (id) => document.getElementById(id);
const PAGE_SIZE = 10;
let token = '';
let claims = null;
let page = 1;
let lastQuery = {};
let expiryTimer = null;

// ---------- RUN chileno: normalización y Módulo 11 ----------
function cleanRun(value) {
  return value.replace(/[^0-9kK]/g, '').toUpperCase();
}
function computeDv(body) {
  let sum = 0;
  let factor = 2;
  for (let i = body.length - 1; i >= 0; i--) {
    sum += Number(body[i]) * factor;
    factor = factor === 7 ? 2 : factor + 1;
  }
  const rest = 11 - (sum % 11);
  return rest === 11 ? '0' : rest === 10 ? 'K' : String(rest);
}
function formatRun(raw) {
  const c = cleanRun(raw);
  if (c.length < 2) return c;
  const body = c.slice(0, -1);
  const dv = c.slice(-1);
  return body.replace(/\B(?=(\d{3})+(?!\d))/g, '.') + '-' + dv;
}
function runStatus(raw) {
  const c = cleanRun(raw);
  if (!c) return { ok: false, msg: 'Escribe el RUN.' };
  const body = c.slice(0, -1);
  const dv = c.slice(-1);
  if (!/^\d{7,8}$/.test(body)) return { ok: false, msg: 'El RUN debe tener 7 u 8 dígitos más el dígito verificador.' };
  const expected = computeDv(body);
  if (dv !== expected) return { ok: false, msg: 'Dígito verificador incorrecto: para ' + body + ' debería ser ' + expected + '.' };
  return { ok: true, msg: 'RUN válido.', normalized: body + '-' + dv };
}

// ---------- sesión (la credencial la emite IAM; PAC solo la usa) ----------
function decodeClaims(jwt) {
  try {
    const part = jwt.split('.')[1].replace(/-/g, '+').replace(/_/g, '/');
    const data = JSON.parse(atob(part));
    if (!data || typeof data !== 'object') return null;
    return data;
  } catch (e) {
    return null;
  }
}
function roleLabel(c) {
  const roles = Array.isArray(c.roles) ? c.roles : [];
  if (roles.includes('pac:write')) return 'Admisión';
  if (roles.includes('pac:read')) return 'Solo lectura';
  return 'Sin permisos PAC';
}
function setOut(el, text, kind) {
  el.textContent = text;
  el.className = 'out ' + (kind || '');
}

async function api(path, options) {
  const headers = { 'Accept': 'application/json' };
  if (token) headers['Authorization'] = 'Bearer ' + token;
  if (options && options.body) headers['Content-Type'] = 'application/json';
  const res = await fetch(path, Object.assign({ headers, credentials: 'omit', cache: 'no-store' }, options || {}));
  let body = null;
  try { body = await res.json(); } catch (e) { body = null; }
  if (res.status === 401 && claims) logout('Tu sesión venció o no es válida. Vuelve a iniciar sesión.');
  return { status: res.status, body };
}
function errorText(status, body) {
  if (status === 401) return 'No autorizado: inicia sesión de nuevo (401).';
  if (status === 403) return 'Tu rol no permite esta acción (403).';
  if (status === 409) return 'Ese RUN ya está registrado (409). Búscalo en la lista.';
  if (status === 422) {
    const first = body && Array.isArray(body.detail) && body.detail[0];
    const field = first && first.loc ? first.loc[first.loc.length - 1] : 'los datos';
    return 'Revisa ' + field + ': el servidor rechazó el valor (422).';
  }
  if (status === 503) return 'La base de datos no está disponible; intenta en un momento (503).';
  return 'Error inesperado (' + status + ').';
}

async function onLogin(e) {
  e.preventDefault();
  const out = $('loginOut');
  const candidate = $('token').value.trim();
  const c = decodeClaims(candidate);
  if (!candidate || !c) { setOut(out, 'La credencial no tiene un formato válido.', 'bad'); return; }
  if (c.exp && c.exp * 1000 <= Date.now()) { setOut(out, 'La credencial ya venció. Pide una nueva a IAM.', 'bad'); return; }
  $('loginBtn').disabled = true;
  setOut(out, 'Verificando con el servidor…', '');
  token = candidate;
  try {
    // La verificación real (firma, emisor, audiencia, vigencia y rol) la hace la API.
    const r = await api('/patients?page_size=1');
    if (r.status === 200) {
      enterApp(c);
    } else {
      token = '';
      setOut(out, r.status === 401 ? 'Credencial rechazada por el servidor (401).' : r.status === 403 ? 'Tu rol no tiene acceso a PAC (403).' : errorText(r.status, r.body), 'bad');
    }
  } catch (err) {
    token = '';
    setOut(out, 'No se pudo conectar con el servidor.', 'bad');
  } finally {
    $('loginBtn').disabled = false;
  }
}

function enterApp(c) {
  claims = c;
  try { sessionStorage.setItem('pac_token', token); } catch (err) { /* modo privado */ }
  $('token').value = '';
  setOut($('loginOut'), '', '');
  const sub = String(c.sub || 'usuario');
  $('userName').textContent = sub;
  $('avatar').textContent = sub.charAt(0).toUpperCase();
  $('userRole').textContent = roleLabel(c);
  const canWrite = Array.isArray(c.roles) && c.roles.includes('pac:write');
  $('regBtn').disabled = !canWrite;
  if (!canWrite) setOut($('regOut'), 'Tu sesión es de solo lectura: puedes buscar, pero no registrar.', '');
  $('login').hidden = true;
  $('app').hidden = false;
  updateExpiry();
  clearInterval(expiryTimer);
  expiryTimer = setInterval(updateExpiry, 30000);
  lastQuery = {};
  search(1);
}
function updateExpiry() {
  if (!claims || !claims.exp) { $('expires').textContent = 'Sesión activa'; return; }
  const ms = claims.exp * 1000 - Date.now();
  if (ms <= 0) { logout('Tu sesión venció. Vuelve a iniciar sesión.'); return; }
  const min = Math.floor(ms / 60000);
  $('expires').textContent = 'Sesión vence en ' + (min >= 60 ? Math.floor(min / 60) + ' h ' + (min % 60) + ' min' : min + ' min');
}
function logout(message) {
  token = '';
  claims = null;
  clearInterval(expiryTimer);
  try { sessionStorage.removeItem('pac_token'); } catch (err) { /* modo privado */ }
  $('regForm').reset();
  onRunInput();
  setOut($('regOut'), '', '');
  $('results').replaceChildren();
  $('app').hidden = true;
  $('login').hidden = false;
  setOut($('loginOut'), message || 'Sesión cerrada.', message ? 'bad' : 'ok');
  $('token').focus();
}

// ---------- registro ----------
function onRunInput() {
  const input = $('run');
  const formatted = formatRun(input.value);
  if (formatted !== input.value) input.value = formatted;
  const st = runStatus(input.value);
  $('runMsg').textContent = input.value ? st.msg : 'Se valida el dígito verificador (Módulo 11) mientras escribes.';
  $('runMsg').className = 'msg ' + (input.value ? (st.ok ? 'ok' : 'bad') : '');
  input.setAttribute('aria-invalid', String(!st.ok && !!input.value));
}

async function onRegister(e) {
  e.preventDefault();
  const out = $('regOut');
  const st = runStatus($('run').value);
  if (!st.ok) { setOut(out, st.msg, 'bad'); $('run').focus(); return; }
  const data = { run: st.normalized };
  for (const name of ['nombres', 'apellido_paterno', 'apellido_materno', 'fecha_nacimiento', 'prevision', 'email', 'telefono', 'direccion']) {
    const v = $(name).value.trim();
    if (v) data[name] = v;
  }
  for (const name of ['nombres', 'apellido_paterno', 'fecha_nacimiento', 'prevision']) {
    if (!data[name]) { setOut(out, 'Completa el campo obligatorio: ' + $(name).labels[0].textContent.replace('*', '').trim() + '.', 'bad'); $(name).focus(); return; }
  }
  $('regBtn').disabled = true;
  setOut(out, 'Registrando…', '');
  try {
    const r = await api('/patients', { method: 'POST', body: JSON.stringify(data) });
    if (r.status === 201) {
      setOut(out, 'Paciente registrado con ID ' + r.body.id + ' (RUN ' + formatRun(r.body.run) + ').', 'ok');
      $('regForm').reset();
      onRunInput();
      search(page);
    } else {
      setOut(out, errorText(r.status, r.body), 'bad');
    }
  } catch (err) {
    setOut(out, 'No se pudo conectar con el servidor.', 'bad');
  } finally {
    $('regBtn').disabled = !(claims && Array.isArray(claims.roles) && claims.roles.includes('pac:write'));
  }
}

// ---------- búsqueda paginada ----------
function ageText(isoDate) {
  const d = new Date(isoDate + 'T00:00:00');
  if (isNaN(d)) return isoDate;
  const now = new Date();
  let age = now.getFullYear() - d.getFullYear();
  if (now < new Date(now.getFullYear(), d.getMonth(), d.getDate())) age--;
  return age + ' años';
}
function messageRow(text) {
  const tbody = $('results');
  tbody.replaceChildren();
  const tr = document.createElement('tr');
  const td = document.createElement('td');
  td.colSpan = 4; td.className = 'empty'; td.textContent = text;
  tr.appendChild(td); tbody.appendChild(tr);
}
function renderRows(items) {
  if (!items.length) { messageRow('Sin resultados. Si el paciente no existe, regístralo en el formulario.'); return; }
  const tbody = $('results');
  tbody.replaceChildren();
  for (const p of items) {
    const tr = document.createElement('tr');
    const add = (text, cls) => {
      const td = document.createElement('td');
      if (cls) td.className = cls;
      td.textContent = text;
      tr.appendChild(td);
      return td;
    };
    add(formatRun(p.run), 'mono');
    add([p.nombres, p.apellido_paterno, p.apellido_materno].filter(Boolean).join(' '));
    add(ageText(p.fecha_nacimiento));
    const td = add('');
    const badge = document.createElement('span');
    badge.className = 'badge ' + (/^[A-Z]+$/.test(p.prevision) ? p.prevision : '');
    badge.textContent = p.prevision;
    td.appendChild(badge);
    tbody.appendChild(tr);
  }
}
async function search(newPage) {
  if (!claims) return;
  const params = new URLSearchParams(lastQuery);
  params.set('page', String(newPage));
  params.set('page_size', String(PAGE_SIZE));
  let r;
  try { r = await api('/patients?' + params.toString()); } catch (e) { messageRow('No se pudo conectar con el servidor.'); return; }
  if (!claims) return;
  if (r.status !== 200) {
    messageRow(errorText(r.status, r.body));
    $('prev').disabled = true; $('next').disabled = true;
    return;
  }
  page = newPage;
  renderRows(r.body.items);
  const pages = Math.max(1, Math.ceil(r.body.total / PAGE_SIZE));
  $('pageInfo').textContent = 'Página ' + page + ' de ' + pages + ' · ' + r.body.total + (r.body.total === 1 ? ' paciente' : ' pacientes');
  $('prev').disabled = page <= 1;
  $('next').disabled = page >= pages;
}
function onSearch(e) {
  e.preventDefault();
  const q = {};
  const runRaw = $('s_run').value.trim();
  if (runRaw) {
    const st = runStatus(runRaw);
    if (!st.ok) { $('sRunMsg').textContent = st.msg; $('sRunMsg').className = 'msg bad'; $('s_run').focus(); return; }
    q.run = st.normalized;
  }
  $('sRunMsg').textContent = 'Búsqueda exacta, la forma más segura de identificar al paciente.';
  $('sRunMsg').className = 'msg';
  const pat = $('s_paterno').value.trim();
  const mat = $('s_materno').value.trim();
  const prev = $('s_prev').value;
  if (pat) q.apellido_paterno = pat;
  if (mat) q.apellido_materno = mat;
  if (prev) q.prevision = prev;
  lastQuery = q;
  search(1);
}
function onClear() {
  $('searchForm').reset();
  $('sRunMsg').textContent = 'Búsqueda exacta, la forma más segura de identificar al paciente.';
  $('sRunMsg').className = 'msg';
  lastQuery = {};
  search(1);
}

document.addEventListener('DOMContentLoaded', () => {
  $('today').textContent = new Date().toLocaleDateString('es-CL', { weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' });
  $('loginForm').addEventListener('submit', onLogin);
  $('logoutBtn').addEventListener('click', () => logout());
  $('run').addEventListener('input', onRunInput);
  $('s_run').addEventListener('input', () => { $('s_run').value = formatRun($('s_run').value); });
  $('regForm').addEventListener('submit', onRegister);
  $('resetBtn').addEventListener('click', () => setTimeout(() => { onRunInput(); setOut($('regOut'), '', ''); }, 0));
  $('searchForm').addEventListener('submit', onSearch);
  $('clearBtn').addEventListener('click', onClear);
  $('prev').addEventListener('click', () => search(page - 1));
  $('next').addEventListener('click', () => search(page + 1));
  // Si la pestaña ya tenía una sesión vigente, se vuelve a verificar con el servidor.
  let saved = '';
  try { saved = sessionStorage.getItem('pac_token') || ''; } catch (err) { saved = ''; }
  if (saved) { $('token').value = saved; $('loginForm').requestSubmit(); } else { $('token').focus(); }
});
