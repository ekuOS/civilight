#!/usr/bin/env dart

import 'dart:io';

import 'lib/commands.dart';
import 'lib/gentoo.dart';
import 'lib/image.dart';
import 'lib/workspace.dart';

const usage = '''
Usage: dart run build.dart --gentoo-keyring FILE --root-password-file FILE [options]
       dart run build.dart clean [--temp-dir DIR] [--output FILE] [--dry-run]

Build a Gentoo AMD64 UEFI disk image with mkosi.

  --gentoo-keyring FILE     Trusted Gentoo Release Engineering keyring (GPG)
  --root-password-file FILE
                           File containing a SHA-512 crypt hash for root
  --stage3 FILE            Use a Gentoo stage3 with a detached FILE.asc signature
                           (default: download the latest signed systemd stage3)
  --packages FILE          Package list (default: packages.conf beside build.dart)
  --output FILE            New raw image (default: out/civilight.raw)
  --temp-dir DIR           Parent for build workspaces (default: output directory)
  --root-size-gib N        Minimum Btrfs root partition size (default: 8)
  --jobs N                 Parallel compiler jobs (default: 2)
  --help                   Show this help

Run as an ordinary user with subordinate UID/GID mappings, or as root.
The clean command removes inactive Civilight workspaces and keeps raw images.
''';

class Options {
  Options(this.values);
  final Map<String, String> values;

  static Options parse(List<String> args, {required bool clean}) {
    final values = <String, String>{};
    final allowed = clean
        ? const {'--temp-dir', '--output'}
        : const {
            '--gentoo-keyring',
            '--root-password-file',
            '--stage3',
            '--packages',
            '--output',
            '--temp-dir',
            '--root-size-gib',
            '--jobs',
          };
    for (var i = 0; i < args.length; i += 2) {
      final key = args[i];
      if (!allowed.contains(key)) {
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

  File get output => File(
    path('--output', Platform.script.resolve('out/civilight.raw').toFilePath()),
  );

  Directory get workParent => Directory(path('--temp-dir', output.parent.path));
}

Future<void> makeDisk(
  Directory work,
  int rootSize,
  String kernelRelease,
  File output,
) async {
  final osRelease = File('${work.path}/root/usr/lib/os-release');
  final release = (await osRelease.readAsLines()).where(
    (line) => !line.startsWith('NAME=') && !line.startsWith('PRETTY_NAME='),
  );
  await osRelease.writeAsString(
    [
      'NAME="ekuOS-civilight"',
      'PRETTY_NAME="ekuOS-civilight"',
      ...release,
      '',
    ].join('\n'),
  );
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
  await run(
    'mkosi',
    ['build'],
    cwd: work.path,
    environment: {'TMPDIR': work.path},
  );
  final image = File('${work.path}/image/civilight.raw');
  if (!await image.exists() || await image.length() == 0) {
    throw const BuildFailure('mkosi did not produce the raw disk image.');
  }
  await verifyBootImage(image, kernelRelease, work);
  await run('chmod', ['0600', image.path]);
  await publishImage(image, output);
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
  // Check this before the Portage build: mtools needs it to populate the ESP.
  final fatCodepage = await Process.run('iconv', [
    '-f',
    'UTF-8',
    '-t',
    'CP850',
    '/dev/null',
  ]);
  if (fatCodepage.exitCode != 0) {
    throw const BuildFailure(
      'Host iconv lacks CP850 support for the EFI partition. '
      'On Fedora, install glibc-gconv-extra.',
    );
  }
  final output = options.output;
  if (!output.path.endsWith('.raw')) {
    throw const BuildFailure('--output must end with .raw.');
  }
  if (await FileSystemEntity.type(output.path, followLinks: false) !=
      FileSystemEntityType.notFound) {
    throw BuildFailure('Output already exists: ${output.path}.');
  }
  await output.parent.create(recursive: true);
  final workParent = await options.workParent.create(recursive: true);
  final workPath = await workParent.resolveSymbolicLinks();
  await requireSpace(workPath, 12 * gib);
  await withWorkspace(Directory(workPath), (work) async {
    final local = options.values.containsKey('--stage3')
        ? options.path('--stage3')
        : null;
    final archive = await stageArchive(work, keyring, local);
    final gentoo = Gentoo(
      Directory('${work.path}/root'),
      jobs,
      Directory.fromUri(script.resolve('config/portage/')),
    );
    await gentoo.unpack(archive);

    final initrd = File('${work.path}/initrd');
    final kernelRelease = await gentoo.install(packages, passwordHash, initrd);
    await requireSpace(work.path, 2 * gib);
    await makeDisk(work, rootSize, kernelRelease, output);
  });
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
    final arguments = args.sublist(inside ? 1 : 0);
    final clean = arguments.isNotEmpty && arguments.first == 'clean';
    if (clean) arguments.removeAt(0);
    final dryRun = clean && arguments.remove('--dry-run');
    final options = Options.parse(arguments, clean: clean);
    if (inside) {
      if (pid != 1 || await capture('id', ['-u']) != '0') {
        throw const BuildFailure(
          'The build requires UID 0 and PID 1 in its private namespaces.',
        );
      }
      if (clean) {
        for (final path in {
          options.workParent.path,
          if (options.values.containsKey('--output'))
            options.output.parent.path,
        }) {
          await cleanWorkspaces(Directory(path), dryRun: dryRun);
        }
      } else {
        await build(options);
      }
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
