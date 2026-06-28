import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../sdk/sdk_provider.dart';
import '../../models/vitals.dart';
import '../../models/metric.dart';
import '../../models/user_profile.dart';
import '../../i18n/locale.dart';
import '../../storage/vitals_db.dart';
import '../../storage/last_metric_cache.dart';
import '../../storage/user_repository.dart';
import '../../services/app_state_manager.dart';
import '../../services/sampling_policy.dart';
import '../../services/health_profile_service.dart';
import '../../services/medical_alert_service.dart';
import '../../services/ble_reconnect_service.dart';
import '../home/home_page.dart' show connectedProvider;
import '../history/history_page.dart';
import '../vitals/ekg_page.dart';

class DeviceDetailsPage extends ConsumerStatefulWidget {
  final String deviceId;
  final String? initialDisplayName;

  const DeviceDetailsPage({
    super.key,
    required this.deviceId,
    this.initialDisplayName,
  });

  @override
  ConsumerState<DeviceDetailsPage> createState() => _DeviceDetailsPageState();
}

class _DeviceDetailsPageState extends ConsumerState<DeviceDetailsPage> {
  static const Map<String, int> _minIntervals = {
    'hr': 20,
    'spo2': 30,
    'temp': 35,
    'steps': 10,
    'bp': 30,
    'hrv': 30,
  };

  final Map<String, bool> _on = {
    'hr': true,
    'spo2': true,
    'temp': true,
    'steps': true,
    'hrv': true,
    'bp': true,
    'callReminder': false,
    'sedentary': false,
    'dnd': false,
  };

  /// Per-vital measurement duration in seconds.
  final Map<String, int> _intervals = {
    'hr': 20, // 20s — enough for HR to stabilize
    'spo2': 35, // 35s — SpO2 wrist sensor needs 30s+ to give stable reading
    'temp': 40, // 40s — bleManager.temperature populated after ~25-30s
    'steps': 15,
    'bp': 45,
    'hrv': 30, // 30s — HRV measurement needs time
  };

  bool _loadedPrefs = false;
  final ValueNotifier<String> _activeVital = ValueNotifier('');
  StreamSubscription<String>? _activeVitalSub;
  final List<StreamSubscription> _historySubs = [];

  String _key(String vital) => 'vitals.${widget.deviceId}.$vital.on';
  String _intervalKey(String vital) =>
      'vitals.${widget.deviceId}.$vital.interval';

  int _sanitizeInterval(String vital, int seconds) {
    final min = _minIntervals[vital] ?? 10;
    return seconds < min ? min : seconds;
  }

  Future<void> _loadPrefs() async {
    final p = await SharedPreferences.getInstance();
    final samplingIntervalKey = <String, String>{
      'hr': 'sampling.hr.interval',
      'spo2': 'sampling.spo2.interval',
      'temp': 'sampling.temp.interval',
      'steps': 'sampling.steps.interval',
      'bp': 'sampling.bp_sys.interval',
      'hrv': 'sampling.hrv.interval',
    };
    final samplingEnabledKey = <String, String>{
      'hr': 'sampling.hr.enabled',
      'spo2': 'sampling.spo2.enabled',
      'temp': 'sampling.temp.enabled',
      'steps': 'sampling.steps.enabled',
      'bp': 'sampling.bp_sys.enabled',
      'hrv': 'sampling.hrv.enabled',
    };

    setState(() {
      _on.updateAll((k, v) {
        final devicePref = p.getBool(_key(k));
        if (devicePref != null) return devicePref;
        final samplingKey = samplingEnabledKey[k];
        if (samplingKey != null) {
          return p.getBool(samplingKey) ?? v;
        }
        return v;
      });
      for (final k in _intervals.keys) {
        final deviceInterval = p.getInt(_intervalKey(k));
        final samplingInterval = samplingIntervalKey[k] != null
            ? p.getInt(samplingIntervalKey[k]!)
            : null;
        // Use map value as final fallback so defaults above are respected
        _intervals[k] = _sanitizeInterval(
          k,
          deviceInterval ?? samplingInterval ?? _intervals[k]!,
        );
      }
      _loadedPrefs = true;
    });
    _restartRotation();
  }

