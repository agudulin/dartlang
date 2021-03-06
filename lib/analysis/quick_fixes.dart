
library atom.quick_fixes;

import 'dart:async';

import 'package:logging/logging.dart';

import '../analysis_server.dart';
import '../atom.dart';
import '../atom_autocomplete.dart';
import '../editors.dart';
import '../state.dart';
import '../utils.dart';
import 'analysis_server_lib.dart';

final Logger _logger = new Logger('quick-fixes');

class QuickFixHelper implements Disposable {
  Disposables disposables = new Disposables();

  QuickFixHelper() {
    disposables.add(atom.commands.add('atom-text-editor',
        'dartlang:quick-fix', (event) => _handleQuickFix(event)));
  }

  void dispose() => disposables.dispose();

  void _handleQuickFix(AtomEvent event) {
    TextEditor editor = event.editor;
    String path = editor.getPath();
    Range range = editor.getSelectedBufferRange();
    int offset = editor.getBuffer().characterIndexForPosition(range.start);

    Job job = new AnalysisRequestJob('quick fix', () {
      return analysisServer.getFixes(path, offset).then((FixesResult result) {
        _handleFixesResult(result, editor);
      });
    });
    job.schedule();
  }

  void _handleFixesResult(FixesResult result, TextEditor editor) {
    List<AnalysisErrorFixes> fixes = result.fixes;

    if (fixes.isEmpty) {
      atom.beep();
      return;
    }

    List<_Change> changes = fixes
      .expand((fix) => fix.fixes.map((c) => new _Change(fix.error, c)))
      .toList();

    if (changes.length == 1) {
      // Apply the fix.
      _applyChange(editor, changes.first.change);
    } else {
      int i = 0;
      var renderer = (_Change change) {
        // We need to create suggestions with unique text replacements.
        return new Suggestion(
          text: 'fix_${++i}',
          replacementPrefix: '',
          displayText: change.change.message,
          rightLabel: 'quick-fix',
          description: change.error.message,
          type: 'function'
        );
      };

      // Show a selection dialog.
      chooseItemUsingCompletions(editor, changes, renderer).then((_Change choice) {
        editor.undo();
        _applyChange(editor, choice.change);
      });
    }
  }
}

class _Change {
  final AnalysisError error;
  final SourceChange change;

  _Change(this.error, this.change);

  String toString() => '${error.message}: ${change.message}';
}

void _applyChange(TextEditor currentEditor, SourceChange change) {
  List<SourceFileEdit> sourceFileEdits = change.edits;
  List<LinkedEditGroup> linkedEditGroups = change.linkedEditGroups;

  Future.forEach(sourceFileEdits, (SourceFileEdit edit) {
    return atom.workspace.open(edit.file,
        options: {'searchAllPanes': true}).then((TextEditor editor) {
      applyEdits(editor, edit.edits);
      int index = sourceFileEdits.indexOf(edit);
      if (index >= 0 && index < linkedEditGroups.length) {
        selectEditGroup(editor, linkedEditGroups[index]);
      }
    });
  }).then((_) {
    String fileSummary = sourceFileEdits.map((edit) => edit.file).join('\n');
    if (sourceFileEdits.length == 1) fileSummary = null;
    atom.notifications.addSuccess(
        'Executed quick fix: ${toStartingLowerCase(change.message)}',
        detail: fileSummary);

    // atom.workspace.open(currentEditor.getPath(),
    //     options: {'searchAllPanes': true}).then((TextEditor editor) {
    //   if (change.selection != null) {
    //     editor.setCursorBufferPosition(
    //         editor.getBuffer().positionForCharacterIndex(change.selection.offset));
    //   } else if (linkedEditGroups.isNotEmpty) {
    //     selectEditGroups(currentEditor, linkedEditGroups);
    //   }
    // });
  }).catchError((e) {
    atom.notifications.addError('Error Performing Rename', detail: '${e}');
  });
}
