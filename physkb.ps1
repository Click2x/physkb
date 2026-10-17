<#
.SYNOPSIS
    Re-sends injected keyboard/mouse input (Parsec, Moonlight, RDP tools, macro software, ...) through the
    Interception driver so Windows apps see it as coming from a physical device.

.DESCRIPTION
    Software input (SendInput etc.) carries an "injected" flag that some apps ignore or treat differently.
    physkb watches for injected keys / clicks / wheel events, swallows them, and sends the same event through the
    Interception driver, which enters Windows below that flag.

    First run (no parameters): a short wizard lets you pick the keyboard and mouse slot to send through.
    Choices are saved to %APPDATA%\physkb\config.json. After that, just run  .\physkb.ps1

    Safety: press Ctrl+Shift+F12 at any time to switch physkb off/on without closing it.

.PARAMETER Setup          Run the device wizard again.
.PARAMETER List           Show detected Interception device slots and exit.
.PARAMETER Device         Keyboard slot (1-10) to send through. 0 = leave the keyboard alone.
.PARAMETER MouseDevice    Mouse slot (11-20) to send through. 0 = leave the mouse alone.
.PARAMETER MouseMoves     Also re-send cursor movement (default: only clicks and wheel). Experimental.
.PARAMETER MouseRelative  With -MouseMoves: send relative deltas instead of absolute positions.
.PARAMETER Trace          Print every key / click seen and what happened to it.
.PARAMETER Observe        Only print what is seen (use with -Trace). Nothing is swallowed or re-sent.
.PARAMETER DllDir         Folder containing the x64 interception.dll (auto-detected if omitted).
.PARAMETER ForgetConfig   Delete the saved settings and exit.

.EXAMPLE
    .\physkb.ps1                      # first run: wizard. later runs: start with saved settings
.EXAMPLE
    .\physkb.ps1 -Device 4 -MouseDevice 12 -Trace
#>
[CmdletBinding()]
param(
    [string]$DllDir,
    [ValidateRange(-1,10)][int]$Device = -1,
    [ValidateRange(-1,20)][int]$MouseDevice = -1,
    [switch]$MouseMoves,
    [switch]$MouseRelative,
    [switch]$Setup,
    [switch]$List,
    [switch]$Trace,
    [switch]$Observe,
    [switch]$ForgetConfig,
    [switch]$CompileOnly,
    [switch]$LoadOnly      # dot-source support (used by physkb-gui.ps1): define PhysKb and helpers, run nothing
)

$ErrorActionPreference = 'Stop'

# ----------------------------------------------------------------------------------------------
# Native helper (compiled once per PowerShell session)
# ----------------------------------------------------------------------------------------------
$code = @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

public static class PhysKb {
    [StructLayout(LayoutKind.Sequential)]
    struct KStroke { public ushort code; public ushort state; public uint info; }
    [StructLayout(LayoutKind.Sequential)]
    struct MStroke { public ushort state; public ushort flags; public short rolling; public int x; public int y; public uint info; }
    [StructLayout(LayoutKind.Sequential)]
    struct KBD { public uint vk; public uint sc; public uint flags; public uint time; public IntPtr extra; }
    [StructLayout(LayoutKind.Sequential)]
    struct POINT { public int x; public int y; }
    [StructLayout(LayoutKind.Sequential)]
    struct MSL { public POINT pt; public uint mouseData; public uint flags; public uint time; public IntPtr extra; }

    delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool SetDllDirectory(string dir);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr GetModuleHandle(string name);
    [DllImport("user32.dll", SetLastError = true)]
    static extern IntPtr SetWindowsHookEx(int id, HookProc fn, IntPtr mod, uint tid);
    [DllImport("user32.dll")]
    static extern bool UnhookWindowsHookEx(IntPtr h);
    [DllImport("user32.dll")]
    static extern IntPtr CallNextHookEx(IntPtr h, int n, IntPtr w, IntPtr l);
    [DllImport("user32.dll")]
    static extern uint MapVirtualKey(uint code, uint type);
    [DllImport("user32.dll")]
    static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")]
    static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")]
    static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")]
    static extern short GetAsyncKeyState(int vk);

