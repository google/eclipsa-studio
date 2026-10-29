// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import '../export/iamf_export_dialog.dart';
import '../logging/log.dart';
import '../loudness/loudness_report_dialog.dart';
import '../session/session.dart';
import '../state.dart';
import '../theme.dart';
import '../window_state.dart';
import '../whats_new/release_notes.dart';
import '../whats_new/whats_new_dialog.dart';
import '../workspace/workspace_actions.dart';
import '../workspace/workspace_close.dart';
import '../workspace/workspace_mode.dart';
import '../workspace/workspace_tab_shortcuts.dart';
import 'chrome_surface.dart';
import 'console_widgets.dart';
import 'theme_cycle.dart';
import 'theme_gallery.dart';
import 'licenses_dialog.dart';
import 'safety_notice_dialog.dart';
import 'session_settings_dialog.dart';
import 'settings_dialog.dart';
import 'shortcuts_dialog.dart';

/// Single root-level menu bar for the whole app.
///
/// On macOS this mounts a [PlatformMenuBar] so menus appear in the
/// system menu bar (the canonical macOS UX). On Windows / Linux,
/// Flutter's `PlatformMenuBar` is a no-op AND throws if it sees a
/// `PlatformProvidedMenuItem`, so the menus are a Flutter-drawn
/// [FlutterMenuBar] instead: in the window titlebar on Windows, and in
/// a row above the page on Linux.
///
/// Both paths are driven by the same workspace mode; menu contents
/// stay in lockstep so the UX is consistent across platforms.
class AppMenuBar extends ConsumerStatefulWidget {
  const AppMenuBar({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<AppMenuBar> createState() => _AppMenuBarState();
}

class _AppMenuBarState extends ConsumerState<AppMenuBar> {
  @override
  void initState() {
    super.initState();
    // Runs once at app launch, regardless of whether the user lands
    // in workspace or landing mode.
    _showLaunchDialogs();
  }

  /// The safety notice gates first use (ES-634), so it goes up first and
  /// the What's New dialog waits for it to close.
  Future<void> _showLaunchDialogs() async {
    try {
      await SafetyNoticeDialog.maybeShow(context, ref);
    } on Exception catch (e) {
      Log.w(LogCat.app, 'Failed to show the safety notice', e);
    }
    if (!mounted) return;
    await _maybeShowWhatsNew();
  }

  Future<void> _maybeShowWhatsNew() async {
    try {
      final prefs = await AppPreferences.load();
      if (!mounted) return;
      final running = ref.read(appVersionProvider);
      final lastSeen = prefs[AppPreferences.kLastSeenVersion] as String?;
      if (lastSeen == running) return;

      // Mark immediately so a crash before dismissal doesn't strand
      // the user in an infinite popup loop on next launch.
      AppPreferences.set(AppPreferences.kLastSeenVersion, running).then(
        (_) {},
        onError: (Object e) =>
            Log.w(LogCat.session, 'Last-seen-version preference not saved', e),
      );

      // First install: nothing to show.
      if (lastSeen == null) return;

      final notes = await loadReleaseNotes();
      if (!mounted) return;
      // releasesSince() falls back to the full list when lastSeen is
      // not in RELEASES.md (e.g. a stale internal build). Intentional:
      // we'd rather show all of recent history than nothing.
      final toShow = releasesSince(notes, lastSeen);
      if (toShow.isEmpty) return;

      await SchedulerBinding.instance.endOfFrame;
      if (!mounted) return;
      await WhatsNewDialog.show(context, releases: toShow);
    } on Exception catch (e) {
      Log.w(LogCat.app, 'Failed to show Release Notes dialog', e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(workspaceModeProvider);
    if (Platform.isMacOS) {
      return PlatformMenuBar(
        menus: _buildMenus(context, ref, mode),
        child: widget.child,
      );
    }
    // Windows: the menus are drawn in the window titlebar
    // (WindowTitlebar), so nothing is added here.
    if (Platform.isWindows) return widget.child;
    // Linux keeps its native titlebar, so the menus take a row of their
    // own above the page.
    return Column(
      mainAxisSize: MainAxisSize.max,
      children: [
        const Align(
          alignment: AlignmentDirectional.centerStart,
          child: FlutterMenuBar(),
        ),
        Expanded(child: widget.child),
      ],
    );
  }

  List<PlatformMenuItem> _buildMenus(
    BuildContext context,
    WidgetRef ref,
    WorkspaceMode mode,
  ) {
    final appMenu = PlatformMenu(
      label: 'Eclipsa Studio',
      menus: [
        PlatformMenuItem(
          label: 'Settings...',
          shortcut: const SingleActivator(LogicalKeyboardKey.comma, meta: true),
          onSelected: () => SettingsDialog.show(context),
        ),
        PlatformMenuItem(
          label: 'Third-Party Licenses...',
          // App-themed, source-grouped license view. Same data as the
          // stock licenses page — Flutter's embedded Dart-package NOTICES
          // plus the engine's statically linked third-party licenses
          // registered at startup (see main.dart / ES-57) — grouped by
          // source rather than a flat list.
          onSelected: () => LicensesDialog.show(context),
        ),
        const PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.quit),
      ],
    );

    final helpMenu = PlatformMenu(
      label: 'Help',
      menus: [
        PlatformMenuItem(
          label: 'Release Notes...',
          onSelected: () => _showWhatsNew(context),
        ),
        PlatformMenuItem(
          label: 'Keyboard Shortcuts',
          onSelected: () => ShortcutsDialog.show(context),
        ),
        PlatformMenuItem(
          label: 'Export Log...',
          onSelected: () => exportLog(ref),
        ),
      ],
    );

    // The theme commands close the View menu, in a group of their own.
    final themeGroup = PlatformMenuItemGroup(
      members: [
        // The gallery is debug-only. kThemeGalleryEnabled is a const,
        // so in a release build this collapses to an empty spread and
        // the gallery itself is tree-shaken out. Next Theme sits below
        // it and ships, matching the T key and the status bar.
        if (kThemeGalleryEnabled)
          PlatformMenuItem(
            label: 'Theme Gallery...',
            onSelected: () => ThemeGallery.show(context),
          ),
        // Cycles every theme, so each can be reviewed on the app's own
        // screens as well as in the gallery.
        //
        // No menu shortcut. The key is the unmodified `t` handled by
        // DevShortcuts, and a macOS menu key-equivalent without a
        // modifier is registered by the system ahead of Flutter's focus
        // handling — it would fire while typing in a text field, which
        // is exactly what DevShortcuts guards against.
        PlatformMenuItem(
          label: 'Next Theme',
          onSelected: () => ThemeCycle.next(ref),
        ),
      ],
    );

    if (mode == WorkspaceMode.none) {
      // Landing screen: File is hidden (no session to save) and View
      // carries only the theme commands, which apply here too. Help
      // stays: Release Notes, Keyboard Shortcuts and Export Log all
      // apply.
      return [
        appMenu,
        PlatformMenu(label: 'View', menus: [themeGroup]),
        helpMenu,
      ];
    }

    final isCreator = mode == WorkspaceMode.creator;
    final recents = ref.watch(recentSessionsProvider);
    final qcRecents = ref.watch(recentQcFilesProvider);

    return [
      appMenu,
      PlatformMenu(
        label: 'File',
        menus: [
          // Creating / opening sessions lives in Creator mode (and on the
          // landing hub). Playback's File menu only opens IAMF / MP4
          // files (ES-170).
          if (isCreator)
            PlatformMenuItemGroup(
              members: [
                PlatformMenuItem(
                  label: 'New Session',
                  shortcut: const SingleActivator(
                    LogicalKeyboardKey.keyN,
                    meta: true,
                  ),
                  onSelected: () => startNewCreatorSession(context, ref),
                ),
                PlatformMenuItem(
                  label: 'Open Session...',
                  shortcut: const SingleActivator(
                    LogicalKeyboardKey.keyO,
                    meta: true,
                  ),
                  onSelected: () => openCreatorSession(context, ref),
                ),
                PlatformMenu(
                  label: 'Open Recent',
                  menus: [
                    ...recents.map(
                      (path) => PlatformMenuItem(
                        label: path,
                        onSelected: () =>
                            openCreatorSession(context, ref, path: path),
                      ),
                    ),
                    if (recents.isEmpty)
                      const PlatformMenuItem(
                        label: 'No Recent Sessions',
                        onSelected: null,
                      ),
                  ],
                ),
              ],
            ),
          // In Playback the File menu only opens media files (bare .iamf
          // audio or .mp4 carrying an IAMF track) — its sole open action
          // and a same-mode reopen. From Creator it would be a cross-mode
          // jump (use the landing hub instead), so it is Playback-only
          // (ES-170). Placed first so the menu reads open → close.
          if (!isCreator)
            PlatformMenuItemGroup(
              members: [
                PlatformMenuItem(
                  label: 'Open File for Playback...',
                  shortcut: const SingleActivator(
                    LogicalKeyboardKey.keyO,
                    meta: true,
                  ),
                  onSelected: () => openIamfForQc(context, ref),
                ),
                PlatformMenu(
                  label: 'Open Recent',
                  menus: [
                    ...qcRecents.map(
                      (path) => PlatformMenuItem(
                        label: path,
                        onSelected: () =>
                            openIamfForQc(context, ref, path: path),
                      ),
                    ),
                    if (qcRecents.isEmpty)
                      const PlatformMenuItem(
                        label: 'No Recent Files',
                        onSelected: null,
                      ),
                  ],
                ),
              ],
            ),
          PlatformMenuItemGroup(
            members: [
              if (isCreator) ...[
                PlatformMenuItem(
                  label: 'Save',
                  shortcut: const SingleActivator(
                    LogicalKeyboardKey.keyS,
                    meta: true,
                  ),
                  onSelected: () => ref.read(sessionProvider.notifier).save(),
                ),
                PlatformMenuItem(
                  label: 'Save As...',
                  shortcut: const SingleActivator(
                    LogicalKeyboardKey.keyS,
                    meta: true,
                    shift: true,
                  ),
                  onSelected: () => ref.read(sessionProvider.notifier).saveAs(),
                ),
              ],
              PlatformMenuItem(
                label: isCreator ? 'Close Session' : 'Close File',
                shortcut: const SingleActivator(
                  LogicalKeyboardKey.keyW,
                  meta: true,
                ),
                onSelected: () => closeWorkspace(context, ref),
              ),
            ],
          ),
          if (isCreator)
            PlatformMenuItemGroup(
              members: [
                PlatformMenuItem(
                  label: 'Session Settings...',
                  shortcut: const SingleActivator(
                    LogicalKeyboardKey.comma,
                    meta: true,
                    shift: true,
                  ),
                  onSelected: () => SessionSettingsDialog.show(context),
                ),
                // Single entry; the target (IAMF / MP4 / YouTube) is chosen
                // inside the dialog, which gates MP4 on a usable video.
                PlatformMenuItem(
                  label: 'Export...',
                  shortcut: const SingleActivator(
                    LogicalKeyboardKey.keyE,
                    meta: true,
                  ),
                  onSelected: () => IamfExportDialog.show(context, ref),
                ),
              ],
            ),
        ],
      ),
      PlatformMenu(
        label: 'View',
        menus: [
          // The mode's tabs in top bar order, on Cmd+1 to Cmd+3.
          PlatformMenuItemGroup(
            members: [
              for (final (i, id) in WorkspaceTabs.allowedIn(mode).indexed)
                PlatformMenuItem(
                  label: WorkspaceTabs.title(id),
                  shortcut: workspaceTabShortcut(i, mac: true),
                  onSelected: () =>
                      ref.read(activeTabProvider.notifier).set(id),
                ),
            ],
          ),
          // Creator measures the session's sources; Playback measures
          // the loaded file (ES-520). The landing screen builds its own
          // View menu above, without this item.
          PlatformMenuItem(
            label: 'Loudness Report...',
            shortcut: const SingleActivator(
              LogicalKeyboardKey.keyL,
              meta: true,
            ),
            onSelected: () => LoudnessReportDialog.show(context),
          ),
          const PlatformProvidedMenuItem(
            type: PlatformProvidedMenuItemType.toggleFullScreen,
          ),
          themeGroup,
        ],
      ),
      PlatformMenu(
        label: 'Window',
        menus: [
          const PlatformProvidedMenuItem(
            type: PlatformProvidedMenuItemType.minimizeWindow,
          ),
          const PlatformProvidedMenuItem(
            type: PlatformProvidedMenuItemType.zoomWindow,
          ),
          // Recovery for a window stuck off screen or oversized (ES-613);
          // before this the only way back was `./build.sh reset-prefs`.
          PlatformMenuItem(
            label: 'Reset Window Size',
            onSelected: () =>
                unawaited(WindowStatePersister().resetToDefault()),
          ),
        ],
      ),
      helpMenu,
    ];
  }
}

/// Height of a row in the drop-down menus. A native Windows 11 menu
/// row is between 28 and 32 px at 100% scaling.
const double _menuRowHeight = 28;

/// Flutter-drawn menu bar for Windows / Linux. Mirrors the macOS
/// PlatformMenuBar contents but uses Material's [MenuBar] so it
/// renders inside the Flutter window (the OS doesn't host menus
/// for Flutter apps on these platforms).
///
/// On Windows it sits at the left of the window titlebar, which
/// `WindowTitlebar` draws, so its titles are inked and highlighted as
/// the titlebar's own: `chromeInk`, with the titlebar hover face
/// (`titlebarHoverFace`) on every ground. On Linux
/// [AppMenuBar] gives it a row of its own.
///
/// Differences from the macOS bar:
///   - No app-name menu (macOS-only convention) -- "Settings..." and
///     "Exit" live under File instead.
///   - "Window > Minimize / Zoom" dropped: native title-bar buttons
///     cover those, so a duplicate menu entry adds noise. The Window
///     menu keeps "Reset Window Size", which has no title-bar button.
///   - Shortcut modifiers use Ctrl, not Cmd (macOS uses Cmd).
class FlutterMenuBar extends ConsumerWidget {
  const FlutterMenuBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watch theme/font providers so MenuBar repaints on theme switch.
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);
    final mode = ref.watch(workspaceModeProvider);

    final isCreator = mode == WorkspaceMode.creator;
    final inWorkspace = mode != WorkspaceMode.none;
    final recents = ref.watch(recentSessionsProvider);
    final qcRecents = ref.watch(recentQcFilesProvider);

    // Top-level titles on the bar. The ground is set by _BarMenu, which
    // highlights a title while it is hovered or its menu is open.
    final barItemStyle = ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size(0, T.titlebar)),
      fixedSize: const WidgetStatePropertyAll(Size.fromHeight(T.titlebar)),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: T.gapMd),
      ),
      shape: const WidgetStatePropertyAll(RoundedRectangleBorder()),
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      // The row height is the one set here on every platform: no
      // 48 px touch-target padding, no density adjustment.
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.standard,
      foregroundColor: WidgetStatePropertyAll(T.chromeInk),
      textStyle: WidgetStatePropertyAll(TextStyle(fontSize: T.fontBody)),
    );

    // The drop-down panels: the same surface as ConsoleSelector's menu,
    // separated from the page by a border and no shadow.
    final panelStyle = MenuStyle(
      backgroundColor: WidgetStatePropertyAll(SelectorChrome.menuColor),
      surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
      elevation: const WidgetStatePropertyAll(0),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(T.radiusSm),
          side: BorderSide(color: T.border, width: T.borderWidth),
        ),
      ),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(vertical: T.gapXs),
      ),
    );

    // Rows inside a panel. The foreground colour inks the shortcut text
    // and the submenu arrow, which Material draws from the button's own
    // style; the label sets its colour itself, so the shortcut reads a
    // step quieter than the command.
    final panelItemStyle = ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size(200, _menuRowHeight)),
      fixedSize: const WidgetStatePropertyAll(Size.fromHeight(_menuRowHeight)),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: T.gapMd),
      ),
      shape: const WidgetStatePropertyAll(RoundedRectangleBorder()),
      overlayColor: const WidgetStatePropertyAll(Colors.transparent),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.standard,
      backgroundColor: WidgetStateProperty.resolveWith(
        (states) =>
            !states.contains(WidgetState.disabled) &&
                (states.contains(WidgetState.hovered) ||
                    states.contains(WidgetState.focused) ||
                    states.contains(WidgetState.pressed))
            ? T.bgHover
            : Colors.transparent,
      ),
      foregroundColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.disabled)
            ? T.textTertiary
            : T.textSecondary,
      ),
      iconColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.disabled)
            ? T.textTertiary
            : T.textSecondary,
      ),
      iconSize: const WidgetStatePropertyAll(T.iconSm),
      textStyle: WidgetStatePropertyAll(TextStyle(fontSize: T.fontBody)),
    );
    final labelStyle = TextStyle(color: T.textPrimary, fontSize: T.fontBody);
    final disabledStyle = TextStyle(
      color: T.textTertiary,
      fontSize: T.fontBody,
    );

    // `&` in a label marks the next character as an Alt-key accelerator
    // (e.g. '&File' -> press Alt+F to open). Pass `accelerator: false`
    // for user-supplied strings (file paths) where `&` is literal.
    Widget item(
      String label, {
      VoidCallback? onPressed,
      MenuSerializableShortcut? shortcut,
      bool accelerator = true,
    }) {
      final style = onPressed == null ? disabledStyle : labelStyle;
      return MenuItemButton(
        shortcut: shortcut,
        onPressed: onPressed,
        style: panelItemStyle,
        child: accelerator
            ? DefaultTextStyle.merge(
                style: style,
                child: MenuAcceleratorLabel(label),
              )
            : Text(label, style: style),
      );
    }

    // A submenu on the bar ([onBar]) or inside a panel (Open Recent).
    Widget submenu(String label, List<Widget> children, {bool onBar = false}) {
      if (onBar) {
        return _BarMenu(
          label: label,
          style: barItemStyle,
          menuStyle: panelStyle,
          menuChildren: children,
        );
      }
      return SubmenuButton(
        menuChildren: children,
        style: panelItemStyle,
        menuStyle: panelStyle,
        child: DefaultTextStyle.merge(
          style: labelStyle,
          child: MenuAcceleratorLabel(label),
        ),
      );
    }

    // A rule between groups of items, as a native menu separator: a
    // hairline with a few pixels of space above and below.
    Widget separator() =>
        Divider(height: T.gapSm + 1, thickness: T.borderWidth, color: T.border);

    // Joins the non-empty groups with a separator between each pair, so
    // a group that a mode leaves empty does not leave two rules together
    // (the landing screen has no Save / Close group).
    List<Widget> grouped(List<List<Widget>> groups) {
      final out = <Widget>[];
      for (final group in groups) {
        if (group.isEmpty) continue;
        if (out.isNotEmpty) out.add(separator());
        out.addAll(group);
      }
      return out;
    }

    // Grouped as the macOS File menu is: open, then save / close, then
    // the session commands, with Settings and Exit (which macOS keeps in
    // the app menu) in groups of their own at the end.
    final fileMenu = submenu(
      '&File',
      onBar: true,
      grouped([
        [
          // Creating / opening sessions lives in Creator mode (and on the
          // landing hub). Playback's File menu only opens IAMF / MP4
          // files (ES-170).
          if (mode != WorkspaceMode.playback) ...[
            item(
              '&New Session',
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyN,
                control: true,
              ),
              onPressed: () => startNewCreatorSession(context, ref),
            ),
            item(
              '&Open Session...',
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyO,
                control: true,
              ),
              onPressed: () => openCreatorSession(context, ref),
            ),
            submenu(
              'Open &Recent',
              recents.isEmpty
                  ? [item('No Recent Sessions', accelerator: false)]
                  : recents
                        .map(
                          (path) => item(
                            path,
                            accelerator: false,
                            onPressed: () =>
                                openCreatorSession(context, ref, path: path),
                          ),
                        )
                        .toList(),
            ),
          ],
          // In Playback the File menu only opens media files (bare .iamf
          // audio or .mp4 carrying an IAMF track) — its sole open action
          // and a same-mode reopen. From Creator it would be a cross-mode
          // jump (use the landing hub instead), so it is Playback-only
          // (ES-170). Placed first so the menu reads open → close.
          if (!isCreator) ...[
            item(
              '&Open File for Playback...',
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyO,
                control: true,
              ),
              onPressed: () => openIamfForQc(context, ref),
            ),
            submenu(
              'Open &Recent',
              qcRecents.isEmpty
                  ? [item('No Recent Files', accelerator: false)]
                  : qcRecents
                        .map(
                          (path) => item(
                            path,
                            accelerator: false,
                            onPressed: () =>
                                openIamfForQc(context, ref, path: path),
                          ),
                        )
                        .toList(),
            ),
          ],
        ],
        [
          if (isCreator) ...[
            item(
              '&Save',
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyS,
                control: true,
              ),
              onPressed: () => ref.read(sessionProvider.notifier).save(),
            ),
            item(
              'Save &As...',
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyS,
                control: true,
                shift: true,
              ),
              onPressed: () => ref.read(sessionProvider.notifier).saveAs(),
            ),
          ],
          if (inWorkspace)
            item(
              isCreator ? '&Close Session' : '&Close File',
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyW,
                control: true,
              ),
              onPressed: () => closeWorkspace(context, ref),
            ),
        ],
        [
          if (isCreator) ...[
            item(
              'Session Se&ttings...',
              shortcut: const SingleActivator(
                LogicalKeyboardKey.comma,
                control: true,
                shift: true,
              ),
              onPressed: () => SessionSettingsDialog.show(context),
            ),
            // Single entry; the target (IAMF / MP4 / YouTube) is chosen
            // inside the dialog, which gates MP4 on a usable video.
            item(
              '&Export...',
              shortcut: const SingleActivator(
                LogicalKeyboardKey.keyE,
                control: true,
              ),
              onPressed: () => IamfExportDialog.show(context, ref),
            ),
          ],
        ],
        [
          item(
            'Settin&gs...',
            shortcut: const SingleActivator(
              LogicalKeyboardKey.comma,
              control: true,
            ),
            onPressed: () => SettingsDialog.show(context),
          ),
        ],
        [
          item(
            'E&xit',
            shortcut: const SingleActivator(LogicalKeyboardKey.f4, alt: true),
            onPressed: requestWindowClose,
          ),
        ],
      ]),
    );

    final viewMenu = submenu(
      '&View',
      onBar: true,
      grouped([
        // The mode's tabs in top bar order, none on the landing screen.
        // Each name's first letter is its Alt key; none repeats another
        // item's in this menu. Ctrl+digit is display-only here, as Ctrl+L
        // is below; the workspace shell's key handler takes Ctrl+digit.
        [
          for (final (i, id) in WorkspaceTabs.allowedIn(mode).indexed)
            item(
              '&${WorkspaceTabs.title(id)}',
              shortcut: workspaceTabShortcut(i, mac: false),
              onPressed: () => ref.read(activeTabProvider.notifier).set(id),
            ),
        ],
        [
          // Creator and Playback (ES-520); greyed on the landing screen.
          // Ctrl+L is display-only here (Material MenuBar does not
          // register menu shortcuts), so a null onPressed fully disables
          // the item.
          item(
            '&Loudness Report...',
            shortcut: const SingleActivator(
              LogicalKeyboardKey.keyL,
              control: true,
            ),
            onPressed: inWorkspace
                ? () => LoudnessReportDialog.show(context)
                : null,
          ),
          item(
            'Toggle &Fullscreen',
            shortcut: const SingleActivator(LogicalKeyboardKey.f11),
            onPressed: () async {
              final isFs = await windowManager.isFullScreen();
              await windowManager.setFullScreen(!isFs);
            },
          ),
        ],
        // As in the macOS View menu: the gallery is debug-only, Next
        // Theme ships. Both are reachable by the unmodified `g` and `t`
        // as well (DevShortcuts), which is why neither carries a menu
        // shortcut here.
        [
          if (kThemeGalleryEnabled)
            item(
              '&Theme Gallery...',
              onPressed: () => ThemeGallery.show(context),
            ),
          item('&Next Theme', onPressed: () => ThemeCycle.next(ref)),
        ],
      ]),
    );

    final windowMenu = submenu('&Window', onBar: true, [
      item(
        '&Reset Window Size',
        onPressed: () => unawaited(WindowStatePersister().resetToDefault()),
      ),
    ]);

    final helpMenu = submenu('&Help', onBar: true, [
      item('&Release Notes...', onPressed: () => _showWhatsNew(context)),
      item(
        '&Third-Party Licenses...',
        onPressed: () => LicensesDialog.show(context),
      ),
      item(
        '&Keyboard Shortcuts',
        onPressed: () => ShortcutsDialog.show(context),
      ),
      item('&Export Log...', onPressed: () => exportLog(ref)),
    ]);

    return MenuBar(
      style: const MenuStyle(
        backgroundColor: WidgetStatePropertyAll(Colors.transparent),
        surfaceTintColor: WidgetStatePropertyAll(Colors.transparent),
        elevation: WidgetStatePropertyAll(0),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder()),
        padding: WidgetStatePropertyAll(EdgeInsets.zero),
      ),
      children: [fileMenu, viewMenu, windowMenu, helpMenu],
    );
  }
}

