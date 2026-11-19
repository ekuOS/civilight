import 'dart:io';

import 'commands.dart';

const kernelName = 'sys-kernel/linux-eku';

Future<Directory> buildKernel(
  Directory checkout,
  Directory work,
  int jobs,
) async {
  await run(
    Platform.resolvedExecutable,
    [
      'run',
      'build.dart',
      '--flavor',
      'aa',
      '--output',
      '${work.path}/kernel-build',
      '--artifacts',
      '${work.path}/kernel-out',
      '--jobs',
      '$jobs',
    ],
    cwd: checkout.path,
    environment: {'TMPDIR': work.path},
  );
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
    await run('depmod', [
      '--basedir',
      payload.path,
      '--moduledir',
      '/usr/lib/modules',
      release,
    ]);
  }
}
