const $ = (id) => document.getElementById(id);
const api = window.godal;
let NAME = 'Jogador', cur = 'opt', busy = false, tt = 0, freeGb = 0, lastGroup = null, doneN = 0, idx = 0, res = {};

const PLAN = {
  opt: {
    title: 'Etapas da otimização', btn: 'Otimizar agora', busy: 'Otimizando…', again: 'Otimizar de novo',
    idle: 'Pronto para otimizar', end: 'Emulador no máximo', emu: true,
    idleMsg: () => `Olá, ${NAME}. Eu sou a GODAL IA e vou deixar seu emulador no máximo.`,
    runMsg: 'Estou aplicando os ajustes. Não feche o emulador até terminar.',
    steps: [
      ['Segurança', ['Ponto de restauração (única vez)']],
      ['Limpeza', ['Reiniciar emulador limpo', 'Fechar apps de segundo plano', 'Limpar disco, temporários e cache', 'Limpar RAM e cache da RAM']],
      ['Alta performance', ['CPU e disco: prioridade do emulador', 'CPU: foco no programa em primeiro plano', 'GPU: alto desempenho',
        'GPU e jogos: prioridade (MMCSS) e rede', 'Game Mode ligado, gravação em fundo off', 'CPU: sem limitação de energia',
        'RAM: manter núcleo do Windows na memória', 'Tela cheia sem otimização do Windows', 'Serviços de telemetria e cache',
        'Defender: não varrer o emulador', 'Guardar backup (restaurar depois)']],
      ['Lançamento', ['Abrir emulador', 'Prioridade Alta, memória e disco']]
    ],
    stats: [['RAM livre', '—'], ['Cache liberado', '—'], ['Apps fechados', '—'], ['Backup dos ajustes', 'Aguardando']],
    statMap: { 'Limpar disco, temporários e cache': 1, 'Fechar apps de segundo plano': 2, 'Guardar backup (restaurar depois)': 3 }
  },
  rest: {
    title: 'Etapas da restauração', btn: 'Restaurar agora', busy: 'Restaurando…', again: 'Restaurar de novo',
    idle: 'Pronto para restaurar', end: 'Valores originais', emu: false,
    idleMsg: () => 'Aqui eu desfaço tudo o que a otimização mudou e devolvo o seu PC aos valores originais.',
    runMsg: 'Estou repondo os valores originais a partir do backup.',
    steps: [['Restauração', ['Repor ajustes do registro', 'Repor serviços']]],
    stats: [['Ajustes do registro', '—'], ['Serviços', '—']],
    statMap: { 'Repor ajustes do registro': 0, 'Repor serviços': 1 }
  }
};
Object.values(PLAN).forEach((p) => { p.total = p.steps.reduce((n, [, it]) => n + it.length, 0); });
const BD = { OK: ['ok', 'OK'], WARN: ['warn', 'AVISO'], SKIP: ['skip', 'IGNORADO'], FAIL: ['fail', 'FALHOU'] };
const esc = (t) => String(t).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

function say(t) {
  clearInterval(tt); const el = $('msg'); el.textContent = ''; let i = 0;
  tt = setInterval(() => { el.textContent = t.slice(0, ++i); if (i >= t.length) clearInterval(tt); }, 14);
}
function setProgress(done) {
  const T = PLAN[cur].total, p = T ? Math.min(1, done / T) : 0;
  $('fg').style.strokeDashoffset = 703.7 * (1 - p); $('pct').textContent = Math.round(p * 100) + '%';
  $('cnt').textContent = Math.min(done, T) + ' de ' + T;
}
function term(txt, cls) {
  const L = $('tlines'), d = document.createElement('div');
  d.innerHTML = '<span class="t">' + new Date().toTimeString().slice(0, 8) + '</span> <span class="' + (cls || '') + '">' + esc(txt) + '</span>';
  L.appendChild(d); while (L.children.length > 300) L.removeChild(L.firstChild);
  const b = $('tl'); b.scrollTop = b.scrollHeight;
}
function setStat(k, v) { const el = $('s' + k); if (el) el.textContent = v; }
function fmtGb(g) { return g.toFixed(1).replace('.', ',') + ' GB'; }

