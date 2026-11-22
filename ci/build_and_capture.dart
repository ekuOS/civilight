import 'dart:io';

import '../lib/commands.dart';
import '../lib/gentoo.dart' show download;
import 'capture_login.dart';

const weeklyKey = '13EBBDBEDE7A12775DFDB1BABB572E0E2D182910';

Future<void> inside(String? flavor) async {
  final dart = Platform.resolvedExecutable;
  await run('dnf', [
    '-y',
    'install',
    'binutils',
    'btrfs-progs',
    'curl',
    'dosfstools',
    'edk2-ovmf',
    'glibc-gconv-extra',
    'gnupg2',
    'mkosi',
    'mtools',
    'openssl',
    flavor == null ? 'qemu-system-x86-core' : 'qemu-system-x86',
    'systemd',
    'systemd-udev',
    'systemd-ukify',
    'tar',
    'tesseract',
    'tesseract-langpack-eng',
    'util-linux',
    'xz',
  ]);
  const work = '/work';
  final gnupg = await Directory('$work/gnupg').create();
  await run('chmod', ['0700', gnupg.path]);
  final gpg = ['--batch', '--homedir', gnupg.path];
  final publicKey = '$work/gentoo.asc';
  await download(
    'https://keys.gentoo.org/pks/lookup?op=get&search=0x$weeklyKey',
    publicKey,
  );
  await run('gpg', [...gpg, '--import', publicKey]);
  final keyring = '$work/gentoo-release.gpg';
  await run('gpg', [...gpg, '--output', keyring, '--export', weeklyKey]);
  if (!await File(keyring).exists() || await File(keyring).length() == 0) {
    throw const BuildFailure('The pinned Gentoo release key was not found.');
  }

  // The screenshot must not include any password. The random password is
  // never printed, and the disk and hash are not uploaded.
  final random = await capture('openssl', ['rand', '-base64', '32']);
  final password = '$work/root-password.hash';
  await run('install', ['-m', '0600', '/dev/null', password]);
  final hash = await Process.start('openssl', ['passwd', '-6', '-stdin']);
  final result = hash.stdout.pipe(File(password).openWrite());
  final errors = hash.stderr.transform(systemEncoding.decoder).join();
  hash.stdin.writeln(random);
  await hash.stdin.close();
  final status = await hash.exitCode;
  await result;
  final diagnostic = await errors;
  if (status != 0)
    throw BuildFailure('Could not hash the CI password: $diagnostic');
  final image = File('$work/civilight.raw');
  await run(dart, [
    'run',
    '/src/build.dart',
    if (flavor != null) ...['--src', flavor, '--root-size-gib', '16'],
    '--gentoo-keyring',
    keyring,
    '--root-password-file',
    password,
    '--jobs',
    '${Platform.numberOfProcessors}',
    '--output',
    image.path,
  ]);
  await captureLogin(
    image,
    File('/usr/share/edk2/ovmf/OVMF.stateless.fd'),
    Directory('/artifacts'),
    gui: flavor != null,
  );
}

Future<void> inDocker(String? flavor) async {
  final repo = File.fromUri(Platform.script).parent.parent;
  final artifacts = await Directory(
    '${repo.path}/out/ci/${flavor == null ? 'minimal' : 'flavor-$flavor'}',
  ).create(recursive: true);
  final sdk = File(Platform.resolvedExecutable).parent.parent.path;
  final temp = Platform.environment['RUNNER_TEMP'] ?? Directory.systemTemp.path;
  // Hosted runners may have a separate, larger temporary disk mounted on /mnt.
  String? parent;
  for (final path in ['/mnt', temp]) {
    if (!await Directory(path).exists()) continue;
    try {
      await requireSpace(path, 18 * gib);
      parent = path;
      break;
    } on BuildFailure {
      continue;
    }
  }
  if (parent == null) {
    throw const BuildFailure(
      'CI needs an 18 GiB build workspace on /mnt or RUNNER_TEMP.',
    );
  }
  final work = await capture('sudo', [
    'mktemp',
    '-d',
    '$parent/civilight-ci.XXXXXXXX',
  ]);
  try {
    // The image builder creates mount and PID namespaces and chroots into
    // Gentoo. The container also supplies mkosi 26 and recent systemd tooling.
    await run('docker', [
      'run',
      '--rm',
      '--privileged',
      '--network=host',
      '--mount',
      'type=bind,src=${repo.path},dst=/src,readonly',
      '--mount',
      'type=bind,src=$sdk,dst=/dart,readonly',
      '--mount',
      'type=bind,src=$work,dst=/work',
      '--mount',
      'type=bind,src=${artifacts.path},dst=/artifacts',
      '--workdir',
      '/work',
      'docker.io/library/fedora:44',
      '/dart/bin/dart',
      '/src/ci/build_and_capture.dart',
      '--inside',
      if (flavor != null) ...['--src', flavor],
    ]);
  } finally {
    await run('sudo', ['rm', '-rf', '--', work]);
  }
}

Future<void> main(List<String> args) async {
  try {
    final container = args.isNotEmpty && args.first == '--inside';
    final options = container ? args.sublist(1) : args;
    if (options.isNotEmpty &&
        (options.length != 2 ||
            options.first != '--src' ||
            !RegExp(r'^[a-z0-9][a-z0-9_-]*$').hasMatch(options.last))) {
      throw const BuildFailure(
        'Usage: dart run ci/build_and_capture.dart [--src NAME]',
      );
    }
    final flavor = options.isEmpty ? null : options.last;
    await (container ? inside(flavor) : inDocker(flavor));
  } on Exception catch (error) {
    stderr.writeln('[ERROR] $error');
    exitCode = 1;
  }
}
