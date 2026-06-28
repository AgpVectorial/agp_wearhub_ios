import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n/locale.dart';
import '../../models/user_profile.dart';
import '../../storage/user_repository.dart';
import '../settings/settings_page.dart';

/// Pagina de gestionare a profilurilor utilizator.
class UserProfilesPage extends ConsumerStatefulWidget {
  const UserProfilesPage({super.key});

  @override
  ConsumerState<UserProfilesPage> createState() => _UserProfilesPageState();
}

class _UserProfilesPageState extends ConsumerState<UserProfilesPage> {
  List<UserProfile> _users = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final repo = ref.read(userRepositoryProvider);
    final users = await repo.getAllUsers();
    setState(() {
      _users = users;
      _loading = false;
    });
  }

  Future<void> _switchTo(UserProfile user) async {
    final session = ref.read(userSessionProvider.notifier);

    if (user.pinHash != null) {
      final pin = await _showPinDialog(user.displayName);
      if (pin == null) return;
      final ok = await session.switchUser(user.id!, pin: pin);
      if (!ok && mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('PIN incorect')));
        return;
      }
    } else {
      await session.switchUser(user.id!);
    }
    // Reîncarcă setările cu datele noului profil
    ref.read(settingsProvider.notifier).reload();
    await _load();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Profilul activ: ${user.displayName}')),
      );
    }
  }

  Future<String?> _showPinDialog(String name) async {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('PIN pentru $name'),
        content: TextField(
          controller: ctrl,
          keyboardType: TextInputType.number,
          maxLength: 6,
          obscureText: true,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'PIN', counterText: ''),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Anulează'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteUser(UserProfile user) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirmă ștergerea'),
        content: Text(
          'Ștergi profilul "${user.displayName}"?\nDatele vitale vor fi păstrate.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Anulează'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Șterge'),
          ),
        ],
      ),
    );

    if (confirm != true) return;
    final repo = ref.read(userRepositoryProvider);
    await repo.deleteUser(user.id!);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = T(ref.watch(localeProvider));
    final activeUser = ref.watch(userSessionProvider);

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      appBar: AppBar(
        title: Text(t.tr('userProfiles')),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _users.length,
              itemBuilder: (ctx, i) {
                final user = _users[i];
                final isActive = user.id == activeUser?.id;

                return Card(
                  elevation: 0,
                  margin: const EdgeInsets.only(bottom: 8),
                  color: isActive
                      ? theme.colorScheme.primaryContainer
                      : theme.colorScheme.surfaceContainerHighest,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                    side: isActive
                        ? BorderSide(color: theme.colorScheme.primary, width: 2)
                        : BorderSide.none,
                  ),
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    leading: CircleAvatar(
                      backgroundColor: isActive
                          ? theme.colorScheme.primary
                          : theme.colorScheme.outline.withOpacity(0.3),
                      child: Text(
                        user.displayName.isNotEmpty
                            ? user.displayName[0].toUpperCase()
                            : '?',
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    title: Text(
                      user.displayName,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(
                      '@${user.username}${user.pinHash != null ? ' 🔒' : ''}',
                      style: theme.textTheme.bodySmall,
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (isActive)
                          Chip(
                            label: const Text('ACTIV'),
                            backgroundColor: theme.colorScheme.primary,
                            labelStyle: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                            ),
                            padding: EdgeInsets.zero,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                          )
                        else
                          TextButton(
                            onPressed: () => _switchTo(user),
                            child: const Text('Selectează'),
                          ),
                        if (user.username != 'default')
                          IconButton(
                            onPressed: () => _deleteUser(user),
                            icon: const Icon(Icons.delete_outline, size: 20),
                            color: Colors.red.withOpacity(0.7),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }
}
