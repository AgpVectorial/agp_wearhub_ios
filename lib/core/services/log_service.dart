import 'dart:async';
import 'package:flutter/foundation.dart';

/// Niveluri vizuale pentru colorare în UI.
enum LogLevel { debug, info, warning, error }

/// O linie de log capturată.
class LogEntry {
  final String message;
  final DateTime time;
  final LogLevel level;

  LogEntry({required this.message, required this.time, required this.level});

  String get timeStr {
    final t = time;
    return '${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}:'
        '${t.second.toString().padLeft(2, '0')}.'
        '${(t.millisecond ~/ 10).toString().padLeft(2, '0')}';
  }

  static LogLevel _detect(String msg) {
    if (msg.contains('[SDK FILTERED]') ||
        msg.contains('REJECTED') ||
        msg.contains('error') ||
        msg.contains('Error') ||
        msg.contains('ERROR')) {
      return LogLevel.error;
    }
    if (msg.contains('[SDK POLL]') || msg.contains('[VitalRotation]')) {
      return LogLevel.info;
    }
    if (msg.contains('[SDK RAW]') ||
        msg.contains('[SDK EMIT]') ||
        msg.contains('[SDK PROCESS]') ||
        msg.contains('[SDK ACCEPTED]')) {
      return LogLevel.debug;
    }
    return LogLevel.debug;
  }

  factory LogEntry.fromMessage(String message) =>
      LogEntry(message: message, time: DateTime.now(), level: _detect(message));
}

/// Serviciu global care interceptează [debugPrint] și stochează log-urile
/// într-un buffer circular de [maxLines] intrări.
class LogService {
  LogService._();

  static final LogService instance = LogService._();

  static const int maxLines = 2000;

  final List<LogEntry> _lines = [];
  final _controller = StreamController<List<LogEntry>>.broadcast();

  /// Stream reactiv — emit lista completă la fiecare adăugare.
  Stream<List<LogEntry>> get stream => _controller.stream;

  /// Copia curentă a log-urilor (imutabilă).
  List<LogEntry> get lines => List.unmodifiable(_lines);

  bool _initialized = false;

  /// Apelează o singură dată la pornirea aplicației (în [main]).
  void init() {
    if (_initialized) return;
    _initialized = true;

    // Salvăm referința originală pentru a putea printa și în consolă nativă.
    final originalPrint = debugPrint;

    debugPrint = (String? message, {int? wrapWidth}) {
      if (message == null) return;
      _add(message);
      originalPrint(message, wrapWidth: wrapWidth);
    };
  }

  void _add(String message) {
    _lines.add(LogEntry.fromMessage(message));
    if (_lines.length > maxLines) {
      _lines.removeRange(0, _lines.length - maxLines);
    }
    if (!_controller.isClosed) {
      _controller.add(List.unmodifiable(_lines));
    }
  }

  void clear() {
    _lines.clear();
    if (!_controller.isClosed) {
      _controller.add(const []);
    }
  }

  /// Exportă toate log-urile ca text simplu.
  String export() =>
      _lines.map((e) => '[${e.timeStr}] ${e.message}').join('\n');
}
