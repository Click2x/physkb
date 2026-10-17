<#
.SYNOPSIS
    Windows Forms front end for physkb: pick keyboard / mouse slots, Start / Stop.

.DESCRIPTION
    Reuses the PhysKb class and helpers from physkb.ps1 (dot-sourced with -LoadOnly), so both entry points
    behave the same. Settings are shared with the command-line version (%APPDATA%\physkb\config.json).
    Like physkb.ps1 it relaunches itself elevated, because the Interception driver needs administrator rights.

    Safety: Ctrl+Shift+F12 switches physkb off/on at any time. The "Driver recovery" button only SHOWS the
    uninstall steps; it never runs anything.

.PARAMETER DllDir     Folder containing the x64 interception.dll (auto-detected if omitted).
.PARAMETER BuildOnly  Construct the form (with sample device names) without showing it, installing hooks or elevating.
                      Used for testing; prints "Form built OK".
#>
[CmdletBinding()]
param(
    [string]$DllDir,
    [switch]$BuildOnly
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Share the PhysKb class and helpers (Find-InterceptionDll, Get-DeviceLabel, Load-Config, Save-Config, ...).
. (Join-Path $PSScriptRoot 'physkb.ps1') -LoadOnly -DllDir $DllDir

$recoveryText = @'
Keyboard or mouse stopped working after installing Interception?
The driver is the usual cause. To remove it:

1. Open the on-screen keyboard: Win+Ctrl+O.
   (Or use the mouse if the keyboard is the only thing broken.)
2. Open an admin PowerShell: Win+X, then A, and accept the prompt.
3. Run (adjust the path to where you unzipped Interception):

   cd "C:\Interception\command line installer"
   .\install-interception.exe /uninstall

4. Restart. The change only applies after a reboot.

This window only shows the steps. Nothing has been run.
'@ -replace "`r?`n", "`r`n"

function Show-RecoveryDialog($owner) {
    $d = New-Object System.Windows.Forms.Form
    $d.Text = 'Driver recovery (steps only)'
    $d.StartPosition = 'CenterParent'
    $d.ClientSize = New-Object System.Drawing.Size(520, 360)
    $d.FormBorderStyle = 'FixedDialog'; $d.MaximizeBox = $false; $d.MinimizeBox = $false
    $t = New-Object System.Windows.Forms.TextBox
    $t.Multiline = $true; $t.ReadOnly = $true; $t.ScrollBars = 'Vertical'
    $t.Font = New-Object System.Drawing.Font('Consolas', 9)
    $t.Text = $recoveryText
    $t.SetBounds(10, 10, 500, 300)
    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'Close'; $ok.DialogResult = 'OK'
    $ok.SetBounds(430, 320, 80, 28)
    $d.Controls.AddRange(@($t, $ok))
    $d.AcceptButton = $ok; $d.CancelButton = $ok
    $t.Select(0, 0)
    [void]$d.ShowDialog($owner)
    $d.Dispose()
}

# Dropdown entries look like "4 - Dell  VID:413C PID:2105"; the slot number is the text before " - ".
function Get-SlotItems($ids, [int[]]$range) {
    $items = @('0 - None (leave alone)')
    foreach ($i in $range) { if ($ids[$i - 1]) { $items += ('{0} - {1}' -f $i, (Get-DeviceLabel $ids[$i - 1])) } }
    return ,$items
}

function Get-SlotNumber($combo) {
    if ($combo.SelectedItem -and ([string]$combo.SelectedItem) -match '^(\d+) - ') { return [int]$Matches[1] }
    return 0
}

function Select-Slot($combo, [int]$slot) {
    $idx = 0
    for ($i = 0; $i -lt $combo.Items.Count; $i++) { if (([string]$combo.Items[$i]) -like "$slot - *") { $idx = $i; break } }
    $combo.SelectedIndex = $idx
}

# Builds the form and returns a hashtable of its controls. $ids = the 20 hardware-id strings from ListDevices.
function New-PhysKbForm($ids, $cfg, [string]$statusText) {
    $ui = @{}
    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'physkb'
    $f.StartPosition = 'CenterScreen'
    $f.FormBorderStyle = 'FixedSingle'; $f.MaximizeBox = $false
    $f.ClientSize = New-Object System.Drawing.Size(540, 290)
    $f.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    $lblK = New-Object System.Windows.Forms.Label
    $lblK.Text = 'Keyboard slot:'; $lblK.SetBounds(15, 20, 100, 20)
    $cbK = New-Object System.Windows.Forms.ComboBox
    $cbK.DropDownStyle = 'DropDownList'; $cbK.SetBounds(120, 17, 405, 24)
    $cbK.Items.AddRange((Get-SlotItems $ids (1..10)))

    $lblM = New-Object System.Windows.Forms.Label
    $lblM.Text = 'Mouse slot:'; $lblM.SetBounds(15, 55, 100, 20)
    $cbM = New-Object System.Windows.Forms.ComboBox
    $cbM.DropDownStyle = 'DropDownList'; $cbM.SetBounds(120, 52, 405, 24)
    $cbM.Items.AddRange((Get-SlotItems $ids (11..20)))

    $kd = 0; $md = 0
    if ($cfg) { $kd = [int]$cfg.Device; $md = [int]$cfg.MouseDevice }
    Select-Slot $cbK $kd
    Select-Slot $cbM $md

    $btnStart = New-Object System.Windows.Forms.Button
    $btnStart.Text = 'Start'; $btnStart.SetBounds(120, 95, 110, 32)
    $btnRecover = New-Object System.Windows.Forms.Button
    $btnRecover.Text = 'Driver recovery...'; $btnRecover.SetBounds(375, 95, 150, 32)

    $lblStatus = New-Object System.Windows.Forms.Label
    $lblStatus.Text = $statusText; $lblStatus.SetBounds(15, 145, 510, 40)
    $lblStatus.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)

    $lblNote = New-Object System.Windows.Forms.Label
    $lblNote.Text = ("Panic key: press Ctrl+Shift+F12 at any time to switch physkb off/on without closing it. " +
        "While off, everything passes through unchanged.`r`n`r`n" +
        "Start physkb last: hook-based tools that are already running still see the injected original. " +
        "Closing this window removes the hooks.")
    $lblNote.SetBounds(15, 195, 510, 85)

    $f.Controls.AddRange(@($lblK, $cbK, $lblM, $cbM, $btnStart, $btnRecover, $lblStatus, $lblNote))
    $ui.Form = $f; $ui.Keyboard = $cbK; $ui.Mouse = $cbM; $ui.Start = $btnStart
    $ui.Recovery = $btnRecover; $ui.Status = $lblStatus
    return $ui
}

