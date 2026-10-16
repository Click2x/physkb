<#
.SYNOPSIS
    Shows whether keyboard and mouse input reaching Windows is "Injected" (software) or "Physical" (hardware).

.DESCRIPTION
    Installs low-level keyboard and mouse hooks and prints the injected flag of every key press and mouse click.
    Use it to check that physkb works: start THIS script first, then physkb, then type / click from your remote
    session. Re-sent input should read "Physical Hardware Input".
    Mouse movement is not printed (too noisy). Close the window to stop.
#>
$code = @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public static class InjectWatch {
    [StructLayout(LayoutKind.Sequential)] struct KBD { public uint vk; public uint sc; public uint flags; public uint time; public IntPtr extra; }
    [StructLayout(LayoutKind.Sequential)] struct MSL { public int x; public int y; public uint mouseData; public uint flags; public uint time; public IntPtr extra; }
    delegate IntPtr HookProc(int n, IntPtr w, IntPtr l);

    [DllImport("user32.dll", SetLastError = true)] static extern IntPtr SetWindowsHookEx(int id, HookProc fn, IntPtr mod, uint tid);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr h, int n, IntPtr w, IntPtr l);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandle(string name);

    static HookProc kp, mp;
    static IntPtr kh, mh;

    static string Src(bool injected) { return injected ? "Injected/Virtual Input" : "Physical Hardware Input"; }

    static IntPtr K(int n, IntPtr w, IntPtr l) {
        int msg = (int)w;
        if (n >= 0 && (msg == 0x100 || msg == 0x104)) {
            KBD k = (KBD)Marshal.PtrToStructure(l, typeof(KBD));
            bool inj = (k.flags & 0x10) != 0;
            Console.ForegroundColor = inj ? ConsoleColor.Yellow : ConsoleColor.Green;
            Console.WriteLine("Key:   {0} (vk {1}) | {2}", (Keys)k.vk, k.vk, Src(inj));
            Console.ResetColor();
        }
        return CallNextHookEx(kh, n, w, l);
    }

    static IntPtr M(int n, IntPtr w, IntPtr l) {
        int msg = (int)w;
        string name = null;
        switch (msg) {
            case 0x201: name = "Left down"; break;   case 0x204: name = "Right down"; break;
            case 0x207: name = "Middle down"; break; case 0x20B: name = "X button down"; break;
            case 0x20A: name = "Wheel"; break;       case 0x20E: name = "H-wheel"; break;
        }
        if (n >= 0 && name != null) {
            MSL m = (MSL)Marshal.PtrToStructure(l, typeof(MSL));
            bool inj = (m.flags & 0x03) != 0;
            Console.ForegroundColor = inj ? ConsoleColor.Yellow : ConsoleColor.Green;
            Console.WriteLine("Mouse: {0} | {1}", name, Src(inj));
            Console.ResetColor();
        }
        return CallNextHookEx(mh, n, w, l);
    }

    public static void Run() {
        IntPtr mod = GetModuleHandle(null);
        kp = K; mp = M;
        kh = SetWindowsHookEx(13, kp, mod, 0);
        mh = SetWindowsHookEx(14, mp, mod, 0);
        Application.Run();
    }
}
'@

if (-not ('InjectWatch' -as [type])) { Add-Type -TypeDefinition $code -ReferencedAssemblies System.Windows.Forms }
Write-Host "Watching keyboard and mouse. Yellow = injected (software), green = physical (hardware)." -ForegroundColor Cyan
Write-Host "Close this window to stop." -ForegroundColor Cyan
[InjectWatch]::Run()
