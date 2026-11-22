import 'dart:io';

import 'commands.dart';
import 'flavor.dart' show applyOverlay;

const autobuilds = 'https://distfiles.gentoo.org/releases/amd64/autobuilds';
const stageFlavor = 'stage3-amd64-llvm-systemd';
const gentooProfile = 'default/linux/amd64/23.0/llvm/systemd';
const glibcName = 'sys-libs/glibc';
const glibcVersion = '2.44-r4';
const glibcSigningFingerprint = '63E58ABD12C94B1A1BBE2076B6F6212704F5903C';
const kernelName = 'sys-kernel/linux-eku-aa';
const kernelRepo = 'ekuos-kernel';
const kernelBinhost = 'https://ekuos.github.io/kernel/amd64/23.0/llvm/systemd';
const kernelSigningFingerprint = '9420B68C629FACA5C38D1858EB89C00F0857F247';

Future<void> download(String url, String path) => run('curl', [
  '--fail',
  '--location',
  '--silent',
  '--show-error',
  '--retry',
  '3',
  '--output',
  path,
  url,
]);

Future<File> stageArchive(Directory work, String keyring, String? local) async {
  final archive = File(local ?? '${work.path}/stage3.tar.xz');
  final signature = '${archive.path}.asc';
  if (local == null) {
    final index = '${work.path}/latest.txt';
    final verified = '${work.path}/latest.verified';
    await download('$autobuilds/latest-$stageFlavor.txt', index);
    await run('gpgv', ['--keyring', keyring, '--output', verified, index]);
    final path = RegExp(
      '^([0-9]{8}T[0-9]{6}Z/$stageFlavor-[0-9]{8}T[0-9]{6}Z[.]tar[.]xz) [0-9]+\$',
      multiLine: true,
    ).firstMatch(await File(verified).readAsString())?[1];
    if (path == null)
      throw const BuildFailure(
        'No matching Gentoo stage3 in the signed index.',
      );
    await download('$autobuilds/$path', archive.path);
    await download('$autobuilds/$path.asc', signature);
  }
  await run('gpgv', ['--keyring', keyring, signature, archive.path]);
  return archive;
}

Future<List<String>> readPackages(File file) async {
  final packages = <String>{};
  final lines = await file.readAsLines();
  // Portage validates the atom itself. Require a category and disallow options
  // or whitespace so each line can be passed as one argument.
  final atom = RegExp(r'^(?:[<>=~]+)?[\w+.-]+/[\w+.*:-]+$');
  for (var i = 0; i < lines.length; i++) {
    final value = lines[i].split('#').first.trim();
    if (value.isEmpty) continue;
    if (!atom.hasMatch(value)) {
      throw BuildFailure('${file.path}:${i + 1}: expected one Portage atom.');
    }
    packages.add(value);
  }
  return packages.toList();
}

class Gentoo {
  Gentoo(this.root, this.jobs, this.portageConfig);
  final Directory root;
  final int jobs;
  final Directory portageConfig;
  String at(String path) => '${root.path}$path';

  Future<void> write(String path, String contents) async {
    final file = File(at(path));
    await file.parent.create(recursive: true);
    await file.writeAsString(contents);
  }

  Future<void> copyPortageConfig(String path) async {
    final target = File(at('/etc/portage/$path'));
    await target.parent.create(recursive: true);
    await File('${portageConfig.path}/$path').copy(target.path);
  }

  Future<void> inside(List<String> args, {String? input}) async {
    // Gentoo's env-update adds the active LLVM slot to ROOTPATH.
    final profile = File(at('/etc/profile.env'));
    final env = await profile.exists() ? await profile.readAsString() : '';
    final path = RegExp(
      r"^export ROOTPATH='([^']+)'$",
      multiLine: true,
    ).firstMatch(env)?[1];
    await run('chroot', [
      root.path,
      '/usr/bin/env',
      '-i',
      'PATH=${path ?? '/usr/bin:/usr/sbin:/bin:/sbin'}',
      'HOME=/root',
      'TERM=dumb',
      'LC_ALL=C.UTF-8',
      'MAKEOPTS=-j$jobs',
      ...args,
    ], input: input);
  }

