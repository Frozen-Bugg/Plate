import 'package:intl/intl.dart';

/// "Sat 12 Sep"
String formatDay(DateTime utc) => DateFormat('EEE d MMM').format(utc.toLocal());

/// "18:05"
String formatTime(DateTime utc) => DateFormat.Hm().format(utc.toLocal());

/// "52 min", "1 h 05 min"
String formatDuration(Duration d) {
  if (d.inMinutes < 60) return '${d.inMinutes} min';
  final minutes = (d.inMinutes % 60).toString().padLeft(2, '0');
  return '${d.inHours} h $minutes min';
}

/// "3 min ago", "yesterday 18:05"
String formatAgo(DateTime utc, {DateTime? now}) {
  final current = now ?? DateTime.now();
  final local = utc.toLocal();
  final diff = current.difference(local);
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
  final today = DateTime(current.year, current.month, current.day);
  final day = DateTime(local.year, local.month, local.day);
  if (day == today) return 'today ${formatTime(utc)}';
  if (today.difference(day).inDays == 1) return 'yesterday ${formatTime(utc)}';
  return '${formatDay(utc)} ${formatTime(utc)}';
}

/// Weights are stored in kilograms and shown without trailing zeros: 60 rather
/// than 60.0, but 62.5 keeps its half.
String formatWeight(double kg) {
  final rounded = (kg * 100).round() / 100;
  final text = rounded == rounded.roundToDouble()
      ? rounded.toStringAsFixed(0)
      : rounded.toString();
  return '$text kg';
}

/// Reps in reserve, shown the way lifters write it.
String formatRir(double rir) {
  final text =
      rir == rir.roundToDouble() ? rir.toStringAsFixed(0) : rir.toString();
  return 'RIR $text';
}

/// A single plate, as a lifter would say it: 25, 2.5, 1.25.
String formatPlate(double kg) =>
    kg == kg.roundToDouble() ? kg.toStringAsFixed(0) : kg.toString();
