import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/log_service.dart';

/// Pagină internă care afișează log-urile capturate de [LogService].
/// Accesibilă din Settings → QA & Testare → Log Viewer.
class LogViewerPage extends StatefulWidget {
  const LogViewerPage({super.key});

  @override
  State<LogViewerPage> createState() => _LogViewerPageState();
}

class _LogViewerPageState extends State<LogViewerPage> {
  final _scrollController = ScrollController();
  final _searchController = TextEditingController();
  StreamSubscription<List<LogEntry>>? _sub;

  List<LogEntry> _all = [];
  List<LogEntry> _filtered = [];
  String _filter = '';
  bool _autoScroll = true;

  // Filtre rapide
  static const _quickFilters = [
    '',
    '[SDK RAW]',
    '[SDK EMIT]',
    '[SDK FILTERED]',
    '[SDK POLL]',
    '[VitalRotation]',
    'error',
  ];
  int _activeQuick = 0;

  @override
  void initState() {
    super.initState();
    _all = LogService.instance.lines.toList();
    _applyFilter(_filter);
    _sub = LogService.instance.stream.listen((lines) {
      if (!mounted) return;
      setState(() {
        _all = lines.toList();
        _applyFilter(_filter);
      });
      if (_autoScroll) _scrollToBottom();
    });
    _searchController.addListener(() {
      setState(() {
        _filter = _searchController.text.toLowerCase();
        _activeQuick = 0;
        _applyFilter(_filter);
      });
      if (_autoScroll) _scrollToBottom();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  @override
  void dispose() {
    _sub?.cancel();
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _applyFilter(String q) {
    if (q.isEmpty) {
      _filtered = List.of(_all);
    } else {
      _filtered = _all
          .where((e) => e.message.toLowerCase().contains(q))
          .toList();
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  Color _colorFor(LogEntry e, ColorScheme cs) {
    return switch (e.level) {
      LogLevel.error => const Color(0xFFFF6B6B),
      LogLevel.warning => const Color(0xFFFFD93D),
      LogLevel.info => const Color(0xFF6BCB77),
      LogLevel.debug => cs.onSurface.withOpacity(0.85),
    };
  }

  void _copyAll() {
    Clipboard.setData(ClipboardData(text: LogService.instance.export()));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Log-urile au fost copiate în clipboard.')),
    );
  }

  void _clear() {
    LogService.instance.clear();
    setState(() {
      _all = [];
      _filtered = [];
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0D),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text(
          'Log Viewer',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        centerTitle: true,
        actions: [
          // Auto-scroll toggle
          IconButton(
            icon: Icon(
              _autoScroll ? Icons.vertical_align_bottom : Icons.pause,
              color: _autoScroll ? cs.primary : cs.onSurface.withOpacity(0.5),
            ),
            tooltip: _autoScroll ? 'Auto-scroll activ' : 'Auto-scroll oprit',
            onPressed: () => setState(() => _autoScroll = !_autoScroll),
          ),
          IconButton(
            icon: const Icon(Icons.copy_outlined),
            tooltip: 'Copiază tot',
            onPressed: _copyAll,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Șterge log-uri',
            onPressed: () => showDialog(
              context: context,
              builder: (_) => AlertDialog(
                title: const Text('Șterge log-uri?'),
                content: const Text('Toate înregistrările vor fi șterse.'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Anulează'),
                  ),
                  TextButton(
                    onPressed: () {
                      _clear();
                      Navigator.pop(context);
                    },
                    child: const Text('Șterge'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // ── Search bar ──
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
            child: TextField(
              controller: _searchController,
              style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
              decoration: InputDecoration(
                hintText: 'Caută în log-uri...',
                prefixIcon: const Icon(Icons.search, size: 18),
                suffixIcon: _filter.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () {
                          _searchController.clear();
                        },
                      )
                    : null,
                isDense: true,
                filled: true,
                fillColor: cs.surface.withOpacity(0.5),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),

          // ── Quick filter chips ──
          SizedBox(
            height: 36,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: _quickFilters.length,
              separatorBuilder: (_, __) => const SizedBox(width: 6),
              itemBuilder: (_, i) {
                final label = _quickFilters[i].isEmpty
                    ? 'Toate'
                    : _quickFilters[i];
                final active = _activeQuick == i;
                return ChoiceChip(
                  label: Text(label, style: const TextStyle(fontSize: 11)),
                  selected: active,
                  onSelected: (_) {
                    setState(() {
                      _activeQuick = i;
                      _searchController.clear();
                      _filter = _quickFilters[i].toLowerCase();
                      _applyFilter(_filter);
                    });
                    if (_autoScroll) _scrollToBottom();
                  },
                );
              },
            ),
          ),

          const SizedBox(height: 4),

          // ── Count bar ──
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Row(
              children: [
                Text(
                  '${_filtered.length} / ${_all.length} linii',
                  style: TextStyle(
                    fontSize: 11,
                    color: cs.onSurface.withOpacity(0.45),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 4),

          // ── Log list ──
          Expanded(
            child: _filtered.isEmpty
                ? Center(
                    child: Text(
                      _all.isEmpty ? 'Niciun log încă.' : 'Niciun rezultat.',
                      style: TextStyle(color: cs.onSurface.withOpacity(0.4)),
                    ),
                  )
                : NotificationListener<ScrollNotification>(
                    onNotification: (n) {
                      if (n is ScrollUpdateNotification) {
                        final atBottom =
                            _scrollController.position.pixels >=
                            _scrollController.position.maxScrollExtent - 40;
                        if (_autoScroll != atBottom) {
                          setState(() => _autoScroll = atBottom);
                        }
                      }
                      return false;
                    },
                    child: ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 4,
                      ),
                      itemCount: _filtered.length,
                      itemBuilder: (_, i) {
                        final e = _filtered[i];
                        return _LogLine(
                          entry: e,
                          color: _colorFor(e, cs),
                          highlight: _filter,
                        );
                      },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _LogLine extends StatelessWidget {
  const _LogLine({
    required this.entry,
    required this.color,
    required this.highlight,
  });

  final LogEntry entry;
  final Color color;
  final String highlight;

  @override
  Widget build(BuildContext context) {
    final text = entry.message;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // timestamp
          Text(
            entry.timeStr,
            style: TextStyle(
              fontSize: 10,
              fontFamily: 'monospace',
              color: Colors.white.withOpacity(0.3),
            ),
          ),
          const SizedBox(width: 6),
          // message
          Expanded(
            child: highlight.isEmpty
                ? Text(
                    text,
                    style: TextStyle(
                      fontSize: 11,
                      fontFamily: 'monospace',
                      color: color,
                    ),
                  )
                : _HighlightText(
                    text: text,
                    query: highlight,
                    baseColor: color,
                  ),
          ),
        ],
      ),
    );
  }
}

/// Text cu porțiunile care corespund query-ului evidențiate în galben.
class _HighlightText extends StatelessWidget {
  const _HighlightText({
    required this.text,
    required this.query,
    required this.baseColor,
  });

  final String text;
  final String query;
  final Color baseColor;

  @override
  Widget build(BuildContext context) {
    final lower = text.toLowerCase();
    final spans = <TextSpan>[];
    int start = 0;
    int idx;
    while ((idx = lower.indexOf(query, start)) != -1) {
      if (idx > start) {
        spans.add(TextSpan(text: text.substring(start, idx)));
      }
      spans.add(
        TextSpan(
          text: text.substring(idx, idx + query.length),
          style: const TextStyle(
            backgroundColor: Color(0xFFFFD93D),
            color: Colors.black,
          ),
        ),
      );
      start = idx + query.length;
    }
    if (start < text.length) {
      spans.add(TextSpan(text: text.substring(start)));
    }
    return Text.rich(
      TextSpan(children: spans),
      style: TextStyle(fontSize: 11, fontFamily: 'monospace', color: baseColor),
    );
  }
}
