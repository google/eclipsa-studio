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

import 'package:flutter/foundation.dart' show LicenseEntry, LicenseRegistry;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state.dart';
import '../theme.dart';
import 'app_dialog.dart';
import 'dialog_shell.dart';
import 'eyebrow_label.dart';

/// Where a license entry comes from, used to group the Third-Party
/// Licenses view by source rather than the flat alphabetical list the
/// stock [showLicensePage] produces.
enum _Category { engine, frameworks, app }

extension on _Category {
  /// Section label (Title Case — this is a dialog section header).
  String get label => switch (this) {
    _Category.engine => 'Audio Engine — Native Libraries',
    _Category.frameworks => 'Bundled Frameworks',
    _Category.app => 'Flutter & Dart Packages',
  };
}

/// One selectable component in the list: a package/library and the full
/// text of every license registered under it.
class _Component {
  const _Component(this.title, this.body, this.category);
  final String title;
  final String body;
  final _Category category;
}

/// Custom, app-themed "Third-Party Licenses" view.
///
/// Named "third-party" rather than "open source" on purpose: not every
/// bundled component is OSI-open-source (e.g. Fraunhofer FDK AAC is
/// source-available but withholds a patent grant), so the broader term is
/// accurate for the whole set. It also matches the repo's
/// `third_party_notices` artifacts.
///
/// Replaces Flutter's generic [showLicensePage]. It reads the same data
/// (`LicenseRegistry`): Flutter's auto-collected Dart/Flutter package
/// NOTICES plus the entries `main.dart` registers at startup from the
/// generated notices file (the engine's statically linked libraries,
/// the libraries and frameworks shipped beside the app, and the
/// bundled typefaces). It groups them by source and renders them in the
/// app's dialog chrome.
class LicensesDialog extends ConsumerStatefulWidget {
  const LicensesDialog({super.key});

  /// The `kind` the notices generator wrote for each native entry, by
  /// package label, filled by `main.dart` as it registers them:
  /// `framework` for an entry that ships .framework bundles, `engine`
  /// for the rest.
  static final Map<String, String> nativeKinds = {};

  /// The section label [package] is listed under.
  @visibleForTesting
  static String sectionLabelFor(String package) =>
      _LicensesDialogState._categorize(package).label;

  static Future<void> show(BuildContext context) => showAppDialog<void>(
    context: context,
    id: LicensesDialog,
    builder: (_) => const LicensesDialog(),
  );

  @override
  ConsumerState<LicensesDialog> createState() => _LicensesDialogState();
}

class _LicensesDialogState extends ConsumerState<LicensesDialog> {
  late final Future<List<_Component>> _components = _collect();
  _Component? _selected;

  /// Every native entry is in [LicensesDialog.nativeKinds] before it is
  /// registered, so a package label missing from it is a pub package.
  static _Category _categorize(String package) {
    final kind = LicensesDialog.nativeKinds[package];
    if (kind == null) return _Category.app;
    return kind == 'framework' ? _Category.frameworks : _Category.engine;
  }

  static String _entryText(LicenseEntry entry) {
    final sb = StringBuffer();
    for (final p in entry.paragraphs) {
      if (sb.isNotEmpty) sb.write('\n');
      sb.write(p.indent > 0 ? '${'    ' * p.indent}${p.text}' : p.text);
    }
    return sb.toString();
  }

  Future<List<_Component>> _collect() async {
    final byPackage = <String, StringBuffer>{};
    await for (final entry in LicenseRegistry.licenses) {
      final text = _entryText(entry);
      for (final package in entry.packages) {
        final buf = byPackage.putIfAbsent(package, StringBuffer.new);
        if (buf.isNotEmpty) buf.write('\n\n${'─' * 32}\n\n');
        buf.write(text);
      }
    }
    final list = [
      for (final e in byPackage.entries)
        _Component(e.key, e.value.toString(), _categorize(e.key)),
    ]..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
    return list;
  }

  @override
  Widget build(BuildContext context) {
    // Const-skip: track theme/font so the dialog repaints on a switch.
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);
    final version = ref.read(appVersionProvider);

    return DialogShell(
      title: 'Third-Party Licenses',
      subtitle:
          'Eclipsa Studio $version — components Eclipsa Studio is '
          'built on',
      width: 920,
      maxHeight: 640,
      bodyFit: DialogBodyFit.expand,
      footerDivider: true,
      actions: [DialogShell.done(context)],
      child: FutureBuilder<List<_Component>>(
        future: _components,
        builder: (ctx, snap) => snap.hasData
            ? _body(snap.data!)
            : const Center(child: CircularProgressIndicator()),
      ),
    );
  }

  Widget _body(List<_Component> all) {
    if (all.isEmpty) {
      return Center(
        child: Text(
          'No licenses found',
          style: TextStyle(fontSize: T.fontBody, color: T.textMuted),
        ),
      );
    }
    final byCat = <_Category, List<_Component>>{};
    for (final c in all) {
      byCat.putIfAbsent(c.category, () => []).add(c);
    }
    // Default to the first audio-engine component (our content), else first.
    final selected =
        _selected ?? byCat[_Category.engine]?.first ?? byCat.values.first.first;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(width: 320, child: _list(byCat, selected)),
        const SizedBox(width: 16),
        Expanded(child: _detail(selected)),
      ],
    );
  }

  Widget _list(Map<_Category, List<_Component>> byCat, _Component selected) {
    return _panel(
      ListView(
        padding: const EdgeInsets.symmetric(vertical: 6),
        children: [
          for (final cat in _Category.values)
            if (byCat[cat]?.isNotEmpty ?? false) ...[
              _categoryHeader(cat, byCat[cat]!.length),
              for (final c in byCat[cat]!) _tile(c, identical(c, selected)),
            ],
        ],
      ),
    );
  }

  Widget _categoryHeader(_Category cat, int count) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
      child: EyebrowLabel('${cat.label}  ·  $count'),
    );
  }

  Widget _tile(_Component c, bool selected) {
    return InkWell(
      onTap: () => setState(() => _selected = c),
      child: Container(
        color: selected ? T.bgSelected : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        child: Text(
          c.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: T.fontSmall,
            height: 1.3,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            color: selected ? T.purpleLight : T.textSecondary,
          ),
        ),
      ),
    );
  }

  Widget _detail(_Component c) {
    return _panel(
      Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              c.title,
              style: TextStyle(
                fontSize: T.fontHeading,
                fontWeight: FontWeight.w600,
                color: T.textPrimary,
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: SingleChildScrollView(
                child: SelectableText(
                  c.body,
                  style: TextStyle(
                    fontFamily: T.monoFamily,
                    fontSize: T.fontSmall,
                    height: 1.5,
                    color: T.textTertiary,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _panel(Widget child) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: T.bgBase,
        borderRadius: BorderRadius.circular(T.radius),
        border: Border.all(color: T.border),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(T.radius),
        child: child,
      ),
    );
  }
}
