import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../lib/commands.dart';

/// Count distinct colours in a binary PPM screenshot. The Linux text console
/// uses a tiny fixed palette, while a graphical greeter has antialiased text
/// and background shading. This is independent of OCR accuracy and locale.
Future<int> distinctColors(File ppm) async {
  final bytes = await ppm.readAsBytes();
  var offset = 0;
  String token() {
    while (offset < bytes.length &&
        const [32, 9, 10, 13].contains(bytes[offset])) {
      offset++;
    }
    if (bytes[offset] == 35) {
      while (offset < bytes.length && bytes[offset] != 10) {
        offset++;
      }
      return token();
    }
    final start = offset;
    while (offset < bytes.length &&
        !const [32, 9, 10, 13].contains(bytes[offset])) {
      offset++;
    }
    return ascii.decode(bytes.sublist(start, offset));
  }

  if (token() != 'P6') throw const BuildFailure('Unexpected PPM header.');
  final width = int.parse(token());
  final height = int.parse(token());
  if (int.parse(token()) != 255) {
    throw const BuildFailure('Unexpected PPM depth.');
  }
  while (offset < bytes.length &&
      const [32, 9, 10, 13].contains(bytes[offset])) {
    offset++;
  }
  final pixels = width * height;
  if (bytes.length - offset < pixels * 3) {
    throw const BuildFailure('Truncated PPM screenshot.');
  }
  final colors = <int>{};
  final step = pixels > 100000 ? pixels ~/ 100000 : 1;
  for (var pixel = 0; pixel < pixels; pixel += step) {
    final at = offset + pixel * 3;
    colors.add((bytes[at] << 16) | (bytes[at + 1] << 8) | bytes[at + 2]);
    if (colors.length > 4000) break;
  }
  return colors.length;
}

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

enum LoginScreen { console, gdm, sddm, tuigreet }

/// Wayland greeters need a GL-capable virtio device. Probe a headless EGL
/// context so a host without GL falls back to the software frame buffer.
Future<bool> qemuGlAvailable() async {
  final process = await Process.start('qemu-system-x86_64', [
    '-nodefaults',
    '-machine',
    'q35,accel=tcg',
    '-display',
    'egl-headless,gl=on',
    '-device',
    'virtio-vga-gl',
    '-S',
    '-monitor',
    'none',
    '-serial',
    'none',
  ]);
  final exited = await Future.any([
    process.exitCode.then((_) => true),
    Future<bool>.delayed(const Duration(seconds: 4), () => false),
  ]);
  process.kill();
  await process.exitCode;
  return !exited;
}

/// Each desktop flavor is verified through its own display manager.
LoginScreen loginScreenFor(String? flavor) => switch (flavor) {
  null => LoginScreen.console,
  'gnome' => LoginScreen.gdm,
  'plasma' => LoginScreen.sddm,
  'sway' => LoginScreen.tuigreet,
  _ => throw BuildFailure('Add a login screen check for flavor $flavor.'),
};

Future<void> captureLogin(
  File image,
  File firmware,
  Directory artifacts, {
  LoginScreen loginScreen = LoginScreen.console,
}) async {
  await artifacts.create(recursive: true);
  final graphical =
      loginScreen == LoginScreen.gdm || loginScreen == LoginScreen.sddm;
  final gl = graphical && await qemuGlAvailable();
  if (graphical) {
    stdout.writeln(
      gl
          ? 'Using virtio-gpu with OpenGL for the Wayland greeter.'
          : 'Host OpenGL is unavailable; using the guest software renderer.',
    );
  }
  final scratch = await Directory.systemTemp.createTemp('civilight-qemu-');
  try {
    final monitor = '${scratch.path}/qmp';
    final serial = File('${artifacts.path}/serial.log');
    final screen = File('${scratch.path}/screen.png');
    final ppm = File('${scratch.path}/screen.ppm');
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
      graphical ? '4096' : '2048',
      '-bios',
      firmware.absolute.path,
      if (gl) ...[
        '-display',
        'egl-headless,gl=on',
        '-vga',
        'none',
        '-device',
        'virtio-vga-gl',
      ] else ...[
        '-display',
        'none',
        '-vga',
        graphical ? 'virtio' : 'std',
      ],
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
      final deadline = DateTime.now().add(
        Duration(minutes: graphical ? 15 : 8),
      );
      while (DateTime.now().isBefore(deadline)) {
        if (stopped != null) throw BuildFailure('QEMU exited ($stopped).');
        if ((loginScreen != LoginScreen.console &&
                await FileSystemEntity.type(monitor) !=
                    FileSystemEntityType.notFound) ||
            (await serial.exists() &&
                utf8
                    .decode(await serial.readAsBytes(), allowMalformed: true)
                    .contains('civilight login:'))) {
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
          await qmp.command('screendump', {
            'filename': ppm.path,
            'format': 'ppm',
          });
          final colors = await distinctColors(ppm);
          stdout.writeln('Guest screen has $colors distinct colours.');
          final text = await capture('tesseract', [
            screen.path,
            'stdout',
            '--psm',
            '11',
          ]);
          await File('${artifacts.path}/screen.txt').writeAsString(text);
          final prompt = RegExp(r'\bcivilight\s+login\b', caseSensitive: false);
          // Never accept the tty1 getty behind a greeter. The greeters differ
          // in wording and OCR quality, so accept any of their own labels.
          final ready = switch (loginScreen) {
            LoginScreen.console => prompt.hasMatch(text),
            LoginScreen.gdm || LoginScreen.sddm =>
              !prompt.hasMatch(text) &&
                  (colors > 32 ||
                      RegExp(
                        r'\b(?:log\s*in|login|password|username|not\s+listed)\b',
                        caseSensitive: false,
                      ).hasMatch(text)),
            LoginScreen.tuigreet =>
              !prompt.hasMatch(text) &&
                  RegExp(
                    r'\b(?:username|sway|password)\b',
                    caseSensitive: false,
                  ).hasMatch(text),
          };
          if (ready) {
            final screenshot = await screen.copy(
              '${artifacts.path}/${graphical ? 'gui' : 'login'}.png',
            );
            stdout.writeln(
              'Captured the guest login screen: ${screenshot.path}',
            );
            return;
          }
        }
        await Future<void>.delayed(
          Duration(seconds: loginScreen == LoginScreen.console ? 2 : 5),
        );
      }
      if (await screen.exists()) {
        await screen.copy('${artifacts.path}/last-screen.png');
      }
      if (await serial.exists()) {
        final boot = utf8.decode(
          await serial.readAsBytes(),
          allowMalformed: true,
        );
        final lines = const LineSplitter().convert(boot);
        stdout.writeln('--- last serial output ---');
        stdout.writeln(
          lines.skip(lines.length > 40 ? lines.length - 40 : 0).join('\n'),
        );
      }
      throw BuildFailure(
        'QEMU did not show the ${loginScreen.name} login prompt. See the boot artifacts.',
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
