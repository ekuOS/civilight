import 'dart:io';

import 'commands.dart';

const kernelName = 'sys-kernel/linux-eku';
const glibcName = 'sys-libs/glibc';

Future<Directory> buildKernel(
  Directory checkout,
  Directory work,
  int jobs,
) async {
  final config = File('${work.path}/linux-eku.conf');
  await config.writeAsString('''
${await File('${checkout.path}/eku.conf').readAsString()}
CONFIG_BTRFS_FS=y
CONFIG_BTRFS_FS_POSIX_ACL=y
CONFIG_BLK_DEV_NVME=y
''');
  await run(Platform.resolvedExecutable, [
    'run',
    'build.dart',
    '--flavor',
    'aa',
    '--config',
    config.path,
    '--output',
    '${work.path}/kernel-build',
    '--artifacts',
    '${work.path}/kernel-out',
    '--jobs',
    '$jobs',
  ], cwd: checkout.path);
  return Directory('${work.path}/kernel-out/linux-eku-aa');
}

class Kernel {
  Kernel(this.artifacts, this.release, this.version);
  final Directory artifacts;
  final String release;
  final String version;

  static Future<Kernel> read(Directory artifacts) async {
    final release = (await File(
      '${artifacts.path}/kernel.release',
    ).readAsString()).trim();
    final match = RegExp(r'^(\d+\.\d+(?:\.\d+)?)(?:-rc(\d+))?-eku-aa$')
        .firstMatch(release);
    if (match == null)
      throw BuildFailure('Expected an AppArmor kernel release, got $release.');
    final config = (await File(
      '${artifacts.path}/.config',
    ).readAsLines()).toSet();
    for (final option in [
      'BTRFS_FS',
      'BLK_DEV_NVME',
      'EFI_STUB',
      'BLK_DEV_INITRD',
      'SECURITY_APPARMOR',
      'MODULE_SIG_FORCE',
    ]) {
      if (!config.contains('CONFIG_$option=y')) {
        throw BuildFailure('$release requires CONFIG_$option=y.');
      }
    }
    final version = match[2] == null ? match[1]! : '${match[1]}_rc${match[2]}';
    return Kernel(artifacts, release, version);
  }

  Future<void> stage(Directory payload) async {
    final modules = await Directory('${payload.path}/usr/lib/modules/$release')
        .create(recursive: true);
    final source = artifacts.path;
    for (final (from, to) in [
      ('bzImage', 'vmlinuz'),
      ('.config', 'config'),
      ('System.map', 'System.map'),
      ('modules.builtin', 'modules.builtin'),
      ('modules.builtin.modinfo', 'modules.builtin.modinfo'),
      ('signing_key.x509', 'signing_key.x509'),
    ]) {
      await File('$source/$from').copy('${modules.path}/$to');
    }
    final order = <String>[];
    for (final line in await File('$source/modules.order').readAsLines()) {
      final path = line.trim().replaceFirst(RegExp(r'\.o$'), '.ko');
      if (path.isEmpty) continue;
      if (!RegExp(r'^[\w./+-]+\.ko$').hasMatch(path) ||
          path.startsWith('/') ||
          path.split('/').contains('..')) {
        throw BuildFailure('Invalid modules.order entry: $line');
      }
      final installed = 'kernel/$path';
      final target = File('${modules.path}/$installed');
      await target.parent.create(recursive: true);
      await File('$source/modules/$path').copy(target.path);
      order.add(installed);
    }
    await File('${modules.path}/modules.order')
        .writeAsString('${order.join('\n')}\n');
    await run('depmod', ['--basedir', payload.path, release]);
  }
}

Future<String> stageGlibc(
  Directory checkout,
  Directory payload,
  int jobs,
) async {
  await run(Platform.resolvedExecutable, [
    'run',
    'build.dart',
    '--jobs',
    '$jobs',
  ], cwd: checkout.path);
  final source = '${checkout.path}/glibc/src';
  final versionHeader = await File('$source/version.h').readAsString();
  final version = RegExp(
    r'^#define VERSION "(\d+\.\d+(?:\.\d+)?)"$',
    multiLine: true,
  ).firstMatch(versionHeader)?[1];
  if (version == null || !await File('$source/malloc/eku-malloc.c').exists()) {
    throw const BuildFailure('Could not identify the ekuOS glibc build.');
  }
  await run('make', [
    '-j$jobs',
    'ekuos-mimalloc-object=${checkout.path}/mimmaloc/build/mimalloc.o',
    'DESTDIR=${payload.path}',
    'install',
  ], cwd: '${checkout.path}/glibc/build');

  // The x86-64 glibc build uses /lib64 and /sbin. Gentoo's usr-merged
  // stage3 implements those paths as symlinks.
  for (final (from, to) in [
    ('lib64', 'usr/lib64'),
    ('sbin', 'usr/bin'),
    ('usr/sbin', 'usr/bin'),
  ]) {
    final old = Directory('${payload.path}/$from');
    if (!await old.exists()) continue;
    final target = await Directory('${payload.path}/$to')
        .create(recursive: true);
    for (final entry in await old.list(followLinks: false).toList()) {
      await entry.rename(
        '${target.path}/${entry.uri.pathSegments.where((s) => s.isNotEmpty).last}',
      );
    }
    await old.delete();
  }
  for (final name in ['libc.so.6', 'ld-linux-x86-64.so.2', 'libc.a']) {
    if (!await File('${payload.path}/usr/lib64/$name').exists()) {
      throw BuildFailure('ekuOS glibc installation lacks /usr/lib64/$name.');
    }
  }
  final info = await Directory('${payload.path}/usr/share/doc/glibc-$version')
      .create(recursive: true);
  await File('${info.path}/ekuOS')
      .writeAsString('https://github.com/ekuOS/glibc\n');
  return version;
}