  Future<void> checkToolchain() async {
    await inside(['clang', '--version']);
    await inside(['ld.lld', '--version']);
  }

  Future<void> installRustUtilities(String targetKernel) async {
    for (final path in [
      'package.accept_keywords/civilight-tools',
      'package.use/civilight-tools',
    ]) {
      await copyPortageConfig(path);
    }
    const source = [
      'emerge',
      '--color=n',
      '--getbinpkg=n',
      '--usepkg=n',
      '--exclude=$glibcName $kernelName',
    ];
    // Avoid compiling a bootstrap Rust toolchain from source.
    await inside([...source, '--oneshot', 'dev-lang/rust-bin']);
    await inside([
      targetKernel,
      ...source,
      'sys-apps/uutils-coreutils',
      'app-admin/sudo-rs',
    ]);
    await inside(['/usr/bin/sudo', '--version']);
    // Gentoo's sudo-rs ebuild can install the file as 0644; visudo wants 0440.
    await run('chmod', ['0440', at('/etc/sudoers-rs')]);
    await inside(['/usr/bin/visudo', '--check']);
  }

  Future<void> replaceGnuCoreutils() async {
    await run('cp', [
      '-a',
      '${portageConfig.parent.path}/repos/civilight',
      at('/var/db/repos/'),
    ]);
    await copyPortageConfig('repos.conf/civilight.conf');
    await copyPortageConfig('package.mask/civilight-coreutils');
    await inside([
      'emerge',
      '--oneshot',
      '--getbinpkg=n',
      '--usepkg=n',
      'sys-apps/coreutils::civilight',
    ]);
    final gnu = await capture('chroot', [
      root.path,
      '/usr/bin/portageq',
      'best_version',
      '/',
      'sys-apps/coreutils::gentoo',
    ]);
    if (gnu.isNotEmpty)
      throw BuildFailure('GNU coreutils is still installed: $gnu');
    await inside([
      'portageq',
      'has_version',
      '/',
      'sys-apps/coreutils::civilight[xattr]',
    ]);
    for (final utility in ['ls', 'cp', 'stat']) {
      final version = await capture('chroot', [
        root.path,
        '/usr/bin/$utility',
        '--version',
      ]);
      if (!version.contains('uutils coreutils')) {
        throw BuildFailure('/usr/bin/$utility is not provided by uutils.');
      }
    }
  }

  Future<void> installGlibc() async {
    const cpv = '$glibcName-$glibcVersion';
    final newer = await capture('chroot', [
      root.path,
      '/usr/bin/portageq',
      'best_version',
      '/',
      '>$cpv',
    ]);
    if (newer.isNotEmpty) {
      throw BuildFailure('Cannot replace $newer with the older ekuOS $cpv.');
    }

    for (final path in [
      'binrepos.conf/ekuos-glibc.conf',
      'package.accept_keywords/ekuos-glibc',
      'package.use/ekuos-glibc',
      'profile/package.use.mask',
    ]) {
      await copyPortageConfig(path);
    }
    await inside(['getuto']);
    await trustSigningKey('ekuos-glibc', glibcSigningFingerprint);
    await installBinpkg('=$cpv', ['--reinstall-atoms=$glibcName']);
    await inside(['/usr/lib64/libc.so.6']);
    await inside(['/usr/lib/libc.so.6']);
  }

  static const gpg = ['gpg', '--batch', '--homedir', '/etc/portage/gnupg'];

  Future<void> trustSigningKey(String name, String fingerprint) async {
    final signingKey = 'keys/$name.asc';
    await copyPortageConfig(signingKey);
    await inside([...gpg, '--import', '/etc/portage/$signingKey']);
    await inside([...gpg, '--import-ownertrust'], input: '$fingerprint:6:\n');
    await inside([...gpg, '--check-trustdb']);
  }

