library atom.buffer_observer;

import 'dart:async';

import 'package:frappe/frappe.dart';

import '../analysis/analysis_server_lib.dart';
import '../analysis/formatting.dart';
import '../atom.dart';
import '../state.dart';
import '../utils.dart';

class BufferObserverManager implements Disposable {
  List<BufferObserver> observers = [];

  BufferObserverManager() {
    // TODO: Fix editorManager.dartProjectEditors.
    editorManager.dartProjectEditors.openEditors.forEach(_newEditor);
    editorManager.dartProjectEditors.onEditorOpened.listen(_newEditor);
  }

  void _newEditor(TextEditor editor) {
    observers.add(new BufferUpdater(this, editor));
    observers.add(new BufferFormatter(this, editor));
  }

  void dispose() {
    observers.toList().forEach((obs) => obs.dispose());
    observers.clear();
  }

  remove(BufferObserver observer) => observers.remove(observer);
}

class BufferObserver extends Disposables {
  final TextEditor editor;
  final BufferObserverManager manager;
  BufferObserver(this.manager, this.editor);
}

class BufferFormatter extends BufferObserver {
  StreamSubscriptions _subs = new StreamSubscriptions();
  bool isFormatting = false;
  bool get formatOnSave => atom.config.getValue('dartlang.formatOnSave');

  BufferFormatter(manager, editor) : super(manager, editor) {
    _subs.add(this.editor.onDidSave.listen((_) {
      if (isFormatting) return;
      if (!formatOnSave) return;
      if (!analysisServer.isActive) return;
      if (!dartProject) return; // Breaks stand-alone dart files?

      isFormatting = true;
      FormattingHelper.formatEditor(editor, quiet: true).then((didFormat) {
        if (didFormat) editor.save();
        // This is a side-effect or bug in Dart:
        // This method will complete before the callbacks initiated by
        // the editor will be invoked. This is different from JavaScript,
        // which will invoke the callbacks first, then continue.
        //
        // To work around this, we set isFormatting = false outside of
        // the method scope.
        new Timer(new Duration(milliseconds: 10), () => isFormatting = false);
      });
    }));

    _subs.add(this.editor.onDidDestroy.listen((_) {
      dispose();
    }));
  }

  void dispose() {
    _subs.cancel();
    manager.remove(this);
  }

  // TODO: Remove once we only watch Dart files that are in a Dart project.
  bool get dartProject =>
      projectManager.getProjectFor(editor.getPath()) != null;
}

/// Observe a TextEditor and notifies the analysis_server of any content changes
/// it should care about.
///
/// Although this class should use the "ChangeContentOverlay" route,
/// Atom doesn't provide us with diffs, so it is more expensive to calculate
/// the diffs than just remove the existing overlay and add a new one with
/// the changed content.
class BufferUpdater extends BufferObserver {
  final StreamSubscriptions _subs = new StreamSubscriptions();

  String lastSent;

  BufferUpdater(manager, editor) : super(manager, editor) {
    _subs.add(analysisServer.isActiveProperty.listen(serverActive));
    // Debounce atom onDidChange events; atom sends us several events as a file
    // is opening. The number of events is proportional to the file size. For
    // a file like dart:html, this is on the order of 800 onDidChange events.
    var onDidChangeSub = new EventStream(editor.onDidChange)
        .debounce(new Duration(milliseconds: 10))
        .listen(_didChange);

    _subs.add(onDidChangeSub);
    _subs.add(editor.onDidDestroy.listen(_didDestroy));

    addOverlay();
  }

  Server get server => analysisServer.server;

  void serverActive(bool active) {
    if (active) {
      addOverlay();
    } else {
      lastSent = null;
    }
  }

  void _didChange([_]) {
    changedOverlay();
  }

  void _didDestroy([_]) {
    dispose();
  }

  addOverlay() {
    if (analysisServer.isActive && dartProject) {
      lastSent = editor.getText();
      server.analysis.updateContent(
          {editor.getPath(): new AddContentOverlay('add', lastSent)});
    }
  }

  changedOverlay() {
    if (analysisServer.isActive && dartProject) {
      if (lastSent == null) {
        addOverlay();
      } else {
        String contents = editor.getText();

        // TODO: See #31.
        // List<Edit> edits = simpleDiff(lastSent, contents);
        // int count = 1;
        // List<SourceEdit> diffs = edits
        //   .map((edit) => new SourceEdit(
        //       edit.offset, edit.length, edit.replacement, id: '${count++}'))
        //   .toList();
        // var overlay = new ChangeContentOverlay('change', diffs);
        // server.analysis.updateContent({ editor.getPath(): overlay });
        server.analysis.updateContent(
            {editor.getPath(): new RemoveContentOverlay('remove')});
        server.analysis.updateContent(
            {editor.getPath(): new AddContentOverlay('add', contents)});

        lastSent = contents;
      }
    }
  }

  removeOverlay() {
    if (analysisServer.isActive && dartProject) {
      server.analysis.updateContent(
          {editor.getPath(): new RemoveContentOverlay('remove')});
    }

    lastSent = null;
  }

  // TODO: Remove once we only watch Dart files that are in a Dart project.
  bool get dartProject =>
      projectManager.getProjectFor(editor.getPath()) != null;

  dispose() {
    removeOverlay();
    super.dispose();
    _subs.cancel();
    manager.remove(this);
  }
}
