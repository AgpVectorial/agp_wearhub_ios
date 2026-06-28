import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path_provider/path_provider.dart';

class EkgSessionReport {
  final String userName;
  final DateTime startedAt;
  final Duration duration;
  final int sampleRateHz;
  final List<double> samples;
  final double? bpm;
  final int? spo2;
  final String observations;

  const EkgSessionReport({
    required this.userName,
    required this.startedAt,
    required this.duration,
    required this.sampleRateHz,
    required this.samples,
    this.bpm,
    this.spo2,
    this.observations = '',
  });
}

class EkgExportService {
  const EkgExportService();

  Future<File> exportPdf(EkgSessionReport report) async {
    final dir = await getApplicationDocumentsDirectory();
    final name = 'ekg_${report.startedAt.millisecondsSinceEpoch}.pdf';
    final file = File('${dir.path}${Platform.pathSeparator}$name');
    await file.writeAsBytes(_buildPdf(report), flush: true);
    return file;
  }

  Future<File> exportRawCsv(EkgSessionReport report) async {
    final dir = await getApplicationDocumentsDirectory();
    final name = 'ekg_raw_${report.startedAt.millisecondsSinceEpoch}.csv';
    final file = File('${dir.path}${Platform.pathSeparator}$name');
    final buffer = StringBuffer('sample_index,time_ms,mv\n');
    for (var i = 0; i < report.samples.length; i++) {
      final timeMs = (i * 1000 / report.sampleRateHz).round();
      buffer.writeln('$i,$timeMs,${report.samples[i].toStringAsFixed(4)}');
    }
    await file.writeAsString(buffer.toString(), flush: true);
    return file;
  }

  List<int> _buildPdf(EkgSessionReport report) {
    final objects = <String>[];
    void add(String object) => objects.add(object);

    final stats = _stats(report.samples);
    final lines = <String>[
      'AGP Wear Hub - Raport EKG',
      'Utilizator: ${report.userName}',
      'Data: ${report.startedAt.toLocal()}',
      'Durata: ${report.duration.inSeconds}s',
      'Sample rate: ${report.sampleRateHz} Hz',
      'BPM: ${report.bpm?.round() ?? '-'}',
      'SpO2: ${report.spo2 != null ? '${report.spo2}%' : '-'}',
      'Amplitude min/max: ${stats.min.toStringAsFixed(2)} / ${stats.max.toStringAsFixed(2)} mV',
      'Interpretare basic: ${_interpret(report, stats)}',
      if (report.observations.isNotEmpty) 'Observatii: ${report.observations}',
      '',
      'Waveform preview:',
      _sparkline(report.samples),
      '',
      'Acest raport este informativ si nu inlocuieste diagnosticul medical.',
    ];

    final content = StringBuffer('BT\n/F1 13 Tf\n50 790 Td\n18 TL\n');
    for (final line in lines) {
      content.writeln('(${_escape(line)}) Tj');
      content.writeln('T*');
    }
    content.write('ET\n');

    add('1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n');
    add('2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n');
    add(
      '3 0 obj\n'
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] '
      '/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>\n'
      'endobj\n',
    );
    add('4 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n');
    add(
      '5 0 obj\n<< /Length ${utf8.encode(content.toString()).length} >>\n'
      'stream\n$content'
      'endstream\nendobj\n',
    );

    final buffer = StringBuffer('%PDF-1.4\n');
    final offsets = <int>[0];
    var byteCount = utf8.encode(buffer.toString()).length;
    for (final object in objects) {
      offsets.add(byteCount);
      buffer.write(object);
      byteCount += utf8.encode(object).length;
    }
    final xrefOffset = byteCount;
    buffer.write('xref\n0 ${objects.length + 1}\n');
    buffer.write('0000000000 65535 f \n');
    for (var i = 1; i < offsets.length; i++) {
      buffer.write('${offsets[i].toString().padLeft(10, '0')} 00000 n \n');
    }
    buffer.write(
      'trailer\n<< /Size ${objects.length + 1} /Root 1 0 R >>\n'
      'startxref\n$xrefOffset\n%%EOF',
    );
    return utf8.encode(buffer.toString());
  }

  ({double min, double max}) _stats(List<double> samples) {
    if (samples.isEmpty) return (min: 0, max: 0);
    var min = samples.first;
    var max = samples.first;
    for (final sample in samples) {
      min = math.min(min, sample);
      max = math.max(max, sample);
    }
    return (min: min, max: max);
  }

  String _interpret(EkgSessionReport report, ({double min, double max}) stats) {
    final bpm = report.bpm;
    if (bpm == null) return 'ritm insuficient pentru interpretare';
    if (bpm < 50) return 'posibila bradicardie';
    if (bpm > 120) return 'posibila tahicardie';
    if ((stats.max - stats.min) < 0.15) return 'semnal EKG foarte slab';
    return 'ritm in limite uzuale pentru screening basic';
  }

  String _sparkline(List<double> samples) {
    if (samples.isEmpty) return '-';
    const chars = '._-~=+*#';
    final step = math.max(1, samples.length ~/ 90);
    final selected = <double>[];
    for (var i = 0; i < samples.length; i += step) {
      selected.add(samples[i]);
    }
    final stats = _stats(selected);
    final span = math.max(0.001, stats.max - stats.min);
    return selected.map((v) {
      final idx = (((v - stats.min) / span) * (chars.length - 1)).round();
      return chars[idx.clamp(0, chars.length - 1).toInt()];
    }).join();
  }

  String _escape(String value) =>
      value.replaceAll(r'\', r'\\').replaceAll('(', r'\(').replaceAll(')', r'\)');
}