  Future<void> _savePref(String vital, bool value) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_key(vital), value);
  }

  Future<void> _saveInterval(String vital, int seconds) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_intervalKey(vital), seconds);
  }

  @override
  void initState() {
    super.initState();
    _loadPrefs();
    _startHistoryRecording();
    final sdk = ref.read(sdkProvider);
    _activeVitalSub = sdk.activeVitalStream.listen((vital) {
      if (mounted) _activeVital.value = vital;
    });
  }

  @override
  void dispose() {
    _activeVitalSub?.cancel();
    _activeVital.dispose();
    // Do NOT stop rotation here — keep device measuring when navigating
    // away, going to settings, or minimizing. Only the disconnect button
    // stops the rotation explicitly.
    for (final sub in _historySubs) {
      sub.cancel();
    }
    super.dispose();
  }

  /// Restarts the vital rotation with currently enabled vitals.
  void _restartRotation() {
    final sdk = ref.read(sdkProvider);
    final enabledVitals = [
      'hr',
      'spo2',
      'temp',
      'steps',
      'bp',
      'hrv',
    ].where((v) => _on[v] ?? false).toList();
    if (enabledVitals.isEmpty) {
      sdk.stopVitalRotation(widget.deviceId);
      return;
    }
    sdk.startVitalRotation(widget.deviceId, enabledVitals, _intervals);
    // Battery polling is independent of rotation — start it alongside
    sdk.startBatteryNotifications(widget.deviceId);
  }

  /// Applies sampling policy changes to the current rotation.
  void _applySamplingPolicy(SamplingPolicyState policy) {
    final keyMap = <String, MetricType>{
      'hr': MetricType.heartRate,
      'spo2': MetricType.spo2,
      'temp': MetricType.temperature,
      'steps': MetricType.steps,
      'bp': MetricType.bloodPressureSystolic,
      'hrv': MetricType.hrv,
    };
    bool changed = false;
    for (final entry in keyMap.entries) {
      final config = policy.configs[entry.value];
      if (config == null) continue;
      final effectiveInterval = _sanitizeInterval(
        entry.key,
        policy.effectiveInterval(entry.value),
      );
      if (_intervals[entry.key] != effectiveInterval) {
        _intervals[entry.key] = effectiveInterval;
        changed = true;
      }
      final enabled = config.enabled;
      if (_on[entry.key] != enabled) {
        _on[entry.key] = enabled;
        changed = true;
      }
    }
    if (changed && mounted) {
      setState(() {});
      _restartRotation();
    }
  }

  Future<void> _evaluateMetricAlert(Metric metric) async {
    final profile = const HealthProfileService().fromUser(
      ref.read(userSessionProvider),
    );
    await ref
        .read(medicalAlertProvider.notifier)
        .evaluate(metric, profile: profile);
  }

  /// Înregistrează sample-urile din stream-uri în baza de date + cache.
  void _startHistoryRecording() {
    final sdk = ref.read(sdkProvider);
    final db = VitalsDatabase();
    final cache = ref.read(lastMetricCacheProvider.notifier);
    final streamsManager = ref.read(metricStreamsManagerProvider.notifier);
    final id = widget.deviceId;
    final userId = ref.read(userSessionProvider.notifier).userId;

    // Activare state manager pentru device connection — delay to avoid
    // modifying provider during widget build
    Future(() {
      if (mounted) {
        ref.read(deviceConnectionManagerProvider.notifier).onConnected();
      }
    });

    _historySubs.add(
      sdk.heartRateStream(id).listen((s) {
        db.insert(
          VitalRecord(
            deviceId: id,
            type: VitalType.hr,
            value: s.value.toDouble(),
            ts: s.ts,
            userId: userId,
          ),
        );
        cache.update(
          Metric(
            userId: userId,
            deviceId: id,
            type: MetricType.heartRate,
            value: s.value.toDouble(),
            timestamp: s.ts,
            source: MetricSource.sdk,
          ),
        );
        streamsManager.onMetricReceived(
          MetricType.heartRate,
          s.value.toDouble(),
        );
        _evaluateMetricAlert(
          Metric(
            userId: userId,
            deviceId: id,
            type: MetricType.heartRate,
            value: s.value.toDouble(),
            timestamp: s.ts,
            source: MetricSource.sdk,
          ),
        );
      }),
    );
    _historySubs.add(
      sdk.spO2Stream(id).listen((s) {
        db.insert(
          VitalRecord(
            deviceId: id,
            type: VitalType.spo2,
            value: s.value.toDouble(),
            ts: s.ts,
            userId: userId,
          ),
        );
        cache.update(
          Metric(
            userId: userId,
            deviceId: id,
            type: MetricType.spo2,
            value: s.value.toDouble(),
            timestamp: s.ts,
            source: MetricSource.sdk,
          ),
        );
        streamsManager.onMetricReceived(MetricType.spo2, s.value.toDouble());
        _evaluateMetricAlert(
          Metric(
            userId: userId,
            deviceId: id,
            type: MetricType.spo2,
            value: s.value.toDouble(),
            timestamp: s.ts,
            source: MetricSource.sdk,
          ),
        );
      }),
    );
    _historySubs.add(
      sdk.temperatureStream(id).listen((s) {
        db.insert(
          VitalRecord(
            deviceId: id,
            type: VitalType.temp,
            value: s.value,
            ts: s.ts,
            userId: userId,
          ),
        );
        cache.update(
          Metric(
            userId: userId,
            deviceId: id,
            type: MetricType.temperature,
            value: s.value,
            timestamp: s.ts,
            source: MetricSource.sdk,
          ),
        );
        streamsManager.onMetricReceived(MetricType.temperature, s.value);
        _evaluateMetricAlert(
          Metric(
            userId: userId,
            deviceId: id,
            type: MetricType.temperature,
            value: s.value,
            timestamp: s.ts,
            source: MetricSource.sdk,
          ),
        );
      }),
    );
    _historySubs.add(
      sdk.stepsStream(id).listen((s) {
        db.insert(
          VitalRecord(
            deviceId: id,
            type: VitalType.steps,
            value: s.value.toDouble(),
            ts: s.ts,
            userId: userId,
          ),
        );
        cache.update(
          Metric(
            userId: userId,
            deviceId: id,
            type: MetricType.steps,
            value: s.value.toDouble(),
            timestamp: s.ts,
            source: MetricSource.sdk,
          ),
        );
        streamsManager.onMetricReceived(MetricType.steps, s.value.toDouble());
      }),
    );
    _historySubs.add(
      sdk.batteryStream(id).listen((s) {
        db.insert(
          VitalRecord(
            deviceId: id,
            type: VitalType.battery,
            value: s.value.toDouble(),
            ts: s.ts,
            userId: userId,
          ),
        );
        cache.update(
          Metric(
            userId: userId,
            deviceId: id,
            type: MetricType.battery,
            value: s.value.toDouble(),
            timestamp: s.ts,
            source: MetricSource.sdk,
          ),
        );
        streamsManager.onMetricReceived(MetricType.battery, s.value.toDouble());
        _evaluateMetricAlert(
          Metric(
            userId: userId,
            deviceId: id,
            type: MetricType.battery,
            value: s.value.toDouble(),
            timestamp: s.ts,
            source: MetricSource.sdk,
          ),
        );
      }),
    );
    // Blood pressure
    _historySubs.add(
      sdk.bloodPressureStream(id).listen((s) {
        db.insert(
          VitalRecord(
            deviceId: id,
            type: VitalType.bp,
            value: s.value.systolic.toDouble(),
            ts: s.ts,
            userId: userId,
          ),
        );
        cache.update(
          Metric(
            userId: userId,
            deviceId: id,
            type: MetricType.bloodPressureSystolic,
            value: s.value.systolic.toDouble(),
            timestamp: s.ts,
            source: MetricSource.sdk,
          ),
        );
        cache.update(
          Metric(
            userId: userId,
            deviceId: id,
            type: MetricType.bloodPressureDiastolic,
            value: s.value.diastolic.toDouble(),
            timestamp: s.ts,
            source: MetricSource.sdk,
          ),
        );
        streamsManager.onMetricReceived(
          MetricType.bloodPressureSystolic,
          s.value.systolic.toDouble(),
        );
        streamsManager.onMetricReceived(
          MetricType.bloodPressureDiastolic,
          s.value.diastolic.toDouble(),
        );
        _evaluateMetricAlert(
          Metric(
            userId: userId,
            deviceId: id,
            type: MetricType.bloodPressureSystolic,
            value: s.value.systolic.toDouble(),
            timestamp: s.ts,
            source: MetricSource.sdk,
          ),
        );
        _evaluateMetricAlert(
          Metric(
            userId: userId,
            deviceId: id,
            type: MetricType.bloodPressureDiastolic,
            value: s.value.diastolic.toDouble(),
            timestamp: s.ts,
            source: MetricSource.sdk,
          ),
        );
      }),
    );
    // HRV
    _historySubs.add(
      sdk.hrvStream(id).listen((s) {
        db.insert(
          VitalRecord(
            deviceId: id,
            type: VitalType.hrv,
            value: s.value.toDouble(),
            ts: s.ts,
            userId: userId,
          ),
        );
        cache.update(
          Metric(
            userId: userId,
            deviceId: id,
            type: MetricType.hrv,
            value: s.value.toDouble(),
            timestamp: s.ts,
            source: MetricSource.sdk,
          ),
        );
        streamsManager.onMetricReceived(MetricType.hrv, s.value.toDouble());
        _evaluateMetricAlert(
          Metric(
            userId: userId,
            deviceId: id,
            type: MetricType.hrv,
            value: s.value.toDouble(),
            timestamp: s.ts,
            source: MetricSource.sdk,
          ),
        );
      }),
    );
    // Stress
    _historySubs.add(
      sdk.stressStream(id).listen((s) {
        db.insert(
          VitalRecord(
            deviceId: id,
            type: VitalType.stress,
            value: s.value.toDouble(),
            ts: s.ts,
            userId: userId,
          ),
        );
        cache.update(
          Metric(
            userId: userId,
            deviceId: id,
            type: MetricType.stress,
            value: s.value.toDouble(),
            timestamp: s.ts,
            source: MetricSource.sdk,
          ),
        );
        streamsManager.onMetricReceived(MetricType.stress, s.value.toDouble());
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final sdk = ref.watch(sdkProvider);
    final lang = ref.watch(localeProvider);
    final t = T(lang);
    final theme = Theme.of(context);
    final cachedMetrics = ref.watch(lastMetricCacheProvider);
    int? cachedInt(MetricType type) {
      final metric = cachedMetrics[type];
      if (metric == null || metric.deviceId != widget.deviceId) return null;
      return metric.value.round();
    }

    double? cachedDouble(MetricType type) {
      final metric = cachedMetrics[type];
      if (metric == null || metric.deviceId != widget.deviceId) return null;
      return metric.value;
    }

    BloodPressure? cachedBloodPressure() {
      final systolic = cachedMetrics[MetricType.bloodPressureSystolic];
      final diastolic = cachedMetrics[MetricType.bloodPressureDiastolic];
      if (systolic == null ||
          diastolic == null ||
          systolic.deviceId != widget.deviceId ||
          diastolic.deviceId != widget.deviceId) {
        return null;
      }
      return BloodPressure(systolic.value.round(), diastolic.value.round());
    }

    // Watch sampling policies — apply changes to rotation intervals
    ref.watch(samplingPolicyProvider);
    ref.listen<SamplingPolicyState>(samplingPolicyProvider, (prev, next) {
      _applySamplingPolicy(next);
    });
    ref.listen<MedicalAlertState>(medicalAlertProvider, (prev, next) {
      final alert = next.latest;
      if (alert == null || alert.id == prev?.latest?.id || !mounted) return;
      final color = alert.severity == MedicalAlertSeverity.critical
          ? Colors.red
          : Colors.orange;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(alert.message),
          backgroundColor: color,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 5),
        ),
      );
      if (alert.severity == MedicalAlertSeverity.critical) {
        showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Alertă medicală'),
            content: Text(alert.message),
            actions: [
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    });

    final title = widget.initialDisplayName == null
        ? '${t.device} ${widget.deviceId}'
        : widget.initialDisplayName!;

    if (!_loadedPrefs) {
      return Scaffold(
        backgroundColor: theme.colorScheme.surface,
        appBar: AppBar(
          title: Text(title),
          centerTitle: true,
          elevation: 0,
          backgroundColor: Colors.transparent,
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      appBar: AppBar(
        title: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
            if (widget.initialDisplayName != null)
              Text(
                widget.deviceId,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withOpacity(0.6),
                ),
              ),
          ],
        ),
        centerTitle: true,
        elevation: 0,
        backgroundColor: Colors.transparent,
        actions: [
          IconButton(
            tooltip: t.tr('viewHistory'),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => HistoryPage(
                  deviceId: widget.deviceId,
                  deviceName: widget.initialDisplayName,
                ),
              ),
            ),
            icon: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withOpacity(
                  0.7,
                ),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: theme.colorScheme.outline.withOpacity(0.2),
                ),
              ),
              child: const Icon(Icons.timeline_rounded, size: 20),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        children: [
          _ConnectionBanner(deviceId: widget.deviceId),
          _BmiProfileCard(user: ref.watch(userSessionProvider)),

          // ── Vital Measurements ──
          _SectionHeader(title: t.tr('vitalSigns') ?? 'Vital Signs'),
          GridView.count(
            crossAxisCount: 2,
            mainAxisSpacing: 8,
            crossAxisSpacing: 8,
            childAspectRatio: 1.3,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              _CompactVitalTile<int>(
                title: t.hr,
                unit: t.bpm,
                icon: Icons.favorite_rounded,
                color: Colors.red,
                stream: sdk
                    .heartRateStream(widget.deviceId)
                    .map((s) => s.value),
                initialValue: cachedInt(MetricType.heartRate),
                format: (v) => '$v',
                isEnabled: _on['hr'] ?? false,
                activeVital: _activeVital,
                vitalKey: 'hr',
                interval: _intervals['hr'] ?? 15,
                onToggle: (v) {
                  setState(() => _on['hr'] = v);
                  _savePref('hr', v);
                  _restartRotation();
                },
                onIntervalChanged: (s) {
                  setState(() => _intervals['hr'] = s);
                  _saveInterval('hr', s);
                  _restartRotation();
                },
              ),
              _CompactVitalTile<int>(
                title: t.spo2,
                unit: t.percent,
                icon: Icons.bloodtype_rounded,
                color: Colors.blue,
                stream: sdk.spO2Stream(widget.deviceId).map((s) => s.value),
                initialValue: cachedInt(MetricType.spo2),
                format: (v) => '$v',
                isEnabled: _on['spo2'] ?? false,
                activeVital: _activeVital,
                vitalKey: 'spo2',
                interval: _intervals['spo2'] ?? 15,
                onToggle: (v) {
                  setState(() => _on['spo2'] = v);
                  _savePref('spo2', v);
                  _restartRotation();
                },
                onIntervalChanged: (s) {
                  setState(() => _intervals['spo2'] = s);
                  _saveInterval('spo2', s);
                  _restartRotation();
                },
              ),
              _CompactVitalTile<BloodPressure>(
                title: t.bloodPressure,
                unit: t.mmHg,
                icon: Icons.monitor_heart_rounded,
                color: Colors.indigo,
                stream: sdk
                    .bloodPressureStream(widget.deviceId)
                    .map((s) => s.value),
                initialValue: cachedBloodPressure(),
                format: (v) => v.toString(),
                isEnabled: _on['bp'] ?? false,
                activeVital: _activeVital,
                vitalKey: 'bp',
                interval: _intervals['bp'] ?? 15,
                onToggle: (v) {
                  setState(() => _on['bp'] = v);
                  _savePref('bp', v);
                  _restartRotation();
                },
                onIntervalChanged: (s) {
                  setState(() => _intervals['bp'] = s);
                  _saveInterval('bp', s);
                  _restartRotation();
                },
              ),
              _CompactVitalTile<int>(
                title: t.hrv,
                unit: t.ms,
                icon: Icons.insights_rounded,
                color: Colors.purple,
                stream: sdk.hrvStream(widget.deviceId).map((s) => s.value),
                initialValue: cachedInt(MetricType.hrv),
                format: (v) => '$v',
                isEnabled: _on['hrv'] ?? false,
                activeVital: _activeVital,
                vitalKey: 'hrv',
                interval: _intervals['hrv'] ?? 15,
                onToggle: (v) {
                  setState(() => _on['hrv'] = v);
                  _savePref('hrv', v);
                  _restartRotation();
                },
                onIntervalChanged: (s) {
                  setState(() => _intervals['hrv'] = s);
                  _saveInterval('hrv', s);
                  _restartRotation();
                },
              ),
              _CompactVitalTile<double>(
                title: t.temperature,
                unit: t.degC,
                icon: Icons.thermostat_rounded,
                color: Colors.orange,
                stream: sdk
                    .temperatureStream(widget.deviceId)
                    .map((s) => s.value),
                initialValue: cachedDouble(MetricType.temperature),
                format: (v) => v.toStringAsFixed(1),
                isEnabled: _on['temp'] ?? false,
                activeVital: _activeVital,
                vitalKey: 'temp',
                interval: _intervals['temp'] ?? 15,
                onToggle: (v) {
                  setState(() => _on['temp'] = v);
                  _savePref('temp', v);
                  _restartRotation();
                },
                onIntervalChanged: (s) {
                  setState(() => _intervals['temp'] = s);
                  _saveInterval('temp', s);
                  _restartRotation();
                },
              ),
              _CompactVitalTile<int>(
                title: t.steps,
                unit: '',
                icon: Icons.directions_walk_rounded,
                color: Colors.green,
                stream: sdk.stepsStream(widget.deviceId).map((s) => s.value),
                initialValue: cachedInt(MetricType.steps),
                format: (v) => '$v',
                isEnabled: _on['steps'] ?? false,
                activeVital: _activeVital,
                vitalKey: 'steps',
                interval: _intervals['steps'] ?? 15,
                onToggle: (v) {
                  setState(() => _on['steps'] = v);
                  _savePref('steps', v);
                  _restartRotation();
                },
                onIntervalChanged: (s) {
                  setState(() => _intervals['steps'] = s);
                  _saveInterval('steps', s);
                  _restartRotation();
                },
              ),
              _CompactVitalTile<int>(
                title: t.battery,
                unit: '%',
                icon: Icons.battery_6_bar_rounded,
                color: Colors.teal,
                stream: sdk.batteryStream(widget.deviceId).map((s) => s.value),
                initialValue: cachedInt(MetricType.battery),
                format: (v) => '$v',
                isEnabled: true,
                activeVital: _activeVital,
                vitalKey: 'battery',
                interval: 60,
                onToggle: null,
                onIntervalChanged: null,
              ),
              _CompactVitalTile<int>(
                title: t.tr('stress'),
                unit: '',
                icon: Icons.psychology_rounded,
                color: Colors.deepOrange,
                stream: sdk.stressStream(widget.deviceId).map((s) => s.value),
                initialValue: cachedInt(MetricType.stress),
                format: (v) => '$v',
                isEnabled: _on['hrv'] ?? false,
                activeVital: _activeVital,
                vitalKey: 'stress',
                interval: _intervals['hrv'] ?? 15,
                onToggle: null,
                onIntervalChanged: null,
              ),
            ],
          ),

          // ── Sleep Monitor ──
          _SectionHeader(title: t.tr('sleepMonitor')),
          _SleepMonitorCard(sdk: sdk, t: t),

          // ── Settings & Actions ──
          _SectionHeader(title: t.tr('settings') ?? 'Settings'),
          _ToggleFeatureCard(
            icon: Icons.phone_in_talk_rounded,
            color: Colors.green,
            title: t.tr('callReminderTitle'),
            subtitle: t.tr('callReminderSubtitle'),
            value: _on['callReminder'] ?? false,
            onChanged: (v) async {
              if (v) {
                final hasAccess = await sdk.isNotificationAccessEnabled();
                if (!hasAccess && mounted) {
                  await sdk.openNotificationAccessSettings();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text(
                        'Activeaza Notification Access pentru AGP Wear Hub, apoi incearca din nou.',
                      ),
                    ),
                  );
                  return;
                }
              }
              final ok = await sdk.setCallReminder(v);
              if (ok && mounted) {
                setState(() => _on['callReminder'] = v);
                _savePref('callReminder', v);
              } else if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Setarea nu a fost confirmata de bratara.'),
                  ),
                );
              }
            },
          ),
          _ToggleFeatureCard(
            icon: Icons.event_seat_rounded,
            color: Colors.orange,
            title: t.tr('sedentaryReminderTitle'),
            subtitle: t.tr('sedentaryReminderSubtitle'),
            value: _on['sedentary'] ?? false,
            onChanged: (v) async {
              final ok = await sdk.setSedentaryReminder(enable: v);
              if (ok && mounted) {
                setState(() => _on['sedentary'] = v);
                _savePref('sedentary', v);
              }
            },
          ),
          _ToggleFeatureCard(
            icon: Icons.do_not_disturb_rounded,
            color: Colors.red.shade300,
            title: t.tr('dndTitle'),
            subtitle: t.tr('dndSubtitle'),
            value: _on['dnd'] ?? false,
            onChanged: (v) async {
              final ok = await sdk.setDnd(enable: v);
              if (ok && mounted) {
                setState(() => _on['dnd'] = v);
                _savePref('dnd', v);
              }
            },
          ),
          _FeatureCard(
            icon: Icons.vibration_rounded,
            color: Colors.teal,
            title: t.tr('findBraceletTitle'),
            subtitle: t.tr('findBraceletSubtitle'),
            trailing: const Icon(Icons.touch_app_rounded),
            onTap: () async {
              await sdk.findDevice();
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(t.tr('braceletVibrating'))),
                );
              }
            },
          ),
          _FeatureCard(
            icon: Icons.alarm_rounded,
            color: Colors.amber,
            title: t.tr('alarmTitle'),
            subtitle: t.tr('alarmSubtitle'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () {
              _showAlarmDialog(context, sdk);
            },
          ),
          _FeatureCard(
            icon: Icons.monitor_heart_outlined,
            color: Colors.red,
            title: t.ekg,
            subtitle: t.ekgSubtitle,
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const EkgPage()),
              );
            },
          ),
          const SizedBox(height: 16),
          // ── Deconectare ──
          SizedBox(
            width: double.infinity,
            height: 52,
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.red,
                side: const BorderSide(color: Colors.red, width: 1.5),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              icon: const Icon(Icons.link_off_rounded),
              label: Text(
                t.tr('disconnectDevice'),
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 15,
                ),
              ),
              onPressed: () async {
                // Cancel all subscriptions first to stop stream activity
                _activeVitalSub?.cancel();
                _activeVitalSub = null;
                for (final sub in _historySubs) {
                  sub.cancel();
                }
                _historySubs.clear();
                await ref.read(bleReconnectProvider.notifier).stop();
                // Now disconnect (this stops rotation, timers, resets EventChannels)
                await sdk.disconnect();
                if (mounted) {
                  ref.read(connectedProvider.notifier).state = false;
                  Navigator.of(context).pop();
                }
              },
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  void _showAlarmDialog(BuildContext context, SdkService sdk) {
    final t = T(ref.read(localeProvider));
    showDialog(
      context: context,
      builder: (ctx) => _MultiAlarmDialog(sdk: sdk, t: t),
    );
  }
}

