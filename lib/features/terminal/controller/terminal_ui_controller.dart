import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'terminal_ui_controller.g.dart';

class TerminalUiState {
  const TerminalUiState({
    this.cwd = '',
    this.backendLabel = '',
    this.terminalTitle,
    this.isRunning = false,
    this.runningCommand,
    this.isPreparingDirectory = false,
    this.nativePtyUnavailable = false,
    this.isAltBufferActive = false,
    this.bracketedPasteMode = false,
    this.autoWrapMode = true,
    this.showCursor = true,
    this.autoFollowOutput = true,
    this.isSearchVisible = false,
    this.hasOutput = false,
    this.searchMatchCount = 0,
    this.activeSearchMatch = -1,
  });

  final String cwd;
  final String backendLabel;
  final String? terminalTitle;
  final bool isRunning;
  final String? runningCommand;
  final bool isPreparingDirectory;
  final bool nativePtyUnavailable;
  final bool isAltBufferActive;
  final bool bracketedPasteMode;
  final bool autoWrapMode;
  final bool showCursor;
  final bool autoFollowOutput;
  final bool isSearchVisible;
  final bool hasOutput;
  final int searchMatchCount;
  final int activeSearchMatch;

  String get displayLocation {
    final title = terminalTitle;
    if (title != null && title.isNotEmpty) return '$title · $cwd';
    return cwd;
  }

  String get searchOrdinalLabel {
    if (searchMatchCount == 0) return '0/0';
    return '${activeSearchMatch + 1}/$searchMatchCount';
  }

  TerminalUiState copyWith({
    String? cwd,
    String? backendLabel,
    String? terminalTitle,
    bool clearTerminalTitle = false,
    bool? isRunning,
    String? runningCommand,
    bool clearRunningCommand = false,
    bool? isPreparingDirectory,
    bool? nativePtyUnavailable,
    bool? isAltBufferActive,
    bool? bracketedPasteMode,
    bool? autoWrapMode,
    bool? showCursor,
    bool? autoFollowOutput,
    bool? isSearchVisible,
    bool? hasOutput,
    int? searchMatchCount,
    int? activeSearchMatch,
  }) {
    return TerminalUiState(
      cwd: cwd ?? this.cwd,
      backendLabel: backendLabel ?? this.backendLabel,
      terminalTitle: clearTerminalTitle
          ? null
          : terminalTitle ?? this.terminalTitle,
      isRunning: isRunning ?? this.isRunning,
      runningCommand: clearRunningCommand
          ? null
          : runningCommand ?? this.runningCommand,
      isPreparingDirectory: isPreparingDirectory ?? this.isPreparingDirectory,
      nativePtyUnavailable: nativePtyUnavailable ?? this.nativePtyUnavailable,
      isAltBufferActive: isAltBufferActive ?? this.isAltBufferActive,
      bracketedPasteMode: bracketedPasteMode ?? this.bracketedPasteMode,
      autoWrapMode: autoWrapMode ?? this.autoWrapMode,
      showCursor: showCursor ?? this.showCursor,
      autoFollowOutput: autoFollowOutput ?? this.autoFollowOutput,
      isSearchVisible: isSearchVisible ?? this.isSearchVisible,
      hasOutput: hasOutput ?? this.hasOutput,
      searchMatchCount: searchMatchCount ?? this.searchMatchCount,
      activeSearchMatch: activeSearchMatch ?? this.activeSearchMatch,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is TerminalUiState &&
        other.cwd == cwd &&
        other.backendLabel == backendLabel &&
        other.terminalTitle == terminalTitle &&
        other.isRunning == isRunning &&
        other.runningCommand == runningCommand &&
        other.isPreparingDirectory == isPreparingDirectory &&
        other.nativePtyUnavailable == nativePtyUnavailable &&
        other.isAltBufferActive == isAltBufferActive &&
        other.bracketedPasteMode == bracketedPasteMode &&
        other.autoWrapMode == autoWrapMode &&
        other.showCursor == showCursor &&
        other.autoFollowOutput == autoFollowOutput &&
        other.isSearchVisible == isSearchVisible &&
        other.hasOutput == hasOutput &&
        other.searchMatchCount == searchMatchCount &&
        other.activeSearchMatch == activeSearchMatch;
  }

  @override
  int get hashCode => Object.hash(
    cwd,
    backendLabel,
    terminalTitle,
    isRunning,
    runningCommand,
    isPreparingDirectory,
    nativePtyUnavailable,
    isAltBufferActive,
    bracketedPasteMode,
    autoWrapMode,
    showCursor,
    autoFollowOutput,
    isSearchVisible,
    hasOutput,
    searchMatchCount,
    activeSearchMatch,
  );
}

@Riverpod(keepAlive: true)
class TerminalUiController extends _$TerminalUiController {
  @override
  TerminalUiState build(String sessionId) => const TerminalUiState();

  void replace(TerminalUiState nextState) {
    if (state == nextState) return;
    state = nextState;
  }
}
