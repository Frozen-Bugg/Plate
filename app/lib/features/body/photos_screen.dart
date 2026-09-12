import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/day.dart';
import '../../core/db/app_database.dart';
import '../../core/format.dart';
import 'body_repository.dart';
import 'photos_repository.dart';

/// Progress photos, newest first, and a way to put two side by side.
///
/// The comparison is the point. A photo on its own says very little — nobody
/// can see a month of work in a single mirror shot — and two twelve weeks apart
/// say more than the scale ever does during a recomposition.
class PhotosScreen extends ConsumerStatefulWidget {
  const PhotosScreen({super.key});

  @override
  ConsumerState<PhotosScreen> createState() => _PhotosScreenState();
}

class _PhotosScreenState extends ConsumerState<PhotosScreen> {
  /// Ids picked for comparison. Two at a time; the oldest drops off.
  final _selected = <String>[];
  var _busy = false;

  Future<void> _capture(ImageSource source) async {
    setState(() => _busy = true);
    try {
      final picked = await ImagePicker().pickImage(
        source: source,
        // Plenty for a comparison, and small enough to upload on gym wifi.
        maxWidth: 1440,
        imageQuality: 85,
      );
      if (picked == null) return;

      final pose = await _askPose();
      if (pose == null || !mounted) return;

      await ref.read(photosRepositoryProvider).add(
            image: File(picked.path),
            pose: pose,
            // Stamped with today's trend weight so a comparison can be labelled
            // without digging the number out later.
            weightKg: ref.read(trendWeightProvider),
          );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _askPose() => showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        builder: (context) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (value, label) in const [
                ('front', 'Front'),
                ('side', 'Side'),
                ('back', 'Back'),
                ('other', 'Other'),
              ])
                ListTile(
                  title: Text(label),
                  onTap: () => Navigator.pop(context, value),
                ),
            ],
          ),
        ),
      );

  void _toggle(ProgressPhoto photo) {
    setState(() {
      if (_selected.remove(photo.id)) return;
      _selected.add(photo.id);
      if (_selected.length > 2) _selected.removeAt(0);
    });
  }

  Future<void> _delete(ProgressPhoto photo) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this photo?'),
        content: const Text(
          'It goes from this phone and from the server. There is no undo.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await ref.read(photosRepositoryProvider).delete(photo);
    setState(() => _selected.remove(photo.id));
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final photos = ref.watch(progressPhotosProvider).value ?? const [];
    final chosen =
        photos.where((p) => _selected.contains(p.id)).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Progress photos'),
        actions: [
          IconButton(
            icon: const Icon(Icons.photo_library_outlined),
            tooltip: 'Choose a photo',
            onPressed: _busy ? null : () => _capture(ImageSource.gallery),
          ),
          IconButton(
            icon: const Icon(Icons.photo_camera_outlined),
            tooltip: 'Take a photo',
            onPressed: _busy ? null : () => _capture(ImageSource.camera),
          ),
        ],
      ),
      body: photos.isEmpty
          ? _Empty(onAdd: _busy ? null : () => _capture(ImageSource.camera))
          : Column(
              children: [
                if (chosen.length == 2)
                  _Compare(
                    photos: chosen,
                    onClear: () => setState(_selected.clear),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: Text(
                      _selected.isEmpty
                          ? 'Tap two photos to compare them.'
                          : 'Pick one more to compare.',
                      style: text.bodySmall?.copyWith(color: muted),
                    ),
                  ),
                Expanded(
                  child: GridView.builder(
                    padding: const EdgeInsets.all(12),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                      childAspectRatio: 0.72,
                    ),
                    itemCount: photos.length,
                    itemBuilder: (context, index) {
                      final photo = photos[index];
                      return _Thumbnail(
                        photo: photo,
                        selected: _selected.contains(photo.id),
                        onTap: () => _toggle(photo),
                        onLongPress: () => _delete(photo),
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }
}

/// Two photos side by side, with the gap between them named.
class _Compare extends StatelessWidget {
  const _Compare({required this.photos, required this.onClear});

  final List<ProgressPhoto> photos;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final ordered = [...photos]
      ..sort((a, b) => a.takenOn.compareTo(b.takenOn));
    final days = parseDayKey(ordered.last.takenOn)
        .difference(parseDayKey(ordered.first.takenOn))
        .inDays;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Column(
        children: [
          Row(
            children: [
              for (final photo in ordered)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Column(
                      children: [
                        AspectRatio(
                          aspectRatio: 0.72,
                          child: _Image(photo: photo, fit: BoxFit.cover),
                        ),
                        const SizedBox(height: 4),
                        Text(photo.takenOn, style: text.labelSmall),
                        if (photo.weightKg case final kg?)
                          Text(formatWeight(kg),
                              style:
                                  text.labelSmall?.copyWith(color: muted)),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                days == 0
                    ? 'Same day'
                    : '$days ${days == 1 ? 'day' : 'days'} apart',
                style: text.bodySmall?.copyWith(color: muted),
              ),
              TextButton(onPressed: onClear, child: const Text('Clear')),
            ],
          ),
        ],
      ),
    );
  }
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({
    required this.photo,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
  });

  final ProgressPhoto photo;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? scheme.primary : scheme.outlineVariant,
            width: selected ? 2.5 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            _Image(photo: photo, fit: BoxFit.cover),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                color: Colors.black54,
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                child: Text(
                  '${photo.takenOn.substring(5)} · ${photo.pose}',
                  style: Theme.of(context)
                      .textTheme
                      .labelSmall
                      ?.copyWith(color: Colors.white),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The photo itself, read from this device's copy.
///
/// Always local: the bucket is private, so showing one from the server would
/// mean minting a signed URL per thumbnail. The copy on disk is the same image
/// and costs nothing.
class _Image extends ConsumerWidget {
  const _Image({required this.photo, required this.fit});

  final ProgressPhoto photo;
  final BoxFit fit;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FutureBuilder<File?>(
      future: ref.watch(photosRepositoryProvider).localFile(photo),
      builder: (context, snapshot) {
        final file = snapshot.data;
        if (file == null) {
          // Taken on another device: the row synced, the file did not.
          return ColoredBox(
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
            child: Center(
              child: Icon(Icons.image_not_supported_outlined,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            ),
          );
        }
        return Image.file(file, fit: fit);
      },
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.onAdd});

  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Same light, same spot', style: text.headlineSmall),
            const SizedBox(height: 8),
            Text(
              'Once a fortnight is plenty. Photos stay in a private bucket only '
              'you can read, and never leave this phone unless you are signed '
              'in and online.',
              textAlign: TextAlign.center,
              style: text.bodyMedium?.copyWith(color: muted),
            ),
            const SizedBox(height: 20),
            FilledButton(onPressed: onAdd, child: const Text('Take one')),
          ],
        ),
      ),
    );
  }
}
