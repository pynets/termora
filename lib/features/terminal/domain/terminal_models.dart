part of '../view/terminal_page.dart';

// The terminal buffer data model (TerminalLine / TerminalSpan / AnsiStyle) and
// the cell-width helpers now live in the public, unit-testable library
// controller/terminal_model.dart. Only widget-local UI enums remain here.

enum _TerminalOverflowAction {
  copyAll,
  save,
  paste,
  pickDir,
  fullDiskAccess,
  linkMatchers,
  clear,
  reset,
  zoomIn,
  zoomOut,
  zoomReset,
  splitHorizontal,
  splitVertical,
  closePane,
  highlight,
  theme,
  broadcast,
  syncScroll,
  sessionLog,
  minimizePane,
  minimap,
  detailsPanel,
}

enum _FooterChipTone { neutral, active, warning }

/// The drop zone within a pane while dragging to rearrange the split layout.
enum _DropRegion { left, right, top, bottom, center }

/// Tabs in the terminal details side panel.
enum _TerminalPanelTab { info, outline, git, files }
