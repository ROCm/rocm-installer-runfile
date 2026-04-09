# ROCm Runfile Installer

A self-contained installer for ROCm and the AMDGPU driver that works without a native Linux package manager. Supports fully offline installation once the installer is built — no network access required at runtime.

## Supported platforms

| Distribution | Versions |
|---|---|
| Ubuntu | 22.04, 24.04 |
| Debian | 12, 13 |
| RHEL | 8.10, 9.4, 9.6, 9.7, 10.0, 10.1 |
| Oracle Linux | 8.10, 9.6, 10.1 |
| Rocky Linux | 9.6 |
| Amazon Linux | 2023 |
| SLES | 15.7, 16.x |

## Repository layout

```
runfile-installer/
├── build-runfile-installer.sh   # Top-level build orchestrator
├── build-installer/
│   ├── setup-installer.sh       # Phase 1: pulls packages from AMD repos
│   ├── build-installer.sh       # Phase 2: extracts packages, builds .run file
│   ├── CMakeLists.txt           # Builds the ncurses GUI binary
│   └── config/                  # Preset build configurations
│       ├── dev.config
│       ├── nightly.config
│       ├── prerelease.config
│       └── release.config
├── package-puller/              # Package download scripts and repo configs
├── package-extractor/           # Package extraction scripts
├── rocm-installer/              # Runtime installer scripts (bundled in .run)
│   └── rocm-installer.sh        # Main install/uninstall script
├── UI/src/                      # ncurses GUI source (C)
└── tests/c/                     # Unit tests
```

## Building

### Build prerequisites

#### Ubuntu / Debian

```bash
sudo apt install -y binutils xz-utils zstd wget curl rsync cmake
```

#### RHEL 8.x / Oracle Linux 8.x

```bash
sudo dnf install wget
wget https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm
sudo rpm -ivh epel-release-latest-8.noarch.rpm
sudo crb enable
sudo dnf install wget curl rsync cmake
```

#### RHEL 9.x / Oracle Linux 9.x / Rocky Linux 9.x

```bash
sudo dnf install wget
wget https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm
sudo rpm -ivh epel-release-latest-9.noarch.rpm
sudo crb enable
sudo dnf install wget curl rsync cmake
```

#### Amazon Linux 2023

```bash
sudo dnf install wget curl rsync cmake
```

#### RHEL 10.x / Oracle Linux 10.x

```bash
sudo dnf install wget
wget https://dl.fedoraproject.org/pub/epel/epel-release-latest-10.noarch.rpm
sudo rpm -ivh epel-release-latest-10.noarch.rpm
sudo crb enable
sudo dnf install wget curl rsync cmake
```

#### SLES 15.7

```bash
sudo SUSEConnect -p PackageHub/15.7/x86_64
sudo zypper install awk cmake gcc gcc-c++ wget rsync
```

#### SLES 16.x

```bash
sudo SUSEConnect -p PackageHub/16.0/x86_64   # verify exact version string for your release
sudo zypper install awk cmake gcc gcc-c++ wget rsync
```

### Clone the repository

```bash
git clone git@github.com:ROCm/rocm-installer-runfile-internal.git
cd rocm-installer-runfile-internal
```

### Build the installer

The build process has two phases:

1. **Setup** — pulls ROCm and AMDGPU packages from AMD repositories (requires network access)
2. **Build** — extracts packages, compiles the GUI, and packages everything into a self-extracting `.run` file

The `build-runfile-installer.sh` script orchestrates both phases. Preset configurations for common build types are provided in `build-installer/config/`.

```bash
cd runfile-installer

# Release build
./build-runfile-installer.sh config=config/release.config

# Nightly build
./build-runfile-installer.sh config=config/nightly.config

# Dev build (single GPU architecture, faster compression)
./build-runfile-installer.sh config=config/dev.config
```

Config paths are relative to the `build-installer/` directory. To use an absolute path or a custom config file, provide the full path.

To run setup and build separately:

```bash
# Phase 1: pull packages only
./build-runfile-installer.sh config=config/release.config skip-build

# Phase 2: build only (packages already pulled)
./build-runfile-installer.sh config=config/release.config skip-setup
```

Common build options:

