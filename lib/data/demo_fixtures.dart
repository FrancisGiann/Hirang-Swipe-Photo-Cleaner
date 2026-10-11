import '../domain/review_state.dart';

/// Fictional, permission-free fixtures used only by the demo deck.
class DemoFixtures {
  static final DateTime _recent = DateTime(2026, 10, 8, 14, 20);

  static final List<PhotoAsset> items = List.generate(8, (index) {
    final labels = [
      'Late light',
      'Market flowers',
      'Quiet coastline',
      'Morning cup',
      'Blue hour',
      'Garden notes',
      'A small detail',
      'Weekend plan',
    ];
    final albums = ['Moments', 'Weekend', 'Travel', 'Everyday'];
    return PhotoAsset(
      id: 'hirang-demo-${index + 1}',
      title: labels[index],
      album: albums[index % albums.length],
      dateTakenMillis: _recent
          .subtract(Duration(days: index * 5))
          .millisecondsSinceEpoch,
      sizeBytes: 1400000 + index * 310000,
      screenshotHeuristic: index == 7,
      demoIndex: index,
    );
  }, growable: false);
}
