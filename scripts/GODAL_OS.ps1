param(
    [string]$NomeOrig = '',
    [string]$DesktopOrig = '',
    [switch]$Restaurar,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
$Host.UI.RawUI.WindowTitle = 'GODAL OS'

# ── Configuração ─────────────────────────────────────────────────────────────
$EmuladorPreferido = ''      # ex.: 'LDPlayer'. Vazio = usa o primeiro que encontrar
$ExclusaoDefender  = $false  # $true = o Defender não varre o emulador (menos travadas, menos proteção)
$EsvaziarLixeira   = $false  # $true = também esvazia a Lixeira na limpeza

function Get-NomeUsuario {
    $login = ([Environment]::UserName).TrimEnd('$')
    if (-not $login) { $login = $env:USERNAME }
    $full = ''
    try {
        $acc = Get-CimInstance Win32_UserAccount -Filter ("Name='{0}'" -f $login.Replace("'", "''")) -ErrorAction Stop | Select-Object -First 1
        if ($acc -and $acc.FullName) { $full = [string]$acc.FullName }
    } catch {}
    $base = if ($full.Trim()) { $full.Trim() } else { $login }
    $first = ($base -split '\s+')[0]
    if (-not $first) { $first = $login }
    if ($first -ceq $first.ToLower()) { $first = (Get-Culture).TextInfo.ToTitleCase($first) }
    return $first
}

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) -and -not $Json) {
    $n = Get-NomeUsuario
    $d = [Environment]::GetFolderPath('Desktop')
    $extra = if ($Restaurar) { ' -Restaurar' } else { '' }
    Start-Process powershell -Verb RunAs -ArgumentList ("-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -NomeOrig `"$n`" -DesktopOrig `"$d`"$extra")
    exit
}

$Nome = if ($NomeOrig) { $NomeOrig } else { Get-NomeUsuario }

try {
    $ui = $Host.UI.RawUI
    $ui.BufferSize = New-Object Management.Automation.Host.Size(100, 1000)
    $ui.WindowSize = New-Object Management.Automation.Host.Size(100, 44)
} catch {}

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class GodalNative {
  [DllImport("ntdll.dll")] static extern int RtlAdjustPrivilege(int p, bool e, bool t, out bool o);
  [DllImport("ntdll.dll")] static extern int NtSetSystemInformation(int c, IntPtr i, int l);
  [DllImport("psapi.dll")] static extern bool EmptyWorkingSet(IntPtr h);
  [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int n);
  [DllImport("kernel32.dll")] static extern bool GetConsoleMode(IntPtr h, out int m);
  [DllImport("kernel32.dll")] static extern bool SetConsoleMode(IntPtr h, int m);
  [DllImport("ntdll.dll")] static extern int NtSetInformationProcess(IntPtr h, int c, ref int i, int l);
  [StructLayout(LayoutKind.Sequential)] struct PWR { public uint Version; public uint ControlMask; public uint StateMask; }
  [DllImport("kernel32.dll")] static extern bool SetProcessInformation(IntPtr h, int c, ref PWR i, int l);
  [DllImport("kernel32.dll")] static extern bool SetProcessInformation(IntPtr h, int c, ref int i, int l);
  public static int Mem(int cmd) {
    bool o; RtlAdjustPrivilege(13, true, false, out o);
    IntPtr p = Marshal.AllocHGlobal(4); Marshal.WriteInt32(p, cmd);
    int r = NtSetSystemInformation(80, p, 4);
    Marshal.FreeHGlobal(p); return r;
  }
  public static bool Trim(IntPtr h) { return EmptyWorkingSet(h); }
  public static void Prio(IntPtr h) {
    bool o; RtlAdjustPrivilege(14, true, false, out o);
    int io = 3; NtSetInformationProcess(h, 33, ref io, 4);
    int mp = 5; SetProcessInformation(h, 0, ref mp, 4);
    PWR p = new PWR(); p.Version = 1; p.ControlMask = 1; p.StateMask = 0;
    SetProcessInformation(h, 4, ref p, 12);
  }
  public static bool EnableVT() {
    IntPtr h = GetStdHandle(-11); int m;
    if (!GetConsoleMode(h, out m)) return false;
    return SetConsoleMode(h, m | 4);
  }
}
"@

$W = 96
$ESC = [char]27
$script:VT = $false
try { $script:VT = [GodalNative]::EnableVT() } catch {}

$script:Results = New-Object System.Collections.ArrayList
$script:RegOrig = New-Object System.Collections.ArrayList
$script:SvcOrig = New-Object System.Collections.ArrayList
$script:N = 0
$script:Emu = $null
$script:Player = $null
$script:Dir = $null
$script:Exes = @()
$script:RamTotal = 0
$script:RamBefore = $null
$script:RamAfter = $null
$script:CacheAntes = -1
$script:CacheDepois = -1
$script:MemStatus = 0
$script:DiscoLiberado = $null
$script:AtalhoCopiado = $false

$DataDir    = Join-Path $env:ProgramData 'GODAL_OS'
$BackupFile = Join-Path $DataDir 'backup.json'

$Emuladores = @(
    @{ Nome = 'BlueStacks / MSI App Player'
       Globs = @("$env:ProgramFiles\BlueStacks*\HD-Player.exe", "${env:ProgramFiles(x86)}\BlueStacks*\HD-Player.exe")
       Main = 'HD-Player'
       Proc = @('HD-Player','HD-Frontend','HD-Agent','HD-MultiInstanceManager','HD-Adb','BstkSVC','BstkVMMgr','BlueStacksServices','HD-LogRotatorService')
       Boost = @('HD-Player','HD-Frontend','HD-Agent','BstkSVC')
       Logs = @("$env:ProgramData\BlueStacks_nxt\Logs", "$env:ProgramData\BlueStacks\Logs") },
    @{ Nome = 'LDPlayer'
       Globs = @("$env:SystemDrive\LDPlayer\LDPlayer*\dnplayer.exe", "$env:ProgramFiles\LDPlayer\LDPlayer*\dnplayer.exe", "${env:ProgramFiles(x86)}\LDPlayer\LDPlayer*\dnplayer.exe")
       Main = 'dnplayer'
       Proc = @('dnplayer','LdVBoxHeadless','LdVBoxSVC','dnmultiplayerex')
       Boost = @('dnplayer','LdVBoxHeadless')
       Logs = @() },
    @{ Nome = 'Nox Player'
       Globs = @("$env:ProgramFiles\Nox\bin\Nox.exe", "${env:ProgramFiles(x86)}\Nox\bin\Nox.exe")
       Main = 'Nox'
       Proc = @('Nox','NoxVMHandle','NoxVMSVC')
       Boost = @('Nox','NoxVMHandle')
       Logs = @() },
    @{ Nome = 'MEmu'
       Globs = @("$env:ProgramFiles\Microvirt\MEmu\MEmu.exe", "${env:ProgramFiles(x86)}\Microvirt\MEmu\MEmu.exe")
       Main = 'MEmu'
       Proc = @('MEmu','MEmuHeadless','MEmuSVC','MEmuConsole')
       Boost = @('MEmu','MEmuHeadless')
       Logs = @() }
)

# Apps de segundo plano que roubam CPU/disco/rede. Fechados UMA vez, antes de abrir o emulador.
$Descartaveis = @(
    'OneDrive','OneDriveStandaloneUpdater','Teams','ms-teams','Skype','SkypeApp','SkypeHost',
    'YourPhone','PhoneExperienceHost','GameBar','GameBarPresenceWriter','Widgets','WidgetService',
    'MicrosoftEdgeUpdate','GoogleUpdate','GoogleCrashHandler','GoogleCrashHandler64',
    'AdobeARM','CCXProcess','CoreSync','Dropbox','GoogleDriveFS','Spotify',
    'EpicWebHelper','EpicGamesLauncher','EADesktop','EABackgroundService','Origin','OriginWebHelperService',
    'UbisoftConnect','upc','CompatTelRunner','MoUsoCoreWorker'
)

$Glifos = @{
    'G' = @(' ██████╗ ','██╔════╝ ','██║  ███╗','██║   ██║','╚██████╔╝',' ╚═════╝ ')
    'O' = @(' ██████╗ ','██╔═══██╗','██║   ██║','██║   ██║','╚██████╔╝',' ╚═════╝ ')
    'D' = @('██████╗ ','██╔══██╗','██║  ██║','██║  ██║','██████╔╝','╚═════╝ ')
    'A' = @(' █████╗ ','██╔══██╗','███████║','██╔══██║','██║  ██║','╚═╝  ╚═╝')
    'L' = @('██╗     ','██║     ','██║     ','██║     ','███████╗','╚══════╝')
    'S' = @('███████╗','██╔════╝','███████╗','╚════██║','███████║','╚══════╝')
    ' ' = @('   ','   ','   ','   ','   ','   ')
}

# ── Visual ───────────────────────────────────────────────────────────────────
function Paint([string]$t, [int[]]$a, [int[]]$b) {
    if (-not $script:VT) { Write-Host $t -ForegroundColor Magenta; return }
    $sb = New-Object Text.StringBuilder
    $span = [math]::Max(1, $t.Length - 1)
    for ($i = 0; $i -lt $t.Length; $i++) {
        $f = $i / $span
        $r = [int]($a[0] + ($b[0] - $a[0]) * $f)
        $g = [int]($a[1] + ($b[1] - $a[1]) * $f)
        $bl = [int]($a[2] + ($b[2] - $a[2]) * $f)
        [void]$sb.Append(("{0}[38;2;{1};{2};{3}m" -f $ESC, $r, $g, $bl))
        [void]$sb.Append($t[$i])
    }
    [void]$sb.Append("$ESC[0m")
    Write-Host $sb.ToString()
}

function Caixa([string[]]$linhas, [string]$moldura, [string]$texto) {
    $in = $W - 2
    Write-Host ('╔' + ('═' * $in) + '╗') -ForegroundColor $moldura
    foreach ($l in $linhas) {
        $txt = (' ' + $l).PadRight($in)
        Write-Host '║' -NoNewline -ForegroundColor $moldura
        Write-Host $txt -NoNewline -ForegroundColor $texto
        Write-Host '║' -ForegroundColor $moldura
    }
    Write-Host ('╚' + ('═' * $in) + '╝') -ForegroundColor $moldura
}

function Ia([string]$t, [string]$c = 'Cyan', [int]$ms = 6) {
    if ($Json) { [Console]::Out.WriteLine('##IA|' + $t); return }
    Write-Host '  ✦ GODAL IA › ' -NoNewline -ForegroundColor Magenta
    foreach ($ch in $t.ToCharArray()) {
        Write-Host $ch -NoNewline -ForegroundColor $c
        if ($ms -gt 0) { Start-Sleep -Milliseconds $ms }
    }
    Write-Host ''
}

function Banner {
    if ($Json) { return }
    Clear-Host
    Write-Host ''
    $word = 'GODAL OS'
    $pad = ' ' * [math]::Floor(($W - 62) / 2)
    for ($row = 0; $row -lt 6; $row++) {
        $line = ''
        foreach ($ch in $word.ToCharArray()) { $line += $Glifos[[string]$ch][$row] }
        Paint ($pad + $line) @(90, 110, 255) @(255, 90, 225)
    }
    Write-Host ''
    $sub = 'Optimizador de Emulador em alta performance'
    Write-Host ((' ' * [math]::Floor(($W - $sub.Length) / 2)) + $sub) -ForegroundColor DarkGray
    Write-Host ''
    Paint ('█' * $W) @(90, 110, 255) @(255, 90, 225)
    Write-Host ''
    Caixa @("Olá, $Nome. Eu sou a GODAL IA e vou deixar seu emulador no máximo.") 'Cyan' 'White'
    Write-Host ''
}

function Section($t) {
    if ($Json) { [Console]::Out.WriteLine('##SEC|' + $t) }
    Write-Host ''
    Write-Host ("  $t") -ForegroundColor Magenta
    Write-Host ('  ' + ('─' * ($W - 4))) -ForegroundColor DarkGray
}

function Badge($s) {
    switch ($s) {
        'OK'   { Write-Host ' OK       ' -NoNewline -BackgroundColor DarkGreen  -ForegroundColor White }
        'FAIL' { Write-Host ' FALHOU   ' -NoNewline -BackgroundColor DarkRed    -ForegroundColor White }
        'WARN' { Write-Host ' AVISO    ' -NoNewline -BackgroundColor DarkYellow -ForegroundColor Black }
        'SKIP' { Write-Host ' IGNORADO ' -NoNewline -BackgroundColor DarkGray   -ForegroundColor White }
    }
}

function Step([string]$Name, [scriptblock]$Do) {
    $script:N++
    if ($Json) { [Console]::Out.WriteLine('##RUN|' + $Name) }
    if (-not $Json) {
        Write-Host ('  [{0:00}] ' -f $script:N) -NoNewline -ForegroundColor DarkMagenta
        Write-Host $Name.PadRight(42) -NoNewline -ForegroundColor White
    }
    $status = 'OK'; $msg = ''
    try {
        $r = @(& $Do)[-1]
        if ($r -is [hashtable]) { $status = $r.Status; $msg = $r.Msg } elseif ($r) { $msg = [string]$r }
    } catch { $status = 'FAIL'; $msg = $_.Exception.Message }
    [void]$script:Results.Add([pscustomobject]@{ Name = $Name; Status = $status; Msg = $msg })
    $short = if ($msg.Length -gt 34) { $msg.Substring(0, 33) + '…' } else { $msg }
    if ($Json) { [Console]::Out.WriteLine('##STEP|' + $Name + '|' + $status + '|' + ($msg -replace '[\r\n|]+',' ')) }
    if (-not $Json) {
        Badge $status
        Write-Host " $short" -ForegroundColor DarkGray
    }
    return ($status -ne 'FAIL')
}

function Pause-Exit { if ($Json) { return }; Write-Host ''; Read-Host '  Pressione Enter para sair' | Out-Null }

# ── Utilidades ───────────────────────────────────────────────────────────────
function FreeRam { [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1MB, 2) }

function CpuPct { [int](Get-CimInstance Win32_PerfFormattedData_PerfOS_Processor -Filter "Name='_Total'").PercentProcessorTime }

function FreeDiskMB {
    try { return [int][math]::Round((Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':'))).Free / 1MB) } catch { return 0 }
}

