import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

class MfpLoginDiagnosticPage extends StatefulWidget {
  const MfpLoginDiagnosticPage({super.key});

  @override
  State<MfpLoginDiagnosticPage> createState() => _MfpLoginDiagnosticPageState();
}

class _MfpLoginDiagnosticPageState extends State<MfpLoginDiagnosticPage> {
  late final WebViewController _controller;
  bool _loading = true;
  int _progress = 0;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (value) {
            if (mounted) setState(() => _progress = value);
          },
          onPageStarted: (_) {
            if (mounted) setState(() => _loading = true);
          },
          onPageFinished: (_) {
            if (mounted) setState(() => _loading = false);
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame == true && mounted) {
              setState(() => _loading = false);
            }
          },
        ),
      )
      ..loadRequest(Uri.parse('https://www.myfitnesspal.com/'));
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    await _controller.reload();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('Login diagnostic'),
          actions: [
            IconButton(
              tooltip: 'Reload page',
              onPressed: _reload,
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        body: Column(
          children: [
            if (_loading)
              LinearProgressIndicator(
                value: _progress == 0 ? null : _progress / 100,
              ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Text(
                'TEST ONLY — Sign in on the official MyFitnessPal website. Open your food diary and confirm it loads. Then leave this page and reopen this test. If your diary still appears without signing in again, tell us. RunFuel does not read or transfer login cookies in this test.',
                style: TextStyle(color: Colors.white70, height: 1.4),
              ),
            ),
            Expanded(child: WebViewWidget(controller: _controller)),
          ],
        ),
      );
}
