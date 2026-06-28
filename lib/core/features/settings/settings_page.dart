import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../i18n/locale.dart';
import '../../storage/user_repository.dart';
import '../../sdk/sdk_provider.dart';
import '../home/home_page.dart' show connectedProvider, selectedIdProvider;

// importuri (poți lăsa chiar dacă ai deja link-urile)
import 'terms_page.dart';
import 'about_app_page.dart';

// 👇 link EKG (ajustează calea dacă ai altă structură)
import '../vitals/ekg_page.dart';
// 👇 NOU: link Ciclul menstrual
import '../vitals/menstrual_cycle_page.dart';

// ── Pagini noi (cloud, securitate, sampling, QA) ──
import 'cloud_settings_page.dart';
import 'security_settings_page.dart';
import 'sampling_policy_page.dart';
import 'qa_panel_page.dart';
import 'log_viewer_page.dart';

/// ====== CHEI PERSISTENȚĂ ======
const _kAdapter = 'settings.adapter'; // 'ble' | 'sdk'
const _kAutoReconnect = 'settings.auto_reconnect'; // bool
const _kAutoStartHr = 'settings.auto_start_hr'; // bool
const _kPollInterval = 'settings.poll_interval_sec'; // int

const _kUserName = 'user.name';
const _kUserAge = 'user.age';
const _kUserWeight = 'user.weight';
const _kUserHeight = 'user.height';
const _kUserEmergencyPhone = 'user.emergency_phone';
const _kActivityType =
    'user.activity_type'; // 'sedentary' | 'moderate' | 'active'

enum ActivityType { sedentary, moderate, active }

extension ActivityTypeCode on ActivityType {
  String get code => switch (this) {
    ActivityType.sedentary => 'sedentary',
    ActivityType.moderate => 'moderate',
    ActivityType.active => 'active',
  };
  static ActivityType fromCode(String? c) => switch (c) {
    'moderate' => ActivityType.moderate,
    'active' => ActivityType.active,
    _ => ActivityType.sedentary,
  };
}

/// ====== STARE & PROVIDER ======
final settingsProvider =
    StateNotifierProvider<SettingsController, AsyncValue<SettingsState>>(
      (ref) => SettingsController(ref),
    );

class SettingsState {
  // tehnice
  final String adapter; // 'ble' | 'sdk'
  final bool autoReconnect;
  final bool autoStartHr;
  final int pollIntervalSec;

  // profil
  final String name;
  final int age;
  final double weightKg;
  final double heightCm;
  final String emergencyPhone;
  final ActivityType activityType;

  const SettingsState({
    required this.adapter,
    required this.autoReconnect,
    required this.autoStartHr,
    required this.pollIntervalSec,
    required this.name,
    required this.age,
    required this.weightKg,
    required this.heightCm,
    required this.emergencyPhone,
    required this.activityType,
  });

  SettingsState copyWith({
    String? adapter,
    bool? autoReconnect,
    bool? autoStartHr,
    int? pollIntervalSec,
    String? name,
    int? age,
    double? weightKg,
    double? heightCm,
    String? emergencyPhone,
    ActivityType? activityType,
  }) {
    return SettingsState(
      adapter: adapter ?? this.adapter,
      autoReconnect: autoReconnect ?? this.autoReconnect,
      autoStartHr: autoStartHr ?? this.autoStartHr,
      pollIntervalSec: pollIntervalSec ?? this.pollIntervalSec,
      name: name ?? this.name,
      age: age ?? this.age,
      weightKg: weightKg ?? this.weightKg,
      heightCm: heightCm ?? this.heightCm,
      emergencyPhone: emergencyPhone ?? this.emergencyPhone,
      activityType: activityType ?? this.activityType,
    );
  }

  static const empty = SettingsState(
    adapter: 'sdk',
    autoReconnect: true,
    autoStartHr: false,
    pollIntervalSec: 5,
    name: '',
    age: 0,
    weightKg: 0,
    heightCm: 0,
    emergencyPhone: '',
    activityType: ActivityType.sedentary,
  );
}