function SistemaEmSSD {
    try {
        $pd = Get-Partition -DriveLetter ($env:SystemDrive.TrimEnd(':')) | Get-Disk | Get-PhysicalDisk | Select-Object -First 1
        return ([string]$pd.MediaType -eq 'SSD')
    } catch { return $false }
}

function ProtegidosEmu { if ($script:Emu) { return @($script:Emu.Proc) } else { return @() } }

function KillList([string[]]$names) {
    $k = 0
    $skip = ProtegidosEmu
    Get-Process | Where-Object { ($names -contains $_.Name) -and ($skip -notcontains $_.Name) } | ForEach-Object {
        try { Stop-Process -Id $_.Id -Force -ErrorAction Stop; $k++ } catch {}
    }
    return $k
}

function LimparDisco {
    $c = 0
    $limite = (Get-Date).AddDays(-1)
    $pastas = @(
        $env:TEMP,
        "$env:SystemRoot\Temp",
        "$env:LOCALAPPDATA\Microsoft\Windows\INetCache",
        "$env:LOCALAPPDATA\Microsoft\Windows\WER",
        "$env:LOCALAPPDATA\CrashDumps",
        "$env:ProgramData\Microsoft\Windows\WER\ReportQueue",
        "$env:ProgramData\Microsoft\Windows\WER\ReportArchive",
        "$env:SystemRoot\Minidump"
    )
    if ($script:Emu -and $script:Emu.Logs) { $pastas += @($script:Emu.Logs) }
    foreach ($d in $pastas) {
        if (-not (Test-Path $d)) { continue }
        Get-ChildItem $d -Force -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $limite } | ForEach-Object {
            try { Remove-Item $_.FullName -Recurse -Force -ErrorAction Stop; $c++ } catch {}
        }
    }
    if ($EsvaziarLixeira) { try { Clear-RecycleBin -Force -ErrorAction Stop } catch {} }
    try { Clear-DnsClientCache } catch {}
    return $c
}

