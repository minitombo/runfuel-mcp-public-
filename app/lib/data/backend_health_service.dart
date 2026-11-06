import 'package:http/http.dart' as http;

class BackendHealthService {
  const BackendHealthService();

  Future<String> check(String baseUrl) async {
    try {
      final parsed = Uri.parse(baseUrl.trim());
      if (parsed.scheme != 'https' || parsed.host.isEmpty) {
        return 'Enter a valid HTTPS backend URL.';
      }

      // Accept either the deployment root or a pasted known endpoint URL.
      // Health is served at /health, alongside /settings and /mcp.
      var path = parsed.path;
      while (path.endsWith('/') && path.isNotEmpty) {
        path = path.substring(0, path.length - 1);
      }
      for (final suffix in ['/mcp', '/settings', '/health']) {
        if (path.endsWith(suffix)) {
          path = path.substring(0, path.length - suffix.length);
          break;
        }
      }
      final healthPath = path.isEmpty ? '/health' : '$path/health';
      final uri = parsed.replace(path: healthPath, query: null, fragment: null);
      final response = await http.get(uri).timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) return 'Backend is reachable.';
      if (response.statusCode == 401 || response.statusCode == 403) {
        return 'Backend is online, but access was denied (HTTP ${response.statusCode}).';
      }
      return 'Backend responded with HTTP ${response.statusCode}. Check the deployment URL.';
    } on FormatException {
      return 'The backend URL is not valid. Check the HTTPS address.';
    } on http.ClientException {
      return 'Could not connect to the backend. Check your internet connection and deployment URL.';
    } catch (error) {
      return 'Backend check failed: ${error.runtimeType}. Check your internet connection and try again.';
    }
  }
}