class SettingsController extends StateNotifier<AsyncValue<SettingsState>> {
  final Ref _ref;
  SettingsController(this._ref) : super(const AsyncLoading()) {
    _load();
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    final s = SettingsState(
      adapter: p.getString(_kAdapter) ?? 'sdk', // Citim preferința reală
      autoReconnect: p.getBool(_kAutoReconnect) ?? true,
      autoStartHr: p.getBool(_kAutoStartHr) ?? false,
      pollIntervalSec: p.getInt(_kPollInterval) ?? 5,
      name: p.getString(_kUserName) ?? '',
      age: p.getInt(_kUserAge) ?? 0,
      weightKg: (p.getDouble(_kUserWeight) ?? 0.0),
      heightCm: (p.getDouble(_kUserHeight) ?? 0.0),
      emergencyPhone: p.getString(_kUserEmergencyPhone) ?? '',
      activityType: ActivityTypeCode.fromCode(p.getString(_kActivityType)),
    );
    state = AsyncData(s);
  }

  /// Reîncarcă setările (apelat după schimbarea utilizatorului).
  Future<void> reload() async => _load();

  Future<void> _save(SettingsState s) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kAdapter, s.adapter);
    await p.setBool(_kAutoReconnect, s.autoReconnect);
    await p.setBool(_kAutoStartHr, s.autoStartHr);
    await p.setInt(_kPollInterval, s.pollIntervalSec);
    await p.setString(_kUserName, s.name);
    await p.setInt(_kUserAge, s.age);
    await p.setDouble(_kUserWeight, s.weightKg);
    await p.setDouble(_kUserHeight, s.heightCm);
    await p.setString(_kUserEmergencyPhone, s.emergencyPhone);
    await p.setString(_kActivityType, s.activityType.code);
  }

  Future<void> updateTechnical({
    String? adapter,
    bool? autoReconnect,
    bool? autoStartHr,
    int? pollIntervalSec,
  }) async {
    final current = state.value ?? SettingsState.empty;
    final next = current.copyWith(
      adapter: adapter,
      autoReconnect: autoReconnect,
      autoStartHr: autoStartHr,
      pollIntervalSec: pollIntervalSec,
    );
    state = AsyncData(next);
    await _save(next);

    // Sincronizăm adapter_kind pentru home_page (care citește din prefs)
    if (adapter != null) {
      final p = await SharedPreferences.getInstance();
      await p.setString('adapter_kind', adapter);
    }
  }

  Future<void> saveUserProfile({
    required String name,
    required int age,
    required double weightKg,
    required double heightCm,
    required String emergencyPhone,
    required ActivityType activityType,
  }) async {
    final current = state.value ?? SettingsState.empty;
    final next = current.copyWith(
      name: name,
      age: age,
      weightKg: weightKg,
      heightCm: heightCm,
      emergencyPhone: emergencyPhone,
      activityType: activityType,
    );
    state = AsyncData(next);
    await _save(next);

    // Persistă și în SQLite (UserProfile) dacă avem user activ
    final session = _ref.read(userSessionProvider);
    if (session != null && session.id != null) {
      final repo = _ref.read(userRepositoryProvider);
      final updated = session.copyWith(
        displayName: name,
        age: age > 0 ? age : null,
        weightKg: weightKg > 0 ? weightKg : null,
        heightCm: heightCm > 0 ? heightCm : null,
        emergencyPhone: emergencyPhone.isNotEmpty ? emergencyPhone : null,
      );
      await repo.updateUser(updated);
      // Actualizează și sesiunea cu datele noi
      _ref.read(userSessionProvider.notifier).refresh();
    }
  }
}