    [DllImport("interception.dll")]
    static extern IntPtr interception_create_context();
    [DllImport("interception.dll", EntryPoint = "interception_send")]
    static extern int interception_send_k(IntPtr ctx, int device, ref KStroke stroke, uint n);
    [DllImport("interception.dll", EntryPoint = "interception_send")]
    static extern int interception_send_m(IntPtr ctx, int device, ref MStroke stroke, uint n);
    [DllImport("interception.dll")]
    static extern uint interception_get_hardware_id(IntPtr ctx, int device, byte[] buf, uint size);

    static IntPtr ctx, khook, mhook;
    static int kdevice, mdevice;
    static int[] mslots = new int[0];
    static int mslotIdx;
    static bool mrelative, mmoves, enabled = true, mouseOk = true;
    static int pendMsg, pendTick, mfail;
    static HookProc kproc, mproc;     // keep references so the delegates aren't collected
    public static bool Trace, Observe;
    public static int MouseConfirmed; // mouse slot that was seen delivering events (0 = none yet)

    public static void Init(string dllDir) {
        SetProcessDPIAware();         // hook coordinates and screen metrics in real pixels
        SetDllDirectory(dllDir);
        ctx = interception_create_context();
        if (ctx == IntPtr.Zero)
            throw new Exception("interception_create_context failed (is the driver installed, and have you rebooted since installing it?)");
    }

    // Candidate mouse slots in order of preference: the chosen one first, then the others. Used for auto-failover.
    public static void SetMouseSlots(int[] slots) { mslots = slots ?? new int[0]; mslotIdx = 0; }

    public static string[] ListDevices() {
        var res = new string[20];
        for (int i = 1; i <= 20; i++) {
            byte[] buf = new byte[1024];
            uint n = interception_get_hardware_id(ctx, i, buf, (uint)buf.Length);
            res[i - 1] = n > 0 ? Encoding.Unicode.GetString(buf, 0, (int)n).TrimEnd('\0') : "";
        }
        return res;
    }

    static bool IsExtendedVk(uint vk) {
        switch (vk) {
            case 0x21: case 0x22: case 0x23: case 0x24:               // PgUp PgDn End Home
            case 0x25: case 0x26: case 0x27: case 0x28:               // arrows
            case 0x2D: case 0x2E:                                     // Ins Del
            case 0x5B: case 0x5C: case 0x5D:                          // Win keys, Apps
            case 0x6F: case 0x90: case 0xA3: case 0xA5: return true;  // Num/, NumLock, RCtrl, RAlt
        }
        return false;
    }

    static IntPtr KCallback(int n, IntPtr w, IntPtr l) {
        if (n >= 0) {
            KBD k = (KBD)Marshal.PtrToStructure(l, typeof(KBD));
            bool injected = (k.flags & 0x10) != 0;
            if (k.vk == 0x7B && (k.flags & 0x80) == 0 && (GetAsyncKeyState(0x11) & 0x8000) != 0 && (GetAsyncKeyState(0x10) & 0x8000) != 0) {
                enabled = !enabled;                                   // Ctrl+Shift+F12 panic toggle
                Console.WriteLine(enabled ? "[physkb] ENABLED" : "[physkb] DISABLED - everything passes through unchanged");
            }
            if (Trace) Console.WriteLine("key vk=0x{0:X2} sc=0x{1:X2} flags=0x{2:X2} injected={3}", k.vk, k.sc, k.flags, injected);
            if (enabled && !Observe && kdevice != 0 && injected && k.vk != 0xE7) {   // 0xE7 = VK_PACKET (unicode text): leave alone
                uint sc = k.sc;
                bool ext = (k.flags & 0x01) != 0;
                if (sc == 0) { sc = MapVirtualKey(k.vk, 0); ext = ext || IsExtendedVk(k.vk); }
                KStroke s = new KStroke();
                s.code = (ushort)sc;
                s.state = (ushort)(((k.flags & 0x80) != 0 ? 1 : 0) | (ext ? 2 : 0));
                int sent = sc != 0 ? interception_send_k(ctx, kdevice, ref s, 1) : -1;
                if (Trace) Console.WriteLine("  -> resend sc=0x{0:X2} state={1} result={2}", sc, s.state, sent);
                if (sent > 0) return (IntPtr)1;                       // swallow the injected original
            }
        }
        return CallNextHookEx(khook, n, w, l);
    }