// ── Section Header ──

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
      child: Text(
        title.toUpperCase(),
        style: theme.textTheme.labelSmall?.copyWith(
          color: theme.colorScheme.onSurface.withOpacity(0.5),
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

class _BmiProfileCard extends StatelessWidget {
  const _BmiProfileCard({required this.user});

  final UserProfile? user;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final metrics = const HealthProfileService().fromUser(user);
    final bmi = metrics.bmi;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.45),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: theme.colorScheme.primary.withOpacity(0.22)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.health_and_safety_rounded,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Profil medical',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Text(
                'BPM max ${metrics.bpmMax}',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (bmi == null)
            Text(
              'Completeaza varsta, greutatea si inaltimea in Setari pentru BMI si zone BPM personalizate.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withOpacity(0.7),
              ),
            )
          else ...[
            Row(
              children: [
                Text(
                  bmi.value.toStringAsFixed(1),
                  style: theme.textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w900,
                    color: theme.colorScheme.primary,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        bmi.label,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        bmi.recommendation,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurface.withOpacity(0.68),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                minHeight: 8,
                value: (bmi.value / 40).clamp(0.0, 1.0),
                backgroundColor: theme.colorScheme.outline.withOpacity(0.18),
                color: _bmiColor(bmi.category),
              ),
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: metrics.zones
                .map(
                  (z) => Chip(
                    label: Text('${z.label} ${z.min}-${z.max}'),
                    visualDensity: VisualDensity.compact,
                    backgroundColor: theme.colorScheme.primary.withOpacity(
                      0.10,
                    ),
                  ),
                )
                .toList(),
          ),
        ],
      ),
    );
  }

  Color _bmiColor(BmiCategory category) => switch (category) {
    BmiCategory.underweight => Colors.blue,
    BmiCategory.normal => Colors.green,
    BmiCategory.overweight => Colors.orange,
    BmiCategory.obese => Colors.red,
  };
}

