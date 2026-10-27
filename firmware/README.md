# Updating the Multi-Peripheral Tester firmware

This folder holds everything needed to install a new firmware version on the tester
using a USB cable. You do not need the Arduino IDE, PlatformIO, or any programmer.

## Multi-Peripheral Tester firmware upload mode
1. Press and hold the TEST button while applying power to the tester. 
2. Release the TEST button after 2 seconds and the tester will enter the firmware upgrade mode

---

## The updater script:

1. Reads the firmware version already on the board
2. Compares it with the latest release published on GitHub
3. Downloads new version and checks SHA-256 hash
4. Flashes firmware and confirms successful upload.

---

## Windows

### Pre-requitisites:

Powershell 3.0 (If on Windows 7 you will need to upgrade to powershell 3.0. Windows 10/11 should already be on powershell 3.0)

### Upgrading:
*Run `update.cmd`*


`update.cmd` is only a wrapper: it checks your PowerShell version, runs `updater.ps1`,
and checks if `avrdude.exe` is already installed or is fetched automatically, and proceeds to flash the latest firmware.

## Linux and macOS

```
chmod +x updater.sh      
./updater.sh
```

`avrdude` must be installed (`sudo apt install avrdude` on Debian/Ubuntu,
`brew install avrdude` on macOS). The script says so if it is missing.

---

## What a successful run looks like

```
[OK] avrdude: .../avrdude/avrdude.exe
[INFO] Checking the latest release
[OK] Latest version: v1.1
[OK] Port: COM4  USB Serial Port (COM4)
[INFO] Reading the installed firmware version
[OK] Installed version: 1.0
Update available: v1.0 -> v1.1

Download and flash v1.1 now? [y/N]: y
[OK] Downloaded 179363 bytes
[OK] SHA-256 matches
[INFO] avrdude -c arduino -p m1280 -b 57600
[OK] Flashed
[OK] Board now reports v1.1
```

Answer `y` at the prompt. Ctrl-C or anything else cancels without touching the board.

If the board is already current you get `Up to date: v1.1` and the script exits without
doing anything. **It also never downgrades**: if the board is newer than the latest
release it says so and stops.

---

## Options

Windows uses `update.cmd <option>`; Linux/macOS uses `./updater.sh <option>`.

| Windows | Linux/macOS | What it does |
|---|---|---|
| `-Yes` | `-y`, `--yes` | flash without asking for confirmation |
| `-Port COM4` | `-p /dev/ttyUSB0` | use a specific serial port instead of auto-detecting |
| `-DryRun` | `-n`, `--dry-run` | download and verify, then stop before flashing |
| `-Hex .\firmware.hex` | — | flash a file you already have; no internet needed |
| `-NoDownload` | — | never fetch anything from the internet |
| `-Force` | `-f`, `--force` | flash even when up to date, or to downgrade deliberately |
| `-BootBaud 115200` | `-b 115200` | try a different bootloader speed |
| `-Help` | `-h` | list the options |

### Offline or restricted networks

If the PC cannot reach GitHub — a proxy, a locked-down network, or an old Windows that
cannot negotiate TLS 1.2 — put `firmware.hex` in this folder and use:

```
update.cmd -Hex .\firmware.hex
```

---

## Troubleshooting firmware upgrade issues

## Windows

**"This PC has no COM ports at all"**

The USB-serial driver is missing. Open Device Manager: under *Ports (COM & LPT)* you
should see `USB Serial Port (COMx)`. If the tester appears under *Other devices* with a
warning triangle, install the FTDI VCP driver from <https://ftdichip.com/drivers/vcp-drivers/>,
replug the board, and run again.

**"Several COM ports exist and none looks like the tester"**

The script lists them. Pick the one the tester is on: `update.cmd -Port COM4`.

**"Could not read the firmware version"**

Close anything else using that COM port — the Arduino IDE, a serial monitor — and check
that the board is powered (the panel lights up). A charge-only USB cable will also do
this: the port appears but the board never answers.

**Could not determine the latest version from GitHub**

No usable internet from this PC. Use `-Hex` as above.


**Windows PowerShell is version 2.0**

The updater needs 3.0 or newer. Install *Windows Management Framework 5.1* from
Microsoft, reboot, and run again — or flash by hand (below).


```
avrdude -c arduino -p m1280 -P COM4 -b 57600 -D -U flash:w:firmware.hex:i
```

---

## Linux

**"Permission denied" on `/dev/ttyUSB0`**

Your user is not in the group that owns serial devices. On Debian/Ubuntu and Fedora
that group is `dialout`; on Arch it is `uucp`; a few distributions use `tty`. The
`ls -l` below shows which one yours is.

```
ls -l /dev/ttyUSB0        # shows the group, e.g.  crw-rw----  root dialout
sudo usermod -aG dialout $USER
```

Then **log out and back in** — group changes only apply to a new session. `newgrp dialout`
works in the current terminal if you would rather not log out.

**The port appears and then vanishes, or the version read fails at random**

A braille-display daemon called `brltty` claims FTDI and CDC serial adapters on some
distributions. It is not needed unless you use a braille display:

```
sudo apt remove brltty
```

If the port is fine but reads are erratic, ModemManager may be probing it:

```
sudo systemctl stop ModemManager
```

**"No serial port found. Connect the board or pass -p /dev/ttyUSB0."**

Check the board is actually enumerating:

```
ls -l /dev/ttyUSB* /dev/ttyACM*
dmesg | tail -20          # should end with "FTDI USB Serial Device ... attached"
```

Nothing listed means the cable, the port or the driver — try another cable (charge-only
USB cables give a port that never answers) and another USB port. With several ports
attached, name the right one: `./updater.sh -p /dev/ttyUSB0`.

**"Could not read the firmware version"**

Something else has the port open:

```
sudo fuser -v /dev/ttyUSB0     # who is using it
```

Close it — minicom, screen, `arduino-cli monitor`, the Arduino IDE, or a PlatformIO
serial monitor left running. `stty -F /dev/ttyUSB0 -hupcl` clears a stuck line state if
the port refuses to reopen after a killed program.

**Nothing happens at all when I run it**

Make the script executable first:

```
chmod +x updater.sh
./updater.sh
```

**avrdude is missing**

```
sudo apt install avrdude        # Debian/Ubuntu
sudo dnf install avrdude        # Fedora
sudo pacman -S avrdude          # Arch
```

**Everything works but the board is still on the old version**

Run it with `--dry-run` to see the version handshake and the checksum without flashing.
If that reports the new version as already installed, check which release is newest:
the updater will not downgrade a board that is ahead of the published release.

## macOS

**The port is `/dev/cu.usbserial-XXXXXXXX`**

The updater finds it automatically. If you are naming it yourself, use the `cu.` name,
not `tty.` — the `tty.` node blocks waiting for carrier detect.

```
ls /dev/cu.*
./updater.sh -p /dev/cu.usbserial-1420
```

**"Could not read the firmware version"**

Usually a driver that has not been approved: newer macOS requires allowing the FTDI
kernel extension in *System Settings → Privacy & Security* after plugging in. Install
the signed VCP driver from <https://ftdichip.com/drivers/vcp-drivers/> if the board never
appears under `ls /dev/cu.*`.

**avrdude is missing**

```
brew install avrdude
```

---

## Files in this folder

| File | Purpose |
|---|---|
| `update.cmd` | Windows: double-click to update |
| `updater.ps1` | Windows: the updater itself |
| `updater.sh` | Linux/macOS: the updater |

`avrdude` is free software under the GNU General Public Licence; see https://github.com/avrdudes/avrdude/