    static void NextMouseSlot() {
        mslotIdx++;
        if (mslotIdx < mslots.Length) {
            mdevice = mslots[mslotIdx];
            Console.WriteLine("[physkb] Mouse events were not delivered. Trying mouse slot {0}...", mdevice);
        } else {
            mouseOk = false;
            Console.WriteLine("[physkb] No mouse slot delivered events. Mouse handling switched OFF (mouse passes through unchanged).");
        }
    }

    static IntPtr MCallback(int n, IntPtr w, IntPtr l) {
        if (n >= 0) {
            MSL m = (MSL)Marshal.PtrToStructure(l, typeof(MSL));
            bool injected = (m.flags & 0x03) != 0;                    // LLMHF_INJECTED | LLMHF_LOWER_IL_INJECTED
            int msg = (int)w;
            if (Trace && msg != 0x200) Console.WriteLine("mouse seen msg=0x{0:X} flags=0x{1:X} injected={2}", msg, m.flags, injected);

            // A re-sent event that comes back as non-injected proves the slot works.
            if (!injected && pendMsg != 0 && msg == pendMsg) {
                pendMsg = 0; mfail = 0;
                if (MouseConfirmed != mdevice) { MouseConfirmed = mdevice; Console.WriteLine("[physkb] Mouse slot {0} confirmed working.", mdevice); }
            }

            if (enabled && !Observe && mouseOk && injected) {
                // Previous re-send never came back? Count it; after 3 misses move on to the next slot.
                if (pendMsg != 0 && unchecked(Environment.TickCount - pendTick) > 250) {
                    pendMsg = 0; mfail++;
                    if (mfail >= 3) { mfail = 0; NextMouseSlot(); if (!mouseOk) return CallNextHookEx(mhook, n, w, l); }
                }
                MStroke s = new MStroke();
                short hi = (short)(m.mouseData >> 16);
                bool handled = true, track = true;
                switch (msg) {
                    case 0x200:                                       // WM_MOUSEMOVE
                        track = false;
                        if (!mmoves) { handled = false; break; }
                        if (mrelative) {
                            POINT cur; GetCursorPos(out cur);
                            s.x = m.pt.x - cur.x; s.y = m.pt.y - cur.y;
                            if (s.x == 0 && s.y == 0) return (IntPtr)1;
                            s.flags = 0x000;                          // MOUSE_MOVE_RELATIVE
                        } else {
                            int vx = GetSystemMetrics(76), vy = GetSystemMetrics(77);
                            int vw = GetSystemMetrics(78), vh = GetSystemMetrics(79);
                            s.x = (int)(((long)(m.pt.x - vx) * 65535) / Math.Max(1, vw - 1));
                            s.y = (int)(((long)(m.pt.y - vy) * 65535) / Math.Max(1, vh - 1));
                            s.flags = 0x003;                          // ABSOLUTE | VIRTUAL_DESKTOP
                        }
                        break;
                    case 0x201: s.state = 0x001; break;               // left down
                    case 0x202: s.state = 0x002; break;               // left up
                    case 0x204: s.state = 0x004; break;               // right down
                    case 0x205: s.state = 0x008; break;               // right up
                    case 0x207: s.state = 0x010; break;               // middle down
                    case 0x208: s.state = 0x020; break;               // middle up
                    case 0x20B: s.state = (ushort)(hi == 1 ? 0x040 : 0x100); break;   // X button down (4 / 5)
                    case 0x20C: s.state = (ushort)(hi == 1 ? 0x080 : 0x200); break;   // X button up
                    case 0x20A: s.state = 0x400; s.rolling = hi; break;               // wheel
                    case 0x20E: s.state = 0x800; s.rolling = hi; break;               // horizontal wheel
                    default: handled = false; break;
                }
                if (handled) {
                    int sent = interception_send_m(ctx, mdevice, ref s, 1);
                    if (Trace && msg != 0x200) Console.WriteLine("mouse msg=0x{0:X} state=0x{1:X} roll={2} slot={3} result={4}", msg, s.state, s.rolling, mdevice, sent);
                    if (sent > 0) {
                        if (track) { pendMsg = msg; pendTick = Environment.TickCount; }
                        return (IntPtr)1;                             // swallow the injected original
                    }
                }
            }
        }
        return CallNextHookEx(mhook, n, w, l);
    }