// ── Feature Card (action) ──

class _FeatureCard extends StatelessWidget {
  const _FeatureCard({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    this.trailing,
    this.onTap,
  });
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: theme.colorScheme.outline.withOpacity(0.15)),
      ),
      child: ListTile(
        leading: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: color.withOpacity(0.15),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: color, size: 22),
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(subtitle, style: theme.textTheme.bodySmall),
        trailing: trailing,
        onTap: onTap,
      ),
    );
  }
}

// ── Toggle Feature Card ──

class _ToggleFeatureCard extends StatelessWidget {
  const _ToggleFeatureCard({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: theme.colorScheme.outline.withOpacity(0.15)),
      ),
      child: ListTile(
        leading: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: color.withOpacity(0.15),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: color, size: 22),
        ),
        title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(subtitle, style: theme.textTheme.bodySmall),
        trailing: Switch(
          value: value,
          onChanged: onChanged,
          activeThumbColor: color,
        ),
      ),
    );
  }
}

// ── Multi Alarm Dialog ──

class _MultiAlarmDialog extends StatefulWidget {
  const _MultiAlarmDialog({required this.sdk, required this.t});
  final SdkService sdk;
  final T t;

  @override
  State<_MultiAlarmDialog> createState() => _MultiAlarmDialogState();
}

