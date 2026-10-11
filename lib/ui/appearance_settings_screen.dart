import 'dart:async';

import 'package:flutter/material.dart';

import '../app/hirang_theme.dart';
import '../app/sift_controller.dart';
import '../domain/hirang_theme_id.dart';

class AppearanceSettingsScreen extends StatefulWidget {
  const AppearanceSettingsScreen({super.key, required this.controller});

  final SiftController controller;

  @override
  State<AppearanceSettingsScreen> createState() =>
      _AppearanceSettingsScreenState();
}

class _AppearanceSettingsScreenState extends State<AppearanceSettingsScreen> {
  bool _saving = false;
  String? _saveError;

  Future<void> _select(HirangThemeId id) async {
    if (_saving || widget.controller.state.themeId == id) return;
    setState(() {
      _saving = true;
      _saveError = null;
    });
    final saved = await widget.controller.selectTheme(id);
    if (!mounted) return;
    setState(() {
      _saving = false;
      _saveError = saved ? null : widget.controller.error;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final theme = Theme.of(context);
        final colors = theme.colorScheme;
        final selected = widget.controller.state.themeId;
        return Scaffold(
          appBar: AppBar(title: const Text('Settings')),
          body: SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(18, 10, 18, 24),
              children: [
                Text(
                  'Appearance',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Theme',
                  style: theme.textTheme.labelLarge?.copyWith(
                    color: colors.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Your choice is saved on this device. Photo colors stay unchanged.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
                if (_saving) ...[
                  const SizedBox(height: 16),
                  const LinearProgressIndicator(),
                ],
                if (_saveError case final message?) ...[
                  const SizedBox(height: 12),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      message,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colors.error,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 18),
                RadioGroup<HirangThemeId>(
                  groupValue: selected,
                  onChanged: (value) {
                    if (!_saving && value != null) unawaited(_select(value));
                  },
                  child: Column(
                    children: [
                      for (final id in HirangThemeId.values)
                        _ThemeOption(
                          id: id,
                          selected: selected == id,
                          enabled: !_saving,
                        ),
                    ],
                  ),
                ),
                if (_saving)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      'Saving appearance…',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ThemeOption extends StatelessWidget {
  const _ThemeOption({
    required this.id,
    required this.selected,
    required this.enabled,
  });

  final HirangThemeId id;
  final bool selected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final palette = hirangPaletteFor(id);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(
          color: selected ? colors.primary : colors.outlineVariant,
          width: selected ? 2 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: RadioListTile<HirangThemeId>(
        key: Key('themeOption-${id.storageId}'),
        value: id,
        selected: selected,
        enabled: enabled,
        activeColor: colors.primary,
        selectedTileColor: colors.primaryContainer.withValues(alpha: .25),
        contentPadding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        title: Text(
          id.label,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 5),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(id.description),
              const SizedBox(height: 10),
              _PaletteSwatches(palette: palette),
            ],
          ),
        ),
      ),
    );
  }
}

class _PaletteSwatches extends StatelessWidget {
  const _PaletteSwatches({required this.palette});

  final HirangPalette palette;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Palette preview',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Swatch(color: palette.scaffold, outline: palette.primary),
          const SizedBox(width: 7),
          _Swatch(color: palette.primary),
          const SizedBox(width: 7),
          _Swatch(color: palette.secondary),
          const SizedBox(width: 7),
          _Swatch(color: palette.tertiary),
        ],
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({required this.color, this.outline});

  final Color color;
  final Color? outline;

  @override
  Widget build(BuildContext context) => Container(
    width: 28,
    height: 22,
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(7),
      border: Border.all(color: outline ?? color.withValues(alpha: .9)),
    ),
  );
}