function CacheMB {
    try {
        $m = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory -ErrorAction Stop
        $t = [double]$m.StandbyCacheNormalPriorityBytes + [double]$m.StandbyCacheReserveBytes + [double]$m.StandbyCacheCoreBytes
        return [int][math]::Round($t / 1MB)
    } catch { return -1 }
}

function CleanRam {
    $a = FreeRam
    $script:CacheAntes = CacheMB
    $skip = ProtegidosEmu
    Get-Process | Where-Object { $_.Id -gt 4 -and ($skip -notcontains $_.Name) } | ForEach-Object {
        try { [void][GodalNative]::Trim($_.Handle) } catch {}
    }
    [void][GodalNative]::Mem(3)
    $script:MemStatus = [GodalNative]::Mem(4)
    Start-Sleep -Seconds 1
    $script:CacheDepois = CacheMB
    $b = FreeRam
    return @($a, $b)
}

function PassoRam {
    $r = CleanRam
    $script:RamBefore = $r[0]; $script:RamAfter = $r[1]
    if ($script:MemStatus -ne 0) { return @{ Status = 'WARN'; Msg = ('cache sem acesso (0x{0:X8})' -f $script:MemStatus) } }
    $txt = '{0}→{1} GB livres' -f $r[0], $r[1]
    if ($r[1] -le $r[0]) { return @{ Status = 'WARN'; Msg = "sem ganho: $txt" } }
    return $txt
}