    public static bool Enabled { get { return enabled; } }   // false while the Ctrl+Shift+F12 panic toggle is off
    public static bool Running { get { return khook != IntPtr.Zero; } }

    // Installs the hooks on the calling thread, which must pump messages (Application.Run / a WinForms form).
    public static void Start(int kdev, int mdev, bool relative, bool moves) {
        kdevice = kdev; mdevice = mdev; mrelative = relative; mmoves = moves;
        enabled = true; mouseOk = true; mfail = 0; pendMsg = 0; MouseConfirmed = 0;
        if (mdev != 0 && mslots.Length == 0) mslots = new int[] { mdev };
        IntPtr mod = GetModuleHandle(null);
        kproc = KCallback;
        khook = SetWindowsHookEx(13, kproc, mod, 0);   // always installed: also carries the Ctrl+Shift+F12 panic key
        if (khook == IntPtr.Zero) throw new Exception("keyboard SetWindowsHookEx failed");
        if (mdev != 0) {
            mproc = MCallback;
            mhook = SetWindowsHookEx(14, mproc, mod, 0);
            if (mhook == IntPtr.Zero) { UnhookWindowsHookEx(khook); khook = IntPtr.Zero; throw new Exception("mouse SetWindowsHookEx failed"); }
        }
    }

    public static void Stop() {
        if (khook != IntPtr.Zero) { UnhookWindowsHookEx(khook); khook = IntPtr.Zero; }
        if (mhook != IntPtr.Zero) { UnhookWindowsHookEx(mhook); mhook = IntPtr.Zero; }
    }

    public static void Run(int kdev, int mdev, bool relative, bool moves) {
        Start(kdev, mdev, relative, moves);
        Console.CancelKeyPress += delegate(object s, ConsoleCancelEventArgs e) { e.Cancel = true; Application.Exit(); };
        try { Application.Run(); }
        finally { Stop(); }
    }
}
'@

if (-not ('PhysKb' -as [type])) {
    Add-Type -TypeDefinition $code -ReferencedAssemblies System.Windows.Forms
}
if ($CompileOnly) { Write-Host "Compiled OK"; return }

# ----------------------------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------------------------
$cfgDir  = Join-Path $env:APPDATA 'physkb'
$cfgPath = Join-Path $cfgDir 'config.json'

function Write-Info($msg)  { Write-Host "  $msg" }
function Write-Good($msg)  { Write-Host "  $msg" -ForegroundColor Green }
function Write-Warn2($msg) { Write-Host "  $msg" -ForegroundColor Yellow }
function Write-Bad($msg)   { Write-Host "  $msg" -ForegroundColor Red }