/// ====== UI ======
class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});
  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _age = TextEditingController();
  final _weight = TextEditingController();
  final _height = TextEditingController();
  final _phone = TextEditingController();
  ActivityType _activity = ActivityType.sedentary;

  @override
  void dispose() {
    _name.dispose();
    _age.dispose();
    _weight.dispose();
    _height.dispose();
    _phone.dispose();
    super.dispose();
  }

  void _fillForm(SettingsState s) {
    _name.text = s.name;
    _age.text = s.age > 0 ? s.age.toString() : '';
    _weight.text = s.weightKg > 0 ? s.weightKg.toStringAsFixed(1) : '';
    _height.text = s.heightCm > 0 ? s.heightCm.toStringAsFixed(1) : '';
    _phone.text = s.emergencyPhone;
    _activity = s.activityType;
    setState(() {});
  }

  String? _req(T t, String? v) =>
      (v == null || v.trim().isEmpty) ? t.requiredField : null;

  @override
  Widget build(BuildContext context) {
    final sAsync = ref.watch(settingsProvider);
    final lang = ref.watch(localeProvider);
    final t = T(lang);
    final theme = Theme.of(context);

    ref.listen<AsyncValue<SettingsState>>(settingsProvider, (prev, next) {
      next.whenOrNull(data: _fillForm);
    });

    return Scaffold(
      // să urce peste tastatură
      resizeToAvoidBottomInset: true,
      backgroundColor: theme.colorScheme.surface,
      appBar: AppBar(
        title: Text(
          t.settingsTitle,
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
        centerTitle: true,
        elevation: 0,
        backgroundColor: Colors.transparent,
      ),
      body: sAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, st) => Center(child: Text('Eroare: $e')),
        data: (s) {
          return _SafeScrollableBody(
            horizontal: 16,
            top: 16,
            bottomExtra: 12,
            child: Column(
              children: [
                /// ====== CARD: LIMBĂ ======
                _SettingsCard(
                  title: t.language,
                  icon: Icons.language_rounded,
                  child: const _LanguageDropdown(),
                ),

                const SizedBox(height: 16),

                /// ====== CARD: SETĂRI TEHNICE ======
                _SettingsCard(
                  title: t.deviceSettings,
                  icon: Icons.settings_bluetooth_rounded,
                  child: Column(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          vertical: 12,
                          horizontal: 16,
                        ),
                        decoration: BoxDecoration(
                          color: Theme.of(
                            context,
                          ).colorScheme.primaryContainer.withOpacity(0.3),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.memory_rounded,
                              size: 20,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            const SizedBox(width: 12),
                            Text(
                              'SDK (QC Wireless)',
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      _CompactSwitch(
                        title: t.autoReconnect,
                        value: s.autoReconnect,
                        onChanged: (v) => ref
                            .read(settingsProvider.notifier)
                            .updateTechnical(autoReconnect: v),
                      ),
                      _CompactSwitch(
                        title: t.startHROnOpen,
                        value: s.autoStartHr,
                        onChanged: (v) => ref
                            .read(settingsProvider.notifier)
                            .updateTechnical(autoStartHr: v),
                      ),
                      const SizedBox(height: 8),
                      _PollIntervalRow(
                        label: t.pollIntervalSec,
                        currentValue: s.pollIntervalSec,
                        onChanged: (interval) => ref
                            .read(settingsProvider.notifier)
                            .updateTechnical(pollIntervalSec: interval),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 16),

                /// ====== CARD: PROFIL UTILIZATOR ======
                _SettingsCard(
                  title: t.userProfile,
                  icon: Icons.person_rounded,
                  child: Form(
                    key: _formKey,
                    child: Column(
                      children: [
                        _CompactTextField(
                          controller: _name,
                          label: t.fullName,
                          icon: Icons.person_outline,
                          validator: (v) => _req(t, v),
                          textInputAction: TextInputAction.next,
                        ),
                        const SizedBox(height: 12),

                        Row(
                          children: [
                            Expanded(
                              child: _CompactTextField(
                                controller: _age,
                                label: t.ageYears,
                                icon: Icons.cake_outlined,
                                keyboardType: TextInputType.number,
                                inputFormatters: [
                                  FilteringTextInputFormatter.digitsOnly,
                                ],
                                validator: (v) {
                                  if (_req(t, v) != null) {
                                    return t.requiredField;
                                  }
                                  final x = int.tryParse(v!.trim());
                                  if (x == null || x < 1 || x > 120) {
                                    return '1–120';
                                  }
                                  return null;
                                },
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _CompactTextField(
                                controller: _weight,
                                label: t.weightKg,
                                icon: Icons.monitor_weight_outlined,
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                      decimal: true,
                                    ),
                                inputFormatters: [
                                  FilteringTextInputFormatter.allow(
                                    RegExp(r'[0-9.]'),
                                  ),
                                ],
                                validator: (v) {
                                  if (_req(t, v) != null) {
                                    return t.requiredField;
                                  }
                                  final x = double.tryParse(v!.trim());
                                  if (x == null || x < 30 || x > 300) {
                                    return '30–300 kg';
                                  }
                                  return null;
                                },
                              ),
                            ),
                          ],
                        ),

                        const SizedBox(height: 12),

                        _CompactTextField(
                          controller: _height,
                          label: t.heightCm,
                          icon: Icons.height_rounded,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          inputFormatters: [
                            FilteringTextInputFormatter.allow(
                              RegExp(r'[0-9.]'),
                            ),
                          ],
                          validator: (v) {
                            if (_req(t, v) != null) return t.requiredField;
                            final x = double.tryParse(v!.trim());
                            if (x == null || x < 100 || x > 250) {
                              return '100–250 cm';
                            }
                            return null;
                          },
                        ),

                        const SizedBox(height: 12),

                        _CompactTextField(
                          controller: _phone,
                          label: t.emergencyPhone,
                          icon: Icons.phone_outlined,
                          hint: '+40 7xx xxx xxx',
                          keyboardType: TextInputType.phone,
                          textInputAction: TextInputAction.done,
                          validator: (v) {
                            if (_req(t, v) != null) return t.requiredField;
                            final s2 = v!.trim();
                            final ok = RegExp(
                              r'^[+0-9][0-9\s-]{6,}$',
                            ).hasMatch(s2);
                            return ok ? null : t.invalidPhone;
                          },
                        ),

                        const SizedBox(height: 12),

                        _ActivityDropdown(
                          label: t.activityType,
                          value: _activity,
                          sedentaryLabel: t.sedentary,
                          moderateLabel: t.moderate,
                          activeLabel: t.active,
                          onChanged: (v) => setState(
                            () => _activity = v ?? ActivityType.sedentary,
                          ),
                        ),

                        const SizedBox(height: 20),

                        SizedBox(
                          width: double.infinity,
                          height: 48,
                          child: FilledButton.icon(
                            icon: const Icon(Icons.save_rounded),
                            label: Text(t.saveProfile),
                            style: FilledButton.styleFrom(
                              backgroundColor: theme.colorScheme.primary,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            onPressed: () async {
                              if (!_formKey.currentState!.validate()) return;
                              final name = _name.text.trim();
                              final age = int.parse(_age.text.trim());
                              final weight = double.parse(_weight.text.trim());
                              final height = double.parse(_height.text.trim());
                              final phone = _phone.text.trim();

                              await ref
                                  .read(settingsProvider.notifier)
                                  .saveUserProfile(
                                    name: name,
                                    age: age,
                                    weightKg: weight,
                                    heightCm: height,
                                    emergencyPhone: phone,
                                    activityType: _activity,
                                  );

                              if (!mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text(t.savedSnack),
                                  behavior: SnackBarBehavior.floating,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),

                        const SizedBox(height: 12),
                        Text(
                          t.savedLocally,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurface.withOpacity(0.6),
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 16),

                /// ====== CARD: MĂSURĂTORI (LINK EKG + CICLU MENSTRUAL) ======
                _SettingsCard(
                  title: t.measurements, // <- locale
                  icon: Icons.monitor_heart_rounded,
                  child: Column(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.monitor_heart_outlined),
                        title: Text(t.ekg), // <- locale
                        subtitle: Text(t.ekgSubtitle), // <- locale
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () {
                          // Wire EKG to real HR stream if device is connected
                          final isConn = ref.read(connectedProvider);
                          final deviceId = ref.read(selectedIdProvider);
                          Stream<double>? ekgStream;
                          if (isConn && deviceId != null) {
                            final sdk = ref.read(sdkProvider);
                            ekgStream = sdk
                                .heartRateStream(deviceId)
                                .map((s) => s.value.toDouble() / 40.0);
                          }
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => EkgPage(ekgStream: ekgStream),
                            ),
                          );
                        },
                      ),
                      const Divider(height: 1),

                      // 👇 NOU: Ciclul menstrual
                      ListTile(
                        leading: const Icon(Icons.water_drop_outlined),
                        title: Text(t.menstrualCycle), // <- locale
                        subtitle: Text(t.menstrualSubtitle), // <- locale
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const MenstrualCyclePage(),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 16),

                /// ====== CARD: CLOUD & BACKEND ======
                _SettingsCard(
                  title: 'Cloud & Backend',
                  icon: Icons.cloud_rounded,
                  child: Column(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.cloud_sync_outlined),
                        title: const Text('Sincronizare & Backup'),
                        subtitle: const Text('API, cloud sync, acces remote'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const CloudSettingsPage(),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 16),

                /// ====== CARD: SECURITATE & GDPR ======
                _SettingsCard(
                  title: 'Securitate & GDPR',
                  icon: Icons.security_rounded,
                  child: Column(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.lock_outlined),
                        title: const Text('Securitatea datelor'),
                        subtitle: const Text('Criptare, audit, GDPR'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const SecuritySettingsPage(),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 16),

                /// ====== CARD: POLITICI DE SAMPLING ======
                _SettingsCard(
                  title: 'Politici de Sampling',
                  icon: Icons.timer_rounded,
                  child: Column(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.tune_outlined),
                        title: const Text('Frecvențe & Intervale'),
                        subtitle: const Text('HR, SpO2, baterie, optimizare'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const SamplingPolicyPage(),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 16),

                /// ====== CARD: QA & TESTARE ======
                _SettingsCard(
                  title: 'QA & Testare',
                  icon: Icons.bug_report_rounded,
                  child: Column(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.checklist_outlined),
                        title: const Text('Plan de testare'),
                        subtitle: const Text(
                          'BLE, reconectare, background, iOS',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const QaPanelPage(),
                            ),
                          );
                        },
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.terminal_outlined),
                        title: const Text('Log Viewer'),
                        subtitle: const Text(
                          'Valori brute SDK, filtre, export',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const LogViewerPage(),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 16),

                /// ====== CARD: LEGAL & INFO ======
                _SettingsCard(
                  title: t.legalInfo, // <- locale
                  icon: Icons.info_outline,
                  child: Column(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.gavel_outlined),
                        title: Text(t.terms), // <- locale
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const TermsAndConditionsPage(),
                            ),
                          );
                        },
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(Icons.info_outline),
                        title: Text(t.aboutApp), // <- locale
                        subtitle: Text(t.nonMedicalApp), // <- locale
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => const AboutAppPage(),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// ====== BODY SAFE & RESPONSIVE (funcționează și pe MIUI) ======
class _SafeScrollableBody extends StatelessWidget {
  const _SafeScrollableBody({
    required this.child,
    this.horizontal = 16,
    this.top = 16,
    this.bottomExtra = 16,
  });

  final Widget child;
  final double horizontal;
  final double top;
  final double bottomExtra;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);

    // Tastatura (când e deschisă)
    final double keyboard = mq.viewInsets.bottom;

    // Dacă SafeArea nu adaugă padding jos (MIUI raportează 0),
    // folosim gesturile sistemului ca fallback.
    final bool safeIsZero = mq.padding.bottom == 0.0;
    final double gestureFallback = safeIsZero
        ? mq.systemGestureInsets.bottom
        : 0.0;

    // SafeArea(bottom:true) va adăuga deja mq.padding.bottom.
    // Noi adăugăm DOAR: fallback (dacă e nevoie) + tastatură + extra.
    final double bottomPad = gestureFallback + keyboard + bottomExtra;

    return SafeArea(
      top: true,
      bottom: true,
      child: AnimatedPadding(
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        padding: EdgeInsets.fromLTRB(horizontal, top, horizontal, bottomPad),
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          child: child,
        ),
      ),
    );
  }
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({
    required this.title,
    required this.icon,
    required this.child,
  });

  final String title;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.colorScheme.outline.withOpacity(0.2)),
        boxShadow: [
          BoxShadow(
            color: theme.colorScheme.shadow.withOpacity(0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
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
            child,
          ],
        ),
      ),
    );
  }
}

/// ====== LANGUAGE DROPDOWN (icon + dropdown cu limbile curente) ======
class _LanguageDropdown extends ConsumerWidget {
  const _LanguageDropdown();

  // Numele native ale limbilor (afișate în dropdown).
  static const Map<AppLang, String> _langNamesNative = {
    AppLang.en: 'English',
    AppLang.ro: 'Română',
    AppLang.fr: 'Français',
    AppLang.de: 'Deutsch',
    AppLang.it: 'Italiano',
    AppLang.es: 'Español',
    AppLang.pt: 'Português',
    AppLang.hu: 'Magyar',
    AppLang.pl: 'Polski',
    AppLang.tr: 'Türkçe',
    AppLang.ru: 'Русский',
    AppLang.uk: 'Українська',
    AppLang.bg: 'Български',
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final current = ref.watch(localeProvider);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outline.withOpacity(0.2)),
      ),
      child: Row(
        children: [
          const SizedBox(width: 4),
          Icon(
            Icons.language_rounded,
            size: 20,
            color: theme.colorScheme.onSurface.withOpacity(0.75),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<AppLang>(
                isExpanded: true,
                value: current,
                borderRadius: BorderRadius.circular(12),
                items: AppLang.values.map((lang) {
                  final label =
                      _langNamesNative[lang] ?? lang.code.toUpperCase();
                  return DropdownMenuItem<AppLang>(
                    value: lang,
                    child: Row(
                      children: [
                        _FlagCircle(code: lang.code),
                        const SizedBox(width: 10),
                        Text(label),
                      ],
                    ),
                  );
                }).toList(),
                onChanged: (value) {
                  if (value == null) return;
                  ref.read(localeProvider.notifier).set(value);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Mic avatar circular cu inițiale de cod limbă (poți înlocui ușor cu imagini de steag)
class _FlagCircle extends StatelessWidget {
  const _FlagCircle({required this.code});
  final String code;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final txt = code.toUpperCase();
    return Container(
      width: 26,
      height: 26,
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: theme.colorScheme.outline.withOpacity(0.12)),
      ),
      alignment: Alignment.center,
      child: Text(
        txt.length > 2 ? txt.substring(0, 2) : txt,
        style: theme.textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.w700,
          color: theme.colorScheme.onPrimaryContainer,
        ),
      ),
    );
  }
}

class _AdapterRow extends StatelessWidget {
  const _AdapterRow({
    required this.bleLabel,
    required this.sdkLabel,
    required this.currentAdapter,
    required this.onChanged,
  });

  final String bleLabel;
  final String sdkLabel;
  final String currentAdapter;
  final Function(String) onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.3),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Expanded(
            child: _AdapterOption(
              title: bleLabel,
              isSelected: currentAdapter == 'ble',
              onTap: () => onChanged('ble'),
            ),
          ),
          Container(
            width: 1,
            height: 32,
            color: theme.colorScheme.outline.withOpacity(0.2),
          ),
          Expanded(
            child: _AdapterOption(
              title: sdkLabel,
              isSelected: currentAdapter == 'sdk',
              onTap: () => onChanged('sdk'),
            ),
          ),
        ],
      ),
    );
  }
}

class _AdapterOption extends StatelessWidget {
  const _AdapterOption({
    required this.title,
    required this.isSelected,
    required this.onTap,
  });

  final String title;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Material(
      color: isSelected ? theme.colorScheme.primary : Colors.transparent,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          height: 40,
          alignment: Alignment.center,
          child: Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: isSelected
                  ? theme.colorScheme.onPrimary
                  : theme.colorScheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }
}

class _CompactSwitch extends StatelessWidget {
  const _CompactSwitch({
    required this.title,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final bool value;
  final Function(bool) onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Expanded(child: Text(title, style: theme.textTheme.bodyMedium)),
          Switch(
            value: value,
            onChanged: onChanged,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ],
      ),
    );
  }
}

class _PollIntervalRow extends StatelessWidget {
  const _PollIntervalRow({
    required this.label,
    required this.currentValue,
    required this.onChanged,
  });

  final String label;
  final int currentValue;
  final Function(int) onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
          SizedBox(
            width: 80,
            height: 36,
            child: TextFormField(
              initialValue: currentValue.toString(),
              decoration: InputDecoration(
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 8,
                ),
              ),
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              textAlign: TextAlign.center,
              onFieldSubmitted: (v) {
                final n = int.tryParse(v.trim());
                if (n == null || n < 1 || n > 60) return;
                onChanged(n);
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _CompactTextField extends StatelessWidget {
  const _CompactTextField({
    required this.controller,
    required this.label,
    required this.icon,
    this.hint,
    this.validator,
    this.keyboardType,
    this.inputFormatters,
    this.textInputAction,
  });

  final TextEditingController controller;
  final String label;
  final IconData icon;
  final String? hint;
  final String? Function(String?)? validator;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;
  final TextInputAction? textInputAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return TextFormField(
      controller: controller,
      validator: validator,
      keyboardType: keyboardType,
      inputFormatters: inputFormatters,
      textInputAction: textInputAction,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: Icon(icon, size: 20),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
            color: theme.colorScheme.outline.withOpacity(0.3),
          ),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
            color: theme.colorScheme.outline.withOpacity(0.3),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: theme.colorScheme.primary, width: 2),
        ),
        filled: true,
        fillColor: theme.colorScheme.surfaceContainerLowest,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 12,
        ),
      ),
    );
  }
}

