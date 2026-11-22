#!/usr/bin/env dart

import 'dart:io';

import 'lib/commands.dart';

const usage = '''
Usage: dart run run.dart [--firmware FILE] [--persist] [IMAGE.raw]

Boot a Civilight image in a QEMU/KVM GTK window with a serial console.
The default image is out/civilight.raw beside this script.
Guest disk changes are temporary unless --persist is supplied.
The default firmware is /usr/share/edk2/ovmf/OVMF.stateless.fd.
''';

Future<void> main(List<String> args) async {
  try {
    if (args.contains('--help')) {
      stdout.write(usage);
      return;
    }
    if (!Platform.isLinux || await capture('uname', ['-m']) != 'x86_64') {
      throw const BuildFailure('An x86-64 Linux host is required for KVM.');
    }
    String? firmware;
    String? image;
    var persist = false;
    for (var index = 0; index < args.length; index++) {
      final arg = args[index];
      if (arg == '--firmware' && firmware == null) {
        if (++index == args.length || args[index].startsWith('--')) {
          throw const BuildFailure('Missing file for --firmware.');
        }
        firmware = args[index];
      } else if (arg == '--persist' && !persist) {
        persist = true;
      } else if (!arg.startsWith('-') && image == null) {
        image = arg;
      } else {
        throw BuildFailure('Unexpected argument: $arg.');
      }
    }
    final disk = File(
      image ?? Platform.script.resolve('out/civilight.raw').toFilePath(),
    ).absolute;
    if (!await disk.exists() || await disk.length() == 0) {
      throw BuildFailure('Image file missing or empty: ${disk.path}.');
    }
    final ovmf = File(firmware ?? '/usr/share/edk2/ovmf/OVMF.stateless.fd')
        .absolute;
    if (!await ovmf.exists()) {
      throw BuildFailure(
        'OVMF firmware not found: ${ovmf.path}. Use --firmware FILE.',
      );
    }
    const qemu = 'qemu-system-x86_64';
    final displays = await capture(qemu, ['-display', 'help']);
    if (!RegExp(r'^\s*gtk\s*$', multiLine: true).hasMatch(displays)) {
      throw const BuildFailure(
        'QEMU GTK display is unavailable. On Fedora, install qemu-ui-gtk.',
      );
    }
    final process = await Process.start(qemu, [
      '-name',
      'ekuOS-civilight',
      '-machine',
      'q35,accel=kvm',
      '-cpu',
      'host',
      '-smp',
      '2',
      '-m',
      '4096',
      '-bios',
      ovmf.path,
      '-drive',
      "file=${disk.path.replaceAll(',', ',,')},format=raw,if=virtio",
      '-display',
      'gtk,show-tabs=on,gl=on',
      '-vga',
      'none',
      '-device',
      'virtio-vga-gl',
      '-monitor',
      'none',
      '-serial',
      'vc',
      if (!persist) '-snapshot',
    ], mode: ProcessStartMode.inheritStdio);
    exitCode = await process.exitCode;
  } on Exception catch (error) {
    stderr.writeln('[ERROR] $error');
    exitCode = 1;
  }
}