function Find-InterceptionDll {
    if ($DllDir) {
        if (Test-Path (Join-Path $DllDir 'interception.dll')) { return $DllDir }
        return $null
    }
    $cands = @(
        $env:INTERCEPTION_DIR,
        $PSScriptRoot,
        (Join-Path $PSScriptRoot 'library\x64'),
        'C:\Interception\library\x64',
        (Join-Path $env:USERPROFILE 'Interception\library\x64'),
        (Join-Path $env:USERPROFILE 'Downloads\Interception\library\x64')
    ) + ($env:PATH -split ';')
    foreach ($c in $cands) {
        if ($c -and (Test-Path (Join-Path $c 'interception.dll'))) { return $c }
    }
    return $null
}

$vendors = @{
    '1532'='Razer'; '413C'='Dell'; '046D'='Logitech'; '1B1C'='Corsair'; '045E'='Microsoft'; '1038'='SteelSeries'
    '0B05'='ASUS'; '1E7D'='ROCCAT'; '03F0'='HP'; '17EF'='Lenovo'; '046A'='Cherry'; '05AC'='Apple'
    '04D9'='Holtek'; '258A'='SINO WEALTH'; '0951'='Kingston/HyperX'; '3434'='Keychron'; '2516'='Cooler Master'
}

function Get-DeviceLabel([string]$hwid) {
    if ($hwid -match 'virtualdevice') { return 'Virtual device (not a real keyboard - avoid)' }
    if ($hwid -match 'VID_([0-9A-Fa-f]{4})&PID_([0-9A-Fa-f]{4})') {
        $v = $Matches[1].ToUpper(); $p = $Matches[2].ToUpper()
        $name = if ($vendors.ContainsKey($v)) { $vendors[$v] } else { 'Unknown vendor' }
        $mi = if ($hwid -match 'MI_(\d\d)') { "  (interface $($Matches[1]))" } else { '' }
        return "$name  VID:$v PID:$p$mi"
    }
    return ($hwid.Substring(0, [Math]::Min(60, $hwid.Length)))
}

function Read-Slot([string]$prompt, [int[]]$valid, [int]$default) {
    while ($true) {
        $r = Read-Host $prompt
        if ([string]::IsNullOrWhiteSpace($r)) { return $default }
        if ($r.Trim() -match '^(n|none|0)$') { return 0 }
        $n = 0
        if ([int]::TryParse($r.Trim(), [ref]$n) -and $valid -contains $n) { return $n }
        Write-Warn2 "Enter one of: $($valid -join ', ')  (Enter = $default, n = none)"
    }
}

function Show-Slots($ids) {
    Write-Host ""
    Write-Host "  Keyboards" -ForegroundColor Cyan
    $any = $false
    for ($i = 1; $i -le 10; $i++) { if ($ids[$i - 1]) { $any = $true; Write-Host ("    [{0,2}]  {1}" -f $i, (Get-DeviceLabel $ids[$i - 1])) } }
    if (-not $any) { Write-Host "    (none detected)" }
    Write-Host "  Mice" -ForegroundColor Cyan
    $any = $false
    for ($i = 11; $i -le 20; $i++) { if ($ids[$i - 1]) { $any = $true; Write-Host ("    [{0,2}]  {1}" -f $i, (Get-DeviceLabel $ids[$i - 1])) } }
    if (-not $any) { Write-Host "    (none detected)" }
    Write-Host ""
}

function Write-Recovery {
    Write-Warn2 "Keyboard or mouse stopped working after installing Interception? The driver is the usual cause:"
    Write-Info "  On-screen keyboard: Win+Ctrl+O.  Admin PowerShell: Win+X, then A."
    Write-Info "  Run  install-interception.exe /uninstall  (from the folder you unzipped it to), then REBOOT."
}