function render() {
  const v = PLAN[cur]; doneN = 0; idx = 0; lastGroup = null; res = { OK: 0, WARN: 0, SKIP: 0, FAIL: 0 };
  $('list').innerHTML = '<div class="hint">As etapas aparecem aqui, uma por uma.</div>';
  $('rt').textContent = v.title; setProgress(0); $('lbl').textContent = v.idle;
  $('emu').style.display = v.emu ? 'flex' : 'none';
  const s = $('stats'); s.className = 'stats' + (v.stats.length === 2 ? ' two' : '');
  s.innerHTML = v.stats.map(([n, i], k) => '<div class="st"><span>' + n + '</span><b id="s' + k + '">' + i + '</b></div>').join('');
  if (cur === 'opt' && freeGb) setStat(0, fmtGb(freeGb));
  $('go').disabled = false; $('go').textContent = v.btn; say(v.idleMsg());
  $('tlines').innerHTML = ''; term('godal-shell v1.0 · sessão iniciada', 'cmd'); term('aguardando comando…', 't');
}

// sem scroll: se não couber, as etapas mais antigas saem do topo
function fit() { const l = $('list'); while (l.scrollHeight > l.clientHeight + 1 && l.children.length > 1) l.removeChild(l.firstChild); }

function rowFor(name) {
  const l = $('list'), h = l.querySelector('.hint'); if (h) h.remove();
  let r = [...l.children].find((x) => x.dataset && x.dataset.name === name);
  if (!r) {
    const g = (PLAN[cur].steps.find(([, it]) => it.includes(name)) || [])[0];
    if (g && g !== lastGroup) { lastGroup = g; const hd = document.createElement('div'); hd.className = 'g'; hd.textContent = g; l.appendChild(hd); }
    r = document.createElement('div'); r.className = 'row'; r.dataset.name = name;
    r.innerHTML = '<i class="dot"></i><span>' + esc(name) + '</span><span class="n"></span>';
    l.appendChild(r); fit();
  }
  return r;
}

api.onEvent((e) => {
  if (!busy) return; const v = PLAN[cur];
  if (e.kind === 'ia') {
    const m = e.text.match(/Encontrei o (.+?)\. /);
    if (m) { $('emun').textContent = m[1]; $('emus').textContent = 'encontrado'; }
    say(e.text); term('# ' + e.text, 'ia');
  } else if (e.kind === 'run') {
    const r = rowFor(e.name); r.classList.add('on'); idx++;
    $('lbl').textContent = 'Etapa ' + Math.min(idx, v.total) + ' de ' + v.total;
    term('$ ' + e.name + ' …', 'cmd');
  } else if (e.kind === 'step') {
    const r = rowFor(e.name); const b = BD[e.status] || BD.OK;
    r.classList.remove('on'); r.classList.add('done'); if (e.status !== 'OK') r.classList.add(b[0]);
    r.querySelector('.n').textContent = e.msg || '';
    term('[' + b[1] + '] ' + e.name + (e.msg ? ' — ' + e.msg : ''), e.status === 'OK' ? 'ok' : e.status === 'WARN' ? 'wr' : e.status === 'FAIL' ? 'er' : 't');
    const bd = document.createElement('span'); bd.className = 'bd ' + b[0]; bd.textContent = b[1]; r.appendChild(bd);
    doneN++; res[BD[e.status] ? e.status : 'OK']++; setProgress(doneN); fit();
    const k = v.statMap[e.name];
    if (k !== undefined) setStat(k, cur === 'opt' && k === 3 ? (e.status === 'OK' ? 'Salvo' : 'Não salvo') : (e.msg || (e.status === 'OK' ? 'OK' : '—')));
  }
});

