import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n/locale.dart';
import '../../models/user_profile.dart';
import '../../storage/user_repository.dart';
import '../settings/settings_page.dart';

/// Pagina de selectare / login utilizator.
class LoginPage extends ConsumerStatefulWidget {
  const LoginPage({super.key});

  @override
  ConsumerState<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends ConsumerState<LoginPage> {
  List<UserProfile> _users = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadUsers();
  }

  Future<void> _loadUsers() async {
    final repo = ref.read(userRepositoryProvider);
    final users = await repo.getAllUsers();
    setState(() {
      _users = users;
      _loading = false;
    });
  }

  Future<void> _selectUser(UserProfile user) async {
    final session = ref.read(userSessionProvider.notifier);

    if (user.pinHash != null) {
      // Trebuie PIN
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
    } // Reîncarcă setările cu datele profilului curent
    if (!mounted) return;
    ref
        .read(settingsProvider.notifier)
        .reload(); // _AuthGate va detecta automat schimbarea și va afișa HomePage
  }

  Future<String?> _showPinDialog(String userName) async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('PIN pentru $userName'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          maxLength: 6,
          obscureText: true,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Introdu PIN-ul',
            counterText: '',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Anulează'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Future<void> _createNewUser() async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const CreateProfilePage()),
    );
    if (result == true) {
      // Reîncarcă lista utilizatorilor
      await _loadUsers();
      // Auto-login pe ultimul creat
      if (_users.isNotEmpty) {
        final last = _users.last;
        final session = ref.read(userSessionProvider.notifier);
        await session.switchUser(last.id!);
        // Reîncarcă setările cu datele noului profil
        ref.read(settingsProvider.notifier).reload();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = T(ref.watch(localeProvider));

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 40),
              Icon(
                Icons.watch_rounded,
                size: 64,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Text(
                'AGP Wear Hub',
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                t.tr('selectUser'),
                style: theme.textTheme.bodyLarge?.copyWith(
                  color: theme.colorScheme.onSurface.withOpacity(0.7),
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),

              if (_loading)
                const Center(child: CircularProgressIndicator())
              else ...[
                Expanded(
                  child: _users.isEmpty
                      ? Center(
                          child: Text(
                            t.tr('noUsers'),
                            style: theme.textTheme.bodyLarge,
                          ),
                        )
                      : ListView.separated(
                          itemCount: _users.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 8),
                          itemBuilder: (ctx, i) {
                            final user = _users[i];
                            return _UserCard(
                              user: user,
                              onTap: () => _selectUser(user),
                            );
                          },
                        ),
                ),
                const SizedBox(height: 16),
                OutlinedButton.icon(
                  onPressed: _createNewUser,
                  icon: const Icon(Icons.person_add_rounded),
                  label: Text(t.tr('addUser')),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                // Acces rapid fără cont
                TextButton(
                  onPressed: () async {
                    final session = ref.read(userSessionProvider.notifier);
                    final repo = ref.read(userRepositoryProvider);
                    await repo.ensureDefaultUser();
                    await session.refresh();
                    ref.read(settingsProvider.notifier).reload();
                    // _AuthGate va detecta automat schimbarea
                  },
                  child: Text(t.tr('continueWithoutAccount')),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _UserCard extends StatelessWidget {
  const _UserCard({required this.user, required this.onTap});
  final UserProfile user;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      elevation: 0,
      color: user.isActive
          ? theme.colorScheme.primaryContainer
          : theme.colorScheme.surfaceContainerHighest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: user.isActive
            ? BorderSide(color: theme.colorScheme.primary, width: 2)
            : BorderSide.none,
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: theme.colorScheme.primary,
                child: Text(
                  user.displayName.isNotEmpty
                      ? user.displayName[0].toUpperCase()
                      : '?',
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      user.displayName,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      '@${user.username}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurface.withOpacity(0.6),
                      ),
                    ),
                  ],
                ),
              ),
              if (user.pinHash != null)
                Icon(
                  Icons.lock_rounded,
                  size: 18,
                  color: theme.colorScheme.onSurface.withOpacity(0.5),
                ),
              if (user.isActive)
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text(
                      'ACTIV',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              const SizedBox(width: 4),
              Icon(
                Icons.chevron_right,
                color: theme.colorScheme.onSurface.withOpacity(0.3),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Pagina de creare profil nou.
class CreateProfilePage extends ConsumerStatefulWidget {
  const CreateProfilePage({super.key});

  @override
  ConsumerState<CreateProfilePage> createState() => _CreateProfilePageState();
}

class _CreateProfilePageState extends ConsumerState<CreateProfilePage> {
  final _formKey = GlobalKey<FormState>();
  final _usernameCtrl = TextEditingController();
  final _displayNameCtrl = TextEditingController();
  final _pinCtrl = TextEditingController();
  final _ageCtrl = TextEditingController();
  final _heightCtrl = TextEditingController();
  final _weightCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  String _gender = 'other';
  bool _usePin = false;
  bool _saving = false;

  @override
  void dispose() {
    _usernameCtrl.dispose();
    _displayNameCtrl.dispose();
    _pinCtrl.dispose();
    _ageCtrl.dispose();
    _heightCtrl.dispose();
    _weightCtrl.dispose();
    _phoneCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);

    try {
      final repo = ref.read(userRepositoryProvider);
      await repo.createUser(
        username: _usernameCtrl.text.trim(),
        displayName: _displayNameCtrl.text.trim(),
        pin: _usePin ? _pinCtrl.text.trim() : null,
        age: int.tryParse(_ageCtrl.text),
        gender: _gender,
        heightCm: double.tryParse(_heightCtrl.text),
        weightKg: double.tryParse(_weightCtrl.text),
        emergencyPhone: _phoneCtrl.text.trim().isNotEmpty
            ? _phoneCtrl.text.trim()
            : null,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Eroare: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = T(ref.watch(localeProvider));

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      appBar: AppBar(
        title: Text(t.tr('addUser')),
        centerTitle: true,
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Username
              TextFormField(
                controller: _usernameCtrl,
                decoration: InputDecoration(
                  labelText: t.tr('username'),
                  prefixIcon: const Icon(Icons.person_outline),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return 'Câmp obligatoriu';
                  if (v.trim().length < 3) return 'Minim 3 caractere';
                  if (!RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(v.trim())) {
                    return 'Doar litere, cifre și _';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),

              // Display name
              TextFormField(
                controller: _displayNameCtrl,
                decoration: InputDecoration(
                  labelText: t.tr('displayName'),
                  prefixIcon: const Icon(Icons.badge_outlined),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Câmp obligatoriu' : null,
              ),
              const SizedBox(height: 16),

              // PIN toggle + field
              SwitchListTile(
                title: Text(t.tr('protectWithPin')),
                subtitle: const Text('PIN numeric (4-6 cifre)'),
                value: _usePin,
                onChanged: (v) => setState(() => _usePin = v),
                contentPadding: EdgeInsets.zero,
              ),
              if (_usePin) ...[
                TextFormField(
                  controller: _pinCtrl,
                  keyboardType: TextInputType.number,
                  maxLength: 6,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: 'PIN',
                    prefixIcon: const Icon(Icons.lock_outline),
                    counterText: '',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  validator: _usePin
                      ? (v) {
                          if (v == null || v.length < 4) return 'Minim 4 cifre';
                          if (!RegExp(r'^\d+$').hasMatch(v)) {
                            return 'Doar cifre';
                          }
                          return null;
                        }
                      : null,
                ),
                const SizedBox(height: 16),
              ],

              // Divider Date Profil
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  t.tr('profileDetails'),
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),

              // Age
              TextFormField(
                controller: _ageCtrl,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: t.tr('age'),
                  prefixIcon: const Icon(Icons.cake_outlined),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Gender
              DropdownButtonFormField<String>(
                initialValue: _gender,
                decoration: InputDecoration(
                  labelText: t.tr('gender'),
                  prefixIcon: const Icon(Icons.wc_outlined),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                items: const [
                  DropdownMenuItem(value: 'male', child: Text('Masculin')),
                  DropdownMenuItem(value: 'female', child: Text('Feminin')),
                  DropdownMenuItem(value: 'other', child: Text('Altul')),
                ],
                onChanged: (v) => setState(() => _gender = v ?? 'other'),
              ),
              const SizedBox(height: 16),

              // Height + Weight
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _heightCtrl,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: '${t.tr("height")} (cm)',
                        prefixIcon: const Icon(Icons.height_rounded),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: _weightCtrl,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: '${t.tr("weight")} (kg)',
                        prefixIcon: const Icon(Icons.monitor_weight_outlined),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Emergency phone
              TextFormField(
                controller: _phoneCtrl,
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(
                  labelText: t.tr('emergencyPhone'),
                  prefixIcon: const Icon(Icons.emergency_rounded),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
              const SizedBox(height: 32),

              // Save button
              FilledButton(
                onPressed: _saving ? null : _save,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: _saving
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(t.tr('save')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
