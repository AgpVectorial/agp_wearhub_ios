import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/metric.dart';
import '../../services/cloud_service.dart';

class CloudSettingsPage extends ConsumerWidget {
  const CloudSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cloud = ref.watch(cloudServiceProvider);
    final svc = ref.read(cloudServiceProvider.notifier);
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text(
          'Cloud & Backend',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        centerTitle: true,
        elevation: 0,
        backgroundColor: Colors.transparent,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Status Sync ──
          _StatusBanner(cloud: cloud),
          const SizedBox(height: 16),

          // ── Sync & Backup ──
          _SectionCard(
            title: 'Sincronizare & Backup',
            icon: Icons.cloud_sync_rounded,
            children: [
              _InfoRow(
                label: 'Ultima sincronizare',
                value: cloud.lastSyncTime != null
                    ? _formatTime(cloud.lastSyncTime!)
                    : 'Niciodată',
              ),
              _InfoRow(
                label: 'Upload-uri în așteptare',
                value: '${cloud.pendingUploads}',
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      icon: Icon(
                        cloud.syncStatus == CloudSyncStatus.syncing
                            ? Icons.hourglass_top
                            : Icons.sync,
                      ),
                      label: Text(
                        cloud.syncStatus == CloudSyncStatus.syncing
                            ? 'Se sincronizează...'
                            : 'Sincronizează acum',
                      ),
                      onPressed: cloud.syncStatus == CloudSyncStatus.syncing
                          ? null
                          : () => svc.syncNow(),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.backup_rounded),
                      label: const Text('Backup complet'),
                      onPressed: cloud.syncStatus == CloudSyncStatus.syncing
                          ? null
                          : () => svc.createBackup(),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                title: const Text('Backup automat'),
                subtitle: const Text('Backup zilnic al datelor'),
                value: cloud.backupEnabled,
                onChanged: svc.setBackupEnabled,
                contentPadding: EdgeInsets.zero,
              ),
            ],
          ),
          const SizedBox(height: 16),