/// A top-level title on [FlutterMenuBar], in `chromeInk` like the
/// titlebar's title, and highlighted with [titlebarHoverFace] while the
/// pointer is over it or its menu is open.
///
/// Not highlighted on focus: a SubmenuButton takes focus back when its
/// menu closes, so a focus highlight stayed on the title after an item
/// was chosen or the menu was dismissed, until something else took
/// focus. A native Windows menu bar clears it when the menu closes.
class _BarMenu extends StatefulWidget {
  const _BarMenu({
    required this.label,
    required this.style,
    required this.menuStyle,
    required this.menuChildren,
  });

  final String label;
  final ButtonStyle style;
  final MenuStyle menuStyle;
  final List<Widget> menuChildren;

  @override
  State<_BarMenu> createState() => _BarMenuState();
}

class _BarMenuState extends State<_BarMenu> {
  bool _open = false;

  // onOpen and onClose can run while the tree is building or being torn
  // down (a menu closes when its anchor is removed), where setState is
  // not allowed; the change then waits for the end of the frame.
  void _setOpen(bool open) {
    if (!mounted || _open == open) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => _setOpen(open));
      return;
    }
    setState(() => _open = open);
  }

  @override
  Widget build(BuildContext context) {
    return SubmenuButton(
      menuChildren: widget.menuChildren,
      onOpen: () => _setOpen(true),
      onClose: () => _setOpen(false),
      style: widget.style.copyWith(
        backgroundColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.pressed)
              ? titlebarHoverFace(pressed: true)
              : _open || states.contains(WidgetState.hovered)
              ? titlebarHoverFace()
              : Colors.transparent,
        ),
      ),
      menuStyle: widget.menuStyle,
      child: DefaultTextStyle.merge(
        style: TextStyle(color: T.chromeInk, fontSize: T.fontBody),
        child: MenuAcceleratorLabel(widget.label),
      ),
    );
  }
}

