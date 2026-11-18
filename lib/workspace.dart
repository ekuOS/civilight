import 'dart:io';

import 'commands.dart';

const _prefix = '.civilight-';
const _marker = '.civilight-workspace';
const _markerText = 'civilight-workspace-v1\n';

Future<void> withWorkspace(
  Directory parent,
  Future<void> Function(Directory work) action,
) async {
  final work = await parent.createTemp(_prefix);
  RandomAccessFile? marker;
  try {
    marker = await File('${work.path}/$_marker').open(mode: FileMode.write);
    await marker.lock(FileLock.exclusive);
    await marker.writeString(_markerText);
    await marker.flush();
    await action(work);
  } finally {
    try {
      await work.delete(recursive: true);
    } finally {
      await marker?.close();
    }
  }
}

Future<void> cleanWorkspaces(Directory parent, {required bool dryRun}) async {
  if (!await parent.exists()) return;
  final path = await parent.resolveSymbolicLinks();
  final entries = await Directory(path).list(followLinks: false).toList();
  entries.sort((a, b) => a.path.compareTo(b.path));
  for (final entry in entries.whereType<Directory>()) {
    final name = entry.uri.pathSegments.lastWhere((part) => part.isNotEmpty);
    if (!name.startsWith(_prefix)) continue;
    final marker = File('${entry.path}/$_marker');
    if (await FileSystemEntity.type(marker.path, followLinks: false) !=
        FileSystemEntityType.file) {
      continue;
    }
    // UID 0 maps to the build user in the private namespace.
    try {
      if (await capture('stat', ['-c', '%u', '--', entry.path]) != '0')
        continue;
    } on BuildFailure {
      if (await entry.exists()) rethrow;
      continue;
    }

    RandomAccessFile? handle;
    try {
      handle = await marker.open(mode: FileMode.append);
      try {
        await handle.lock(FileLock.exclusive);
      } on FileSystemException catch (error) {
        if (error.osError?.errorCode != 11 && error.osError?.errorCode != 13) {
          rethrow;
        }
        stdout.writeln('Skipping active workspace ${entry.path}');
        continue;
      }
      await handle.setPosition(0);
      if (String.fromCharCodes(await handle.read(_markerText.length + 1)) !=
          _markerText) {
        continue;
      }
      if (dryRun) {
        stdout.writeln('Would remove ${entry.path}');
      } else {
        await entry.delete(recursive: true);
        stdout.writeln('Removed ${entry.path}');
      }
    } on FileSystemException catch (error) {
      // Another clean may have removed this directory after it was listed.
      if (error.osError?.errorCode != 2) rethrow;
    } finally {
      await handle?.close();
    }
  }
}

Future<void> publishImage(File image, File output) async {
  final args = ['--no-target-directory', '--', image.path, output.path];
  final link = await Process.run('ln', args, environment: {'LC_ALL': 'C'});
  if (link.exitCode == 0) return;
  final error = (link.stderr as String).trim();
  if (!error.contains('Invalid cross-device link')) throw BuildFailure(error);

  // Keep the copy sparse, then publish it with an atomic no-clobber link.
  await withWorkspace(output.parent, (staging) async {
    final copy = '${staging.path}/civilight.raw';
    await run('cp', [
      '--sparse=always',
      '--preserve=mode',
      '--',
      image.path,
      copy,
    ]);
    await run('ln', ['--no-target-directory', '--', copy, output.path]);
  });
}