class _MultiAlarmDialogState extends State<_MultiAlarmDialog> {
  // Up to 5 alarm slots (index 0-4)
  final List<({int hour, int minute, bool enabled})> _alarms = [
    (hour: 8, minute: 0, enabled: false),
  ];

  void _addAlarm() {
    if (_alarms.length >= 5) return;
    setState(() {
      _alarms.add((hour: 8, minute: 0, enabled: false));
    });
  }

  void _removeAlarm(int index) {
    if (_alarms.length <= 1) return;
    // Disable alarm on bracelet before removing
    widget.sdk.setAlarm(index: index, enable: false, hour: 0, minute: 0);
    setState(() {
      _alarms.removeAt(index);
    });
  }

  Future<void> _setAlarm(int index) async {
    final alarm = _alarms[index];
    final ok = await widget.sdk.setAlarm(
      index: index,
      enable: true,
      hour: alarm.hour,
      minute: alarm.minute,
    );
    if (!mounted) return;
    if (ok) {
      setState(() {
        _alarms[index] = (
          hour: alarm.hour,
          minute: alarm.minute,
          enabled: true,
        );
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${widget.t.tr('alarmSetFor')} ${alarm.hour.toString().padLeft(2, '0')}:${alarm.minute.toString().padLeft(2, '0')}',
          ),
        ),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Alarma nu a putut fi setata.')),
      );
    }
  }

  Future<void> _disableAlarm(int index) async {
    final alarm = _alarms[index];
    await widget.sdk.setAlarm(
      index: index,
      enable: false,
      hour: alarm.hour,
      minute: alarm.minute,
    );
    if (mounted) {
      setState(() {
        _alarms[index] = (
          hour: alarm.hour,
          minute: alarm.minute,
          enabled: false,
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = widget.t;

    return AlertDialog(
      title: Text(t.tr('setAlarm')),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ...List.generate(_alarms.length, (i) {
              final alarm = _alarms[i];
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    // Hour picker
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          iconSize: 20,
                          constraints: const BoxConstraints(
                            minWidth: 32,
                            minHeight: 32,
                          ),
                          onPressed: () => setState(() {
                            final h = (alarm.hour + 1) % 24;
                            _alarms[i] = (
                              hour: h,
                              minute: alarm.minute,
                              enabled: alarm.enabled,
                            );
                          }),
                          icon: const Icon(Icons.keyboard_arrow_up_rounded),
                        ),
                        Text(
                          alarm.hour.toString().padLeft(2, '0'),
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        IconButton(
                          iconSize: 20,
                          constraints: const BoxConstraints(
                            minWidth: 32,
                            minHeight: 32,
                          ),
                          onPressed: () => setState(() {
                            final h = (alarm.hour - 1 + 24) % 24;
                            _alarms[i] = (
                              hour: h,
                              minute: alarm.minute,
                              enabled: alarm.enabled,
                            );
                          }),
                          icon: const Icon(Icons.keyboard_arrow_down_rounded),
                        ),
                      ],
                    ),
                    Text(
                      ':',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    // Minute picker
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          iconSize: 20,
                          constraints: const BoxConstraints(
                            minWidth: 32,
                            minHeight: 32,
                          ),
                          onPressed: () => setState(() {
                            final m = (alarm.minute + 1) % 60;
                            _alarms[i] = (
                              hour: alarm.hour,
                              minute: m,
                              enabled: alarm.enabled,
                            );
                          }),
                          icon: const Icon(Icons.keyboard_arrow_up_rounded),
                        ),
                        Text(
                          alarm.minute.toString().padLeft(2, '0'),
                          style: theme.textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        IconButton(
                          iconSize: 20,
                          constraints: const BoxConstraints(
                            minWidth: 32,
                            minHeight: 32,
                          ),
                          onPressed: () => setState(() {
                            final m = (alarm.minute - 1 + 60) % 60;
                            _alarms[i] = (
                              hour: alarm.hour,
                              minute: m,
                              enabled: alarm.enabled,
                            );
                          }),
                          icon: const Icon(Icons.keyboard_arrow_down_rounded),
                        ),
                      ],
                    ),
                    const SizedBox(width: 8),
                    // Set / toggle
                    IconButton(
                      icon: Icon(
                        alarm.enabled
                            ? Icons.alarm_on_rounded
                            : Icons.alarm_add_rounded,
                        color: alarm.enabled
                            ? Colors.green
                            : theme.colorScheme.primary,
                      ),
                      onPressed: () =>
                          alarm.enabled ? _disableAlarm(i) : _setAlarm(i),
                      tooltip: alarm.enabled ? t.tr('cancel') : t.tr('set'),
                    ),
                    if (_alarms.length > 1)
                      IconButton(
                        icon: const Icon(
                          Icons.delete_outline_rounded,
                          size: 20,
                        ),
                        onPressed: () => _removeAlarm(i),
                        color: Colors.red,
                      ),
                  ],
                ),
              );
            }),
            if (_alarms.length < 5)
              TextButton.icon(
                onPressed: _addAlarm,
                icon: const Icon(Icons.add_rounded),
                label: Text(t.tr('addAlarm')),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t.tr('close')),
        ),
      ],
    );
  }
}