  Future<void> installBinpkg(
    String atom, [
    List<String> options = const [],
  ]) async {
    await inside([
      'FEATURES=binpkg-request-signature',
      'emerge',
      '--color=n',
      '--getbinpkgonly',
      '--binpkg-respect-use=y',
      '--oneshot',
      ...options,
      atom,
    ]);
  }

  Future<void> configureKernelBinhost() async {
    await trustSigningKey(kernelRepo, kernelSigningFingerprint);
    final scratch = await Directory(at('/var/tmp'))
        .createTemp('kernel-binhost-');
    try {
      const archive = 'overlay.tar.gz';
      const sums = 'SHA256SUMS';
      for (final name in [sums, '$sums.asc', archive]) {
        await download('$kernelBinhost/$name', '${scratch.path}/$name');
      }
      final insideScratch =
          '/var/tmp/${scratch.uri.pathSegments.where((s) => s.isNotEmpty).last}';
      await inside([
        ...gpg,
        '--assert-signer',
        kernelSigningFingerprint,
        '--verify',
        '$insideScratch/$sums.asc',
        '$insideScratch/$sums',
      ]);
      final expected = RegExp(
        r'^([0-9a-f]{64})  overlay\.tar\.gz$',
        multiLine: true,
      ).allMatches(await File('${scratch.path}/$sums').readAsString()).toList();
      final file = '${scratch.path}/$archive';
      final actual = (await capture('sha256sum', [file])).split(' ').first;
      if (expected.length != 1 || actual != expected.single[1]) {
        throw const BuildFailure(
          'The ekuOS kernel overlay checksum does not match.',
        );
      }
      final overlay = await Directory(at('/var/db/repos/$kernelRepo')).create();
      await run('tar', [
        '--extract',
        '--no-same-owner',
        '--file',
        file,
        '--directory',
        overlay.path,
      ]);
    } finally {
      await scratch.delete(recursive: true);
    }
    for (final path in [
      'binrepos.conf/$kernelRepo.conf',
      'repos.conf/$kernelRepo.conf',
      'package.accept_keywords/$kernelRepo',
    ]) {
      await copyPortageConfig(path);
    }
  }

  Future<String> installedKernelRelease() async {
    final cpv = await capture('chroot', [
      root.path,
      '/usr/bin/portageq',
      'best_version',
      '/',
      '$kernelName::$kernelRepo',
    ]);
    final version = RegExp(
      '^$kernelName-(\\d+\\.\\d+(?:\\.\\d+)?)(?:-r\\d+)?\$',
    ).firstMatch(cpv)?[1];
    if (version == null) {
      throw BuildFailure(
        'Could not identify the installed kernel from $kernelRepo: $cpv.',
      );
    }
    final release = '$version-eku-aa';
    final modules = '/usr/lib/modules/$release';
    final config = File(at('/boot/config-$release'));
    for (final path in [
      config.path,
      at('/boot/vmlinuz-$release'),
      at('$modules/modules.dep.bin'),
    ]) {
      if (!await File(path).exists() || await File(path).length() == 0) {
        throw BuildFailure('The $release binpkg is missing $path.');
      }
    }
    final options = (await config.readAsLines()).toSet();
    for (final option in [
      'BTRFS_FS',
      'BLK_DEV_NVME',
      'EFI_STUB',
      'DRM_EFIDRM',
      'DRM_FBDEV_EMULATION',
      'FRAMEBUFFER_CONSOLE',
      'BLK_DEV_INITRD',
      'IA32_EMULATION',
      'SECURITY_APPARMOR',
      'MODULE_SIG_FORCE',
    ]) {
      if (!options.contains('CONFIG_$option=y')) {
        throw BuildFailure(
          'The $release binpkg requires CONFIG_$option=y to build Civilight.',
        );
      }
    }
    // mkosi uses the versioned image in /boot and copies it to the module tree.
    return release;
  }

