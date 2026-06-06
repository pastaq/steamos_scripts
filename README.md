# SteamOS Custom Kernel & Service Utilities

A collection of specialized system administration tools optimized for SteamOS
development, custom kernel deployment, and interactive input debugging.

> ⚠️ **Prerequisite:** Before executing these scripts on SteamOS, you must disable
  the read-only file system protection. Run `sudo steamos-readonly disable` in
  your terminal.

## 🛠️ Scripts Overview

### 1. Kernel Installation Manager (`install-kernel.sh`)

This script handles the extraction, provision mapping, and registration of
custom x86 compressed Linux kernel archives directly onto the SteamOS root
partition.

#### System Requirements

* SteamOS environment (with read-only mode disabled)
* `zstd` extraction tools
* Pre-compiled custom kernel archive matching the pattern: `linux-[VERSION]-x86.tar.zst`

#### Usage

Build your kernel from source with the following flags:

```bash
make LLVM=1 ZSTD_CLEVEL=19 INSTALL_MOD_STRIP=1 -j$(nproc) tarzst-pkg

```

Transfer to the target device with ssh:

```bash
scp linux-* deck@steamdeck:~/ && rm linux-*
```

Pass your target kernel version identifier string as the primary argument:

```bash
./install-kernel.sh 7.0.0
```

---

### 2. Kernel Selector Tool (`choose-kernel.sh`)

This script acts as an interactive picker interface allowing you to manually
swap the active, default boot flag pointer between your stock and customized
SteamOS kernels.

#### Usage

```bash
./choose-kernel
```

* Generates a listed prompt of all installed kernels found inside the `/boot` partition.
* Allows selecting a targeted image version to modify the default symlink structure,
  ensuring that version boots on the next cycle.

---

### 3. GRUB Selector Enabler (`enable-select-kernel.sh`)

SteamOS hides the GRUB boot menu by default to speed up boot times. This script
overrides the hidden timeouts, allowing you to manually choose your custom kernel
package visually at device startup.

#### Usage

```bash
./enable-select-kernel [mode]
```

#### Available Run Flags

| Option | Operation Description |
| :--- | :--- |
| true | Enable kernel selection at boot |
| false | Disable kernel selection at boot |
| status | Show current configuration state |

---

### 4. Inputplumber Controller & Debugger (`update-inputplumber.sh`)

#### Usage

```bash
./update-inputplumber.sh [mode]
```

#### Available Run Flags (`[mode]`)

| Option | Operation Description |
| :--- | :--- |
| `trace` | Runs application using verbose, granular `trace` execution tracking. Outputs to stdout and pipes to `.inputplumber.log`. |
| `no-log` | Drops file streaming operations. Launches standard `debug` logs entirely inside your active console shell. |
| `none` | Stops operational backend daemons, updates the file assets, and securely terminates execution without initiating a foreground console stream. |
| *(Default)* | Clears flag declarations, streaming traditional environment `debug` parameters directly to standard console and the `.inputplumber.log` artifact. |