class _ActivityDropdown extends StatelessWidget {
  const _ActivityDropdown({
    required this.label,
    required this.value,
    required this.sedentaryLabel,
    required this.moderateLabel,
    required this.activeLabel,
    required this.onChanged,
  });

  final String label;
  final ActivityType value;
  final String sedentaryLabel;
  final String moderateLabel;
  final String activeLabel;
  final Function(ActivityType?) onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: theme.colorScheme.outline.withOpacity(0.3)),
        borderRadius: BorderRadius.circular(12),
        color: theme.colorScheme.surfaceContainerLowest,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Row(
          children: [
            Icon(
              Icons.directions_run_outlined,
              size: 20,
              color: theme.colorScheme.onSurface.withOpacity(0.7),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: DropdownButtonHideUnderline(
                child: DropdownButton<ActivityType>(
                  value: value,
                  hint: Text(label),
                  isExpanded: true,
                  onChanged: onChanged,
                  items: [
                    DropdownMenuItem(
                      value: ActivityType.sedentary,
                      child: Text(sedentaryLabel),
                    ),
                    DropdownMenuItem(
                      value: ActivityType.moderate,
                      child: Text(moderateLabel),
                    ),
                    DropdownMenuItem(
                      value: ActivityType.active,
                      child: Text(activeLabel),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
