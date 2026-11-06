// ignore_for_file: prefer_interpolation_to_compose_strings

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_gallery_saver_plus/image_gallery_saver_plus.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:share_plus/share_plus.dart';

class CoachingReportCard extends StatefulWidget {
  const CoachingReportCard({super.key, required this.text, required this.source});
  final String text;
  final String source;
  @override
  State<CoachingReportCard> createState() => _CoachingReportCardState();
}

class _CoachingReportCardState extends State<CoachingReportCard> {
  final GlobalKey _captureKey = GlobalKey();
  bool _exportingPdf = false;
  bool _exportingImage = false;

  String get _sourceLabel => switch (widget.source) {
    'gemini' => 'Gemini online coach',
    'local' => 'On-device Gemma coach',
    'chatgpt' => 'ChatGPT response',
    'openai' => 'AI coach',
    _ => 'RunFuel coach',
  };

  MarkdownStyleSheet _style(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return MarkdownStyleSheet.fromTheme(theme).copyWith(
      p: theme.textTheme.bodyMedium?.copyWith(height: 1.48),
      h1: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900, color: scheme.primary),
      h2: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800, color: scheme.primary),
      h3: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w800),
      strong: const TextStyle(fontWeight: FontWeight.w800),
      tableHead: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w800),
      tableBody: theme.textTheme.bodySmall?.copyWith(height: 1.35),
      tableBorder: TableBorder.all(color: scheme.outlineVariant),
      tableCellsPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
      blockquoteDecoration: BoxDecoration(
        color: scheme.primaryContainer.withValues(alpha: .35),
        borderRadius: BorderRadius.circular(8),
        border: Border(left: BorderSide(color: scheme.primary, width: 3))),
      blockquotePadding: const EdgeInsets.all(9),
      horizontalRuleDecoration: BoxDecoration(
        border: Border(top: BorderSide(color: scheme.outlineVariant))),
    );
  }

  Future<Uint8List> _buildPdfBytes() async {
    final doc = pw.Document();
    final now = DateTime.now().toLocal().toString().substring(0, 16);
    final widgets = <pw.Widget>[
      pw.Text('RUNFUEL', style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold, color: PdfColors.blueGrey700)),
      pw.SizedBox(height: 4),
      pw.Text('Coaching Report', style: pw.TextStyle(fontSize: 23, fontWeight: pw.FontWeight.bold)),
      pw.SizedBox(height: 4),
      pw.Text(now + ' · ' + _sourceLabel, style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700)),
      pw.Divider(color: PdfColors.grey400),
      pw.SizedBox(height: 8),
    ];
    for (final raw in widget.text.replaceAll('\\r\\n', '\\n').split('\\n')) {
      final line = raw.trimRight();
      if (line.trim().isEmpty) {
        widgets.add(pw.SizedBox(height: 4));
      } else if (line.startsWith('### ')) {
        widgets.add(pw.Padding(padding: const pw.EdgeInsets.only(top: 9, bottom: 3),
          child: pw.Text(line.substring(4), style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold))));
      } else if (line.startsWith('## ')) {
        widgets.add(pw.Padding(padding: const pw.EdgeInsets.only(top: 12, bottom: 4),
          child: pw.Text(line.substring(3), style: pw.TextStyle(fontSize: 15, fontWeight: pw.FontWeight.bold, color: PdfColors.blueGrey800))));
      } else if (line.startsWith('# ')) {
        widgets.add(pw.Padding(padding: const pw.EdgeInsets.only(top: 12, bottom: 4),
          child: pw.Text(line.substring(2), style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold))));
      } else if (line.startsWith('- ') || RegExp(r'^\\d+[.)] ').hasMatch(line)) {
        widgets.add(pw.Padding(padding: const pw.EdgeInsets.only(left: 9, bottom: 4),
          child: pw.Row(crossAxisAlignment: pw.CrossAxisAlignment.start, children: [
            pw.Text('•  ', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
            pw.Expanded(child: pw.Text(line.replaceFirst(RegExp(r'^(- |\\d+[.)] )'), ''), style: const pw.TextStyle(fontSize: 9.5, lineSpacing: 3))),
          ])));
      } else if (line.startsWith('|')) {
        widgets.add(pw.Padding(padding: const pw.EdgeInsets.only(bottom: 3),
          child: pw.Text(line.replaceAll('|', '   ·   ').replaceAll(RegExp(r'[-:]{2,}'), ''), style: const pw.TextStyle(fontSize: 8.5))));
      } else if (!RegExp(r'^\\s*[-*_]{3,}\\s*$').hasMatch(line)) {
        widgets.add(pw.Padding(padding: const pw.EdgeInsets.only(bottom: 4),
          child: pw.Text(line.replaceAll('**', '').replaceAll(String.fromCharCode(96), ''), style: const pw.TextStyle(fontSize: 9.5, lineSpacing: 3))));
      }
    }
    doc.addPage(pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(42, 42, 42, 48),
      footer: (ctx) => pw.Align(alignment: pw.Alignment.centerRight,
        child: pw.Text('RunFuel · Page ' + ctx.pageNumber.toString() + ' of ' + ctx.pagesCount.toString(), style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey600))),
      build: (_) => widgets,
    ));
    return Uint8List.fromList(await doc.save());
  }

  Future<void> _savePdf() async {
    if (_exportingPdf || _exportingImage) return;
    setState(() => _exportingPdf = true);
    try {
      final bytes = await _buildPdfBytes();
      final savedPath = await FilePicker.platform.saveFile(
        dialogTitle: 'Save RunFuel coaching report',
        fileName: 'runfuel-coaching-report.pdf',
        type: FileType.custom,
        allowedExtensions: ['pdf'],
        bytes: bytes,
      );
      if (savedPath != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('PDF saved to your selected location.')),
        );
      }
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save PDF: $error')));
    } finally {
      if (mounted) setState(() => _exportingPdf = false);
    }
  }

  Future<void> _sharePdf() async {
    if (_exportingPdf || _exportingImage) return;
    setState(() => _exportingPdf = true);
    try {
      final bytes = await _buildPdfBytes();
      final dir = await getTemporaryDirectory();
      final file = File(dir.path + '/runfuel-coaching-report.pdf');
      await file.writeAsBytes(bytes, flush: true);
      await Share.shareXFiles([XFile(file.path, mimeType: 'application/pdf')], subject: 'RunFuel Coaching Report');
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not share PDF: $error')));
    } finally {
      if (mounted) setState(() => _exportingPdf = false);
    }
  }

  Future<Uint8List> _buildReportImageBytes() async {
    await WidgetsBinding.instance.endOfFrame;
    final object = _captureKey.currentContext?.findRenderObject();
    if (object is! RenderRepaintBoundary) throw StateError('The report is not ready to capture.');
    final image = await object.toImage(pixelRatio: 2.5);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) throw StateError('Could not encode report image.');
      return bytes.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  }

  Future<void> _saveImageToGallery() async {
    if (_exportingPdf || _exportingImage) return;
    setState(() => _exportingImage = true);
    try {
      final bytes = await _buildReportImageBytes();
      final result = await ImageGallerySaverPlus.saveImage(
        bytes,
        quality: 100,
        name: 'runfuel-coaching-report-${DateTime.now().millisecondsSinceEpoch}',
      );
      final success = result is Map && result['isSuccess'] == true;
      if (!success) throw StateError('Android did not confirm the image was saved.');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Report image saved to Gallery.')),
        );
      }
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save report image to Gallery: $error')));
    } finally {
      if (mounted) setState(() => _exportingImage = false);
    }
  }

  Future<void> _shareImage() async {
    if (_exportingPdf || _exportingImage) return;
    setState(() => _exportingImage = true);
    try {
      final bytes = await _buildReportImageBytes();
      final dir = await getTemporaryDirectory();
      final file = File(dir.path + '/runfuel-coaching-report.png');
      await file.writeAsBytes(bytes, flush: true);
      await Share.shareXFiles([XFile(file.path, mimeType: 'image/png')], subject: 'RunFuel Coaching Report');
    } catch (error) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not share report image: $error')));
    } finally {
      if (mounted) setState(() => _exportingImage = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      RepaintBoundary(key: _captureKey, child: Container(
        width: double.infinity, color: theme.colorScheme.surfaceContainer,
        padding: const EdgeInsets.all(2),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          MarkdownBody(data: widget.text, selectable: true, styleSheet: _style(context), shrinkWrap: true),
          const SizedBox(height: 7),
          Text(_sourceLabel + ' · RunFuel coaching', style: TextStyle(fontSize: 10, color: theme.colorScheme.onSurfaceVariant)),
        ]))),
      const SizedBox(height: 8),
      Wrap(spacing: 4, runSpacing: 2, children: [
        TextButton.icon(
          onPressed: _exportingPdf || _exportingImage ? null : _savePdf,
          icon: _exportingPdf ? const SizedBox(width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.picture_as_pdf_outlined, size: 17),
          label: const Text('Save PDF'),
          style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 7))),
        TextButton.icon(
          onPressed: _exportingPdf || _exportingImage ? null : _sharePdf,
          icon: const Icon(Icons.share_outlined, size: 17),
          label: const Text('Share PDF'),
          style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 7))),
        TextButton.icon(
          onPressed: _exportingPdf || _exportingImage ? null : _saveImageToGallery,
          icon: _exportingImage ? const SizedBox(width: 15, height: 15, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.image_outlined, size: 17),
          label: const Text('Save to Gallery'),
          style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 7))),
        TextButton.icon(
          onPressed: _exportingPdf || _exportingImage ? null : _shareImage,
          icon: const Icon(Icons.ios_share_outlined, size: 17),
          label: const Text('Share image'),
          style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 7))),
      ]),
    ]);
  }
}
