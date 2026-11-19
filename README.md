# Civilight

Civilight builds a raw, bootable ekuOS-civilight image for x86-64 UEFI systems
from Gentoo. The GPT image contains a FAT EFI System Partition with systemd-boot,
a unified kernel image, and a writable Btrfs root filesystem. After writing the image to
a whole drive, boot it and sign in as `root` with the password selected during
the build.

## Requirements

- An x86-64 Linux host, Dart SDK 3, mkosi 26, and the systemd host tools
  including `systemd-repart`, `systemd-firstboot`, `bootctl`, and `ukify`.
- GNU coreutils and tar, util-linux with `unshare --map-auto`, `curl`, `gpgv`,
  `kmod` with `depmod --moduledir`, `btrfs-progs`, `dosfstools`, `mtools`,
  and the build dependencies listed in the kernel repository.
- Network access for Gentoo, the ekuOS glibc binhost, and the kernel sources.
  An unprivileged build requires subordinate UID and GID allocations and
  working `newuidmap` and `newgidmap` helpers. The script also accepts execution
  as root.
- At least 12 GiB free in the build workspace, with more space for large
  package selections. The output filesystem needs room for the raw image
  when it is on a separate volume.
  The kernel checkout also needs room for its source tree. The script
  reports insufficient space and out-of-space tool failures on stderr.

Place the kernel checkout next to this repository, or pass `--kernel DIR`.
No local glibc checkout is needed.

```sh
git clone https://github.com/ekuOS/kernel ../kernel
```

## Build

Prepare a binary GPG keyring containing the trusted Gentoo weekly release
signing key. Verify the fingerprint before exporting it from your GPG
keyring. [Gentoo release signatures](https://www.gentoo.org/downloads/signatures/)

```sh
gpg --export 13EBBDBEDE7A12775DFDB1BABB572E0E2D182910 > gentoo-release.gpg
umask 077
openssl passwd -6 > root-password.hash

dart run build.dart \
  --gentoo-keyring gentoo-release.gpg \
  --root-password-file root-password.hash
```

`openssl` prompts for the password interactively. The image contains the
password hash. Keep the image and hash file private.

By default the script verifies Gentoo's signed download index, downloads the
AMD64 no-multilib systemd stage3, and verifies its detached signature before
extraction. To reuse a specific archive, pass `--stage3 /path/to/stage3.tar.xz`
and place its detached signature at `/path/to/stage3.tar.xz.asc`.

Edit [packages.conf](packages.conf) or supply `--packages FILE`. Put one
category/package atom on each line. Blank lines and comments beginning with
`#` are ignored. Portage installs the listed packages and their dependencies.
The build always installs systemd with its EFI boot manager, Dracut, kmod,
Btrfs tools, and AppArmor userspace and profiles.

Edit [config/portage](config/portage) to change the image's Portage settings.
After unpacking the signed stage3, Portage replaces its C library with
`sys-libs/glibc-2.44-r4` from the [ekuOS glibc binhost] for amd64 systemd without
multilib. Portage verifies the GPKG signature using the bundled ekuOS public
key. The build does not fall back to a source build or Gentoo's binary package
if the ekuOS package is unavailable. If the stage3 already has a newer glibc,
use a compatible signed stage3 or update the ekuOS package version and Portage
settings together.

The builder installs Clang, LLD, and LLVM from Gentoo's signed binary
repository. Portage then builds the image's additional packages and their
missing dependencies from source with that toolchain, without replacing glibc.

[ekuOS glibc binhost]: https://github.com/ekuOS/glibc/blob/main/packaging/gentoo/README.md

The kernel builder uses the AppArmor flavor and its default `eku.conf`.
Use a kernel checkout whose default profile enables Btrfs and NVMe.
Use `--kernel-artifacts DIR` to reuse a compatible
`linux-eku-aa` artifact bundle. The image registers it with Portage as
`sys-kernel/linux-eku`. The kernel binpkg and the downloaded glibc binpkg are
retained in the image's Portage caches. The ekuOS binhost remains configured in
the image. The package keeps Gentoo's repository identity and slot, so a normal
source upgrade after boot may replace it.

The default output is `out/civilight.raw`. Temporary workspaces are created in
the output directory by default. Use `--temp-dir DIR` to put workspaces on a
separate filesystem and `--output FILE.raw` to choose the image destination.
The root partition starts at 8 GiB. Use `--root-size-gib N` to change its
minimum size. The build uses two parallel jobs by default. Use `--jobs N`
to change the job count. Run `dart run build.dart --help` for all options.

## Clean temporary files

Successful or failed builds normally remove their own workspaces. Use
`clean` to remove inactive Civilight workspaces left by interrupted builds.
Use `--temp-dir` to select the build workspace parent and `--output` to scan
the output directory for temporary image copies. The default is `out/`.
Use the same account that ran the build. Published raw images are kept.

```sh
dart run build.dart clean --temp-dir /path/to/work --dry-run
dart run build.dart clean --temp-dir /path/to/work
```

## Run in QEMU

Install QEMU with KVM, GTK, and OVMF. Fedora provides the GTK backend in
`qemu-ui-gtk`. The launcher opens a window with the guest's serial login.
It uses temporary disk changes by default. Add `--persist` to write back to
the raw image and `--firmware FILE` to select a different OVMF firmware file.

```sh
dart run run.dart
dart run run.dart /path/to/civilight.raw
```

## Write and boot

Select the whole destination device carefully. The following command
overwrites its partition table and data. The drive needs at least the raw
file's apparent size and must present 512-byte logical sectors.

```sh
lsblk -o NAME,PATH,SIZE,MODEL,LOG-SEC,MOUNTPOINTS
sudo dd if=out/civilight.raw of=/dev/sdX bs=16M status=progress conv=fsync
```

Boot the device in x86-64 UEFI mode with Secure Boot disabled. The firmware
can use the standard EFI fallback path without a preconfigured boot entry.
The root filesystem grows to fill its partition at boot. Ethernet DHCP is
enabled. Include any hardware-specific firmware packages in
`packages.conf` before building for that hardware.

After signing in, check the running kernel, filesystem, and installed
packages.

```sh
uname -r
findmnt -no FSTYPE /
cat /sys/kernel/security/lsm
portageq match / sys-kernel/linux-eku
portageq match / sys-libs/glibc
```
