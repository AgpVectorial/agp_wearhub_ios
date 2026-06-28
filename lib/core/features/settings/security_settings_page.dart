import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/security_service.dart';

class SecuritySettingsPage extends ConsumerWidget {
  const SecuritySettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sec = ref.watch(securityServiceProvider);
    final svc = ref.read(securityServiceProvider.notifier);
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      appBar: AppBar(
        title: const Text(
          'Securitate & GDPR',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        centerTitle: true,
        elevation: 0,
        backgroundColor: Colors.transparent,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // ── Criptare ──
          _SectionCard(
            title: 'Criptarea datelor',
            icon: Icons.lock_rounded,
            children: [
              SwitchListTile(
                title: const Text('Criptare date locale'),
                subtitle: const Text('AES-256 pentru baza de date locală'),
                value: sec.localEncryptionEnabled,
                onChanged: svc.setEncryption,
                contentPadding: EdgeInsets.zero,
              ),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: sec.localEncryptionEnabled
                      ? Colors.green.withOpacity(0.1)
                      : Colors.red.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(
                      sec.localEncryptionEnabled
                          ? Icons.shield
                          : Icons.shield_outlined,
                      color: sec.localEncryptionEnabled
                          ? Colors.green
                          : Colors.red,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      sec.localEncryptionEnabled
                          ? 'Datele sunt criptate local'
                          : 'Datele NU sunt criptate',
                      style: TextStyle(
                        fontSize: 12,
                        color: sec.localEncryptionEnabled
                            ? Colors.green
                            : Colors.red,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // ── Protecție acces ──
          _SectionCard(
            title: 'Protecție acces metrici',
            icon: Icons.security_rounded,
            children: [
              SwitchListTile(
                title: const Text('Protecție acces metrici'),
                subtitle: const Text(
                  'Necesită autentificare pentru vizualizare date',
                ),
                value: sec.metricsAccessProtection,
                onChanged: svc.setAccessProtection,
                contentPadding: EdgeInsets.zero,
              ),
              SwitchListTile(
                title: const Text('Audit acces date'),
                subtitle: const Text(
                  'Jurnalizare automată a accesărilor de date',
                ),
                value: sec.auditEnabled,
                onChanged: svc.setAuditEnabled,
                contentPadding: EdgeInsets.zero,
              ),
              if (sec.auditEnabled) ...[
                const Divider(),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.history, size: 20),
                  title: const Text('Jurnal audit'),
                  subtitle: Text('${svc.auditLog.length} intrări înregistrate'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _showAuditLog(context, svc),
                ),
              ],
            ],
          ),
          const SizedBox(height: 16),

          // ── GDPR ──
          _SectionCard(
            title: 'GDPR – Date medicale',
            icon: Icons.privacy_tip_rounded,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: sec.gdprConsentGiven
                      ? Colors.green.withOpacity(0.1)
                      : Colors.orange.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: sec.gdprConsentGiven
                        ? Colors.green.withOpacity(0.3)
                        : Colors.orange.withOpacity(0.3),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          sec.gdprConsentGiven
                              ? Icons.check_circle
                              : Icons.warning_amber,
                          color: sec.gdprConsentGiven
                              ? Colors.green
                              : Colors.orange,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          sec.gdprConsentGiven
                              ? 'Consimțământ GDPR acordat'
                              : 'Consimțământ GDPR necesar',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: sec.gdprConsentGiven
                                ? Colors.green
                                : Colors.orange,
                          ),
                        ),
                      ],
                    ),
                    if (sec.gdprConsentDate != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4, left: 26),
                        child: Text(
                          'Acordat: ${_formatDate(sec.gdprConsentDate!)}',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: sec.gdprConsentGiven
                        ? OutlinedButton(
                            onPressed: () => _confirmRevoke(context, svc),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.red,
                            ),
                            child: const Text('Retrage consimțământ'),
                          )
                        : FilledButton(
                            onPressed: () => svc.giveGdprConsent(),
                            child: const Text('Acordă consimțământ'),
                          ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              const Text(
                'Drepturi GDPR',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
              ),
              const SizedBox(height: 8),
              _GdprAction(
                icon: Icons.download_rounded,
                title: 'Export date (Art. 20)',
                subtitle: sec.lastDataExportRequest != null
                    ? 'Ultima cerere: ${_formatDate(sec.lastDataExportRequest!)}'
                    : 'Portabilitatea datelor',
                onTap: () async {
                  await svc.requestDataExport();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Mock: Exportul datelor a fost generat'),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  }
                },
              ),
              _GdprAction(
                icon: Icons.delete_forever_rounded,
                title: 'Ștergere date (Art. 17)',
                subtitle: sec.lastDataDeletionRequest != null
                    ? 'Ultima cerere: ${_formatDate(sec.lastDataDeletionRequest!)}'
                    : 'Dreptul de a fi uitat',
                onTap: () => _confirmDeletion(context, svc),
                isDestructive: true,
              ),
            ],
          ),
          const SizedBox(height: 16),

          // ── Mock indicator ──
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
                    'Toate funcțiile de securitate sunt în modul mockup. '
                    'Criptarea reală va fi implementată la integrare.',
                    style: TextStyle(fontSize: 12),
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

  void _showAuditLog(BuildContext context, SecurityService svc) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.9,
        builder: (ctx, scroll) => Container(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Jurnal Audit',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: svc.auditLog.isEmpty
                    ? const Center(child: Text('Nicio intrare de audit'))
                    : ListView.builder(
                        controller: scroll,
                        itemCount: svc.auditLog.length,
                        itemBuilder: (ctx, i) {
                          final entry = svc.auditLog.reversed.toList()[i];
                          return ListTile(
                            dense: true,
                            leading: _auditIcon(entry.action),
                            title: Text(entry.action.toUpperCase()),
                            subtitle: Text(
                              '${entry.details ?? ""}\n'
                              '${_formatDate(entry.timestamp)}',
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _auditIcon(String action) {
    final (icon, color) = switch (action) {
      'view' => (Icons.visibility, Colors.blue),
      'export' => (Icons.download, Colors.green),
      'share' => (Icons.share, Colors.orange),
      'delete' => (Icons.delete, Colors.red),
      _ => (Icons.info, Colors.grey),
    };
    return Icon(icon, color: color, size: 20);
  }

  void _confirmRevoke(BuildContext context, SecurityService svc) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Retrage consimțământ GDPR?'),
        content: const Text(
          'Această acțiune va opri colectarea și procesarea datelor medicale.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Anulează'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () {
              svc.revokeGdprConsent();
              Navigator.pop(ctx);
            },
            child: const Text('Retrage'),
          ),
        ],
      ),
    );
  }

  void _confirmDeletion(BuildContext context, SecurityService svc) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Ștergere completă date?'),
        content: const Text(
          'Toate datele medicale vor fi șterse permanent.\n'
          'Această acțiune este ireversibilă.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Anulează'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () async {
              await svc.requestDataDeletion();
              if (ctx.mounted) Navigator.pop(ctx);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Mock: Cererea de ștergere a fost procesată'),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              }
            },
            child: const Text('Șterge tot'),
          ),
        ],
      ),
    );
  }

  static String _formatDate(DateTime dt) {
    final d = dt.toLocal();
    return '${d.day.toString().padLeft(2, '0')}.'
        '${d.month.toString().padLeft(2, '0')}.'
        '${d.year} '
        '${d.hour.toString().padLeft(2, '0')}:'
        '${d.minute.toString().padLeft(2, '0')}';
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

class _GdprAction extends StatelessWidget {
  const _GdprAction({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.isDestructive = false,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final bool isDestructive;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: isDestructive ? Colors.red : null, size: 22),
      title: Text(
        title,
        style: TextStyle(color: isDestructive ? Colors.red : null),
      ),
      subtitle: Text(subtitle, style: const TextStyle(fontSize: 12)),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}
