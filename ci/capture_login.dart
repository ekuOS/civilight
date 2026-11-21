import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../lib/commands.dart';

class Qmp {
  Qmp(this.socket)
    : messages = StreamIterator(
        socket
            .cast<List<int>>()
            .transform(utf8.decoder)
            .transform(const LineSplitter()),
      );

  final Socket socket;
  final StreamIterator<String> messages;

  Future<Map<String, dynamic>> read() async {
    if (!await messages.moveNext().timeout(const Duration(seconds: 10))) {
      throw const BuildFailure('QEMU closed its monitor.');
    }
    return jsonDecode(messages.current) as Map<String, dynamic>;
  }

  Future<void> command(String name, [Map<String, Object>? arguments]) async {
    socket.writeln(
      jsonEncode({
        'execute': name,
        if (arguments != null) 'arguments': arguments,
      }),
    );
    while (true) {
      final reply = await read();
      if (reply.containsKey('event')) continue;
      if (reply.containsKey('return')) return;
      throw BuildFailure('QEMU $name failed: $reply');
    }
  }

  Future<void> close() async {
    socket.destroy();
    await messages.cancel();
  }
}

Future<void> captureLogin(
  File image,
  File firmware,
  Directory artifacts,
) async {
  await artifacts.create(recursive: true);
  final scratch = await Directory.systemTemp.createTemp('civilight-qemu-');
  try {
    final monitor = '${scratch.path}/qmp';
    final serial = File('${artifacts.path}/serial.log');
    final screen = File('${scratch.path}/screen.png');
    final qemu = await Process.start('qemu-system-x86_64', [
      if (Platform.environment['QEMU_FIRMWARE_DIR'] case final String path) ...[
        '-L',
        path,
      ],
      '-machine',
      'q35,accel=tcg',
      '-cpu',
      'max',
      '-smp',
      '2',
      '-m',
      '2048',
      '-bios',
      firmware.absolute.path,
      '-display',
      'none',
      '-vga',
      'std',
      '-nic',
      'none',
      '-monitor',
      'none',
      '-serial',
      'file:${serial.absolute.path}',
      '-qmp',
      'unix:$monitor,server=on,wait=off',
      '-drive',
      'file=${image.absolute.path.replaceAll(',', ',,')},format=raw,if=none,id=os,snapshot=on',
      '-device',
      'nvme,drive=os,serial=civilight',
      '-no-reboot',
    ], mode: ProcessStartMode.inheritStdio);
    int? stopped;
    unawaited(qemu.exitCode.then((code) => stopped = code));
    Qmp? qmp;
    try {
      final deadline = DateTime.now().add(const Duration(minutes: 8));
      while (DateTime.now().isBefore(deadline)) {
        if (stopped != null) throw BuildFailure('QEMU exited ($stopped).');
        if (await serial.exists() &&
            utf8
                .decode(await serial.readAsBytes(), allowMalformed: true)
                .contains('civilight login:')) {
          if (qmp == null) {
            qmp = Qmp(
              await Socket.connect(
                InternetAddress(monitor, type: InternetAddressType.unix),
                0,
              ),
            );
            if (!(await qmp.read()).containsKey('QMP')) {
              throw const BuildFailure('Invalid QEMU monitor greeting.');
            }
            await qmp.command('qmp_capabilities');
          }
          await qmp.command('screendump', {
            'filename': screen.path,
            'format': 'png',
          });
          final text = await capture('tesseract', [
            screen.path,
            'stdout',
            '--psm',
            '11',
          ]);
          if (RegExp(
            r'\bcivilight\s+login\b',
            caseSensitive: false,
          ).hasMatch(text)) {
            final screenshot = await screen.copy('${artifacts.path}/login.png');
            stdout.writeln(
              'Captured the guest login screen: ${screenshot.path}',
            );
            return;
          }
        }
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      if (await screen.exists()) {
        await screen.copy('${artifacts.path}/last-screen.png');
      }
      throw const BuildFailure(
        'QEMU did not show the graphical login prompt. See the boot artifacts.',
      );
    } finally {
      await qmp?.close();
      qemu.kill();
      await qemu.exitCode;
    }
  } finally {
    await scratch.delete(recursive: true);
  }
}

Future<void> main(List<String> args) async {
  try {
    if (args.length != 3) {
      throw const BuildFailure(
        'Usage: dart run ci/capture_login.dart IMAGE.raw OVMF.fd ARTIFACTS',
      );
    }
    await captureLogin(File(args[0]), File(args[1]), Directory(args[2]));
  } on Exception catch (error) {
    stderr.writeln('[ERROR] $error');
    exitCode = 1;
  }
}
