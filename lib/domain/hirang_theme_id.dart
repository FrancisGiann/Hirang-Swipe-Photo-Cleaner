enum HirangThemeId {
  amihan(
    'amihan',
    'Amihan',
    'Cool ivory with deep blue and sky-blue accents.',
    false,
  ),
  dapithapon(
    'dapithapon',
    'Dapithapon',
    'Warm cream with terracotta and muted-peach accents.',
    false,
  ),
  hatinggabi(
    'hatinggabi',
    'Hatinggabi',
    'Charcoal surfaces with soft white and lavender accents.',
    true,
  );

  const HirangThemeId(
    this.storageId,
    this.label,
    this.description,
    this.isDark,
  );

  final String storageId;
  final String label;
  final String description;
  final bool isDark;

  static HirangThemeId fromStorage(Object? value) {
    for (final theme in values) {
      if (theme.storageId == value) return theme;
    }
    return HirangThemeId.amihan;
  }
}