function Invoke-Wizard($ids) {
    Write-Host ""
    Write-Host "  physkb setup" -ForegroundColor Cyan
    Write-Host "  ------------"
    Write-Recovery
    Write-Host ""
    Write-Info "physkb re-sends injected input through a real device slot. Pick the slots below."
    Write-Info "Duplicates are normal - one physical device can show up several times."
    Show-Slots $ids

    $kbs = @(1..10  | Where-Object { $ids[$_ - 1] })
    $mice = @(11..20 | Where-Object { $ids[$_ - 1] })

    # Suggest a real keyboard: not virtual, and not an extra interface (MI_01, MI_02, ...) of a composite device.
    $kbDefault = 0
    $real = @($kbs | Where-Object { $ids[$_ - 1] -notmatch 'virtualdevice' })
    $primary = @($real | Where-Object { $ids[$_ - 1] -notmatch 'MI_0[1-9]' })
    if ($primary.Count -gt 0) { $kbDefault = $primary[0] } elseif ($real.Count -gt 0) { $kbDefault = $real[0] }
    $mouseDefault = if ($mice.Count -gt 0) { $mice[0] } else { 0 }

    $kb = 0; $ms = 0
    if ($kbs.Count -gt 0) { $kb = Read-Slot "  Keyboard slot to send through [$kbDefault] (n = leave keyboard alone)" $kbs $kbDefault }
    if ($mice.Count -gt 0) {
        $ms = Read-Slot "  Mouse slot to send through [$mouseDefault] (n = leave mouse alone)" $mice $mouseDefault
        Write-Info "(If clicks don't land on that slot, physkb tries your other mouse slots automatically.)"
    }
    $moves = $false
    if ($ms -ne 0) {
        $a = Read-Host "  Also re-send cursor MOVEMENT? Experimental - most people say no [y/N]"
        $moves = ($a -match '^(y|yes)$')
    }
    $cfg = [pscustomobject]@{ Device = $kb; MouseDevice = $ms; MouseMoves = $moves; MouseRelative = $false }
    Save-Config $cfg
    Write-Good "Saved to $cfgPath"
    return $cfg
}

function Save-Config($cfg) {
    if (-not (Test-Path $cfgDir)) { New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null }
    $cfg | ConvertTo-Json | Set-Content -Path $cfgPath -Encoding UTF8
}

function Load-Config {
    if (Test-Path $cfgPath) {
        try { return (Get-Content $cfgPath -Raw | ConvertFrom-Json) } catch { return $null }
    }
    return $null
}

if ($LoadOnly) { return }

# ----------------------------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------------------------
if ($ForgetConfig) {
    if (Test-Path $cfgPath) { Remove-Item $cfgPath -Force; Write-Good "Saved settings deleted." } else { Write-Info "No saved settings." }
    return
}

# Interception needs administrator rights: relaunch elevated if necessary.
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Warn2 "physkb needs administrator rights - relaunching elevated (accept the UAC prompt)..."
    $argList = @('-NoExit', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath))
    foreach ($k in $PSBoundParameters.Keys) {
        $v = $PSBoundParameters[$k]
        if ($v -is [switch]) { if ($v.IsPresent) { $argList += "-$k" } }
        else { $argList += "-$k"; $argList += ('"{0}"' -f $v) }
    }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $argList
    return
}

if (-not [Environment]::Is64BitProcess) { Write-Bad "Run this in 64-bit PowerShell (it needs the x64 interception.dll)."; return }

$dir = Find-InterceptionDll
if (-not $dir) {
    Write-Bad "interception.dll (x64) not found."
    Write-Info "1. Download Interception from https://github.com/oblitum/Interception/releases"
    Write-Info "2. Unzip it, e.g. to C:\Interception"
    Write-Info "3. Run  install-interception.exe /install  from an admin prompt, then REBOOT"
    Write-Info "4. Run physkb again (or pass -DllDir <folder with the x64 interception.dll>)"
    Write-Host ""
    Write-Warn2 "Interception is a kernel driver that filters ALL keyboards and mice. Know how to remove it first:"
    Write-Recovery
    return
}

