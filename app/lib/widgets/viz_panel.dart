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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../renderer/viz_module.dart';
import '../renderer/viz_state.dart';
import '../state.dart';
import '../theme.dart';
import 'app_button.dart';
import 'eyebrow_label.dart';

/// Collapsible panel listing all registered channel-viz modules with
/// per-module toggles, param sliders, and a debug-HUD toggle.
///
/// Drops into the renderer view as a `Positioned` child. State routes
/// through [vizStateProvider], persisting via AppPreferences.
class VizPanel extends ConsumerStatefulWidget {
  const VizPanel({super.key});

  @override
  ConsumerState<VizPanel> createState() => _VizPanelState();
}

class _VizPanelState extends ConsumerState<VizPanel> {
  bool _expanded = false;
  final Set<String> _openModules = {};

  @override
  Widget build(BuildContext context) {
    // Panel is constructed as `const VizPanel()` upstream, so parent
    // rebuilds skip past it (Element.updateChild bails when widget
    // identity matches). Watch theme + font-mode here so the panel
    // tracks them on its own.
    ref.watch(themeModeProvider);
    ref.watch(fontSizeModeProvider);
    final channel = VizRegistry.ofDomain(VizDomain.channel);
    final scene = VizRegistry.ofDomain(VizDomain.scene);
    return Material(
      type: MaterialType.transparency,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
        width: _expanded ? 320 : 148,
        constraints: const BoxConstraints(maxHeight: 600),
        // Border-only separation from the canvas behind — follows the
        // project's "no decorative drop shadows" convention.
        decoration: BoxDecoration(
          color: T.bgSurface.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(T.radiusSm),
          border: Border.all(color: T.borderLight),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(
              expanded: _expanded,
              onTap: () => setState(() => _expanded = !_expanded),
            ),
            // Not const: _PanelDivider reads T.* — a const instance is
            // canonicalized and skips rebuilds on theme switches.
            if (_expanded) _PanelDivider(),
            if (_expanded)
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(T.gapSm),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (channel.isEmpty && scene.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(8),
                          child: Text(
                            'No visualizers registered.',
                            style: T.styleLabel,
                          ),
                        ),
                      if (channel.isNotEmpty) ...[
                        // Not const: reads T.* (see _PanelDivider above).
                        _SectionLabel('Channel-based'),
                        const SizedBox(height: 4),
                        for (var i = 0; i < channel.length; i++) ...[
                          if (i > 0) const SizedBox(height: T.gapPair),
                          _buildCard(channel[i]),
                        ],
                      ],
                      if (scene.isNotEmpty) ...[
                        if (channel.isNotEmpty) const SizedBox(height: 12),
                        // Not const: reads T.* (see _PanelDivider above).
                        _SectionLabel('Ambisonic'),
                        const SizedBox(height: 4),
                        for (var i = 0; i < scene.length; i++) ...[
                          if (i > 0) const SizedBox(height: T.gapPair),
                          _buildCard(scene[i]),
                        ],
                      ],
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildCard(VizModule m) {
    return _ModuleCard(
      module: m,
      open: _openModules.contains(m.id),
      onToggleOpen: () => setState(() {
        if (_openModules.contains(m.id)) {
          _openModules.remove(m.id);
        } else {
          _openModules.add(m.id);
        }
      }),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(padding: const EdgeInsets.all(2), child: EyebrowLabel(text));
  }
}

/// Header row — expand caret on the left, title in the middle, debug-
/// HUD toggle on the right.
class _Header extends ConsumerWidget {
  final bool expanded;
  final VoidCallback onTap;

  const _Header({required this.expanded, required this.onTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final hudOn = ref.watch(vizHudVisibleProvider);
    return Row(
      children: [
        Expanded(
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(T.radiusSm),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
              child: Row(
                children: [
                  Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                    size: T.iconSm,
                    color: T.textSecondary,
                  ),
                  const SizedBox(width: T.gapPair),
                  Text(
                    'Visualizers',
                    style: TextStyle(
                      fontSize: T.fontSmall,
                      fontWeight: FontWeight.w600,
                      color: T.textPrimary,
                      letterSpacing: 0.2,
                    ),
                  ),
                  if (expanded) ...[
                    const SizedBox(width: 8),
                    // Not const: reads T.* (see _PanelDivider). FittedBox
                    // keeps the pill from overflowing the header at the
                    // Large font size.
                    Flexible(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        child: _ExperimentalTag(),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        _HeaderAction(
          tooltip: hudOn ? 'Hide stats HUD' : 'Show stats HUD',
          icon: Icons.insights,
          active: hudOn,
          onPressed: () => ref.read(vizHudVisibleProvider.notifier).toggle(),
        ),
      ],
    );
  }
}

/// "EXPERIMENTAL" pill shown next to the title while the panel is
/// expanded — the visualizer feature ships as a preview in 0.20.
/// Styled after MixStatusBadge, the app's status-pill pattern.
class _ExperimentalTag extends StatelessWidget {
  const _ExperimentalTag();

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message:
          'Visualizers are experimental. '
          'Behavior and performance may change.',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration: BoxDecoration(
          color: T.meterYellow.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(T.radiusSm),
        ),
        child: Text(
          'EXPERIMENTAL',
          style: TextStyle(
            fontSize: T.fontCaption,
            color: T.meterYellow,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

class _HeaderAction extends StatelessWidget {
  final String tooltip;
  final IconData icon;
  final bool active;
  final VoidCallback onPressed;

  const _HeaderAction({
    required this.tooltip,
    required this.icon,
    required this.active,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(T.radiusSm),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(
            icon,
            size: T.iconSm,
            color: active ? T.purple : T.textSecondary,
          ),
        ),
      ),
    );
  }
}

class _PanelDivider extends StatelessWidget {
  const _PanelDivider();

  @override
  Widget build(BuildContext context) {
    return Container(height: 1, color: T.borderLight.withValues(alpha: 0.6));
  }
}

/// One module card — toggle switch, name + description, tune button.
/// Expanded state shows sliders and a reset button.
class _ModuleCard extends ConsumerWidget {
  final VizModule module;
  final bool open;
  final VoidCallback onToggleOpen;

  const _ModuleCard({
    required this.module,
    required this.open,
    required this.onToggleOpen,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(vizStateProvider.notifier);
    // Watch so rebuilding on toggle is cheap.
    ref.watch(vizStateProvider);
    final s = notifier.stateFor(module.id);

    return Container(
      decoration: BoxDecoration(
        color: T.bgElevated.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(T.radiusSm),
        border: Border.all(
          color: s.enabled
              ? T.purple.withValues(alpha: 0.35)
              : T.borderLight.withValues(alpha: 0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Row 1 — toggle, title/desc, tune affordance.
          InkWell(
            onTap: module.params.isEmpty ? null : onToggleOpen,
            borderRadius: BorderRadius.circular(T.radiusSm),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(6, 6, 6, 6),
              child: Row(
                children: [
                  SizedBox(
                    height: 24,
                    width: 38,
                    child: Switch(
                      value: s.enabled,
                      onChanged: (v) => notifier.setEnabled(module.id, v),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                  const SizedBox(width: T.gapPair),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          module.displayName,
                          style: TextStyle(
                            fontSize: T.fontBody,
                            color: T.textPrimary,
                            fontWeight: FontWeight.w600,
                            height: 1.2,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          module.description,
                          style: TextStyle(
                            fontSize: T.fontCaption,
                            color: T.textMuted,
                            height: 1.25,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (module.params.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(left: 2),
                      child: Icon(
                        open ? Icons.expand_less : Icons.tune,
                        size: T.iconSm,
                        color: T.textSecondary,
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (open && module.params.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    height: 1,
                    margin: const EdgeInsets.only(bottom: 6),
                    color: T.borderLight.withValues(alpha: 0.4),
                  ),
                  for (final p in module.params)
                    _ParamSlider(module: module, param: p),
                  const SizedBox(height: 2),
                  Align(
                    alignment: Alignment.centerRight,
                    child: AppButton(
                      label: 'Reset',
                      icon: Icons.restore,
                      role: AppButtonRole.quiet,
                      size: AppButtonSize.compact,
                      onPressed: () => notifier.resetModule(module.id),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// One parameter row — label + tabular-figures value + slider.
class _ParamSlider extends ConsumerWidget {
  final VizModule module;
  final VizParam param;

  const _ParamSlider({required this.module, required this.param});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(vizStateProvider.notifier);
    ref.watch(vizStateProvider);
    final s = notifier.stateFor(module.id);
    final value = s.values[param.id] ?? param.defaultValue;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  param.label,
                  style: TextStyle(
                    fontSize: T.fontCaption,
                    color: T.textSecondary,
                  ),
                ),
              ),
              Text(
                _formatValue(value, param.unit),
                style: TextStyle(
                  fontSize: T.fontCaption,
                  color: T.textPrimary,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          SizedBox(
            height: 18,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape: SliderComponentShape.noOverlay,
                activeTrackColor: T.purple,
                inactiveTrackColor: T.borderLight.withValues(alpha: 0.6),
                thumbColor: T.purple,
              ),
              child: Slider(
                value: value.clamp(param.min, param.max),
                min: param.min,
                max: param.max,
                onChanged: (v) => notifier.setParam(module.id, param.id, v),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatValue(double v, String unit) {
    final s = v.abs() >= 10 ? v.toStringAsFixed(1) : v.toStringAsFixed(2);
    return unit.isEmpty ? s : '$s $unit';
  }
}
