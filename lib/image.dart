import 'dart:convert';
import 'dart:io';

import 'commands.dart';

const espType = 'c12a7328-f81f-11d2-ba4b-00a0c93ec93b';
const rootType = '4f68bce3-e8cd-4db1-96e7-fbcaf984b709'; // x86-64 root

Future<void> verifyBootImage(File image, String release, Directory work) async {
  final report = jsonDecode(await capture('sfdisk', ['--json', image.path]));
  final table = report['partitiontable'];
  if (table['label'] != 'gpt' || table['sectorsize'] != 512) {
    throw const BuildFailure('Expected a GPT image with 512-byte sectors.');
  }
  final partitions = table['partitions'] as List;
  final esp = partitions.where((p) => p['type'].toLowerCase() == espType);
  final root = partitions.where((p) => p['type'].toLowerCase() == rootType);
  if (esp.length != 1 || root.length != 1) {
    throw const BuildFailure('Expected one EFI and one x86-64 root partition.');
  }
  final sectorSize = table['sectorsize'] as int;
  final rootOffset = (root.single['start'] as int) * sectorSize;
  final rootSize = (root.single['size'] as int) * sectorSize;
  final rootFs = await capture('blkid', [
    '--probe',
    '--offset',
    '$rootOffset',
    '--size',
    '$rootSize',
    '--match-tag',
    'TYPE',
    '--output',
    'value',
    image.path,
  ]);
  if (rootFs != 'btrfs') {
    throw BuildFailure('Expected a Btrfs root filesystem, found $rootFs.');
  }
  final offset = (esp.single['start'] as int) * sectorSize;
  final fat = '${image.path}@@$offset';
  final loader = '${work.path}/verify-bootx64.efi';
  await run('mcopy', ['-i', fat, '::/EFI/BOOT/BOOTX64.EFI', loader]);
  if (await File(loader).length() == 0) {
    throw const BuildFailure('The UEFI fallback loader is empty.');
  }
  final uki = '${work.path}/verify-uki.efi';
  await run('mcopy', ['-i', fat, '::/EFI/Linux/civilight-$release.efi', uki]);

  final ukify = await File('/usr/lib/systemd/ukify').exists()
      ? '/usr/lib/systemd/ukify'
      : 'ukify';
  final sections = jsonDecode(
    await capture(ukify, ['inspect', uki, '--json=short', '--all']),
  );
  final cmdline =
      (sections['.cmdline']?['text'] as String?)?.trim().split(
        RegExp(r'\s+'),
      ) ??
      const <String>[];
  final roots = cmdline.where((arg) => arg.startsWith('root=')).toList();
  final uuid = (root.single['uuid'] as String).toLowerCase();
  if (roots.length != 1 ||
      roots.single.toLowerCase() != 'root=partuuid=$uuid' ||
      !cmdline.contains('rootfstype=btrfs') ||
      sections['.uname']?['text']?.trim() != release ||
      (sections['.linux']?['size'] ?? 0) <= 0 ||
      (sections['.initrd']?['size'] ?? 0) <= 0) {
    throw const BuildFailure(
      'The EFI image does not contain the expected kernel, initramfs, and root PARTUUID.',
    );
  }
}
