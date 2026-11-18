import 'dart:io';

import 'commands.dart';
import 'eku.dart';

const autobuilds = 'https://distfiles.gentoo.org/releases/amd64/autobuilds';
const stageFlavor = 'stage3-amd64-nomultilib-systemd';

Future<File> stageArchive(Directory work, String keyring, String? local) async {
  final archive = File(local ?? '${work.path}/stage3.tar.xz');
  final signature = '${archive.path}.asc';
  if (local == null) {
    final index = '${work.path}/latest.txt';
    final verified = '${work.path}/latest.verified';
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

  Future<void> installToolchain() async {
    await inside([
      'emerge',
      '--color=n',
      '--getbinpkg',
      '--usepkgonly',
      '--noreplace',
      'llvm-core/clang',
      'llvm-core/lld',
      'llvm-core/llvm',
    ]);
    await inside(['env-update']);
    await inside(['clang', '--version']);
    await inside(['ld.lld', '--version']);
    await copyPortageConfig('make.conf');
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
        ).target()).endsWith('/no-multilib/systemd')) {
      throw const BuildFailure(
        'Expected a usr-merged Gentoo amd64 no-multilib systemd stage3.',
      );
    }
  }

  Future<void> install(
    List<String> packages,
    Kernel kernel,
    Directory kernelPayload,
    String glibcVersion,
    Directory glibcPayload,
    String passwordHash,
    File initrd,
  ) async {
    await withMounts(() async {
      await File('/etc/resolv.conf').copy(at('/etc/resolv.conf'));
      await copyPortageConfig('package.use/civilight');
      // linux-info.eclass must check the target configuration during emerge,
      // including when AppArmor is installed from a binary package.
      const kernelConfig = '/usr/src/linux';
      final numbers = kernel.release.split('-').first.split('.');
      final extra = RegExp(r'-rc[0-9]+').firstMatch(kernel.release)?[0] ?? '';
      await write('$kernelConfig/Makefile', '''
VERSION = ${numbers[0]}
PATCHLEVEL = ${numbers[1]}
SUBLEVEL = ${numbers.length == 3 ? numbers[2] : '0'}
EXTRAVERSION = $extra
''');
      await write(
        '$kernelConfig/include/config/kernel.release',
        '${kernel.release}\n',
      );
      await File('${kernel.artifacts.path}/.config')
          .copy(at('$kernelConfig/.config'));
      const targetKernel = 'KERNEL_DIR=$kernelConfig';
      await inside(['emerge-webrsync', '--quiet']);
      await installToolchain();
      await inside([
        targetKernel,
        'emerge',
        '--color=n',
        '--getbinpkg=n',
        '--usepkg=n',
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
      if (packages.isNotEmpty) {
        await inside([
          targetKernel,
          'emerge',
          '--color=n',
          '--getbinpkg=n',
          '--usepkg=n',
          ...packages,
        ]);
      }
      await Directory(at(kernelConfig)).delete(recursive: true);
      final newerGlibc = await capture('chroot', [
        root.path,
        '/usr/bin/portageq',
        'best_version',
        '/',
        '>$glibcName-$glibcVersion-r999999',
      ]);
      if (newerGlibc.isNotEmpty) {
        throw BuildFailure(
          'The Gentoo image needs $newerGlibc but ekuOS glibc is $glibcVersion.',
        );
      }

      await write('/var/db/repos/civilight/profiles/repo_name', 'civilight\n');
      await write('/var/db/repos/civilight/metadata/layout.conf', '''
masters = gentoo
thin-manifests = true
''');
      await copyPortageConfig('repos.conf/civilight.conf');
      await mergePayload(
        kernelName,
        kernel.version,
        kernelPayload,
        slot: '0',
        license: 'GPL-2',
        description: 'ekuOS AppArmor kernel',
      );
      // Gentoo installs the time zone utilities through sys-libs/timezone-data.
      for (final name in ['tzselect', 'zdump', 'zic']) {
        final file = File('${glibcPayload.path}/usr/bin/$name');
        if (await file.exists()) await file.delete();
      }
      for (final path in [
        '/etc/env.d/00glibc',
        '/etc/gai.conf',
        '/etc/host.conf',
        '/etc/nsswitch.conf',
        '/etc/rpc',
      ]) {
        final existing = File(at(path));
        final destination = File('${glibcPayload.path}$path');
        if (await existing.exists() && !await destination.exists()) {
          await destination.parent.create(recursive: true);
          await existing.copy(destination.path);
        }
      }
      await mergePayload(
        glibcName,
        glibcVersion,
        glibcPayload,
        slot: '2.2',
        license: 'LGPL-2.1+ BSD HPND ISC inner-net rc PCRE',
        description: 'ekuOS GNU C Library with mimalloc',
        use: '+cet +multiarch +ssp +static-libs',
      );
      await copyPortageConfig('package.mask/civilight');
      await inside(['ldconfig']);
      await inside(['/usr/lib64/libc.so.6']);
      await inside(['chpasswd', '--encrypted'], input: 'root:$passwordHash\n');
      await inside([
        'dracut',
        '--force',
        '--no-hostonly',
        '--no-hostonly-cmdline',
        '--no-early-microcode',
        '--kver',
        kernel.release,
        '/var/tmp/civilight.initrd',
      ]);
      await File(at('/var/tmp/civilight.initrd')).rename(initrd.path);
      final buildState = Directory(at('/var/tmp/portage'));
      if (await buildState.exists()) await buildState.delete(recursive: true);
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
    await write(
      '/etc/systemd/system/local-fs.target.d/civilight-growfs.conf',
      '''
[Unit]
Wants=systemd-growfs-root.service
After=systemd-growfs-root.service
''',
    );
    await Directory(at('/efi')).create();
    await run('chmod', ['0700', at('/efi')]);
    await write(
      '/efi/loader/loader.conf',
      'default civilight-${kernel.release}.efi\n',
    );
    await write('/etc/machine-id', '');
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

  Future<void> mergePayload(
    String name,
    String version,
    Directory payload, {
    required String slot,
    required String license,
    required String description,
    String use = '',
  }) async {
    final pf = '${name.split('/').last}-$version';
    final ebuild = '/var/db/repos/civilight/$name/$pf.ebuild';
    // Dart supplies the prepared image after the empty install phase.
    // Portage then packages it and merges it through its binary package path.
    await write(ebuild, '''
EAPI=8
DESCRIPTION="$description"
HOMEPAGE="https://github.com/ekuOS"
LICENSE="$license"
SLOT="$slot"
KEYWORDS="amd64"
IUSE="$use"
RESTRICT="strip"
S="\${WORKDIR}"
''');
    await inside(['ebuild', '--skip-manifest', ebuild, 'clean', 'install']);
    final buildDir = '/var/tmp/portage/${name.split('/').first}/$pf';
    final packageRoot = '$buildDir/image';
    await run('cp', ['-a', '${payload.path}/.', at(packageRoot)]);
    if (name == glibcName) await recordGlibcLinkage(buildDir);
    await inside([
      'FEATURES=noauto -binpkg-signing',
      'ebuild',
      '--skip-manifest',
      ebuild,
      'package',
    ]);
    await inside([
      'emerge',
      '--color=n',
      '--usepkgonly',
      '--oneshot',
      '--nodeps',
      '=$name-$version::civilight',
    ]);
    final installed = '/var/db/pkg/${name.split('/').first}/$pf';
    if ((await File(at('$installed/repository')).readAsString()).trim() !=
        'civilight') {
      throw BuildFailure('Portage did not record $name from civilight.');
    }
    await inside(['ebuild', '--skip-manifest', ebuild, 'clean']);
    await File(at(ebuild)).delete();
  }

  Future<void> recordGlibcLinkage(String buildDir) async {
    // Portage's install-time ELF scan ran before Dart supplied the payload.
    // Preserve its normal ABI index for dependency resolution and upgrades.
    final scan = await capture('chroot', [
      root.path,
      '/usr/bin/scanelf',
      '-yRBF',
      '%a;%p;%S;%r;%n',
      '$buildDir/image/',
    ]);
    final provides = <String>{};
    final requires = <String>{};
    final linkage = <String>[];
    for (final line in scan.split('\n')) {
      final fields = line.split(';');
      if (fields.length != 5 || fields[0] != 'EM_X86_64') {
        throw BuildFailure('Unexpected ELF metadata in ekuOS glibc: $line');
      }
      final path = '/${fields[1]}';
      final soname = fields[2].isEmpty && path.endsWith('.so')
          ? path.split('/').last
          : fields[2];
      final rpath = fields[3].trim() == '-' ? '' : fields[3];
      final needed = fields[4];
      if (soname.isNotEmpty) {
        provides.add(soname);
      }
      requires.addAll(needed.split(',').where((library) => library.isNotEmpty));
      linkage.add('X86_64;$path;$soname;$rpath;$needed;x86_64');
    }
    if (!provides.containsAll(['libc.so.6', 'ld-linux-x86-64.so.2'])) {
      throw const BuildFailure(
        'ekuOS glibc ELF metadata omits libc or its loader.',
      );
    }
    await write('$buildDir/build-info/NEEDED.ELF.2', '${linkage.join('\n')}\n');
    await write(
      '$buildDir/build-info/PROVIDES',
      'x86_64: ${(provides.toList()..sort()).join(' ')}',
    );
    requires.removeAll(provides);
    if (requires.isNotEmpty) {
      await write(
        '$buildDir/build-info/REQUIRES',
        'x86_64: ${(requires.toList()..sort()).join(' ')}',
      );
    }
  }
}
