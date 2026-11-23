const { app, BrowserWindow, ipcMain } = require('electron');
const { spawn, execFile } = require('child_process');
const path = require('path');
const os = require('os');

const isWin = process.platform === 'win32';
let win = null;
let proc = null;
let tickTimer = null;
let prevCpu = null;

const psEncoded = (script) =>
  Buffer.from("$ProgressPreference='SilentlyContinue';" + script, 'utf16le').toString('base64');

function runPS(script, timeout = 15000) {
  return new Promise((resolve) => {
    if (!isWin) return resolve('');
    execFile('powershell.exe',
      ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', psEncoded(script)],
      { windowsHide: true, timeout, encoding: 'utf8' },
      (err, out) => resolve(err ? '' : String(out).replace(/^\uFEFF/, '').trim()));
  });
}

function userFirstName() {
  let n = '';
  try { n = os.userInfo().username; } catch (e) { n = process.env.USERNAME || 'Jogador'; }
  n = n.replace(/\$+$/, '').split(/\s+/)[0] || 'Jogador';
  if (n === n.toLowerCase()) n = n.charAt(0).toUpperCase() + n.slice(1);
  return n;
}

function scriptPath() {
  return app.isPackaged
    ? path.join(process.resourcesPath, 'scripts', 'GODAL_OS.ps1')
    : path.join(__dirname, 'scripts', 'GODAL_OS.ps1');
}

function send(ch, data) { if (win && !win.isDestroyed()) win.webContents.send(ch, data); }

function createWindow() {
  win = new BrowserWindow({
    width: 1100, height: 700, minWidth: 960, minHeight: 620,
    frame: false, backgroundColor: '#070617', show: false,
    icon: path.join(__dirname, 'build', 'icon.png'),
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true, nodeIntegration: false, sandbox: true
    }
  });
  win.setMenu(null);
  win.loadFile(path.join(__dirname, 'src', 'index.html'));
  win.once('ready-to-show', () => win.show());
  win.on('closed', () => { win = null; });
}

// ---- janela ----
ipcMain.on('win:min', () => win && win.minimize());
ipcMain.on('win:max', () => win && (win.isMaximized() ? win.unmaximize() : win.maximize()));
ipcMain.on('win:close', () => win && win.close());

// ---- informações do PC ----
ipcMain.handle('sys:info', async () => {
  const base = { name: userFirstName(), os: 'Windows', cpu: os.cpus()[0] ? os.cpus()[0].model.trim() : 'CPU',
    cores: os.cpus().length, gpu: 'GPU', ram: Math.round(os.totalmem() / 1073741824), disk: 'Disco', diskGb: 0, speed: 0 };
  const out = await runPS(
    "$o=Get-CimInstance Win32_OperatingSystem;$c=Get-CimInstance Win32_Processor|Select-Object -First 1;" +
    "$v=Get-CimInstance Win32_VideoController|Where-Object{$_.Name -notmatch 'Basic|Remote|Virtual'}|Select-Object -First 1;" +
    "$d=Get-CimInstance Win32_DiskDrive|Select-Object -First 1;$m=Get-CimInstance Win32_PhysicalMemory|Select-Object -First 1;" +
    "[pscustomobject]@{os=$o.Caption;arch=$o.OSArchitecture;cpu=$c.Name.Trim();cores=$c.NumberOfCores;gpu=$v.Name;disk=$d.Model;" +
    "diskGb=[math]::Round($d.Size/1GB);speed=$m.Speed;ramGb=[math]::Round($o.TotalVisibleMemorySize/1MB)}|ConvertTo-Json -Compress");
  try { return Object.assign(base, JSON.parse(out)); } catch (e) { return base; }
});

function cpuTimes() {
  return os.cpus().reduce((a, c) => {
    const t = c.times; a.idle += t.idle; a.total += t.user + t.nice + t.sys + t.idle + t.irq; return a;
  }, { idle: 0, total: 0 });
}

let slow = { gpu: 0, disk: 0 }, slowBusy = false;
async function slowTick() {
  if (slowBusy) return; slowBusy = true;
  const out = await runPS(
    "$g=0;try{$g=[int](Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine -ErrorAction Stop|" +
    "Where-Object{$_.Name -like '*engtype_3D*'}|Measure-Object UtilizationPercentage -Sum).Sum}catch{};" +
    "$d=0;try{$d=[int](Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk -Filter \"Name='_Total'\" -ErrorAction Stop).PercentDiskTime}catch{};" +
    "\"$g|$d\"", 10000);
  const m = out.match(/^(\d+)\|(\d+)$/);
  if (m) slow = { gpu: Math.min(100, +m[1]), disk: Math.min(100, +m[2]) };
  slowBusy = false;
}

ipcMain.on('sys:watch', () => {
  if (tickTimer) return;
  prevCpu = cpuTimes();
  const tick = () => {
    const cur = cpuTimes();
    const dt = cur.total - prevCpu.total, di = cur.idle - prevCpu.idle;
    const cpu = dt > 0 ? Math.round(100 * (1 - di / dt)) : 0;
    prevCpu = cur;
    const total = os.totalmem(), free = os.freemem();
    send('sys:tick', { cpu, ram: Math.round(100 * (1 - free / total)), freeGb: free / 1073741824, gpu: slow.gpu, disk: slow.disk });
  };
  tick(); slowTick();
  tickTimer = setInterval(() => { tick(); slowTick(); }, 2000);
});

// ---- executa o script de otimização / restauração ----
ipcMain.handle('run:start', (_e, mode) => {
  if (proc) return { ok: false, error: 'Já existe uma execução em andamento.' };
  if (!isWin) return { ok: false, error: 'O GODAL OS só funciona no Windows.' };
  const args = ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', scriptPath(), '-Json', '-NomeOrig', userFirstName()];
  if (mode === 'rest') args.push('-Restaurar');
  proc = spawn('powershell.exe', args, { windowsHide: true });
  proc.stdout.setEncoding('utf8'); proc.stderr.setEncoding('utf8');
  let buf = '', err = '';
  const feed = (line) => {
    line = line.replace(/^\uFEFF/, '').replace(/\r$/, '');
    const k = line.indexOf('##'); if (k < 0) return; line = line.slice(k);
    const p = line.slice(2).split('|');
    const kind = p.shift();
    if (kind === 'SEC') send('run:event', { kind: 'sec', name: p.join('|') });
    else if (kind === 'RUN') send('run:event', { kind: 'run', name: p.join('|') });
    else if (kind === 'IA') send('run:event', { kind: 'ia', text: p.join('|') });
    else if (kind === 'STEP') send('run:event', { kind: 'step', name: p[0], status: p[1], msg: p.slice(2).join('|') });
  };
  proc.stdout.on('data', (d) => { buf += d; let i; while ((i = buf.indexOf('\n')) >= 0) { feed(buf.slice(0, i)); buf = buf.slice(i + 1); } });
  proc.stderr.on('data', (d) => { err += d; });
  proc.on('error', (e) => { send('run:done', { code: -1, error: e.message }); proc = null; });
  proc.on('close', (code) => { if (buf) feed(buf); send('run:done', { code, error: err.trim().split('\n')[0] || '' }); proc = null; });
  return { ok: true };
});

const lock = app.requestSingleInstanceLock();
if (!lock) app.quit();
else {
  app.on('second-instance', () => { if (win) { if (win.isMinimized()) win.restore(); win.focus(); } });
  app.whenReady().then(createWindow);
  app.on('window-all-closed', () => { if (tickTimer) clearInterval(tickTimer); app.quit(); });
}
