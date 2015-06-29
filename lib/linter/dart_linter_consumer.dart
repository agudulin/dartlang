part of linter;

/// Consumes the atomlinter/linter self-service API.
class DartLinterConsumer extends LinterConsumer with Disposables {
  static final List<String> acceptableErrorTypes = ['ERROR', 'WARNING'];
  ErrorRepository _errorRepository;
  DartLinterConsumer(this._errorRepository);

  consume(LinterService service) {
    var provider = new DartLinterProvider();

    _errorRepository.onChange.listen((_) {
      var allErrors =
          _errorRepository.knownErrors.values.expand((l) => l).toList();
      var sortedErrors = new List<AnalysisError>.from(allErrors)
        ..sort(_errorComparer);
      var formattedErrors = sortedErrors
          .where((e) => acceptableErrorTypes.contains(e.severity))
          .map((e) => _errorToLintMessage(e.location.file, e))
          .toList();

      service.deleteProjectMessages(provider);
      service.setProjectMessages(provider, formattedErrors);
    });
  }
}