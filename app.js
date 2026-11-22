import { createClient } from 'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.58.0/+esm';
import { SUPABASE_URL, SUPABASE_KEY, VAPID_PUBLIC_KEY } from './config.js';

const sb = createClient(SUPABASE_URL, SUPABASE_KEY);
const $ = (id) => document.getElementById(id);
let me, partner;

if ('serviceWorker' in navigator) navigator.serviceWorker.register('./sw.js');

// ---------- helpers ----------
const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const mult = (n) => 'x' + (2n ** BigInt(n)).toString();
const date = (d) => new Date(d).toLocaleDateString('it-IT');
const msg = (text) => { $('msg').textContent = text || ''; };
const show = (view) => ['auth', 'link', 'main'].forEach((v) => { $(v).hidden = v !== view; });
function check({ data, error }) { if (error) throw error; return data; }
async function run(fn) { msg(''); try { await fn(); } catch (e) { msg(e.message || String(e)); } }

function taskHtml(t) {
  return `<p class="text">${esc(t.text)}</p>
    <p>🎁 Premio: ${esc(t.reward)}</p>
    <p>⚡ Punizione: ${esc(t.punishment)} <b class="mult">${mult(t.doublings)}</b></p>
    <p class="small">Estratto il ${date(t.drawn_at)}</p>`;
}

// ---------- load / render ----------
async function load() {
  const { data: { session } } = await sb.auth.getSession();
  if (!session) return show('auth');
  const profiles = check(await sb.from('profiles').select('*'));
  me = profiles.find((p) => p.id === session.user.id);
  partner = profiles.find((p) => p.id !== session.user.id);
  if (!partner) {
    $('my-code').textContent = me.invite_code;
    return show('link');
  }

  const tasks = check(await sb.from('tasks').select('*'));
  const open = (t) => t.status === 'active' || t.status === 'done';
  const mine = tasks.find((t) => t.recipient_id === me.id && open(t));
  const theirs = tasks.find((t) => t.author_id === me.id && open(t));

  document.querySelectorAll('.partner-name').forEach((el) => { el.textContent = partner.name || 'partner'; });

  $('mine').innerHTML = !mine ? '<p class="small">Nessun task: il prossimo arriva lunedì.</p>'
    : taskHtml(mine) + (mine.status === 'active'
      ? `<button data-done="${mine.id}">Fatto ✓</button>`
      : `<p class="small">In attesa della conferma di ${esc(partner.name)}.</p>`);

  $('theirs').innerHTML = !theirs ? '<p class="small">Nessun task in corso.</p>'
    : taskHtml(theirs) + (theirs.status === 'done'
      ? `<button data-confirm="${theirs.id}">Conferma ✓</button>`
      : '<p class="small">Non ancora fatto.</p>');

  const pool = tasks.filter((t) => t.author_id === me.id && t.status === 'pool').length;
  $('pool-count').textContent = `Nel pool: ${pool} task`;

  const history = tasks.filter((t) => t.status === 'completed')
    .sort((a, b) => b.completed_at.localeCompare(a.completed_at));
  $('history').innerHTML = history.length ? history.map((t) =>
    `<li><b>${t.recipient_id === me.id ? 'Io' : esc(partner.name)}</b>: ${esc(t.text)}
     <span class="small">· ${date(t.completed_at)}${t.doublings ? ' · punizione ' + mult(t.doublings) : ''}</span></li>`).join('')
    : '<li class="small">Ancora niente.</li>';

  $('hours').value = me.reminder_hours;
  show('main');
  resyncPush();
}

// ---------- actions ----------
$('login-btn').onclick = () => run(async () => {
  check(await sb.auth.signInWithPassword({ email: $('email').value.trim(), password: $('password').value }));
  await load();
});

$('signup-btn').onclick = () => run(async () => {
  const name = $('name').value.trim();
  if (!name) throw new Error('Inserisci il tuo nome per registrarti.');
  const data = check(await sb.auth.signUp({
    email: $('email').value.trim(), password: $('password').value, options: { data: { name } },
  }));
  if (!data.session) return msg('Conferma la registrazione dal link nella email, poi accedi.');
  await load();
});

document.querySelectorAll('.logout').forEach((b) => {
  b.onclick = () => run(async () => { await sb.auth.signOut(); show('auth'); });
});

$('join-btn').onclick = () => run(async () => {
  check(await sb.rpc('join_partner', { code: $('partner-code').value }));
  await load();
});
$('refresh-btn').onclick = () => run(load);

$('main').addEventListener('click', (e) => {
  const { done, confirm } = e.target.dataset;
  if (done) run(async () => { check(await sb.rpc('mark_done', { task_id: Number(done) })); await load(); });
  if (confirm) run(async () => { check(await sb.rpc('confirm_done', { task_id: Number(confirm) })); await load(); });
});

$('add').onsubmit = (e) => {
  e.preventDefault();
  run(async () => {
    check(await sb.from('tasks').insert({
      recipient_id: partner.id,
      text: $('t-text').value.trim(),
      reward: $('t-reward').value.trim(),
      punishment: $('t-punishment').value.trim(),
    }));
    $('add').reset();
    await load();
    msg('Task aggiunto ✓');
  });
};

$('hours-btn').onclick = () => run(async () => {
  check(await sb.from('profiles').update({ reminder_hours: Number($('hours').value) }).eq('id', me.id));
  msg('Salvato ✓');
});

// ---------- push ----------
function urlB64ToUint8(b64) {
  const s = atob((b64 + '='.repeat((4 - (b64.length % 4)) % 4)).replace(/-/g, '+').replace(/_/g, '/'));
  return Uint8Array.from(s, (c) => c.charCodeAt(0));
}

async function saveSubscription(sub) {
  const j = sub.toJSON();
  check(await sb.rpc('save_subscription', { p_endpoint: j.endpoint, p_p256dh: j.keys.p256dh, p_auth: j.keys.auth }));
}

$('notif-btn').onclick = () => run(async () => {
  if (!('PushManager' in window) || !('Notification' in window)) {
    throw new Error("Per le notifiche apri l'app dall'icona sulla Home (Safari → Condividi → Aggiungi alla schermata Home).");
  }
  if (!VAPID_PUBLIC_KEY) throw new Error('Notifiche non ancora configurate.');
  // iOS: the permission request must be the first await after the tap.
  if (await Notification.requestPermission() !== 'granted') throw new Error('Permesso notifiche negato.');
  const reg = await navigator.serviceWorker.ready;
  const sub = await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: urlB64ToUint8(VAPID_PUBLIC_KEY) });
  await saveSubscription(sub);
  msg('Notifiche attive ✓');
});

// Keep the stored subscription up to date if permission was already granted.
async function resyncPush() {
  try {
    if (!VAPID_PUBLIC_KEY || !('PushManager' in window) || Notification.permission !== 'granted') return;
    const sub = await (await navigator.serviceWorker.ready).pushManager.getSubscription();
    if (sub) await saveSubscription(sub);
  } catch { /* ignore */ }
}

document.addEventListener('visibilitychange', () => { if (!document.hidden && me) run(load); });
run(load);
