# Civilight

Civilight builds a raw, bootable Gentoo disk image for x86-64 UEFI systems. The
GPT image contains a FAT EFI System Partition with systemd-boot and a unified
kernel image, plus a writable Btrfs root filesystem. After writing the image to
a whole drive, boot it and sign in as `root` with the password selected during
the build.

## Requirements

- An x86-64 Linux host, Dart SDK 3, mkosi 26, and the systemd host tools
  including `systemd-repart`, `systemd-firstboot`, `bootctl`, and `ukify`.
- GNU coreutils and tar, util-linux with `unshare --map-auto`, `curl`, `gpgv`,
  `kmod` with `depmod --moduledir`, `btrfs-progs`, `dosfstools`, `mtools`,
  and the build dependencies listed in the kernel and glibc repositories.
- Network access for Gentoo and the development sources. An unprivileged build
  requires subordinate UID and GID allocations and working `newuidmap` and
  `newgidmap` helpers. The script also accepts execution as root.
- At least 12 GiB free on the output filesystem, with more space for large
  package selections. Temporary files are created next to the raw image.
  External checkouts also need room for their source trees. The script
  reports insufficient space and out-of-space tool failures on stderr.

Place the external builders next to this repository, or pass `--kernel` and
`--glibc` with their locations. The builder invokes the Dart scripts from
those checkouts.

```sh
git clone https://github.com/ekuOS/kernel ../kernel
git clone https://github.com/ekuOS/glibc ../glibc
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

The kernel builder uses the AppArmor flavor with Btrfs and common boot
requirements enabled. Use `--kernel-artifacts DIR` to reuse a compatible
`linux-eku-aa` artifact bundle. The image registers it with Portage as
`sys-kernel/linux-eku`. The patched 64-bit ekuOS glibc replaces the Gentoo
package in its existing slot as `sys-libs/glibc`. Both local binary packages
are retained in the image's Portage package cache. Gentoo's stock glibc is
masked after the replacement. Rebuild the image with updated ekuOS checkouts
to refresh the kernel, its unified kernel image, and glibc.

The default output is `out/civilight.raw`. Use `--output /path/to/civilight.raw`
to place both the temporary workspace and image on a different filesystem.
The root partition starts at 8 GiB. Use `--root-size-gib N` to change its
minimum size. The build uses two parallel jobs by default. Use `--jobs N`
to change the job count. Run `dart run build.dart --help` for all options.

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
The root filesystem keeps the size assigned during the build. Ethernet DHCP
is enabled. Include any hardware-specific firmware packages in
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