# Roda UMA vez depois que o emulador abre. Não fica nada em loop.
function Boost {
    $n = 0
    foreach ($name in $script:Emu.Boost) {
        Get-Process -Name $name -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                if ($_.PriorityClass -ne 'High') { $_.PriorityClass = 'High' }
                $_.PriorityBoostEnabled = $true
                try { [GodalNative]::Prio($_.Handle) } catch {}
                $n++
            } catch {}
        }
    }
    return $n
}

# ── Registro, backup e restauração ───────────────────────────────────────────
function RegGet([string]$Path, [string]$Name) {
    try { return (Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop).$Name } catch { return $null }
}

function RegSet([string]$Path, [string]$Name, $Value, [string]$Type = 'DWord') {
    if (-not (Test-Path $Path)) { New-Item $Path -Force | Out-Null }
    $old = RegGet $Path $Name
    [void]$script:RegOrig.Add([pscustomobject]@{ Path = $Path; Name = $Name; Old = $old; Type = $Type })
    Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type
}

function Ponto-Restauracao {
    $marca = Join-Path $DataDir 'ponto_restauracao.ok'
    if (Test-Path $marca) { return @{ Status = 'SKIP'; Msg = 'já criado antes' } }
    try { Enable-ComputerRestore -Drive ($env:SystemDrive + '\') -ErrorAction Stop } catch {}
    $k = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $nome = 'SystemRestorePointCreationFrequency'
    $old = RegGet $k $nome
    try { Set-ItemProperty -Path $k -Name $nome -Value 0 -Type DWord -ErrorAction Stop } catch {}
    try {
        Checkpoint-Computer -Description 'GODAL OS' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
    } finally {
        try {
            if ($null -eq $old) { Remove-ItemProperty -Path $k -Name $nome -ErrorAction SilentlyContinue }
            else { Set-ItemProperty -Path $k -Name $nome -Value $old -Type DWord }
        } catch {}
    }
    New-Item $DataDir -ItemType Directory -Force | Out-Null
    Set-Content -Path $marca -Value (Get-Date -Format 's')
    return 'criado'
}

function Ler-Backup {
    $res = [pscustomobject]@{ Reg = @(); Svc = @() }
    if (Test-Path $BackupFile) {
        try {
            $j = Get-Content $BackupFile -Raw | ConvertFrom-Json
            if ($j.Reg) { $res.Reg = @($j.Reg) }
            if ($j.Svc) { $res.Svc = @($j.Svc) }
        } catch {}
    }
    return $res
}

# Guarda sempre o valor ORIGINAL: se já existe no backup, não sobrescreve.
function Salvar-Backup {
    New-Item $DataDir -ItemType Directory -Force | Out-Null
    $bk = Ler-Backup
    $regs = New-Object System.Collections.ArrayList
    foreach ($r in $bk.Reg) { [void]$regs.Add($r) }
    foreach ($r in $script:RegOrig) {
        $ja = @($regs | Where-Object { $_.Path -eq $r.Path -and $_.Name -eq $r.Name })
        if ($ja.Count -eq 0) { [void]$regs.Add([pscustomobject]@{ Path = $r.Path; Name = $r.Name; Old = $r.Old; Type = $r.Type }) }
    }
    $svcs = New-Object System.Collections.ArrayList
    foreach ($s in $bk.Svc) { [void]$svcs.Add($s) }
    foreach ($s in $script:SvcOrig) {
        $ja = @($svcs | Where-Object { $_.Nome -eq $s.Nome })
        if ($ja.Count -eq 0) { [void]$svcs.Add([pscustomobject]@{ Nome = $s.Nome; Start = $s.Start }) }
    }
    $obj = [pscustomobject]@{ Reg = @($regs); Svc = @($svcs) }
    ConvertTo-Json -InputObject $obj -Depth 5 | Set-Content -Path $BackupFile -Encoding UTF8
}

function MapaStart([string]$m) {
    switch ($m) { 'Auto' { 'Automatic' } 'Manual' { 'Manual' } 'Disabled' { 'Disabled' } default { 'Manual' } }
}

function Restaurar-Tudo {
    if (-not (Test-Path $BackupFile)) {
        Ia 'Não há nada para restaurar. Seu PC já está nos valores originais.' 'Yellow'
        return
    }
    $bk = Ler-Backup
    [void](Step 'Repor ajustes do registro' {
        $n = 0
        foreach ($r in $bk.Reg) {
            try {
                if ($null -eq $r.Old) { Remove-ItemProperty -Path $r.Path -Name $r.Name -ErrorAction SilentlyContinue }
                else { Set-ItemProperty -Path $r.Path -Name $r.Name -Value $r.Old -Type $r.Type }
                $n++
            } catch {}
        }
        "$n valor(es) reposto(s)"
    })
    [void](Step 'Repor serviços' {
        $n = 0
        foreach ($s in $bk.Svc) {
            try {
                $t = MapaStart $s.Start
                Set-Service -Name $s.Nome -StartupType $t
                if ($t -eq 'Automatic') { Start-Service -Name $s.Nome -ErrorAction SilentlyContinue }
                $n++
            } catch {}
        }
        "$n serviço(s)"
    })
    Remove-Item $BackupFile -Force -ErrorAction SilentlyContinue
}

# ── Atalho ───────────────────────────────────────────────────────────────────
function Criar-Atalho {
    try {
        $pasta = $PSScriptRoot
        if ($pasta -match '\\Temp\\') {
            # Rodando de dentro do ZIP/pasta temporária: instala uma cópia fixa para o atalho não quebrar.
            $dest = Join-Path $DataDir 'app'
            New-Item $dest -ItemType Directory -Force | Out-Null
            foreach ($f in @('GODAL_OS.ps1', 'GODAL_OS.bat', 'GODAL_OS.ico', 'GODAL_RESTAURAR.bat')) {
                $o = Join-Path $pasta $f
                if (Test-Path $o) { Copy-Item $o $dest -Force }
            }
            $pasta = $dest
            $script:AtalhoCopiado = $true
        }
        $bat = Join-Path $pasta 'GODAL_OS.bat'
        $icoSrc = Join-Path $pasta 'GODAL_OS.ico'
        New-Item $DataDir -ItemType Directory -Force | Out-Null
        $ico = ''
        if (Test-Path $icoSrc) {
            $h = (Get-FileHash $icoSrc -Algorithm SHA256).Hash.Substring(0, 8)
            $ico = Join-Path $DataDir "GODAL_OS_$h.ico"
            if (-not (Test-Path $ico)) { Copy-Item $icoSrc $ico -Force }
            Get-ChildItem $DataDir -Filter 'GODAL_OS*.ico' -ErrorAction SilentlyContinue | Where-Object { $_.FullName -ne $ico } | Remove-Item -Force -ErrorAction SilentlyContinue
        }
        $desk = if ($DesktopOrig) { $DesktopOrig } else { [Environment]::GetFolderPath('Desktop') }
        $lnk = Join-Path $desk 'GODAL OS.lnk'
        $ws = New-Object -ComObject WScript.Shell
        $existia = Test-Path $lnk
        if ($existia) {
            $atual = $ws.CreateShortcut($lnk)
            if ($atual.TargetPath -eq $bat -and ((-not $ico) -or $atual.IconLocation -eq "$ico,0")) { return 'existente' }
        }
        $s = $ws.CreateShortcut($lnk)
        $s.TargetPath = $bat
        $s.WorkingDirectory = $pasta
        $s.Description = 'GODAL OS - Optimizador de Emulador'
        $s.WindowStyle = 1
        if ($ico) { $s.IconLocation = "$ico,0" }
        $s.Save()
        $b = [IO.File]::ReadAllBytes($lnk)
        $b[0x15] = $b[0x15] -bor 0x20
        [IO.File]::WriteAllBytes($lnk, $b)
        try { & "$env:SystemRoot\System32\ie4uinit.exe" -show } catch {}
        if ($existia) { return 'atualizado' }
        return 'criado'
    } catch { return 'erro: ' + $_.Exception.Message }
}

# ── Diagnóstico ──────────────────────────────────────────────────────────────
function Diagnostico {
    try {
        $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
        $cs  = Get-CimInstance Win32_ComputerSystem
        $gpu = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -notmatch 'Basic|Remote|Virtual' } | Select-Object -First 1
        $ram = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        $script:RamTotal = $ram
        $livre = FreeRam
        $uso = CpuPct
        $discoGb = [math]::Round((FreeDiskMB) / 1024, 1)
        $tipo = if (SistemaEmSSD) { 'SSD' } else { 'disco do sistema' }
        Ia "Analisando seu PC, $Nome..." 'Cyan'
        Ia ("Processador: {0} ({1} núcleos)" -f $cpu.Name.Trim(), $cpu.NumberOfLogicalProcessors) 'Gray' 3
        if ($gpu) { Ia ("Placa de vídeo: {0}" -f $gpu.Name.Trim()) 'Gray' 3 }
        Ia ("Memória: {0} GB no total, {1} GB livres. CPU a {2}% agora." -f $ram, $livre, $uso) 'Gray' 3
        Ia ("Espaço livre no {0}: {1} GB" -f $tipo, $discoGb) 'Gray' 3
        if ($livre -lt ($ram * 0.3)) { Ia "A RAM está bem ocupada, $Nome. Vou liberar antes de abrir o emulador." 'Yellow' }
        elseif ($uso -gt 60) { Ia 'O CPU já está carregado antes do emulador. Vou fechar o que estiver atrapalhando.' 'Yellow' }
        else { Ia 'Seu PC está em bom estado. Vou deixar ainda melhor.' 'Green' }
    } catch {}
}

function Achar-Emulador {
    $achados = @()
    foreach ($e in $Emuladores) {
        foreach ($g in $e.Globs) {
            foreach ($f in @(Get-ChildItem $g -ErrorAction SilentlyContinue)) {
                $achados += [pscustomobject]@{ Emu = $e; File = $f }
            }
        }
    }
    $sel = $null
    if ($achados.Count) {
        if ($EmuladorPreferido) { $sel = $achados | Where-Object { $_.Emu.Nome -like "*$EmuladorPreferido*" } | Select-Object -First 1 }
        if (-not $sel) { $sel = $achados[0] }
    }
    return $sel
}

# ── Resumo ───────────────────────────────────────────────────────────────────
function Summary([string]$Final) {
    $ok   = @($script:Results | Where-Object Status -eq 'OK').Count
    $warn = @($script:Results | Where-Object Status -eq 'WARN').Count
    $fail = @($script:Results | Where-Object Status -eq 'FAIL').Count
    $skip = @($script:Results | Where-Object Status -eq 'SKIP').Count
    Section 'RESULTADO'
    Write-Host '  ' -NoNewline
    Write-Host "● $ok deu certo" -NoNewline -ForegroundColor Green;   Write-Host '   ' -NoNewline
    Write-Host "▲ $warn avisos"  -NoNewline -ForegroundColor Yellow;  Write-Host '   ' -NoNewline
    Write-Host "■ $fail falhas"  -NoNewline -ForegroundColor Red;     Write-Host '   ' -NoNewline
    Write-Host "○ $skip ignorados" -ForegroundColor DarkGray
    Write-Host ''
    if ($null -ne $script:RamBefore) {
        Write-Host ("  RAM livre     {0} GB  →  {1} GB" -f $script:RamBefore, $script:RamAfter) -ForegroundColor Cyan
    }
    if ($script:CacheAntes -ge 0 -and $script:CacheDepois -ge 0) {
        Write-Host ("  Cache da RAM  {0} MB  →  {1} MB" -f $script:CacheAntes, $script:CacheDepois) -ForegroundColor Cyan
    }
    if ($null -ne $script:DiscoLiberado) {
        Write-Host ("  Disco liberado  {0} MB" -f $script:DiscoLiberado) -ForegroundColor Cyan
    }
    if ($script:Player) { Write-Host "  Emulador      $($script:Emu.Nome)" -ForegroundColor DarkGray }
    if ($fail -gt 0) {
        Section 'O QUE DEU ERRADO'
        $script:Results | Where-Object Status -eq 'FAIL' | ForEach-Object {
            Write-Host "  ■ $($_.Name)" -ForegroundColor Red
            Write-Host "    $($_.Msg)" -ForegroundColor DarkGray
        }
    }
    if ($warn -gt 0) {
        Section 'ATENÇÃO'
        $script:Results | Where-Object Status -eq 'WARN' | ForEach-Object {
            Write-Host "  ▲ $($_.Name): $($_.Msg)" -ForegroundColor Yellow
        }
    }
    Write-Host ''
    if ($fail -eq 0 -and $Final) { Write-Host "  ✦ $Final" -ForegroundColor Green }
    elseif ($fail -gt 0) { Write-Host '  Algumas etapas falharam. Veja os detalhes acima.' -ForegroundColor Red }
    return $fail
}

# ── Otimização (única, automática) ───────────────────────────────────────────
function Otimizar($sel) {
    $script:Emu = $sel.Emu
    $script:Player = $sel.File.FullName
    $script:Dir = $sel.File.DirectoryName
    $bn = @($script:Emu.Boost | ForEach-Object { "$_.exe" })
    $script:Exes = @(Get-ChildItem $script:Dir -Filter *.exe -ErrorAction SilentlyContinue | Where-Object { $bn -contains $_.Name })

    Write-Host ''
    Ia "Encontrei o $($script:Emu.Nome). Vou preparar tudo ANTES de abrir, assim nada fica rodando durante o jogo." 'Magenta'

    Section 'SEGURANÇA'
    [void](Step 'Ponto de restauração (única vez)' { Ponto-Restauracao })

    Section 'LIMPEZA'
    $discoAntes = FreeDiskMB
    [void](Step 'Reiniciar emulador limpo' {
        $ativos = @(Get-Process -Name $script:Emu.Proc -ErrorAction SilentlyContinue)
        if (-not $ativos.Count) { return @{ Status = 'SKIP'; Msg = 'não estava aberto' } }
        foreach ($p in @(Get-Process -Name $script:Emu.Main -ErrorAction SilentlyContinue)) { try { [void]$p.CloseMainWindow() } catch {} }
        $t = 0
        while ($t -lt 8 -and @(Get-Process -Name $script:Emu.Main -ErrorAction SilentlyContinue).Count) { Start-Sleep 1; $t++ }
        $k = 0
        foreach ($n in $script:Emu.Proc) { Get-Process -Name $n -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue; $k++ } }
        Start-Sleep -Seconds 2
        $left = @(Get-Process -Name $script:Emu.Proc -ErrorAction SilentlyContinue)
        if ($left.Count) { throw ('Ainda ativos: ' + (($left | Select-Object -ExpandProperty Name -Unique) -join ', ')) }
        'fechado'
    })
    [void](Step 'Fechar apps de segundo plano' {
        $k = KillList $Descartaveis
        "$k encerrado(s)"
    })
    [void](Step 'Limpar disco, temporários e cache' {
        $c = LimparDisco
        $script:DiscoLiberado = [math]::Max(0, (FreeDiskMB) - $discoAntes)
        "$c item(ns), $($script:DiscoLiberado) MB"
    })
    [void](Step 'Limpar RAM e cache da RAM' { PassoRam })

    Section 'ALTA PERFORMANCE'
    [void](Step 'CPU e disco: prioridade do emulador' {
        $ifeo = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
        foreach ($n in $script:Emu.Boost) {
            $k = "$ifeo\$n.exe\PerfOptions"
            RegSet $k 'CpuPriorityClass' 3
            RegSet $k 'IoPriority' 3
            RegSet $k 'PagePriority' 5
        }
        "$($script:Emu.Boost.Count) processos, sempre em Alta"
    })
    [void](Step 'CPU: foco no programa em primeiro plano' {
        RegSet 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'Win32PrioritySeparation' 38
        'foco no emulador'
    })
    [void](Step 'GPU: alto desempenho' {
        if (-not $script:Exes.Count) { throw 'Executáveis do emulador não encontrados.' }
        $k = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
        foreach ($e in $script:Exes) { RegSet $k $e.FullName 'GpuPreference=2;' 'String' }
        "$($script:Exes.Count) exe(s)"
    })
    [void](Step 'GPU e jogos: prioridade (MMCSS) e rede' {
        $sp = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
        RegSet $sp 'SystemResponsiveness' 0
        RegSet $sp 'NetworkThrottlingIndex' ([int]-1)
        RegSet "$sp\Tasks\Games" 'GPU Priority' 8
        RegSet "$sp\Tasks\Games" 'Priority' 6
        RegSet "$sp\Tasks\Games" 'Scheduling Category' 'High' 'String'
        RegSet "$sp\Tasks\Games" 'SFIO Priority' 'High' 'String'
        'ajustado'
    })
    [void](Step 'Game Mode ligado, gravação em fundo off' {
        RegSet 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0
        RegSet 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0
        RegSet 'HKCU:\Software\Microsoft\GameBar' 'AllowAutoGameMode' 1
        RegSet 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 1
        'Game Mode on, Game DVR off'
    })
    [void](Step 'CPU: sem limitação de energia' {
        RegSet 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff' 1
        'processos sem limite'
    })
    [void](Step 'RAM: manter núcleo do Windows na memória' {
        if ($script:RamTotal -lt 8) { return @{ Status = 'SKIP'; Msg = 'precisa de 8 GB ou mais' } }
        RegSet 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' 'DisablePagingExecutive' 1
        'ativo após reiniciar o PC'
    })
    [void](Step 'Tela cheia sem otimização do Windows' {
        if (-not $script:Exes.Count) { throw 'Executáveis do emulador não encontrados.' }
        $k = 'HKCU:\Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers'
        $flag = 'DISABLEDXMAXIMIZEDWINDOWEDMODE'
        foreach ($e in $script:Exes) {
            $old = RegGet $k $e.FullName
            $novo = if ($old) { if ($old -match $flag) { [string]$old } else { "$old $flag" } } else { "~ $flag" }
            RegSet $k $e.FullName $novo 'String'
        }
        "$($script:Exes.Count) exe(s)"
    })
    [void](Step 'Serviços de telemetria e cache' {
        $lista = @('DiagTrack')
        if (SistemaEmSSD) { $lista += 'SysMain' }
        $n = 0
        foreach ($s in $lista) {
            $w = Get-CimInstance Win32_Service -Filter "Name='$s'" -ErrorAction SilentlyContinue
            if ($w -and $w.StartMode -ne 'Disabled') {
                [void]$script:SvcOrig.Add([pscustomobject]@{ Nome = $s; Start = [string]$w.StartMode })
                try { Stop-Service -Name $s -Force -ErrorAction SilentlyContinue } catch {}
                Set-Service -Name $s -StartupType Disabled
                $n++
            }
        }
        "$n desativado(s)"
    })
    [void](Step 'Defender: não varrer o emulador' {
        if (-not $ExclusaoDefender) { return @{ Status = 'SKIP'; Msg = 'desligado na configuração' } }
        Add-MpPreference -ExclusionProcess $bn -ExclusionPath $script:Dir
        'exclusão aplicada'
    })
    [void](Step 'Guardar backup (restaurar depois)' {
        Salvar-Backup
        'GODAL_RESTAURAR.bat desfaz tudo'
    })

    Section 'LANÇAMENTO'
    $launched = Step 'Abrir emulador' {
        Start-Process -FilePath $script:Player -WorkingDirectory $script:Dir
        $t = 0; $p = $null
        while ($t -lt 90 -and -not ($p = Get-Process -Name $script:Emu.Main -ErrorAction SilentlyContinue | Select-Object -First 1)) { Start-Sleep 1; $t++ }
        if (-not $p) { throw 'O emulador não apareceu em 90s.' }
        "PID $($p.Id)"
    }
    if ($launched) {
        [void](Step 'Prioridade Alta, memória e disco' {
            Start-Sleep -Seconds 4
            $n = Boost
            $p = Get-Process -Name $script:Emu.Main -ErrorAction Stop | Select-Object -First 1
            if ($p.PriorityClass -ne 'High') { throw "O emulador está em $($p.PriorityClass)." }
            "$n processo(s) em Alta"
        })
    } else {
        [void]$script:Results.Add([pscustomobject]@{ Name = 'Prioridade Alta, memória e disco'; Status = 'SKIP'; Msg = 'emulador não iniciou' })
    }

    Write-Host ''
    $fail = Summary 'Pronto. Emulador no máximo.'
    Write-Host ''
    if ($fail -eq 0) {
        Ia "$Nome, pode jogar! Não deixo nada rodando em segundo plano, então nada atrapalha o seu FPS." 'Green'
        for ($i = $(if ($Json) { 0 } else { 8 }); $i -ge 1; $i--) {
            Write-Host ("`r  Esta janela fecha sozinha em {0}s   " -f $i) -NoNewline -ForegroundColor DarkGray
            Start-Sleep -Seconds 1
        }
        Write-Host ''
    } else {
        Pause-Exit
    }
}