/// Open the What's New dialog with the full release history.
Future<void> _showWhatsNew(BuildContext context) =>
    WhatsNewDialog.showAll(context);

/// Prompt for a destination and copy the live JSONL log there.
///
/// Remembers its own folder rather than reusing the export one: a support
/// dump and a deliverable rarely belong in the same place, and sharing a
/// value would leave the IAMF picker pointing at wherever a log last went.
Future<void> exportLog(WidgetRef ref) async {
  final now = DateTime.now();
  final stamp =
      '${now.year}-'
      '${now.month.toString().padLeft(2, '0')}-'
      '${now.day.toString().padLeft(2, '0')}_'
      '${now.hour.toString().padLeft(2, '0')}-'
      '${now.minute.toString().padLeft(2, '0')}-'
      '${now.second.toString().padLeft(2, '0')}';
  final path = await FilePicker.saveFile(
    dialogTitle: 'Export Log',
    fileName: 'eclipsa_studio_log_$stamp.txt',
    initialDirectory: ref.read(lastLogExportDirProvider),
  );
  if (path == null) return;
  ref.read(lastLogExportDirProvider.notifier).set(File(path).parent.path);
  final ok = await Log.exportToFile(path);
  if (ok) {
    Log.i(LogCat.app, 'Log copied to $path');
  } else {
    Log.w(LogCat.app, 'Log export failed');
  }
}