| Option | Description |
|---|---|
| `pull=<dev\|nightly\|prerelease\|release>` | Repository to pull from |
| `pulltag=<tag>` | Build tag (date for nightly, rc0/rc1 for prerelease) |
| `pullrunid=<id>` | Component build run ID |
| `pullrocmver=<version>` | ROCm version (e.g., `7.12.0`) |
| `pullamdgpu=<type>,<ver>` | AMDGPU type and version (e.g., `release,31.10`) |
| `rocm-archs=<archs>` | Comma-separated GPU architectures (e.g., `gfx94x,gfx110x`) |
| `rocm` / `amdgpu` | Pull only ROCm or only AMDGPU packages |
| `mscomp=<mode>` | Compression: `prodsmall`, `prodmedium`, `normal`, `prodfast`, `dev` |
| `norunfile` | Skip `.run` file creation |
| `nogui` | Skip GUI build |

The built `.run` file is placed in the build output directory under `build-installer/`.

---

## Running the installer

### GUI

Launch the interactive terminal UI by running the installer with no arguments:

```bash
bash rocm-installer.run
```

The GUI walks through pre-install configuration, component selection, driver options, and post-install settings. For full GUI documentation, see the [ROCm runfile installer guide](https://rocm.docs.amd.com/projects/install-on-linux/en/latest/install/rocm-runfile-installer.html).

### Command line

```bash
bash rocm-installer.run [options]
```

---

## Command-line reference

### Runfile options

These options control `.run` file extraction behavior. The `.run` file verifies a checksum, extracts to a `rocm-installer/` directory in the current working directory, and then automatically launches the GUI or executes `rocm-installer.sh` with any provided arguments. On exit, the `rocm-installer/` directory is deleted (except for log files).

| Option | Description |
|---|---|
| `help` | Display usage information |
| `version` | Display the installer version |
| `noexec` | Extract the `.run` file and exit without launching the installer. Use this to run `rocm-installer.sh` directly for multiple operations without re-extracting. |
| `noexec-cleanup` | Run the installer normally but skip cleanup of `rocm-installer/` on exit |
| `untar <directory>` | Extract only the ROCm installation tree to `<directory>`, without running the installer |

**Example — extract once, run multiple install operations:**

```bash
bash rocm-installer.run noexec
cd rocm-installer
bash rocm-installer.sh rocm
bash rocm-installer.sh amdgpu
```

**Example — extract the ROCm tree to a custom location:**

```bash
bash rocm-installer.run untar "/home/amd/myrocm"
```

After extraction, a `setup-modules-<version>.sh` script is generated inside the output directory. Run it to configure environment modules support:

```bash
cd /home/amd/myrocm/rocm-7.x.x
./setup-modules-7.x.x.sh
source /etc/profile.d/modules.sh
module load rocm/7.x.x
```

> **Note:** `setup-modules` installs the `environment-modules` package but does not install ROCm dependencies or configure GPU access permissions. Those steps must be handled separately.

---

### Dependency options

ROCm and the AMDGPU driver require non-AMD system packages to be installed before running. Use these options to list, validate, or install them.

| Option | Description |
|---|---|
| `deps=list <rocm\|amdgpu>` | List required dependency packages and exit |
| `deps=validate <rocm\|amdgpu>` | List missing dependency packages and exit |
| `deps=install <rocm\|amdgpu>` | Install missing dependencies, then continue with installation |
| `deps=install-only <rocm\|amdgpu>` | Install missing dependencies and exit |
| `deps=file <file-path>` | Install dependencies from a custom list file, then continue |
| `deps=file-only <file-path>` | Install dependencies from a custom list file and exit |

`<rocm|amdgpu>` can be specified individually or together.

```bash
# List ROCm dependencies
bash rocm-installer.run deps=list rocm

# Validate both ROCm and AMDGPU dependencies
bash rocm-installer.run deps=validate rocm amdgpu

# Install dependencies then install ROCm
bash rocm-installer.run deps=install rocm

# Install only the dependencies and exit
bash rocm-installer.run deps=install-only rocm amdgpu

# Install from a custom dependency file
bash rocm-installer.run deps=file /home/amd/mydeps.txt
```

The custom dependency file must follow the same format as the output of `deps=list` — one package name per line.

---

### Install options

| Option | Description |
|---|---|
| `rocm` | Enable ROCm installation |
| `amdgpu` | Enable AMDGPU driver installation |
| `target=<directory>` | Target directory for ROCm installation. Default: `/opt` |
| `gfx=<arch>` | GPU architecture to install (e.g., `gfx94x`, `gfx950`, `gfx110x`). If omitted, only base components are installed. Use `gfx=list` to see architectures available in this installer. |
| `compo=<component>` | ROCm component(s) to install. Default: `core`. Comma-separated for multiple (e.g., `compo=core,dev-tools`). Available: `core`, `core-dev`, `dev-tools`, `core-sdk`, `opencl`. Use `compo=list` to see what is in this installer. |
| `force` | Skip confirmation prompts when a previous runfile ROCm installation is detected |

```bash
# Install ROCm with gfx94x support to the default location (/opt/rocm-x.y.z)
bash rocm-installer.run gfx=gfx94x rocm

# Install ROCm to a custom location
bash rocm-installer.run target="/home/amd/myrocm" gfx=gfx94x rocm

# Install with dependencies
bash rocm-installer.run deps=install gfx=gfx94x rocm

# Install both ROCm and the AMDGPU driver
bash rocm-installer.run deps=install gfx=gfx94x rocm amdgpu gpu-access=all

# Install a specific component set
bash rocm-installer.run compo=core-sdk gfx=gfx94x rocm
```

> **Note:** `rocm` and `amdgpu` must each be specified to install their respective components. Omitting one skips it.

---

### Post-install options

Post-install configuration runs automatically after ROCm installation by default. Use `nopostrocm` to skip it and run it separately later.

| Option | Description |
|---|---|
| `nopostrocm` | Skip post-install configuration during installation. Run `postrocm` separately afterwards. |
| `postrocm` | Run post-install configuration (symlinks, library config, scripts). Use when re-running after a previous `nopostrocm` install. Accepts `target=`, `gfx=`, and `compo=` to match original install args; auto-detects if omitted. |
| `gpu-access=user` | Add the current user to the `video,render` groups for GPU access |
| `gpu-access=all` | Grant GPU access to all users via udev rules |
| `amdgpu-start` | Start the AMDGPU driver immediately after installation |

```bash
# Standard install — post-install runs automatically
bash rocm-installer.run target="/" gfx=gfx94x rocm gpu-access=user

# Install without post-install, then run it separately
bash rocm-installer.run gfx=gfx94x rocm nopostrocm
bash rocm-installer.run postrocm                              # auto-detect at /opt
bash rocm-installer.run target="/home/amd/myrocm" postrocm   # custom parent path
```

---

### Uninstall options

| Option | Description |
|---|---|
| `uninstall-rocm` | Uninstall ROCm. Default location: `/opt/rocm-x.y.z`. Accepts `target=`, `compo=`, and `gfx=` for selective uninstall; auto-detects all installed components if omitted. |
| `uninstall-amdgpu` | Uninstall the AMDGPU driver |

```bash
# Uninstall ROCm from the default location (/opt/rocm-x.y.z)
bash rocm-installer.run uninstall-rocm

# Uninstall ROCm from a specific version path
bash rocm-installer.run target="/home/amd/myrocm/rocm-7.x.x" uninstall-rocm

# Selective uninstall — specify same compo= and gfx= as original install
bash rocm-installer.run target="/opt/rocm-7.x.x" compo=core-sdk gfx=gfx94x uninstall-rocm

# Uninstall both ROCm and the AMDGPU driver
bash rocm-installer.run uninstall-rocm uninstall-amdgpu

# Uninstall the AMDGPU driver only
bash rocm-installer.run uninstall-amdgpu
```

> **Note:** These options only remove runfile-based installations. Package manager installations of ROCm or the AMDGPU driver are not affected.

---

### Information and debug options

| Option | Description |
|---|---|
| `findrocm` | Search for existing ROCm installations on the system |
| `complist` | List the ROCm components and versions included in this installer |
| `prompt` | Pause at critical points and prompt the user before continuing |
| `verbose` | Enable verbose logging |

```bash
bash rocm-installer.run findrocm
bash rocm-installer.run complist
bash rocm-installer.run target="/" rocm prompt verbose
```

---

## Logs

| Phase | Location |
|---|---|
| Package pull (setup) | `runfile-installer/package-puller/logs/` |
| Package extraction (build) | `runfile-installer/package-extractor/logs/` |
| Installation (runtime) | `rocm-installer/logs/` (inside the extracted `.run` directory) |

The `rocm-installer/` runtime directory is created when the `.run` file extracts to the current working directory. Log files in this directory are preserved after the installer cleans up.

---

## Development

### Running unit tests

Unit tests for the UI source live in `runfile-installer/tests/` and use the [cmocka](https://cmocka.org/) framework. The test project builds independently from the production binary.

**Requirements:** `libcmocka-dev` (apt) / `libcmocka-devel` (dnf/zypper)

```bash
cd runfile-installer/tests
cmake -B build -DCMAKE_BUILD_TYPE=Debug .
cmake --build build
ctest --test-dir build --output-on-failure
```

After the initial configure step, only the build and test commands are needed for subsequent runs.