  Future<void> unpack(File archive) async {
    await root.create();
    await run('tar', [
      '--extract',
      '--numeric-owner',
      '--xattrs',
      '--xattrs-include=*',
      '--exclude=./dev/*',
      '--file',
      archive.path,
      '--directory',
      root.path,
    ]);
    if (!await Link(at('/lib64')).exists() ||
        await Link(at('/lib64')).target() != 'usr/lib64' ||
        !await Link(at('/sbin')).exists() ||
        await Link(at('/sbin')).target() != 'usr/bin' ||
        !await Link(at('/etc/portage/make.profile')).exists() ||
        !(await Link(
          at('/etc/portage/make.profile'),
        ).target()).endsWith('/$gentooProfile')) {
      throw const BuildFailure(
        'Expected a usr-merged Gentoo amd64 23.0 LLVM/systemd stage3.',
      );
    }
  }

  Future<String> install(
    List<String> packages,
    String passwordHash,
    File initrd, {
    Directory? overlay,
  }) async {
    late String release;
    await withMounts(() async {
      await File('/etc/resolv.conf').copy(at('/etc/resolv.conf'));
      for (final path in [
        'package.use/civilight',
        'package.mask/civilight-llvm',
        'package.env/civilight',
        'env/apparmor-libstdcxx.conf',
      ]) {
        await copyPortageConfig(path);
      }
      await inside(['emerge-webrsync', '--quiet']);
      await installGlibc();
      await configureKernelBinhost();
      await installBinpkg('$kernelName::$kernelRepo', [
        '--reinstall-atoms=$kernelName',
      ]);
      release = await installedKernelRelease();
      // linux-info.eclass must check the target configuration during emerge,
      // but the kernel binpkg does not ship a build tree.
      const kernelConfig = '/var/tmp/civilight-kernel-config';
      final numbers = release.split('-').first.split('.');
      await write('$kernelConfig/Makefile', '''
VERSION = ${numbers[0]}
PATCHLEVEL = ${numbers[1]}
SUBLEVEL = ${numbers.length == 3 ? numbers[2] : '0'}
EXTRAVERSION =
''');
      await write('$kernelConfig/include/config/kernel.release', '$release\n');
      await File(at('/boot/config-$release')).copy(at('$kernelConfig/.config'));
      const targetKernel = 'KERNEL_DIR=$kernelConfig';
      await checkToolchain();
      await inside([
        targetKernel,
        'emerge',
        '--color=n',
        '--getbinpkg=n',
        '--usepkg=n',
        '--exclude=$glibcName $kernelName',
        '--update',
        '--newuse',
        '--oneshot',
        'sys-apps/systemd',
        'sys-kernel/dracut',
        'sys-apps/kmod',
        'sys-apps/apparmor',
        'sys-apps/apparmor-utils',
        'sec-policy/apparmor-profiles',
        'sys-fs/btrfs-progs',
      ]);
      await installRustUtilities(targetKernel);
      if (overlay != null) {
        await applyOverlay(
          Directory('${overlay.path}/etc/portage'),
          root,
          at: '/etc/portage',
        );
      }
      if (packages.isNotEmpty) {
        await inside([
          targetKernel,
          'emerge',
          '--color=n',
          if (overlay == null) ...[
            '--getbinpkg=n',
            '--usepkg=n',
          ] else ...[
            '--getbinpkg',
            '--binpkg-respect-use=y',
            '--autounmask=n',
          ],
          '--exclude=$glibcName $kernelName',
          ...packages,
        ]);
      }
      await Directory(at(kernelConfig)).delete(recursive: true);
      await replaceGnuCoreutils();
      await inside(['chpasswd', '--encrypted'], input: 'root:$passwordHash\n');
      final buildState = Directory(at('/var/tmp/portage'));
      if (await buildState.exists()) await buildState.delete(recursive: true);
      // Desktop distfiles and cached binpkgs are build inputs, not image content.
      if (overlay != null) {
        for (final path in [
          '/var/cache/distfiles',
          '/var/cache/binhost',
          '/var/cache/binpkgs',
        ]) {
          final cache = Directory(at(path));
          if (await cache.exists()) await cache.delete(recursive: true);
        }
      }
      if (!await File(at('/usr/lib/systemd/boot/efi/systemd-bootx64.efi'))
              .exists() ||
          !await File(at('/usr/lib/systemd/systemd')).exists()) {
        throw const BuildFailure(
          'Gentoo systemd or its x86-64 EFI boot manager is missing.',
        );
      }
    });

    await File(at('/etc/resolv.conf')).delete();
    await Link(at('/etc/resolv.conf'))
        .create('/run/systemd/resolve/stub-resolv.conf');
    await write('/etc/systemd/network/80-civilight.network', '''
[Match]
Name=en* eth*

[Network]
DHCP=yes
''');
    await write('/etc/systemd/system-preset/00-civilight.preset', '''
enable apparmor.service
enable systemd-networkd.service
enable systemd-resolved.service
''');
    await write('/etc/fstab', '''
PARTLABEL=civilight-esp /efi vfat umask=0077,nofail,x-systemd.automount 0 2
''');
    // On a larger target disk, enlarge the existing root GPT partition before
    // growing the mounted Btrfs filesystem. Leave the ESP untouched.
    await write('/etc/repart.d/10-civilight-root.conf', '''
[Partition]
Type=root
''');
    await write(
      '/etc/systemd/system/local-fs.target.d/civilight-growfs.conf',
      '''
[Unit]
Wants=systemd-repart.service systemd-growfs-root.service
After=systemd-growfs-root.service
''',
    );
    await Directory(at('/efi')).create();
    await run('chmod', ['0700', at('/efi')]);
    await write('/efi/loader/loader.conf', 'default civilight-$release.efi\n');
    await write('/etc/machine-id', '');
    final osRelease = File(at('/usr/lib/os-release'));
    final releaseLines = (await osRelease.readAsLines()).where(
      (line) => !line.startsWith('NAME=') && !line.startsWith('PRETTY_NAME='),
    );
    await osRelease.writeAsString(
      [
        'NAME="ekuOS-civilight"',
        'PRETTY_NAME="ekuOS-civilight"',
        ...releaseLines,
        '',
      ].join('\n'),
    );
    if (overlay != null) await applyOverlay(overlay, root);
    await withMounts(() async {
      await inside([
        'dracut',
        '--force',
        '--no-hostonly',
        '--no-hostonly-cmdline',
        '--no-early-microcode',
        '--kver',
        release,
        '/var/tmp/civilight.initrd',
      ]);
      await File(at('/var/tmp/civilight.initrd')).rename(initrd.path);
    });
    return release;
  }

