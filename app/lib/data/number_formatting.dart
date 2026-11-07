/// Shared display formatting for human-readable training and nutrition values.
String formatRunFuelNumber(num value, {int decimals = 0}) {
  final parts = value.toStringAsFixed(decimals).split('.');
  final rawWhole = parts.first;
  final negative = rawWhole.startsWith('-');
  final digits = negative ? rawWhole.substring(1) : rawWhole;
  final grouped = digits.replaceAllMapped(
    RegExp(r'(\d)(?=(\d{3})+(?!\d))'),
    (match) => '${match[1]},',
  );
  return '${negative ? '-' : ''}$grouped${parts.length > 1 ? '.${parts[1]}' : ''}';
}
