import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n/locale.dart';
import '../../models/metric.dart';
import '../../services/sampling_policy.dart';

class SamplingPolicyPage extends ConsumerWidget {
  const SamplingPolicyPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final policy = ref.watch(samplingPolicyProvider);
    final svc = ref.read(samplingPolicyProvider.notifier);
    final t = T(ref.watch(localeProvider));
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: Text(
          t.tr('samplingPoliciesTitle'),
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        centerTitle: true,
        elevation: 0,
        backgroundColor: Colors.transparent,
        actions: [
          IconButton(
            icon: const Icon(Icons.restore),
            tooltip: t.tr('resetDefaults'),
            onPressed: () {
              svc.resetToDefaults();
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(t.tr('resetDone')),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Battery Mode ──
          _SectionCard(
            title: t.tr('batteryMode'),
            icon: Icons.battery_charging_full_rounded,
            children: [
              SegmentedButton<BatteryMode>(
                segments: [
                  ButtonSegment(
                    value: BatteryMode.performance,
                    label: Text(t.tr('performance')),
                    icon: Icon(Icons.speed, size: 18),
                  ),
                  ButtonSegment(
                    value: BatteryMode.balanced,
                    label: Text(t.tr('balanced')),
                    icon: Icon(Icons.balance, size: 18),
                  ),
                  ButtonSegment(
                    value: BatteryMode.powerSaver,
                    label: Text(t.tr('eco')),
                    icon: Icon(Icons.eco, size: 18),
                  ),
                ],
                selected: {policy.batteryMode},
                onSelectionChanged: (s) => svc.setBatteryMode(s.first),
              ),
              const SizedBox(height: 12),
              _BatteryModeInfo(mode: policy.batteryMode, t: t),
              const SizedBox(height: 12),
              SwitchListTile(
                title: Text(t.tr('samplingAdaptive')),
                subtitle: Text(t.tr('samplingAdaptiveDesc')),
                value: policy.adaptiveSampling,
                onChanged: svc.setAdaptiveSampling,
                contentPadding: EdgeInsets.zero,
              ),
            ],
          ),
          const SizedBox(height: 16),

          // ── Frecvențe de citire ──
          _SectionCard(
            title: t.tr('readingFrequencies'),
            icon: Icons.timer_rounded,
            children: [
              _MetricIntervalTile(
                label: t.hr,
                icon: Icons.favorite,
                color: Colors.red,
                config: policy.configs[MetricType.heartRate]!,
                effectiveInterval: policy.effectiveInterval(
                  MetricType.heartRate,
                ),
                t: t,
                onIntervalChanged: (v) =>
                    svc.setInterval(MetricType.heartRate, v),
                onEnabledChanged: (v) =>
                    svc.setEnabled(MetricType.heartRate, v),
              ),
              const Divider(height: 1),
              _MetricIntervalTile(
                label: t.spo2,
                icon: Icons.air,
                color: Colors.blue,
                config: policy.configs[MetricType.spo2]!,
                effectiveInterval: policy.effectiveInterval(MetricType.spo2),
                t: t,
                onIntervalChanged: (v) => svc.setInterval(MetricType.spo2, v),
                onEnabledChanged: (v) => svc.setEnabled(MetricType.spo2, v),
              ),
              const Divider(height: 1),
              _MetricIntervalTile(
                label: t.temperature,
                icon: Icons.thermostat,
                color: Colors.orange,
                config: policy.configs[MetricType.temperature]!,
                effectiveInterval: policy.effectiveInterval(
                  MetricType.temperature,
                ),
                t: t,
                onIntervalChanged: (v) =>
                    svc.setInterval(MetricType.temperature, v),
                onEnabledChanged: (v) =>
                    svc.setEnabled(MetricType.temperature, v),
              ),
              const Divider(height: 1),
              _MetricIntervalTile(
                label: t.steps,
                icon: Icons.directions_walk,
                color: Colors.green,
                config: policy.configs[MetricType.steps]!,
                effectiveInterval: policy.effectiveInterval(MetricType.steps),
                t: t,
                onIntervalChanged: (v) => svc.setInterval(MetricType.steps, v),
                onEnabledChanged: (v) => svc.setEnabled(MetricType.steps, v),
              ),
              const Divider(height: 1),
              _MetricIntervalTile(
                label: t.battery,
                icon: Icons.battery_std,
                color: Colors.amber,
                config: policy.configs[MetricType.battery]!,
                effectiveInterval: policy.effectiveInterval(MetricType.battery),
                t: t,
                onIntervalChanged: (v) =>
                    svc.setInterval(MetricType.battery, v),
                onEnabledChanged: (v) => svc.setEnabled(MetricType.battery, v),
              ),
              const Divider(height: 1),
              _MetricIntervalTile(
                label: t.respiration,
                icon: Icons.air_rounded,
                color: Colors.teal,
                config: policy.configs[MetricType.respiration]!,
                effectiveInterval: policy.effectiveInterval(
                  MetricType.respiration,
                ),
                t: t,
                onIntervalChanged: (v) =>
                    svc.setInterval(MetricType.respiration, v),
                onEnabledChanged: (v) =>
                    svc.setEnabled(MetricType.respiration, v),
              ),
              const Divider(height: 1),
              _MetricIntervalTile(
                label: t.hrv,
                icon: Icons.show_chart,
                color: Colors.purple,
                config: policy.configs[MetricType.hrv]!,
                effectiveInterval: policy.effectiveInterval(MetricType.hrv),
                t: t,
                onIntervalChanged: (v) => svc.setInterval(MetricType.hrv, v),
                onEnabledChanged: (v) => svc.setEnabled(MetricType.hrv, v),
              ),
              const Divider(height: 1),
              _MetricIntervalTile(
                label: t.bloodPressure,
                icon: Icons.monitor_heart,
                color: Colors.redAccent,
                config: policy.configs[MetricType.bloodPressureSystolic]!,
                effectiveInterval: policy.effectiveInterval(
                  MetricType.bloodPressureSystolic,
                ),
                t: t,
                onIntervalChanged: (v) {
                  svc.setInterval(MetricType.bloodPressureSystolic, v);
                  svc.setInterval(MetricType.bloodPressureDiastolic, v);
                },
                onEnabledChanged: (v) {
                  svc.setEnabled(MetricType.bloodPressureSystolic, v);
                  svc.setEnabled(MetricType.bloodPressureDiastolic, v);
                },
              ),
              const Divider(height: 1),
              _MetricIntervalTile(
                label: t.tr('calories'),
                icon: Icons.local_fire_department,
                color: Colors.deepOrange,
                config: policy.configs[MetricType.calories]!,
                effectiveInterval: policy.effectiveInterval(
                  MetricType.calories,
                ),
                t: t,
                onIntervalChanged: (v) =>
                    svc.setInterval(MetricType.calories, v),
                onEnabledChanged: (v) => svc.setEnabled(MetricType.calories, v),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // ── Mock indicator ──
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.green.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.green.withOpacity(0.3)),
            ),
            child: Row(
              children: [
                const Icon(Icons.info_outline, color: Colors.green, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    t.tr('samplingRealNotice'),
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

class _BatteryModeInfo extends StatelessWidget {
  const _BatteryModeInfo({required this.mode, required this.t});
  final BatteryMode mode;
  final T t;

  @override
  Widget build(BuildContext context) {
    final (desc, color) = switch (mode) {
      BatteryMode.performance => (t.tr('performanceDesc'), Colors.red),
      BatteryMode.balanced => (t.tr('balancedDesc'), Colors.green),
      BatteryMode.powerSaver => (t.tr('ecoDesc'), Colors.blue),
    };

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, color: color, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(desc, style: TextStyle(fontSize: 12, color: color)),
          ),
        ],
      ),
    );
  }
}

class _MetricIntervalTile extends StatelessWidget {
  const _MetricIntervalTile({
    required this.label,
    required this.icon,
    required this.color,
    required this.config,
    required this.effectiveInterval,
    required this.t,
    required this.onIntervalChanged,
    required this.onEnabledChanged,
  });

  final String label;
  final IconData icon;
  final Color color;
  final SamplingConfig config;
  final int effectiveInterval;
  final T t;
  final ValueChanged<int> onIntervalChanged;
  final ValueChanged<bool> onEnabledChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 10),
          Expanded(
            flex: 2,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontWeight: FontWeight.w500,
                    fontSize: 13,
                  ),
                ),
                Text(
                  t
                      .tr('intervalWithEffective')
                      .replaceAll('{base}', '${config.intervalSeconds}')
                      .replaceAll('{effective}', '$effectiveInterval'),
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurface.withOpacity(0.5),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(
            width: 120,
            child: Slider(
              value: config.intervalSeconds.toDouble(),
              min: 1,
              max: 120,
              divisions: 119,
              label: '${config.intervalSeconds}s',
              onChanged: config.enabled
                  ? (v) => onIntervalChanged(v.round())
                  : null,
            ),
          ),
          Switch(value: config.enabled, onChanged: onEnabledChanged),
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.icon,
    required this.children,
  });
  final String title;
  final IconData icon;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.colorScheme.outline.withOpacity(0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  icon,
                  size: 18,
                  color: theme.colorScheme.onPrimaryContainer,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                title,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          ...children,
        ],
      ),
    );
  }
}
