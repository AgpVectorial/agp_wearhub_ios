import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Status individual al unui test.
enum TestStatus { notRun, running, passed, failed, skipped }

/// Rezultatul unui test.
@immutable
class TestResult {
  final String id;
  final String name;
  final String category;
  final TestStatus status;
  final String? details;
  final Duration? duration;
  final DateTime? runAt;

  const TestResult({
    required this.id,
    required this.name,
    required this.category,
    this.status = TestStatus.notRun,
    this.details,
    this.duration,
    this.runAt,
  });

  TestResult copyWith({
    TestStatus? status,
    String? details,
    Duration? duration,
    DateTime? runAt,
  }) => TestResult(
    id: id,
    name: name,
    category: category,
    status: status ?? this.status,
    details: details ?? this.details,
    duration: duration ?? this.duration,
    runAt: runAt ?? this.runAt,
  );
}

/// Starea completă QA.
@immutable
class QaState {
  final List<TestResult> tests;
  final bool isRunning;

  const QaState({this.tests = const [], this.isRunning = false});

  int get passedCount =>
      tests.where((t) => t.status == TestStatus.passed).length;
  int get failedCount =>
      tests.where((t) => t.status == TestStatus.failed).length;
  int get totalCount => tests.length;
  int get runCount => tests.where((t) => t.status != TestStatus.notRun).length;
}

/// Serviciu QA – planuri de testare mock.
class QaService extends StateNotifier<QaState> {
  QaService() : super(QaState(tests: _buildTestPlan()));

  static List<TestResult> _buildTestPlan() => [
    // ── Testare pe device real ──
    const TestResult(
      id: 'dev_1',
      name: 'Scanare BLE – descoperire dispozitiv',
      category: 'Device Real',
    ),
    const TestResult(
      id: 'dev_2',
      name: 'Conectare BLE – pairing',
      category: 'Device Real',
    ),
    const TestResult(
      id: 'dev_3',
      name: 'Citire HR în timp real',
      category: 'Device Real',
    ),
    const TestResult(
      id: 'dev_4',
      name: 'Citire SpO2 în timp real',
      category: 'Device Real',
    ),
    const TestResult(
      id: 'dev_5',
      name: 'Citire temperatură',
      category: 'Device Real',
    ),
    const TestResult(
      id: 'dev_6',
      name: 'Citire pași (steps)',
      category: 'Device Real',
    ),
    const TestResult(
      id: 'dev_7',
      name: 'Citire baterie dispozitiv',
      category: 'Device Real',
    ),

    // ── Stabilitate BLE ──
    const TestResult(
      id: 'ble_1',
      name: 'Conexiune stabilă 10 min',
      category: 'Stabilitate BLE',
    ),
    const TestResult(
      id: 'ble_2',
      name: 'Conexiune stabilă 30 min',
      category: 'Stabilitate BLE',
    ),
    const TestResult(
      id: 'ble_3',
      name: 'Pierdere semnal → alertă',
      category: 'Stabilitate BLE',
    ),
    const TestResult(
      id: 'ble_4',
      name: 'Distanță maximă (10m indoor)',
      category: 'Stabilitate BLE',
    ),
    const TestResult(
      id: 'ble_5',
      name: 'Interferență WiFi activă',
      category: 'Stabilitate BLE',
    ),

    // ── Reconectare ──
    const TestResult(
      id: 'rec_1',
      name: 'Reconectare automată după pierdere BLE',
      category: 'Reconectare',
    ),
    const TestResult(
      id: 'rec_2',
      name: 'Reconectare după mod avion ON/OFF',
      category: 'Reconectare',
    ),
    const TestResult(
      id: 'rec_3',
      name: 'Reconectare – backoff exponențial',
      category: 'Reconectare',
    ),
    const TestResult(
      id: 'rec_4',
      name: 'Reconectare – max 10 reîncercări',
      category: 'Reconectare',
    ),
    const TestResult(
      id: 'rec_5',
      name: 'Reconectare – reluare stream metrici',
      category: 'Reconectare',
    ),

    // ── Background ──
    const TestResult(
      id: 'bg_1',
      name: 'Colectare metrici cu app minimizat',
      category: 'Background',
    ),
    const TestResult(
      id: 'bg_2',
      name: 'Notificări critice din background',
      category: 'Background',
    ),
    const TestResult(
      id: 'bg_3',
      name: 'Persistare date la kill app',
      category: 'Background',
    ),
    const TestResult(
      id: 'bg_4',
      name: 'Wake-lock BLE în Doze mode',
      category: 'Background',
    ),
    const TestResult(
      id: 'bg_5',
      name: 'Repornire serviciu după reboot',
      category: 'Background',
    ),

    // ── iOS BLE ──
    const TestResult(
      id: 'ios_1',
      name: 'CoreBluetooth – scanare',
      category: 'iOS BLE',
    ),
    const TestResult(
      id: 'ios_2',
      name: 'CoreBluetooth – conectare',
      category: 'iOS BLE',
    ),
    const TestResult(
      id: 'ios_3',
      name: 'CoreBluetooth – notificări characteristic',
      category: 'iOS BLE',
    ),
    const TestResult(
      id: 'ios_4',
      name: 'Background mode iOS (bluetooth-central)',
      category: 'iOS BLE',
    ),
    const TestResult(
      id: 'ios_5',
      name: 'State restoration iOS',
      category: 'iOS BLE',
    ),
  ];

  /// Rulează mock toate testele (simulare).
  Future<void> runAllTests() async {
    state = QaState(tests: state.tests, isRunning: true);

    final updated = <TestResult>[];
    for (final test in state.tests) {
      // Simulăm execuția
      final running = test.copyWith(status: TestStatus.running);
      updated.add(running);
      state = QaState(
        tests: [...updated, ...state.tests.sublist(updated.length)],
        isRunning: true,
      );

      await Future.delayed(const Duration(milliseconds: 300));

      // Mock pass/fail (90% pass)
      final passed = DateTime.now().millisecond % 10 != 0;
      updated[updated.length - 1] = test.copyWith(
        status: passed ? TestStatus.passed : TestStatus.failed,
        details: passed ? 'OK' : 'Mock failure – need real device',
        duration: Duration(
          milliseconds: 200 + (DateTime.now().millisecond % 500),
        ),
        runAt: DateTime.now(),
      );
      state = QaState(
        tests: [...updated, ...state.tests.sublist(updated.length)],
        isRunning: true,
      );
    }

    state = QaState(tests: updated, isRunning: false);
    debugPrint(
      '[QaService] All tests complete: ${state.passedCount}/${state.totalCount} passed',
    );
  }

  /// Rulează un singur test.
  Future<void> runTest(String testId) async {
    final idx = state.tests.indexWhere((t) => t.id == testId);
    if (idx < 0) return;

    final tests = List<TestResult>.from(state.tests);
    tests[idx] = tests[idx].copyWith(status: TestStatus.running);
    state = QaState(tests: tests, isRunning: true);

    await Future.delayed(const Duration(milliseconds: 500));

    tests[idx] = tests[idx].copyWith(
      status: TestStatus.passed,
      details: 'Mock – passed',
      duration: const Duration(milliseconds: 450),
      runAt: DateTime.now(),
    );
    state = QaState(tests: tests, isRunning: false);
  }

  /// Reset test results.
  void resetAll() {
    state = QaState(tests: _buildTestPlan());
  }
}

final qaServiceProvider = StateNotifierProvider<QaService, QaState>(
  (ref) => QaService(),
);
