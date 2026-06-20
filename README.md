# Easy SSD Tester

Version 1.0 - 2026

Portable Windows 11 utility for checking SSD health, SMART data and simple sequential read/write performance.

## Start

Run `EasySSDTester.cmd`. No installation is required.
Execution is only possible with administrator rights.

For the most complete SMART output, place `smartctl.exe` from smartmontools in `Tools\smartctl.exe` next to the app, or make it available in `PATH`.

Without smartctl, the app still uses Windows storage information where available, but detailed wear counters may be limited.

## Features

- SSD/HDD/NVMe/SATA/USB drive overview
- Windows health and reliability counters
- Optional smartctl SMART/NVMe analysis
- Traffic-light style health verdict
- Manufacturer detection from model names
- Sequential read/write plausibility test
- HTML report export
- Portable execution on Windows 11

## Legal

Copyright by Dr. René Bäder (PhDs)

Easy SSD Tester is Freeware and kostenlos.

This project is distributed under the GNU General Public License v3.0. See `LICENSE`.

Third-party tool note: smartmontools is a separate project. If you bundle `smartctl.exe`, include the matching smartmontools license files from that project.
