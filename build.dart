#!/usr/bin/env dart

import 'dart:io';

import 'lib/commands.dart';
import 'lib/eku.dart';
import 'lib/gentoo.dart';

const usage = '''
Usage: dart run build.dart --gentoo-keyring FILE --root-password-file FILE [options]

Build a Gentoo AMD64 UEFI disk image with mkosi.

  --gentoo-keyring FILE     Trusted Gentoo Release Engineering keyring (GPG)
  --root-password-file FILE
                           File containing a SHA-512 crypt hash for root
  --stage3 FILE            Use a Gentoo stage3 with a detached FILE.asc signature
                           (default: download the latest signed systemd stage3)
  --packages FILE          Package list (default: packages.conf beside build.dart)
  --kernel DIR             ekuOS kernel checkout (default: ../kernel)
  --kernel-artifacts DIR   Reuse a compatible linux-eku-aa artifact directory
  --glibc DIR              ekuOS glibc checkout (default: ../glibc)
  --output FILE            New raw image (default: out/civilight.raw)
  --root-size-gib N        Minimum Btrfs root partition size (default: 8)
  --jobs N                 Parallel compiler jobs (default: 2)
  --help                   Show this help

Run as an ordinary user with subordinate UID/GID mappings, or as root.
''';

class Options {
  Options(this.values);
  final Map<String, String> values;

  static Options parse(List<String> args) {
    final values = <String, String>{};
    for (var i = 0; i < args.length; i += 2) {
      final key = args[i];
      if (!const {
        '--gentoo-keyring',
        '--root-password-file',
        '--stage3',
        '--packages',
        '--kernel',
        '--kernel-artifacts',
        '--glibc',
        '--output',
        '--root-size-gib',
        '--jobs',
      }.contains(key)) {
        throw BuildFailure('Unknown option: $key.');
      }
      if (i + 1 == args.length ||
          args[i + 1].isEmpty ||
          args[i + 1].startsWith('--')) {
        throw BuildFailure('Missing value for $key.');
      }
      if (values.containsKey(key))
        throw BuildFailure('Duplicate option: $key.');
      values[key] = args[i + 1];
    }
    return Options(values);
  }

  String path(String key, [String? fallback]) {
    final value = values[key] ?? fallback;
    if (value == null) throw BuildFailure('$key is required.');
    return File(value).absolute.path;
  }

  int number(String key, int fallback, {int minimum = 1}) {
    final value = int.tryParse(values[key] ?? '$fallback');
    if (value == null || value < minimum) {
      throw BuildFailure('$key must be an integer of at least $minimum.');
    }
    return value;
  }
}

Future<void> makeDisk(Directory work, int rootSize, File output) async {
  // A Gentoo package can install a named pipe. mkosi 26 copies directory
  // trees with cp --copy-contents, which would wait on the pipe.
  await run('tar', [
    '--create',
    '--sparse',
    '--numeric-owner',
    '--acls',
    '--xattrs',
    '--xattrs-include=*',
    '--file',
    '${work.path}/root.tar',
    '--directory',
    '${work.path}/root',
    '.',
  ]);
  final repart = await Directory('${work.path}/mkosi.repart').create();
  await File('${repart.path}/00-esp.conf').writeAsString('''
[Partition]
Type=esp
Label=civilight-esp
Format=vfat
CopyFiles=/boot:/
CopyFiles=/efi:/
SizeMinBytes=512M
SizeMaxBytes=512M
''');
  await File('${repart.path}/10-root.conf').writeAsString('''
[Partition]
Type=root
Label=civilight-root
Format=btrfs
CopyFiles=/
Minimize=guess
SizeMinBytes=${rootSize}G
''');
  await File('${work.path}/mkosi.conf').writeAsString('''
[Distribution]
Distribution=custom
Architecture=x86-64

[Output]
Format=disk
Output=civilight
OutputDirectory=image
CompressOutput=no
SectorSize=512

[Content]
BaseTrees=root.tar
Bootable=yes
Bootloader=systemd-boot
UnifiedKernelImages=unsigned
UnifiedKernelImageFormat=civilight-&k
Initrds=initrd
KernelCommandLine=root=PARTUUID rootfstype=btrfs rw console=tty0 console=ttyS0,115200n8
CleanPackageMetadata=no
Hostname=civilight
Locale=C.UTF-8

[Validation]
SecureBoot=no

[Build]
BuildSources=
PackageCacheDirectory=pkgcache
WorkspaceDirectory=workspace
''');
  await Directory('${work.path}/workspace').create();
  await run('mkosi', ['build'], cwd: work.path);
  final image = File('${work.path}/image/civilight.raw');
  if (!await image.exists() || await image.length() == 0) {
    throw const BuildFailure('mkosi did not produce the raw disk image.');
  }
  await run('chmod', ['0600', image.path]);
  // Both paths are on the output filesystem. A hard link publishes the
  // completed image atomically and fails if another build already won.
  await run('ln', ['--no-target-directory', '--', image.path, output.path]);
  stdout.writeln('Image written to ${output.path}');
}

