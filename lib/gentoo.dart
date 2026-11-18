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
  Gentoo(this.root, this.jobs);
  final Directory root;
  final int jobs;
  String at(String path) => '${root.path}$path';

  Future<void> write(String path, String contents) async {
    final file = File(at(path));
    await file.parent.create(recursive: true);
    await file.writeAsString(contents);
  }

  Future<void> inside(List<String> args, {String? input}) => run('chroot', [
    root.path,
    '/usr/bin/env',
    '-i',
    'PATH=/usr/bin:/usr/sbin:/bin:/sbin',
    'HOME=/root',
    'TERM=dumb',
    'LC_ALL=C.UTF-8',
    'MAKEOPTS=-j$jobs',
    ...args,
  ], input: input);

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
    final mounted = <String>[];
    try {
      for (final name in ['/dev', '/sys', '/proc']) {
        final target = at(name);
        await run('mount', [
          name == '/proc' ? '--bind' : '--rbind',
          name,
          target,
        ]);
        mounted.add(target);
      }
      await File('/etc/resolv.conf').copy(at('/etc/resolv.conf'));
      await write('/etc/portage/package.use/civilight', '''
sys-apps/systemd boot kernel-install apparmor
sys-kernel/dracut systemd
''');
      await inside(['emerge-webrsync']);
      await inside([
        'emerge',
        '--color=n',
        '--getbinpkg',
        '--oneshot',
        'sys-apps/systemd',
        'sys-kernel/dracut',
        'sys-apps/kmod',
        'sys-apps/apparmor',
        'sys-apps/apparmor-utils',
        'sys-fs/btrfs-progs',
      ]);
      if (packages.isNotEmpty) {
        await inside(['emerge', '--color=n', '--getbinpkg', ...packages]);
      }

      await write('/var/db/repos/civilight/profiles/repo_name', 'civilight\n');
      await write('/var/db/repos/civilight/metadata/layout.conf', '''
masters = gentoo
thin-manifests = true
''');
      await write('/etc/portage/repos.conf/civilight.conf', '''
[civilight]
location = /var/db/repos/civilight
auto-sync = no
priority = 100
''');
      await mergePayload(
        kernelName,
        kernel.version,
        kernelPayload,
        slot: '0',
        license: 'GPL-2',
        description: 'ekuOS AppArmor kernel',
      );
      await mergePayload(
        glibcName,
        glibcVersion,
        glibcPayload,
        slot: '2.2',
        license: 'LGPL-2.1+ BSD HPND ISC inner-net rc PCRE',
        description: 'ekuOS GNU C Library with mimalloc',
        use: '+cet +multiarch +ssp +static-libs',
      );
      await write(
        '/etc/portage/package.mask/civilight',
        'sys-libs/glibc::gentoo\n',
      );
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
      if (!await File(at('/usr/lib/systemd/boot/efi/systemd-bootx64.efi'))
              .exists() ||
          !await File(at('/usr/lib/systemd/systemd')).exists()) {
        throw const BuildFailure(
          'Gentoo systemd or its x86-64 EFI boot manager is missing.',
        );
      }
    } finally {
      for (final mount in mounted.reversed) {
        await run('umount', ['--lazy', mount]);
      }
    }

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
    await Directory(at('/efi')).create();
    await write('/etc/machine-id', '');
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
    // Portage runs the standard phases. Dart supplies the prepared image
    // between install and qmerge so no custom ebuild phase scripts are needed.
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
    await inside(['ebuild', '--skip-manifest', ebuild, 'install']);
    final packageRoot = '/var/tmp/portage/${name.split('/').first}/$pf/image';
    await run('cp', ['-a', '${payload.path}/.', at(packageRoot)]);
    await inside([
      'FEATURES=noauto -binpkg-signing',
      'ebuild',
      '--skip-manifest',
      ebuild,
      'package',
      'qmerge',
    ]);
    final installed = '/var/db/pkg/${name.split('/').first}/$pf';
    if ((await File(at('$installed/repository')).readAsString()).trim() !=
        'civilight') {
      throw BuildFailure('Portage did not record $name from civilight.');
    }
    await File(at(ebuild)).delete();
  }
}