// ── Sleep Monitor Card (real-time tracking) ──

class _SleepMonitorCard extends StatefulWidget {
  const _SleepMonitorCard({required this.sdk, required this.t});
  final SdkService sdk;
  final T t;

  @override
  State<_SleepMonitorCard> createState() => _SleepMonitorCardState();
}

class _SleepMonitorCardState extends State<_SleepMonitorCard> {
  bool _tracking = false;
  DateTime? _startTime;
  Timer? _uiTimer;

  // Sleep phase data recorded during tracking
  final List<({DateTime time, int phase})> _phases = [];
  // phase: 1=deep, 2=light, 3=REM, 4=awake

  // Computed stats
  int _deepMin = 0;
  int _lightMin = 0;
  int _remMin = 0;
  int _awakeMin = 0;
  int _totalMin = 0;

  String _formatMinutes(int m) {
    if (m <= 0) return '--';
    final h = m ~/ 60;
    final r = m % 60;
    return h > 0 ? '${h}h ${r}m' : '${r}m';
  }

  void _startTracking() {
    setState(() {
      _tracking = true;
      _startTime = DateTime.now();
      _phases.clear();
      _deepMin = 0;
      _lightMin = 0;
      _remMin = 0;
      _awakeMin = 0;
      _totalMin = 0;
    });
    // Poll sleep data periodically from bracelet
    _uiTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _pollSleepData();
    });
  }

  void _stopTracking() {
    _uiTimer?.cancel();
    _uiTimer = null;
    // Final poll
    _pollSleepData();
    setState(() {
      _tracking = false;
    });
  }

  Future<void> _pollSleepData() async {
    final data = await widget.sdk.syncSleep();
    if (data != null && mounted) {
      setState(() {
        _deepMin = (data['deepSleep'] as num?)?.toInt() ?? 0;
        _lightMin = (data['lightSleep'] as num?)?.toInt() ?? 0;
        _remMin = (data['remSleep'] as num?)?.toInt() ?? 0;
        _awakeMin = (data['awake'] as num?)?.toInt() ?? 0;
        _totalMin = (data['totalSleep'] as num?)?.toInt() ?? 0;

        // Build phases from segments if available
        if (data['segments'] is List) {
          _phases.clear();
          final segments = data['segments'] as List;
          var time = _startTime ?? DateTime.now();
          for (final seg in segments) {
            if (seg is Map) {
              final duration = (seg['duration'] as num?)?.toInt() ?? 0;
              final type = (seg['type'] as num?)?.toInt() ?? 2;
              _phases.add((time: time, phase: type));
              time = time.add(Duration(minutes: duration));
            }
          }
        }
      });
    }
  }

  @override
  void dispose() {
    _uiTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = widget.t;
    const color = Colors.indigo;
    final hasData = _totalMin > 0;
    final elapsed = _startTime != null
        ? DateTime.now().difference(_startTime!)
        : Duration.zero;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: theme.colorScheme.outline.withOpacity(0.15)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: color.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.bedtime_rounded,
                    color: color,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        t.tr('sleepMonitor'),
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      if (_tracking && _startTime != null)
                        Text(
                          '${t.tr('tracking')} - ${_formatMinutes(elapsed.inMinutes)}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: Colors.green,
                          ),
                        )
                      else
                        Text(
                          t.tr('tapToStartSleep'),
                          style: theme.textTheme.bodySmall,
                        ),
                    ],
                  ),
                ),
                FilledButton.icon(
                  onPressed: _tracking ? _stopTracking : _startTracking,
                  icon: Icon(
                    _tracking ? Icons.stop_rounded : Icons.play_arrow_rounded,
                    size: 18,
                  ),
                  label: Text(
                    _tracking ? t.tr('stop') : t.tr('start'),
                    style: const TextStyle(fontSize: 12),
                  ),
                  style: FilledButton.styleFrom(
                    backgroundColor: _tracking ? Colors.red : color,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    minimumSize: Size.zero,
                  ),
                ),
              ],
            ),
            if (hasData) ...[
              const Divider(height: 20),
              // ── Sleep phase graph ──
              SizedBox(
                height: 60,
                child: CustomPaint(
                  size: const Size(double.infinity, 60),
                  painter: _SleepGraphPainter(
                    deepMin: _deepMin,
                    lightMin: _lightMin,
                    remMin: _remMin,
                    awakeMin: _awakeMin,
                    totalMin: _totalMin,
                    isDark: theme.brightness == Brightness.dark,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              // ── Legend ──
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _SleepLegend(
                    color: Colors.blue.shade800,
                    label: t.tr('deep'),
                  ),
                  _SleepLegend(color: Colors.lightBlue, label: t.tr('light')),
                  _SleepLegend(color: Colors.purple, label: 'REM'),
                  _SleepLegend(color: Colors.orange, label: t.tr('awake')),
                ],
              ),
              const SizedBox(height: 8),
              // ── Stats ──
              Row(
                children: [
                  _SleepStat(
                    label: t.tr('total'),
                    value: _formatMinutes(_totalMin),
                    color: color,
                  ),
                  _SleepStat(
                    label: t.tr('deep'),
                    value: _formatMinutes(_deepMin),
                    color: Colors.blue.shade800,
                  ),
                  _SleepStat(
                    label: t.tr('light'),
                    value: _formatMinutes(_lightMin),
                    color: Colors.lightBlue,
                  ),
                  _SleepStat(
                    label: 'REM',
                    value: _formatMinutes(_remMin),
                    color: Colors.purple,
                  ),
                  _SleepStat(
                    label: t.tr('awake'),
                    value: _formatMinutes(_awakeMin),
                    color: Colors.orange,
                  ),
                ],
              ),
            ] else if (!_tracking) ...[
              const Divider(height: 20),
              Center(
                child: Text(
                  t.tr('tapToStartSleep'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withOpacity(0.5),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ── Sleep Graph Painter ──

class _SleepGraphPainter extends CustomPainter {
  _SleepGraphPainter({
    required this.deepMin,
    required this.lightMin,
    required this.remMin,
    required this.awakeMin,
    required this.totalMin,
    required this.isDark,
  });

  final int deepMin;
  final int lightMin;
  final int remMin;
  final int awakeMin;
  final int totalMin;
  final bool isDark;

  @override
  void paint(Canvas canvas, Size size) {
    if (totalMin <= 0) return;

    final total = deepMin + lightMin + remMin + awakeMin;
    if (total <= 0) return;

    final phases = <(Color, double)>[
      (Colors.blue.shade800, deepMin / total),
      (Colors.lightBlue, lightMin / total),
      (Colors.purple, remMin / total),
      (Colors.orange, awakeMin / total),
    ];

    // Bar chart style - horizontal stacked bars
    final barHeight = size.height * 0.6;
    final barY = (size.height - barHeight) / 2;
    final radius = Radius.circular(6);

    double x = 0;
    for (int i = 0; i < phases.length; i++) {
      final (color, fraction) = phases[i];
      if (fraction <= 0) continue;
      final w = fraction * size.width;
      final paint = Paint()..color = color;

      RRect rr;
      if (i == 0 && x == 0) {
        rr = RRect.fromLTRBAndCorners(
          x,
          barY,
          x + w,
          barY + barHeight,
          topLeft: radius,
          bottomLeft: radius,
        );
      } else if (i == phases.length - 1 || (x + w >= size.width - 1)) {
        rr = RRect.fromLTRBAndCorners(
          x,
          barY,
          x + w,
          barY + barHeight,
          topRight: radius,
          bottomRight: radius,
        );
      } else {
        rr = RRect.fromLTRBR(x, barY, x + w, barY + barHeight, Radius.zero);
      }
      canvas.drawRRect(rr, paint);
      x += w;
    }
  }

  @override
  bool shouldRepaint(covariant _SleepGraphPainter old) =>
      old.deepMin != deepMin ||
      old.lightMin != lightMin ||
      old.remMin != remMin ||
      old.awakeMin != awakeMin;
}

// ── Sleep Legend ──

class _SleepLegend extends StatelessWidget {
  const _SleepLegend({required this.color, required this.label});
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(3),
          ),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(fontSize: 10),
        ),
      ],
    );
  }
}