function Wire-PhysKbForm($ui, $ids, $cfg) {
    $moves = [bool]($cfg -and $cfg.MouseMoves)
    $rel   = [bool]($cfg -and $cfg.MouseRelative)
    $green = [System.Drawing.Color]::DarkGreen
    $amber = [System.Drawing.Color]::DarkOrange
    $red   = [System.Drawing.Color]::Firebrick

    $setStatus = {
        param($text, $color)
        $ui.Status.Text = $text; $ui.Status.ForeColor = $color
    }

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 500
    $tick = {
        if ([PhysKb]::Running) {
            if ([PhysKb]::Enabled) { & $setStatus 'Running - injected input is being re-sent. (Ctrl+Shift+F12 pauses.)' $green }
            else { & $setStatus 'PAUSED by Ctrl+Shift+F12 - everything passes through unchanged.' $amber }
        }
    }
    $timer.Add_Tick($tick.GetNewClosure())

    $click = {
        if ([PhysKb]::Running) {
            [PhysKb]::Stop()
            $timer.Stop()
            $ui.Start.Text = 'Start'
            $ui.Keyboard.Enabled = $true; $ui.Mouse.Enabled = $true
            & $setStatus 'Stopped. Hooks removed.' ([System.Drawing.Color]::Black)
            return
        }
        $k = Get-SlotNumber $ui.Keyboard
        $m = Get-SlotNumber $ui.Mouse
        if ($k -eq 0 -and $m -eq 0) { & $setStatus 'Nothing to do: pick a keyboard and/or a mouse slot.' $red; return }
        if ($m -ne 0) {
            $others = @(11..20 | Where-Object { $ids[$_ - 1] -and $_ -ne $m })
            [PhysKb]::SetMouseSlots(@($m) + $others)
        }
        [PhysKb]::Trace = $false; [PhysKb]::Observe = $false
        try { [PhysKb]::Start($k, $m, $rel, $moves) }
        catch { & $setStatus ("Could not start: " + $_.Exception.Message) $red; return }
        Save-Config ([pscustomobject]@{ Device = $k; MouseDevice = $m; MouseMoves = $moves; MouseRelative = $rel })
        $ui.Start.Text = 'Stop'
        $ui.Keyboard.Enabled = $false; $ui.Mouse.Enabled = $false
        & $setStatus 'Running - injected input is being re-sent. (Ctrl+Shift+F12 pauses.)' $green
        $timer.Start()
    }
    $ui.Start.Add_Click($click.GetNewClosure())

    $ui.Recovery.Add_Click({ Show-RecoveryDialog $ui.Form }.GetNewClosure())

    $ui.Form.Add_FormClosing({
        if ([PhysKb]::Running) { [PhysKb]::Stop() }
        $timer.Stop(); $timer.Dispose()
    }.GetNewClosure())
}

