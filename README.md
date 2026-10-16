# physkb

Re-send injected keyboard and mouse input through the [Interception](https://github.com/oblitum/Interception) driver, so Windows apps see it as coming from a physical device instead of from software.

Typical use: remote-desktop / game-streaming hosts (Parsec, Moonlight, ...), macro and remapping tools, and accessibility setups, where some applications ignore or mishandle input that carries Windows' "injected" flag.

## How it works

Software input (`SendInput`, remote-desktop injection, most macro tools) is marked with an *injected* flag (`LLKHF_INJECTED` for keys, `LLMHF_INJECTED` for the mouse). physkb:

1. installs low-level keyboard / mouse hooks,
2. spots injected keys, clicks and wheel events,
3. swallows them, and
4. sends the same event through a real device slot of the Interception driver, which enters Windows below that flag.

Real hardware input is never touched.

## Requirements

- Windows 10 / 11, 64-bit PowerShell 5.1+
- The Interception driver installed (admin prompt, then **reboot**):
  1. Download from <https://github.com/oblitum/Interception/releases>
  2. Unzip, e.g. to `C:\Interception`
  3. `install-interception.exe /install`, reboot
- Memory Integrity (Core isolation) can block this older driver on some systems.

physkb auto-detects `interception.dll` in common places (`C:\Interception\library\x64`, next to the script, `%INTERCEPTION_DIR%`, `PATH`). Otherwise pass `-DllDir`. The DLL and driver are **not** bundled here; they have their own license.

## Quick start

```powershell
powershell -ExecutionPolicy Bypass -File .\physkb.ps1
```

On first run a short wizard lists your detected devices and asks which keyboard and mouse slot to send through. Your choice is saved to `%APPDATA%\physkb\config.json`. After that, just run the script again. It re-launches itself elevated if needed.

Verify it works with the included checker. Start it **first**, then physkb, then type and click from your remote session:

```powershell
.\Test-InjectedInput.ps1
```

Yellow lines are injected (software) input, green lines are physical. Input handled by physkb should show green.

## Options

| Option | What it does |
|---|---|
| `-Setup` | Run the device wizard again |
| `-List` | Show detected device slots and exit |
| `-Device N` | Keyboard slot (1-10); `0` leaves the keyboard alone |
| `-MouseDevice N` | Mouse slot (11-20); `0` leaves the mouse alone |
| `-MouseMoves` | Also re-send cursor movement (experimental, off by default) |
| `-MouseRelative` | With `-MouseMoves`: relative deltas instead of absolute positions |
| `-Trace` | Print each key / click seen and what happened to it |
| `-Observe` | Only report what is seen; swallow and re-send nothing (use with `-Trace`) |
| `-DllDir <folder>` | Folder containing the x64 `interception.dll` |
| `-ForgetConfig` | Delete saved settings |

## Safety

- **Ctrl+Shift+F12** switches physkb off/on at any time without closing it. While off, everything passes through unchanged.
- If re-sent mouse events never come back as physical events, physkb automatically tries your other mouse slots, then switches mouse handling off rather than leaving you without a working mouse.
- `-Observe` is always safe to try first.
- Stop with Ctrl+C or by closing the window; hooks are removed on exit.

## Limitations

- A hook-based program that is already running will still see the injected original before physkb swallows it, because Windows calls the most recently installed hook first. Start physkb **last**.
- Cursor movement is **not** re-sent by default, so mouse moves still carry the injected flag. `-MouseMoves` exists but is experimental: absolute moves through Interception are poorly behaved on some mice, and relative moves are subject to pointer acceleration.
- Unicode text packets (`VK_PACKET`) are passed through unchanged.
- Apps that read the sending *device* through Raw Input will see the slot you chose.
- Developed and checked on one setup (Windows 11, Dell keyboard, Razer mouse, Parsec): keyboard and clicks/wheel. Moves are untested. Reports for other setups welcome.

## Responsible use

Intended for your own machines and software: remote access, accessibility, automation of your own applications, and testing. It will not get around kernel anti-cheat (Vanguard, EAC, BattlEye and others block Interception), and using it in online games can violate their terms of service and get you banned. Don't use it to deceive systems you don't have permission to automate.

## License

MIT for the code in this repository. Interception is a separate project with its own license (free for non-commercial use); see its repository.
