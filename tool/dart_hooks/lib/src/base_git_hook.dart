// Copyright (c) 2026, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:convert';
import 'dart:io';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as path;
import 'hook_utils.dart';
import 'process_runner.dart';

/// Base class for Git hooks using the Template Method pattern.
abstract class BaseGitHook {
  BaseGitHook({
    required this.processRunner,
    required this.fileExists,
    required this.printStdout,
    required this.logToFile,
    required this.onExit,
  });

  final ProcessRunner processRunner;
  final bool Function(String) fileExists;
  final void Function(String) printStdout;
  final Future<void> Function(String) logToFile;
  final void Function(int) onExit;

  /// The allowed file extensions for this hook (e.g., ['.dart']).
  List<String> get allowedExtensions;

  /// The name of the hook for logging purposes.
  String get hookName;

  /// Runs the specific command on the files (e.g., `dart analyze`).
  @protected
  Future<ProcessResult> executeCommand(List<String> files);

  /// Runs the hook logic.
  Future<void> run({
    required List<String> args,
    required String currentPath,
    required String packageRoot,
    required String triggerSource,
  }) async {
    await logToFile('$hookName started in $currentPath (Trigger: $triggerSource)');

    try {
      // 1. Get repo root
      final ProcessResult repoRootResult = await processRunner.run('git', [
        'rev-parse',
        '--show-toplevel',
      ]);

      if (repoRootResult.exitCode != 0) {
        await logToFile('ERROR: Failed to get git repo root.');
        printStdout(jsonEncode({'decision': 'continue', 'reason': 'Failed to get git repo root.'}));
        onExit(0);
        return;
      }
      final String repoRoot = (repoRootResult.stdout as String).trim();

      // 2. Get modified files
      final List<String> files;
      try {
        // ignore: invalid_use_of_visible_for_testing_member
        files = await getModifiedFilesInternal(
          runProcess: processRunner.run,
          packageRoot: packageRoot,
          repoRoot: repoRoot,
          fileExists: fileExists,
          allowedExtensions: allowedExtensions,
        );
      } catch (e) {
        await logToFile('ERROR: Failed to get modified files: $e');
        printStdout(jsonEncode({'decision': 'continue', 'reason': 'Failed to get git status.'}));
        onExit(0);
        return;
      }

      // 3. Filter files (Hierarchical scoping)
      // The scope is the directory containing the .agents folder.
      // packageRoot is passed as the directory containing .agents.
      final scopeDir = packageRoot;

      final List<String> scopedFiles = files.where((file) {
        return path.isWithin(scopeDir, file);
      }).toList();

      if (scopedFiles.isEmpty) {
        await logToFile('No matching files found to process in scope: $scopeDir.');
        printStdout(jsonEncode({'decision': 'stop'}));
        onExit(0);
        return;
      }

      await logToFile('Running command on ${scopedFiles.length} files...');

      // 4. Execute the specific command
      final ProcessResult result = await executeCommand(scopedFiles);

      final int exitCode = result.exitCode;
      final output = result.stdout as String;
      final error = result.stderr as String;

      await logToFile('Command finished with code $exitCode');

      // 5. Handle result
      if (exitCode == 0) {
        await logToFile('Command passed');
        printStdout(jsonEncode({'decision': 'stop'}));
        onExit(0);
        return;
      }

      await logToFile('Command failed');
      final reason = '$hookName issues found. Please fix these before finishing:\n\n$output$error';
      printStdout(jsonEncode({'decision': 'continue', 'reason': reason}));
      onExit(0);
      return;
    } catch (e, stackTrace) {
      await logToFile('UNHANDLED EXCEPTION: $e');
      await logToFile(stackTrace.toString());
      printStdout(
        jsonEncode({'decision': 'continue', 'reason': 'Unhandled exception in $hookName hook.'}),
      );
      onExit(1);
      return;
    }
  }
}