try { [PhysKb]::Init($dir) }
catch { Write-Bad $_.Exception.Message; Write-Info "Install the driver with 'install-interception.exe /install' (admin), then reboot."; return }

$ids = [PhysKb]::ListDevices()
if ($List) { Show-Slots $ids; return }

$cfg = Load-Config
$explicit = ($Device -ge 0) -or ($MouseDevice -ge 0)
if ($Setup -or (-not $cfg -and -not $explicit)) { $cfg = Invoke-Wizard $ids }

$kd    = if ($Device -ge 0)      { $Device }      elseif ($cfg) { [int]$cfg.Device }      else { 0 }
$md    = if ($MouseDevice -ge 0) { $MouseDevice } elseif ($cfg) { [int]$cfg.MouseDevice } else { 0 }
$moves = $MouseMoves.IsPresent -or ($cfg -and [bool]$cfg.MouseMoves)
$rel   = $MouseRelative.IsPresent -or ($cfg -and [bool]$cfg.MouseRelative)

if ($kd -ne 0 -and ($kd -lt 1 -or $kd -gt 10 -or -not $ids[$kd - 1])) { Write-Bad "Keyboard slot $kd has no device. Run  .\physkb.ps1 -Setup"; return }
if ($md -ne 0 -and ($md -lt 11 -or $md -gt 20 -or -not $ids[$md - 1])) { Write-Bad "Mouse slot $md has no device (mouse slots are 11-20). Run  .\physkb.ps1 -Setup"; return }
if ($kd -eq 0 -and $md -eq 0) { Write-Bad "Nothing to do: keyboard and mouse are both off. Run  .\physkb.ps1 -Setup"; return }

if ($md -ne 0) {
    $others = @(11..20 | Where-Object { $ids[$_ - 1] -and $_ -ne $md })
    [PhysKb]::SetMouseSlots(@($md) + $others)
}
[PhysKb]::Trace   = $Trace.IsPresent
[PhysKb]::Observe = $Observe.IsPresent

Write-Host ""
Write-Host "  physkb is running" -ForegroundColor Green
Write-Host "  -----------------"
if ($kd -ne 0) { Write-Info ("Keyboard : injected keys  -> slot {0}  ({1})" -f $kd, (Get-DeviceLabel $ids[$kd - 1])) } else { Write-Info "Keyboard : left alone" }
if ($md -ne 0) {
    $what = if ($moves) { if ($rel) { 'clicks, wheel, relative moves' } else { 'clicks, wheel, absolute moves' } } else { 'clicks and wheel (cursor movement untouched)' }
    Write-Info ("Mouse    : {0} -> slot {1}  ({2})" -f $what, $md, (Get-DeviceLabel $ids[$md - 1]))
} else { Write-Info "Mouse    : left alone" }
if ($Observe) { Write-Warn2 "OBSERVE mode: nothing is swallowed or re-sent." }
Write-Info "Panic key: Ctrl+Shift+F12 switches physkb off/on.   Stop: Ctrl+C or close this window."
Write-Info "Tip: start any other hook-based tools (e.g. Test-InjectedInput.ps1) BEFORE physkb, so they never see the injected original."
Write-Host ""

try { [PhysKb]::Run($kd, $md, $rel, $moves) }
catch { Write-Bad $_.Exception.Message; return }

# Remember a mouse slot that proved to work if it differs from the saved one (auto-failover).
$confirmed = [PhysKb]::MouseConfirmed
if ($confirmed -ne 0 -and $confirmed -ne $md -and -not $Observe) {
    Save-Config ([pscustomobject]@{ Device = $kd; MouseDevice = $confirmed; MouseMoves = $moves; MouseRelative = $rel })
    Write-Good "Mouse slot $confirmed worked, so it was saved as your default."
}
Write-Info "physkb stopped."