          // ── Remote Access ──
          _SectionCard(
            title: 'Acces Remote',
            icon: Icons.people_rounded,
            children: [
              SwitchListTile(
                title: const Text('Acces remote familie/medic'),
                subtitle: const Text('Permite accesul la metrici în timp real'),
                value: cloud.remoteAccessEnabled,
                onChanged: svc.setRemoteAccessEnabled,
                contentPadding: EdgeInsets.zero,
              ),
              const Divider(),
              ...svc.sharedAccess.map(
                (entry) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(
                    backgroundColor: entry.role == 'doctor'
                        ? Colors.blue.withOpacity(0.2)
                        : Colors.green.withOpacity(0.2),
                    child: Icon(
                      entry.role == 'doctor'
                          ? Icons.medical_services
                          : Icons.family_restroom,
                      color: entry.role == 'doctor'
                          ? Colors.blue
                          : Colors.green,
                      size: 20,
                    ),
                  ),
                  title: Text(entry.name),
                  subtitle: Text(
                    '${entry.role == "doctor" ? "Medic" : "Familie"} • ${entry.email}',
                  ),
                  trailing: IconButton(
                    icon: const Icon(
                      Icons.remove_circle_outline,
                      color: Colors.red,
                    ),
                    onPressed: () => svc.revokeSharedAccess(entry.id),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.person_add),
                label: const Text('Adaugă acces'),
                onPressed: () => _showAddAccessDialog(context, svc),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // ── Server Notifications ──
          _SectionCard(
            title: 'Notificări Server-Side',
            icon: Icons.notifications_active_rounded,
            children: [
              SwitchListTile(
                title: const Text('Notificări server'),
                subtitle: const Text(
                  'Alertează familia/medicul la valori critice',
                ),
                value: cloud.serverNotificationsEnabled,
                onChanged: svc.setServerNotifications,
                contentPadding: EdgeInsets.zero,
              ),
              const Divider(),
              ...svc.notificationRules.map(
                (rule) => ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    rule.isAbove ? Icons.arrow_upward : Icons.arrow_downward,
                    color: Colors.orange,
                  ),
                  title: Text(
                    '${rule.metricType.dbName.toUpperCase()} '
                    '${rule.isAbove ? ">" : "<"} ${rule.threshold.toStringAsFixed(0)}',
                  ),
                  subtitle: Text('Destinatari: ${rule.recipients.join(", ")}'),
                  trailing: Icon(
                    rule.enabled ? Icons.check_circle : Icons.cancel,
                    color: rule.enabled ? Colors.green : Colors.grey,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // ── API Info (mock) ──
          _SectionCard(
            title: 'API Backend',
            icon: Icons.api_rounded,
            children: [
              _InfoRow(label: 'Endpoint', value: 'https://api.agpwear.mock/v1'),
              _InfoRow(label: 'Status', value: 'Mock (simulat local)'),
              _InfoRow(label: 'Versiune API', value: 'v1.0.0-mock'),
              _InfoRow(label: 'Autentificare', value: 'JWT Bearer (mock)'),
              const SizedBox(height: 8),
              Container(
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
                        'Backend-ul este în modul mockup. Toate operațiile '
                        'sunt simulate local.',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  void _showAddAccessDialog(BuildContext context, CloudService svc) {
    final nameCtrl = TextEditingController();
    final emailCtrl = TextEditingController();
    String role = 'family';

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Adaugă acces'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                decoration: const InputDecoration(labelText: 'Nume'),
              ),
              TextField(
                controller: emailCtrl,
                decoration: const InputDecoration(labelText: 'Email'),
              ),
              const SizedBox(height: 12),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'family', label: Text('Familie')),
                  ButtonSegment(value: 'doctor', label: Text('Medic')),
                ],
                selected: {role},
                onSelectionChanged: (s) => setDialogState(() => role = s.first),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Anulează'),
            ),
            FilledButton(
              onPressed: () {
                if (nameCtrl.text.isNotEmpty && emailCtrl.text.isNotEmpty) {
                  svc.addSharedAccess(
                    name: nameCtrl.text,
                    role: role,
                    email: emailCtrl.text,
                  );
                  Navigator.pop(ctx);
                }
              },
              child: const Text('Adaugă'),
            ),
          ],
        ),
      ),
    );
  }

  static String _formatTime(DateTime dt) {
    final d = dt.toLocal();
    return '${d.day.toString().padLeft(2, '0')}.'
        '${d.month.toString().padLeft(2, '0')}.'
        '${d.year} '
        '${d.hour.toString().padLeft(2, '0')}:'
        '${d.minute.toString().padLeft(2, '0')}';
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.cloud});
  final CloudState cloud;

  @override
  Widget build(BuildContext context) {
    final (icon, color, text) = switch (cloud.syncStatus) {
      CloudSyncStatus.idle => (Icons.cloud_off, Colors.grey, 'Neconectat'),
      CloudSyncStatus.syncing => (
        Icons.cloud_sync,
        Colors.blue,
        'Se sincronizează...',
      ),
      CloudSyncStatus.synced => (Icons.cloud_done, Colors.green, 'Sincronizat'),
      CloudSyncStatus.error => (
        Icons.cloud_off,
        Colors.red,
        'Eroare sincronizare',
      ),
    };

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 28),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                text,
                style: TextStyle(fontWeight: FontWeight.w600, color: color),
              ),
              if (cloud.lastSyncTime != null)
                Text(
                  'Ultima: ${CloudSettingsPage._formatTime(cloud.lastSyncTime!)}',
                  style: TextStyle(fontSize: 12, color: color.withOpacity(0.7)),
                ),
            ],
          ),
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

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
              fontSize: 13,
            ),
          ),
          Flexible(
            child: Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13),
              textAlign: TextAlign.end,
            ),
          ),
        ],
      ),
    );
  }
}
