bool isPublicHttpUri(Uri uri) {
  if (uri.scheme != 'http' && uri.scheme != 'https') return false;
  if (uri.host.isEmpty) return false;
  if (uri.hasAuthority && (uri.userInfo.isNotEmpty)) return false;
  return !isPrivateOrLocalHost(uri.host);
}

bool isPrivateOrLocalHost(String host) {
  final normalized = host.toLowerCase().replaceAll('[', '').replaceAll(']', '');
  if (normalized == 'localhost' ||
      normalized == '127.0.0.1' ||
      normalized == '0.0.0.0' ||
      normalized == '::1') {
    return true;
  }
  if (normalized.endsWith('.local') || normalized.endsWith('.internal')) {
    return true;
  }
  if (normalized.contains(':')) {
    if (normalized == '::1' ||
        normalized.startsWith('fc') ||
        normalized.startsWith('fd') ||
        normalized.startsWith('fe80')) {
      return true;
    }
  }
  final parts = normalized.split('.');
  if (parts.length != 4) return false;
  final octets = <int>[];
  for (final part in parts) {
    if (part.isEmpty || part.length > 3) return false;
    final value = int.tryParse(part);
    if (value == null || value > 255) return true;
    octets.add(value);
  }
  final a = octets[0];
  final b = octets[1];
  if (a == 10 || a == 127 || a == 0) return true;
  if (a == 169 && b == 254) return true;
  if (a == 172 && b >= 16 && b <= 31) return true;
  if (a == 192 && b == 168) return true;
  return false;
}