  Future<void> withMounts(Future<void> Function() action) async {
    final mounted = <String>[];
    try {
      await run('mount', [
        '-t',
        'tmpfs',
        '-o',
        'mode=0755',
        'tmpfs',
        at('/dev'),
      ]);
      mounted.add(at('/dev'));
      for (final device in [
        'null',
        'zero',
        'full',
        'random',
        'urandom',
        'tty',
      ]) {
        final target = at('/dev/$device');
        await File(target).create();
        await run('mount', ['--bind', '/dev/$device', target]);
      }
      await Directory(at('/dev/pts')).create();
      await run('mount', [
        '-t',
        'devpts',
        '-o',
        'newinstance,ptmxmode=0666,mode=0620,gid=5',
        'devpts',
        at('/dev/pts'),
      ]);
      for (final (name, target) in [
        ('ptmx', 'pts/ptmx'),
        ('fd', '/proc/self/fd'),
        ('stdin', 'fd/0'),
        ('stdout', 'fd/1'),
        ('stderr', 'fd/2'),
      ]) {
        await Link(at('/dev/$name')).create(target);
      }
      await Directory(at('/dev/shm')).create();
      await run('mount', [
        '-t',
        'tmpfs',
        '-o',
        'mode=1777',
        'tmpfs',
        at('/dev/shm'),
      ]);
      for (final (name, mode) in [('/sys', '--rbind'), ('/proc', '--bind')]) {
        await run('mount', [mode, name, at(name)]);
        mounted.add(at(name));
      }
      await action();
    } finally {
      for (final mount in mounted.reversed) {
        await run('umount', ['--lazy', mount]);
      }
    }
  }
}