# ----------------------------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------------------------
if ($BuildOnly) {
    # No driver, no hooks, no elevation: sample device names only.
    $ids = @('') * 20
    $ids[0] = 'HID\VID_413C&PID_2105&REV_0114'
    $ids[1] = 'virtualdevice'
    $ids[10] = 'HID\VID_1532&PID_0067&REV_0200'
    $ui = New-PhysKbForm $ids ([pscustomobject]@{ Device = 1; MouseDevice = 11 }) 'Not started.'
    Wire-PhysKbForm $ui $ids $null
    "Keyboard items: {0}; Mouse items: {1}; selected {2} / {3}" -f $ui.Keyboard.Items.Count, $ui.Mouse.Items.Count, (Get-SlotNumber $ui.Keyboard), (Get-SlotNumber $ui.Mouse)
    $ui.Form.Dispose()
    Write-Host 'Form built OK'
    return
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', ('"{0}"' -f $PSCommandPath))
    if ($DllDir) { $argList += @('-DllDir', ('"{0}"' -f $DllDir)) }
    Start-Process powershell.exe -Verb RunAs -ArgumentList $argList
    return
}

[System.Windows.Forms.Application]::EnableVisualStyles()

$problem = $null
$ids = @('') * 20
if (-not [Environment]::Is64BitProcess) { $problem = 'Run this in 64-bit PowerShell (it needs the x64 interception.dll).' }
else {
    $dir = Find-InterceptionDll
    if (-not $dir) { $problem = 'interception.dll (x64) not found. See the README for installing the Interception driver.' }
    else {
        try { [PhysKb]::Init($dir); $ids = [PhysKb]::ListDevices() }
        catch { $problem = $_.Exception.Message }
    }
}

$cfg = Load-Config
$ui = New-PhysKbForm $ids $cfg $(if ($problem) { $problem } else { 'Not started. Pick slots and press Start.' })
Wire-PhysKbForm $ui $ids $cfg
if ($problem) { $ui.Start.Enabled = $false; $ui.Status.ForeColor = [System.Drawing.Color]::Firebrick }
[void]$ui.Form.ShowDialog()