api.onDone((d) => {
  const v = PLAN[cur]; $('core').classList.remove('work');
  const total = res.OK + res.WARN + res.SKIP + res.FAIL;
  $('list').querySelectorAll('.row.on').forEach((r) => r.classList.remove('on'));
  term('✔ processo finalizado (' + total + ' etapas, código ' + d.code + ')', total ? 'ok' : 'er');
  if (!total) {
    $('lbl').textContent = 'Não concluído';
    say(d.error ? 'Não consegui executar: ' + d.error : 'Não consegui aplicar nada. Abra o GODAL OS como administrador e tenha um emulador instalado (BlueStacks, MSI, LDPlayer, Nox ou MEmu).');
  } else {
    setProgress(v.total); $('lbl').textContent = v.end;
    if (cur === 'opt') say(`Pronto, ${NAME}. ${res.OK} ajustes aplicados, ${res.WARN} aviso${res.WARN === 1 ? '' : 's'}, ${res.SKIP} ignorado${res.SKIP === 1 ? '' : 's'}` + (res.FAIL ? ` e ${res.FAIL} falha${res.FAIL === 1 ? '' : 's'}` : '') + '. Para voltar atrás, abra Restaurar.');
    else say('Valores originais repostos. Reinicie o PC para concluir a restauração.');
  }
  $('go').disabled = false; $('go').textContent = v.again; busy = false;
});

async function run() {
  if (busy) return; const v = PLAN[cur]; render(); busy = true;
  $('go').disabled = true; $('go').textContent = v.busy; say(v.runMsg); $('core').classList.add('work');
  term('$ godal --' + (cur === 'opt' ? 'otimizar' : 'restaurar') + ' --admin', 'cmd');
  const r = await api.run(cur);
  if (!r.ok) { busy = false; $('core').classList.remove('work'); $('go').disabled = false; $('go').textContent = v.btn; say(r.error); }
}

const HW = [['CPU'], ['GPU'], ['RAM'], ['Disco']];
$('hw').innerHTML = HW.map(([k], i) => '<div class="hi"><div class="t">' + k + '<b id="hp' + i + '">0%</b></div><div class="nm" id="hn' + i + '">…</div><div class="bar"><i id="hb' + i + '"></i></div></div>').join('');
const setHw = (i, pct) => { $('hp' + i).textContent = pct + '%'; $('hb' + i).style.width = pct + '%'; };

api.watch((t) => {
  setHw(0, t.cpu); setHw(1, t.gpu); setHw(2, t.ram); setHw(3, t.disk); freeGb = t.freeGb;
  if (cur === 'opt') setStat(0, fmtGb(freeGb));
});
api.info().then((i) => {
  NAME = i.name; $('who').textContent = 'Olá, ' + NAME;
  $('os').textContent = (i.os || 'Windows').replace(/^Microsoft\s+/, '') + (i.arch ? ' · ' + i.arch : '');
  const names = [i.cpu + (i.cores ? ' · ' + i.cores + ' núcleos' : ''), i.gpu || 'GPU', (i.ramGb || i.ram) + ' GB' + (i.speed ? ' · ' + i.speed + ' MHz' : ''), (i.disk || 'Disco') + (i.diskGb ? ' · ' + i.diskGb + ' GB' : '')];
  names.forEach((n, k) => { $('hn' + k).textContent = n; $('hn' + k).title = n; });
  if (!busy) say(PLAN[cur].idleMsg());
});

$('go').onclick = run;
$('wmin').onclick = api.min; $('wmax').onclick = api.max; $('wclose').onclick = api.close;
$('nav').addEventListener('click', (e) => {
  const b = e.target.closest('button'); if (!b || busy || b.dataset.v === cur) return; cur = b.dataset.v;
  [...$('nav').children].forEach((x) => x === b ? x.setAttribute('aria-current', 'page') : x.removeAttribute('aria-current'));
  render();
});
render();