Future<void> build(Options options) async {
  final script = Platform.script;
  final jobs = options.number('--jobs', 2);
  final rootSize = options.number('--root-size-gib', 8, minimum: 4);
  final keyring = options.path('--gentoo-keyring');
  if (!await File(keyring).exists())
    throw BuildFailure('Keyring not found: $keyring.');
  final passwordFile = File(options.path('--root-password-file'));
  final passwordHash = (await passwordFile.readAsString()).trim();
  if (!RegExp(
    r'^\$6\$(?:rounds=[0-9]+\$)?[./0-9A-Za-z]{1,16}\$[./0-9A-Za-z]{86}$',
  ).hasMatch(passwordHash)) {
    throw const BuildFailure(
      'Expected a SHA-512 crypt hash in --root-password-file.',
    );
  }
  final packages = await readPackages(
    File(
      options.path('--packages', script.resolve('packages.conf').toFilePath()),
    ),
  );
  final kernelCheckout = Directory(
    options.path('--kernel', script.resolve('../kernel/').toFilePath()),
  );
  final glibcCheckout = Directory(
    options.path('--glibc', script.resolve('../glibc/').toFilePath()),
  );
  final reuseKernel = options.values.containsKey('--kernel-artifacts');
  for (final checkout in [if (!reuseKernel) kernelCheckout, glibcCheckout]) {
    if (!await File('${checkout.path}/build.dart').exists()) {
      throw BuildFailure('Builder not found in ${checkout.path}.');
    }
  }
  final output = File(
    options.path('--output', script.resolve('out/civilight.raw').toFilePath()),
  );
  if (!output.path.endsWith('.raw')) {
    throw const BuildFailure('--output must end with .raw.');
  }
  if (await FileSystemEntity.type(output.path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    throw BuildFailure('Output already exists: ${output.path}.');
  }
  await output.parent.create(recursive: true);
  final workParent = await output.parent.resolveSymbolicLinks();
  await requireSpace(workParent, 12 * gib);
  await requireSpace(glibcCheckout.path, 3 * gib);
  if (!reuseKernel) await requireSpace(kernelCheckout.path, 3 * gib);
  final work = await Directory(workParent).createTemp('.civilight-');
  try {
    final local = options.values.containsKey('--stage3')
        ? options.path('--stage3')
        : null;
    final archive = await stageArchive(work, keyring, local);
    final gentoo = Gentoo(Directory('${work.path}/root'), jobs);
    await gentoo.unpack(archive);

    final artifacts = reuseKernel
        ? Directory(options.path('--kernel-artifacts'))
        : await buildKernel(kernelCheckout, work, jobs);
    final kernel = await Kernel.read(artifacts);
    final kernelPayload = Directory('${work.path}/linux-eku');
    await kernel.stage(kernelPayload);
    final glibcPayload = await Directory('${work.path}/glibc').create();
    final glibcVersion = await stageGlibc(glibcCheckout, glibcPayload, jobs);

    final initrd = File('${work.path}/initrd');
    await gentoo.install(
      packages,
      kernel,
      kernelPayload,
      glibcVersion,
      glibcPayload,
      passwordHash,
      initrd,
    );
    await requireSpace(work.path, 2 * gib);
    await makeDisk(work, rootSize, output);
  } finally {
    await work.delete(recursive: true);
  }
}

Future<void> main(List<String> args) async {
  try {
    if (args.isEmpty || args.contains('--help')) {
      stdout.write(usage);
      return;
    }
    if (!Platform.isLinux || await capture('uname', ['-m']) != 'x86_64') {
      throw const BuildFailure('An x86-64 Linux build host is required.');
    }
    final inside = args.first == '--inside-build-namespace';
    final options = Options.parse(inside ? args.sublist(1) : args);
    if (inside) {
      if (pid != 1 || await capture('id', ['-u']) != '0') {
        throw const BuildFailure(
          'The build requires UID 0 and PID 1 in its private namespaces.',
        );
      }
      await build(options);
      return;
    }
    final rootless = await capture('id', ['-u']) != '0';
    await run('unshare', [
      if (rootless) ...['--map-auto', '--map-root-user'],
      '--mount',
      '--propagation',
      'private',
      '--pid',
      '--fork',
      '--kill-child',
      '--mount-proc',
      '--',
      Platform.resolvedExecutable,
      Platform.script.toFilePath(),
      '--inside-build-namespace',
      ...args,
    ]);
  } on Exception catch (error) {
    final message = error.toString();
    stderr.writeln(
      diskError.hasMatch(message) && error is! BuildFailure
          ? '[ERROR] Disk space exhausted. $message'
          : '[ERROR] $message',
    );
    exitCode = 1;
  }
}
