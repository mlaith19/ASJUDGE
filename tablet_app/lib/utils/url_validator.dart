bool isValidHttpUrl(String? s) {
  if (s == null || s.trim().isEmpty) return false;
  final uri = Uri.tryParse(s.trim());
  if (uri == null || !uri.hasScheme) return false;
  return uri.scheme == 'http' || uri.scheme == 'https';
}