// ── Sleep Stat ──

class _SleepStat extends StatelessWidget {
  const _SleepStat({
    required this.label,
    required this.value,
    required this.color,
  });
  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 14,
              color: color,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(fontSize: 10),
          ),
        ],
      ),
    );
  }
}

// ── Number Picker for Alarm Dialog ──

class _ConnectionBanner extends ConsumerWidget {
  const _ConnectionBanner({required this.deviceId});

  final String deviceId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final t = T(ref.watch(localeProvider));

    const Color bannerColor = Colors.green;
    final String statusText = t.connectedActive;
    final String subtitleText = t.realtimeMonitoring;
    const IconData icon = Icons.bluetooth_connected_rounded;

    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [bannerColor.withOpacity(0.1), bannerColor.withOpacity(0.2)],
        ),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: bannerColor.withOpacity(0.2)),
      ),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: bannerColor,
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(icon, color: Colors.white, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  statusText,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: bannerColor.withOpacity(0.9),
                  ),
                ),
                Text(
                  subtitleText,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: bannerColor.withOpacity(0.8),
                  ),
                ),
              ],
            ),
          ),
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: Colors.green,
              borderRadius: BorderRadius.circular(4),
              boxShadow: [
                BoxShadow(
                  color: Colors.green.withOpacity(0.4),
                  blurRadius: 4,
                  spreadRadius: 1,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CompactVitalTile<T> extends StatefulWidget {
  const _CompactVitalTile({
    required this.title,
    required this.unit,
    required this.icon,
    required this.color,
    required this.stream,
    required this.initialValue,
    required this.format,
    required this.isEnabled,
    required this.activeVital,
    required this.vitalKey,
    required this.interval,
    required this.onToggle,
    required this.onIntervalChanged,
  });

  final String title;
  final String unit;
  final IconData icon;
  final Color color;
  final Stream<T> stream;
  final T? initialValue;
  final String Function(T) format;
  final bool isEnabled;
  final ValueListenable<String> activeVital;
  final String vitalKey;
  final int interval;
  final ValueChanged<bool>? onToggle;
  final ValueChanged<int>? onIntervalChanged;

  @override
  State<_CompactVitalTile<T>> createState() => _CompactVitalTileState<T>();
}

class _CompactVitalTileState<T> extends State<_CompactVitalTile<T>>
    with SingleTickerProviderStateMixin {
  T? _currentValue;
  StreamSubscription<T>? _sub;
  late AnimationController _pulseCtrl;

  bool get _isMeasuring => widget.activeVital.value == widget.vitalKey;

  void _onActiveVitalChanged() {
    final measuring = _isMeasuring;
    if (measuring && !_pulseCtrl.isAnimating) {
      _pulseCtrl.repeat(reverse: true);
    } else if (!measuring && _pulseCtrl.isAnimating) {
      _pulseCtrl.stop();
      _pulseCtrl.value = 0;
    }
  }

  @override
  void initState() {
    super.initState();
    _currentValue = widget.initialValue;
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _sub = widget.stream.listen((value) {
      if (mounted) setState(() => _currentValue = value);
    });
    widget.activeVital.addListener(_onActiveVitalChanged);
    if (_isMeasuring) _pulseCtrl.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant _CompactVitalTile<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_currentValue == null &&
        widget.initialValue != oldWidget.initialValue) {
      _currentValue = widget.initialValue;
    }
  }

  @override
  void dispose() {
    widget.activeVital.removeListener(_onActiveVitalChanged);
    _pulseCtrl.dispose();
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = widget.isEnabled;
    final measuring = _isMeasuring;

    return Container(
      decoration: BoxDecoration(
        color: active
            ? widget.color.withOpacity(0.1)
            : theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: active
              ? widget.color.withOpacity(0.3)
              : theme.colorScheme.outline.withOpacity(0.2),
          width: active ? 2 : 1,
        ),
        boxShadow: active
            ? [
                BoxShadow(
                  color: widget.color.withOpacity(0.1),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ]
            : null,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                AnimatedBuilder(
                  animation: _pulseCtrl,
                  builder: (_, child) => Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: measuring
                          ? widget.color.withOpacity(
                              0.6 + 0.4 * _pulseCtrl.value,
                            )
                          : active
                          ? widget.color
                          : theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Icon(
                      widget.icon,
                      size: 14,
                      color: active
                          ? Colors.white
                          : theme.colorScheme.onSurface.withOpacity(0.6),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    widget.title,
                    style: theme.textTheme.labelMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: active
                          ? widget.color
                          : theme.colorScheme.onSurface,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (widget.onToggle != null)
                  Transform.scale(
                    scale: 0.7,
                    child: Switch(
                      value: active,
                      onChanged: widget.onToggle,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      activeThumbColor: widget.color,
                    ),
                  ),
              ],
            ),

            const Spacer(),

            if (_currentValue != null) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    widget.format(_currentValue as T),
                    style: theme.textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: active
                          ? widget.color
                          : theme.colorScheme.onSurface,
                    ),
                  ),
                  if (widget.unit.isNotEmpty) ...[
                    const SizedBox(width: 3),
                    Text(
                      widget.unit,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: active
                            ? widget.color.withOpacity(0.8)
                            : theme.colorScheme.onSurface.withOpacity(0.6),
                      ),
                    ),
                  ],
                ],
              ),
            ] else ...[
              Text(
                active ? (measuring ? '...' : '—') : '--',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: theme.colorScheme.onSurface.withOpacity(0.4),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
