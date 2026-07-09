// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'terminal_ui_controller.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(TerminalUiController)
final terminalUiControllerProvider = TerminalUiControllerFamily._();

final class TerminalUiControllerProvider
    extends $NotifierProvider<TerminalUiController, TerminalUiState> {
  TerminalUiControllerProvider._({
    required TerminalUiControllerFamily super.from,
    required String super.argument,
  }) : super(
         retry: null,
         name: r'terminalUiControllerProvider',
         isAutoDispose: false,
         dependencies: null,
         $allTransitiveDependencies: null,
       );

  @override
  String debugGetCreateSourceHash() => _$terminalUiControllerHash();

  @override
  String toString() {
    return r'terminalUiControllerProvider'
        ''
        '($argument)';
  }

  @$internal
  @override
  TerminalUiController create() => TerminalUiController();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(TerminalUiState value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<TerminalUiState>(value),
    );
  }

  @override
  bool operator ==(Object other) {
    return other is TerminalUiControllerProvider && other.argument == argument;
  }

  @override
  int get hashCode {
    return argument.hashCode;
  }
}

String _$terminalUiControllerHash() =>
    r'de068e3365723e044943dcd62e0bcc49f8056d6e';

final class TerminalUiControllerFamily extends $Family
    with
        $ClassFamilyOverride<
          TerminalUiController,
          TerminalUiState,
          TerminalUiState,
          TerminalUiState,
          String
        > {
  TerminalUiControllerFamily._()
    : super(
        retry: null,
        name: r'terminalUiControllerProvider',
        dependencies: null,
        $allTransitiveDependencies: null,
        isAutoDispose: false,
      );

  TerminalUiControllerProvider call(String sessionId) =>
      TerminalUiControllerProvider._(argument: sessionId, from: this);

  @override
  String toString() => r'terminalUiControllerProvider';
}

abstract class _$TerminalUiController extends $Notifier<TerminalUiState> {
  late final _$args = ref.$arg as String;
  String get sessionId => _$args;

  TerminalUiState build(String sessionId);
  @$mustCallSuper
  @override
  void runBuild() {
    final ref = this.ref as $Ref<TerminalUiState, TerminalUiState>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<TerminalUiState, TerminalUiState>,
              TerminalUiState,
              Object?,
              Object?
            >;
    element.handleCreate(ref, () => build(_$args));
  }
}
