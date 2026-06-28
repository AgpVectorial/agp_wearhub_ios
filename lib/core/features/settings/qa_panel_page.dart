import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/qa_service.dart';

class QaPanelPage extends ConsumerWidget {
  const QaPanelPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final qa = ref.watch(qaServiceProvider);
    final svc = ref.read(qaServiceProvider.notifier);
    final theme = Theme.of(context);

    // Grupare pe categorii
    final categories = <String, List<TestResult>>{};
    for (final test in qa.tests) {
      categories.putIfAbsent(test.category, () => []).add(test);
    }

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text(
          'QA & Testare',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        centerTitle: true,
        elevation: 0,
        backgroundColor: Colors.transparent,
        actions: [
          IconButton(
            icon: const Icon(Icons.restore),
            tooltip: 'Reset rezultate',
            onPressed: svc.resetAll,
          ),
        ],
      ),
      body: Column(
        children: [
          // ── Summary bar ──
          Container(
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: theme.colorScheme.outline.withOpacity(0.2),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _StatChip(
                  label: 'Total',
                  value: '${qa.totalCount}',
                  color: Colors.grey,
                ),
                _StatChip(
                  label: 'Passed',
                  value: '${qa.passedCount}',
                  color: Colors.green,
                ),
                _StatChip(
                  label: 'Failed',
                  value: '${qa.failedCount}',
                  color: Colors.red,
                ),
                _StatChip(
                  label: 'Run',
                  value: '${qa.runCount}/${qa.totalCount}',
                  color: Colors.blue,
                ),
              ],
            ),
          ),

          // ── Run All button ──
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SizedBox(
              width: double.infinity,
              height: 48,
              child: FilledButton.icon(
                icon: qa.isRunning
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : const Icon(Icons.play_arrow_rounded),
                label: Text(
                  qa.isRunning ? 'Se rulează...' : 'Rulează toate testele',
                ),
                onPressed: qa.isRunning ? null : () => svc.runAllTests(),
              ),
            ),
          ),
          const SizedBox(height: 16),

          // ── Test list by category ──
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                ...categories.entries.map((entry) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _CategoryHeader(
                        title: entry.key,
                        passed: entry.value
                            .where((t) => t.status == TestStatus.passed)
                            .length,
                        total: entry.value.length,
                      ),
                      ...entry.value.map(
                        (test) => _TestTile(
                          test: test,
                          onRun: () => svc.runTest(test.id),
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                  );
                }),
                Container(
                  margin: const EdgeInsets.only(bottom: 32),
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.amber.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.amber.withOpacity(0.3)),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.info_outline, color: Colors.amber, size: 18),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Toate testele sunt simulate (mockup). '
                          'Testarea reală necesită dispozitiv BLE fizic.',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  const _StatChip({
    required this.label,
    required this.value,
    required this.color,
  });
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          value,
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: color,
          ),
        ),
        Text(
          label,
          style: TextStyle(fontSize: 11, color: color.withOpacity(0.7)),
        ),
      ],
    );
  }
}

class _CategoryHeader extends StatelessWidget {
  const _CategoryHeader({
    required this.title,
    required this.passed,
    required this.total,
  });
  final String title;
  final int passed;
  final int total;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 4),
      child: Row(
        children: [
          Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: theme.colorScheme.primary,
            ),
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer.withOpacity(0.3),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '$passed/$total',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TestTile extends StatelessWidget {
  const _TestTile({required this.test, required this.onRun});
  final TestResult test;
  final VoidCallback onRun;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final (icon, color) = switch (test.status) {
      TestStatus.notRun => (Icons.circle_outlined, Colors.grey),
      TestStatus.running => (Icons.hourglass_top, Colors.blue),
      TestStatus.passed => (Icons.check_circle, Colors.green),
      TestStatus.failed => (Icons.cancel, Colors.red),
      TestStatus.skipped => (Icons.skip_next, Colors.orange),
    };

    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.colorScheme.outline.withOpacity(0.1)),
      ),
      child: ListTile(
        dense: true,
        leading: test.status == TestStatus.running
            ? SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2, color: color),
              )
            : Icon(icon, color: color, size: 20),
        title: Text(test.name, style: const TextStyle(fontSize: 13)),
        subtitle: test.details != null
            ? Text(
                '${test.details}'
                '${test.duration != null ? " (${test.duration!.inMilliseconds}ms)" : ""}',
                style: TextStyle(fontSize: 11, color: color.withOpacity(0.8)),
              )
            : null,
        trailing: test.status == TestStatus.notRun
            ? IconButton(
                icon: const Icon(Icons.play_arrow, size: 18),
                onPressed: onRun,
              )
            : null,
      ),
    );
  }
}