# ── Início ───────────────────────────────────────────────────────────────────
Banner

if ($Restaurar) {
    Section 'RESTAURAR'
    Restaurar-Tudo
    [void](Summary 'Valores originais repostos.')
    Ia 'Reinicie o PC para concluir o restauro.' 'Yellow'
    Pause-Exit
    exit
}

$atalho = if ($Json) { 'ignorado' } else { Criar-Atalho }
if ($atalho -eq 'criado') {
    Ia "$Nome, criei o atalho 'GODAL OS' na sua área de trabalho." 'Green'
    if ($script:AtalhoCopiado) { Ia 'Você abriu de uma pasta temporária, então instalei uma cópia fixa para o atalho não quebrar.' 'Yellow' }
} elseif ($atalho -eq 'atualizado') {
    Ia "$Nome, atualizei o atalho 'GODAL OS' na sua área de trabalho." 'Green'
} elseif ($atalho -like 'erro*') {
    Ia "Não consegui criar o atalho ($atalho)." 'Yellow'
}

Diagnostico

$sel = Achar-Emulador
if (-not $sel) {
    Write-Host ''
    Ia 'Não encontrei nenhum emulador suportado (BlueStacks, MSI, LDPlayer, Nox, MEmu).' 'Yellow'
    Pause-Exit
    exit
}

Otimizar $sel
