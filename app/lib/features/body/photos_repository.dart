import 'dart:io';

import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:powersync/powersync.dart' show uuid;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/auth/auth_service.dart';
import '../../core/day.dart';
import '../../core/db/app_database.dart';
import '../../core/db/database_providers.dart';

final _log = Logger('photos');

/// Progress photos: the row syncs, the image does not.
///
/// PowerSync moves rows, not files, so the picture takes a different path from
/// everything else in the app. It is copied into the app's own directory
/// immediately — so the photo survives the lifter clearing their camera roll —
/// and uploaded to a private Supabase bucket when there is a connection.
///
/// Offline capture matters here more than anywhere else: photos get taken in
/// gym changing rooms, which is exactly where there is no signal. A file that
/// has not made it up yet keeps a `.pending` suffix, and [uploadPending] walks
/// them on the next launch. The row exists either way, so the photo is visible
/// on this device from the moment it is taken.
class PhotosRepository {
  PhotosRepository(this._db, this._userId, this._storage);

  final AppDatabase _db;
  final String _userId;
  final SupabaseClient? _storage;

  static const bucket = 'progress-photos';

  Stream<List<ProgressPhoto>> watchRecent({int limit = 200}) {
    return (_db.select(_db.progressPhotos)
          ..where((p) => p.userId.equals(_userId))
          ..where((p) => p.deletedAt.isNull())
          ..orderBy([(p) => OrderingTerm.desc(p.takenOn)])
          ..limit(limit))
        .watch();
  }

  /// Where this device keeps its copies.
  Future<Directory> _localDirectory() async {
    final documents = await getApplicationDocumentsDirectory();
    final directory = Directory(p.join(documents.path, 'progress_photos'));
    if (!directory.existsSync()) await directory.create(recursive: true);
    return directory;
  }

  /// The local file for a photo, uploaded or not.
  Future<File?> localFile(ProgressPhoto photo) async {
    final directory = await _localDirectory();
    for (final name in ['${photo.id}.jpg', '${photo.id}.jpg.pending']) {
      final file = File(p.join(directory.path, name));
      if (file.existsSync()) return file;
    }
    return null;
  }

  /// Files and rows a photo, from an image the lifter just took or picked.
  ///
  /// The object key is `<user id>/<photo id>.jpg`, which is the shape every
  /// storage policy on the bucket checks: a leaked row id gets nobody anything.
  Future<String> add({
    required File image,
    required String pose,
    String? day,
    double? weightKg,
  }) async {
    final id = uuid.v7();
    final on = day ?? dayKey();
    final directory = await _localDirectory();
    final local = File(p.join(directory.path, '$id.jpg.pending'));
    await image.copy(local.path);

    await _db.into(_db.progressPhotos).insert(
          ProgressPhotosCompanion.insert(
            id: Value(id),
            userId: _userId,
            takenOn: on,
            storagePath: '$_userId/$id.jpg',
            pose: Value(pose),
            weightKg: Value(weightKg),
          ),
        );

    await _upload(local, '$_userId/$id.jpg');
    return id;
  }

  /// Uploads anything still waiting. Safe to call on every launch.
  Future<int> uploadPending() async {
    final directory = await _localDirectory();
    final pending = directory
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.jpg.pending'))
        .toList();

    var uploaded = 0;
    for (final file in pending) {
      final id = p.basename(file.path).replaceAll('.jpg.pending', '');
      // Only upload files that still have a row: a deleted photo leaves its
      // file behind until this notices and cleans it up.
      final row = await (_db.select(_db.progressPhotos)
            ..where((p) => p.id.equals(id))
            ..where((p) => p.deletedAt.isNull())
            ..limit(1))
          .getSingleOrNull();
      if (row == null) {
        await file.delete();
        continue;
      }
      if (await _upload(file, row.storagePath)) uploaded++;
    }
    return uploaded;
  }

  /// Returns whether the file made it up. A failure is not an error the lifter
  /// needs to see — the photo is safe on the device and this runs again.
  Future<bool> _upload(File file, String path) async {
    final storage = _storage;
    if (storage == null) return false;
    try {
      await storage.storage.from(bucket).upload(
            path,
            file,
            fileOptions: const FileOptions(upsert: true),
          );
      // Drop the suffix so the next sweep skips it.
      await file.rename(file.path.replaceAll('.jpg.pending', '.jpg'));
      return true;
    } catch (e) {
      _log.info('Progress photo still waiting to upload: $e');
      return false;
    }
  }

  /// Soft delete, so the deletion reaches every device, plus the local copy and
  /// the object itself. A progress photo is the most personal thing the app
  /// holds: deleting it should actually delete it.
  Future<void> delete(ProgressPhoto photo) async {
    final now = nowUtc();
    await (_db.update(_db.progressPhotos)..where((p) => p.id.equals(photo.id)))
        .write(
      ProgressPhotosCompanion(deletedAt: Value(now), updatedAt: Value(now)),
    );

    if (await localFile(photo) case final file?) {
      await file.delete();
    }
    try {
      await _storage?.storage.from(bucket).remove([photo.storagePath]);
    } catch (e) {
      // The row is already marked deleted, so the photo is gone from every
      // screen. An object left behind is a cleanup problem, not a data one.
      _log.warning('Could not remove the stored photo: $e');
    }
  }
}

final photosRepositoryProvider = Provider<PhotosRepository>((ref) {
  final user = ref.watch(currentUserProvider);
  if (user == null) {
    throw StateError('PhotosRepository used while signed out');
  }
  return PhotosRepository(
    ref.watch(appDatabaseProvider),
    user.id,
    Supabase.instance.client,
  );
});

final progressPhotosProvider = StreamProvider<List<ProgressPhoto>>(
  (ref) => ref.watch(photosRepositoryProvider).watchRecent(),
);

/// Sweeps up any photo that has not made it to the bucket yet.
///
/// Runs once per launch from the shell. Gym changing rooms have no signal, so
/// the common case is a photo taken offline and uploaded the next time the app
/// opens somewhere with wifi.
final pendingPhotoUploadProvider = FutureProvider<int>(
  (ref) => ref.watch(photosRepositoryProvider).uploadPending(),
);
