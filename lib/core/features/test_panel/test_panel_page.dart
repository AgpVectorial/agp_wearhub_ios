import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:audioplayers/audioplayers.dart';

import '../../storage/vitals_db.dart';
import '../../storage/user_repository.dart';
import '../device/device_details_page.dart';
import '../history/history_page.dart';

/// Panou de testare — simulează alerte, notificări, scenarii mock.
/// Se va elimina înainte de producție.
class TestPanelPage extends ConsumerStatefulWidget {
  const TestPanelPage({super.key});

  @override
  ConsumerState<TestPanelPage> createState() => _TestPanelPageState();
}

class _TestPanelPageState extends ConsumerState<TestPanelPage> {
  final _log = <_LogEntry>[];
  Timer? _stressTimer;
  bool _stressRunning = false;
  final _rnd = Random();
  final _alertPlayer = AudioPlayer();

  // simulare device mock
  static const _mockDeviceId = 'AA:BB:CC:DD:EE:01';
  static const _mockDeviceName = 'AGP Ring Pro (Test)';

  void _addLog(String msg, {Color color = Colors.white70}) {
    setState(() {
      _log.insert(0, _LogEntry(DateTime.now(), msg, color));
      if (_log.length > 100) _log.removeLast();
    });
  }

  // ─── Alerte vitale ─────────────────────────────────────────────

  void _alertHighHR() {
    final bpm = 160 + _rnd.nextInt(30);
    _addLog('⚠️ ALERTĂ: Puls ridicat $bpm BPM!', color: Colors.redAccent);
    _showAlertDialog(
      icon: Icons.favorite,
      color: Colors.red,
      title: 'Puls Ridicat',
      body: 'Pulsul curent: $bpm BPM\nPeste limita de 150 BPM.',
    );
  }

  void _alertLowHR() {
    final bpm = 35 + _rnd.nextInt(10);
    _addLog('⚠️ ALERTĂ: Puls scăzut $bpm BPM!', color: Colors.orangeAccent);
    _showAlertDialog(
      icon: Icons.favorite_border,
      color: Colors.orange,
      title: 'Puls Scăzut',
      body: 'Pulsul curent: $bpm BPM\nSub limita de 50 BPM.',
    );
  }

  void _alertLowSpo2() {
    final spo2 = 85 + _rnd.nextInt(5);
    _addLog('⚠️ ALERTĂ: SpO2 scăzut $spo2%!', color: Colors.blueAccent);
    _showAlertDialog(
      icon: Icons.bloodtype,
      color: Colors.blue,
      title: 'SpO2 Scăzut',
      body: 'Nivel oxigen: $spo2%\nSub limita de 90%.',
    );
  }

  void _alertHighTemp() {
    final temp = (38.0 + _rnd.nextDouble() * 2).toStringAsFixed(1);
    _addLog(
      '⚠️ ALERTĂ: Temperatură crescută $temp°C!',
      color: Colors.orangeAccent,
    );
    _showAlertDialog(
      icon: Icons.thermostat,
      color: Colors.deepOrange,
      title: 'Temperatură Crescută',
      body: 'Temperatură: $temp°C\nPeste limita de 38°C.',
    );
  }

  void _alertLowBattery() {
    final bat = 5 + _rnd.nextInt(10);
    _addLog('🔋 ALERTĂ: Baterie scăzută $bat%!', color: Colors.amberAccent);
    _showAlertDialog(
      icon: Icons.battery_alert,
      color: Colors.amber,
      title: 'Baterie Scăzută',
      body: 'Nivel baterie: $bat%\nÎncărcați dispozitivul.',
    );
  }

  // ─── Apel de urgență automat ───────────────────────────────────

  void _simEmergencyAutoCall() {
    _addLog('🚨 Simulare: valori critice detectate!', color: Colors.red);
    HapticFeedback.heavyImpact();
    final bpm = 180 + _rnd.nextInt(20);
    final spo2 = 78 + _rnd.nextInt(7);
    _showEmergencyDialog(bpm, spo2);
  }

  Future<void> _stopAlertSound() async {
    await _alertPlayer.stop();
  }

  void _showEmergencyDialog(int bpm, int spo2) {
    if (!mounted) return;
    int countdown = 10;
    Timer? countdownTimer;
    bool cancelled = false;

    // Pornește sunetul de alertă în loop
    _alertPlayer.setReleaseMode(ReleaseMode.loop);
    _alertPlayer.play(AssetSource('sounds/red_alert.mp3'));

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx2, setDialogState) {
            countdownTimer ??= Timer.periodic(const Duration(seconds: 1), (t) {
              if (cancelled) {
                t.cancel();
                return;
              }
              countdown--;
              if (countdown <= 0) {
                t.cancel();
                _stopAlertSound();
                if (Navigator.of(ctx2).canPop()) Navigator.pop(ctx2);
                _performEmergencyCall();
              } else {
                setDialogState(() {});
              }
            });

            return AlertDialog(
              backgroundColor: const Color(0xFF2C0A0A),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              title: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: Colors.red.withOpacity(0.3),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: const Icon(
                      Icons.emergency,
                      color: Colors.red,
                      size: 26,
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text(
                      'URGENȚĂ DETECTATĂ',
                      style: TextStyle(
                        color: Colors.red,
                        fontWeight: FontWeight.w800,
                        fontSize: 18,
                      ),
                    ),
                  ),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Valori critice detectate:\n• Puls: $bpm BPM (critic)\n• SpO2: $spo2% (periculos)',
                    style: const TextStyle(color: Colors.white70, height: 1.5),
                  ),
                  const SizedBox(height: 16),
                  Center(
                    child: Container(
                      width: 80,
                      height: 80,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.red.withOpacity(0.2),
                        border: Border.all(color: Colors.red, width: 3),
                      ),
                      child: Center(
                        child: Text(
                          '$countdown',
                          style: const TextStyle(
                            color: Colors.red,
                            fontSize: 36,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Center(
                    child: Text(
                      'Se va apela nr. de urgență automat...',
                      style: TextStyle(
                        color: Colors.red,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    cancelled = true;
                    countdownTimer?.cancel();
                    _stopAlertSound();
                    Navigator.pop(ctx2);
                    _addLog(
                      '❌ Apel de urgență anulat de utilizator',
                      color: Colors.orange,
                    );
                    _showSnack('Apel anulat', Colors.orange);
                  },
                  child: const Text(
                    'ANULEAZĂ',
                    style: TextStyle(
                      color: Colors.white54,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                FilledButton(
                  onPressed: () {
                    cancelled = true;
                    countdownTimer?.cancel();
                    _stopAlertSound();
                    Navigator.pop(ctx2);
                    _performEmergencyCall();
                  },
                  style: FilledButton.styleFrom(backgroundColor: Colors.red),
                  child: const Text(
                    'SUNĂ ACUM',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  static const _callChannel = MethodChannel('com.agptech.agp_wear_hub/call');

  Future<void> _performEmergencyCall() async {
    final prefs = await SharedPreferences.getInstance();
    String number = prefs.getString('user.emergency_phone') ?? '112';
    if (number.trim().isEmpty) number = '112';
    _addLog('📞 Apel de urgență → $number', color: Colors.red);
    HapticFeedback.heavyImpact();

    // Solicită permisiunea CALL_PHONE la runtime
    final status = await Permission.phone.request();
    if (!status.isGranted) {
      _addLog('❌ Permisiune CALL_PHONE refuzată', color: Colors.red);
      if (mounted) _showSnack('Acordă permisiunea de apel!', Colors.red);
      return;
    }

    try {
      await _callChannel.invokeMethod('directCall', {'number': number.trim()});
      _addLog('✅ Apel inițiat cu succes', color: Colors.green);
    } catch (e) {
      _addLog('❌ Eroare apel: $e', color: Colors.red);
      if (mounted) _showSnack('Nu s-a putut apela $number', Colors.red);
    }
  }

  // ─── Simulare conexiune ────────────────────────────────────────

  void _simConnectionLost() {
    _addLog('🔌 Conexiune pierdută cu device-ul!', color: Colors.red);
    _showSnack('Conexiune pierdută!', Colors.red);
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) {
        _addLog('🔄 Se reconectează... (retry 1/10)', color: Colors.orange);
        _showSnack('Reconectare... retry 1/10', Colors.orange);
      }
    });
    Future.delayed(const Duration(seconds: 6), () {
      if (mounted) {
        _addLog('✅ Reconectat cu succes!', color: Colors.green);
        _showSnack('Reconectat cu succes!', Colors.green);
      }
    });
  }

  void _simDeviceOffline() {
    _addLog('📡 Device offline — nu răspunde!', color: Colors.red);
    _showAlertDialog(
      icon: Icons.signal_wifi_off,
      color: Colors.red,
      title: 'Device Offline',
      body:
          'Device-ul nu răspunde.\nVerificați dacă este pornit și în raza BLE.',
    );
  }

  // ─── Notificări in-app ─────────────────────────────────────────

  void _notifInAppBanner() {
    _addLog('🔔 Banner notificare in-app', color: Colors.cyan);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showMaterialBanner(
      MaterialBanner(
        padding: const EdgeInsets.all(16),
        leading: const Icon(Icons.notifications_active, color: Colors.cyan),
        backgroundColor: Colors.cyan.withOpacity(0.15),
        content: const Text(
          'Notificare: Monitorizarea este activă. Pulsul este stabil.',
          style: TextStyle(color: Colors.white),
        ),
        actions: [
          TextButton(
            onPressed: () =>
                ScaffoldMessenger.of(context).hideCurrentMaterialBanner(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  void _notifSnackSuccess() {
    _addLog('✅ Snack success', color: Colors.green);
    _showSnack('Profilul a fost salvat cu succes!', Colors.green);
  }

  void _notifSnackError() {
    _addLog('❌ Snack eroare', color: Colors.red);
    _showSnack('Eroare la salvarea datelor!', Colors.red);
  }

  void _notifSnackWarning() {
    _addLog('⚠️ Snack avertizare', color: Colors.amber);
    _showSnack('Senzorul nu este calibrat!', Colors.amber);
  }

  // ─── Simulare date DB ──────────────────────────────────────────

  Future<void> _generateHistoryData() async {
    final userId = ref.read(userSessionProvider.notifier).userId;
    _addLog(
      '📊 Se generează date istorice (user: $userId)...',
      color: Colors.purple,
    );
    final db = VitalsDatabase();
    final now = DateTime.now();
    final records = <VitalRecord>[];

    for (var i = 0; i < 200; i++) {
      final ts = now.subtract(Duration(minutes: i * 3));
      records.addAll([
        VitalRecord(
          deviceId: _mockDeviceId,
          type: VitalType.hr,
          value: (65 + _rnd.nextInt(30)).toDouble(),
          ts: ts,
          userId: userId,
        ),
        VitalRecord(
          deviceId: _mockDeviceId,
          type: VitalType.spo2,
          value: (93 + _rnd.nextInt(7)).toDouble(),
          ts: ts,
          userId: userId,
        ),
        VitalRecord(
          deviceId: _mockDeviceId,
          type: VitalType.temp,
          value: 36.2 + _rnd.nextDouble() * 1.5,
          ts: ts,
          userId: userId,
        ),
        VitalRecord(
          deviceId: _mockDeviceId,
          type: VitalType.steps,
          value: (1000 + i * 15).toDouble(),
          ts: ts,
          userId: userId,
        ),
        VitalRecord(
          deviceId: _mockDeviceId,
          type: VitalType.battery,
          value: (100 - i * 0.4).clamp(5, 100).toDouble(),
          ts: ts,
          userId: userId,
        ),
      ]);
    }

    await db.insertBatch(records);
    _addLog(
      '✅ ${records.length} sample-uri generate (200 per tip vital)',
      color: Colors.green,
    );
    _showSnack('${records.length} sample-uri generate!', Colors.green);
  }

  Future<void> _clearHistoryData() async {
    _addLog('🗑️ Se șterg datele istorice...', color: Colors.orange);
    final db = VitalsDatabase();
    await db.pruneOlderThan(0);
    _addLog('✅ Date șterse', color: Colors.green);
    _showSnack('Istoric șters!', Colors.orange);
  }

  // ─── Navigare rapidă ──────────────────────────────────────────

  void _openDeviceDetails() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const DeviceDetailsPage(
          deviceId: _mockDeviceId,
          initialDisplayName: _mockDeviceName,
        ),
      ),
    );
    _addLog('📱 Deschis Device Details', color: Colors.teal);
  }

  void _openHistory() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => const HistoryPage(
          deviceId: _mockDeviceId,
          deviceName: _mockDeviceName,
        ),
      ),
    );
    _addLog('📈 Deschis History', color: Colors.teal);
  }

  // ─── Stress test (multi-alert rapid) ───────────────────────────

  void _toggleStressTest() {
    if (_stressRunning) {
      _stressTimer?.cancel();
      _stressTimer = null;
      setState(() => _stressRunning = false);
      _addLog('⏹️ Stress test oprit', color: Colors.grey);
    } else {
      setState(() => _stressRunning = true);
      _addLog(
        '⏺️ Stress test pornit — alertă la fiecare 2s',
        color: Colors.red,
      );
      _stressTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        final alerts = [
          _alertHighHR,
          _alertLowHR,
          _alertLowSpo2,
          _alertHighTemp,
          _alertLowBattery,
        ];
        alerts[_rnd.nextInt(alerts.length)]();
        HapticFeedback.mediumImpact();
      });
    }
  }

  // ─── Vibrație / Haptic ─────────────────────────────────────────

  void _hapticLight() {
    HapticFeedback.lightImpact();
    _addLog('📳 Haptic: light', color: Colors.grey);
  }

  void _hapticMedium() {
    HapticFeedback.mediumImpact();
    _addLog('📳 Haptic: medium', color: Colors.grey);
  }

  void _hapticHeavy() {
    HapticFeedback.heavyImpact();
    _addLog('📳 Haptic: heavy', color: Colors.grey);
  }

  // ─── Helpers ───────────────────────────────────────────────────

  void _showSnack(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 12),
            Flexible(child: Text(msg)),
          ],
        ),
        backgroundColor: color.withOpacity(0.2),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _showAlertDialog({
    required IconData icon,
    required Color color,
    required String title,
    required String body,
  }) {
    if (!mounted) return;
    HapticFeedback.heavyImpact();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E2C),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: color.withOpacity(0.2),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: color, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                style: TextStyle(color: color, fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
        content: Text(
          body,
          style: const TextStyle(color: Colors.white70, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              'OK',
              style: TextStyle(color: color, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _stressTimer?.cancel();
    _alertPlayer.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      backgroundColor: theme.colorScheme.surface,
      appBar: AppBar(
        title: const Text(
          '🧪 Test Panel',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        centerTitle: true,
        elevation: 0,
        backgroundColor: Colors.transparent,
        actions: [
          IconButton(
            tooltip: 'Șterge log',
            onPressed: () => setState(() => _log.clear()),
            icon: const Icon(Icons.delete_sweep, size: 22),
          ),
        ],
      ),
      body: Column(
        children: [
          // ── Butoane simulare ──
          Expanded(
            flex: 3,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              children: [
                _SectionHeader('Alerte Vitale'),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _TestBtn(
                      icon: Icons.favorite,
                      label: 'Puls Ridicat',
                      color: Colors.red,
                      onTap: _alertHighHR,
                    ),
                    _TestBtn(
                      icon: Icons.favorite_border,
                      label: 'Puls Scăzut',
                      color: Colors.orange,
                      onTap: _alertLowHR,
                    ),
                    _TestBtn(
                      icon: Icons.bloodtype,
                      label: 'SpO2 Scăzut',
                      color: Colors.blue,
                      onTap: _alertLowSpo2,
                    ),
                    _TestBtn(
                      icon: Icons.thermostat,
                      label: 'Temp Crescută',
                      color: Colors.deepOrange,
                      onTap: _alertHighTemp,
                    ),
                    _TestBtn(
                      icon: Icons.battery_alert,
                      label: 'Baterie Scăz.',
                      color: Colors.amber,
                      onTap: _alertLowBattery,
                    ),
                  ],
                ),

                _SectionHeader('Urgență & Conexiune'),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _TestBtn(
                      icon: Icons.emergency,
                      label: 'Auto-Call Urgență',
                      color: Colors.red.shade400,
                      onTap: _simEmergencyAutoCall,
                    ),
                    _TestBtn(
                      icon: Icons.link_off,
                      label: 'Pierdere Conex.',
                      color: Colors.red,
                      onTap: _simConnectionLost,
                    ),
                    _TestBtn(
                      icon: Icons.signal_wifi_off,
                      label: 'Device Offline',
                      color: Colors.red.shade300,
                      onTap: _simDeviceOffline,
                    ),
                  ],
                ),

                _SectionHeader('Notificări In-App'),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _TestBtn(
                      icon: Icons.campaign,
                      label: 'Banner',
                      color: Colors.cyan,
                      onTap: _notifInAppBanner,
                    ),
                    _TestBtn(
                      icon: Icons.check_circle,
                      label: 'Snack OK',
                      color: Colors.green,
                      onTap: _notifSnackSuccess,
                    ),
                    _TestBtn(
                      icon: Icons.error,
                      label: 'Snack Eroare',
                      color: Colors.red,
                      onTap: _notifSnackError,
                    ),
                    _TestBtn(
                      icon: Icons.warning,
                      label: 'Snack Warning',
                      color: Colors.amber,
                      onTap: _notifSnackWarning,
                    ),
                  ],
                ),

                _SectionHeader('Date & Navigare'),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _TestBtn(
                      icon: Icons.storage,
                      label: 'Generează Istoric',
                      color: Colors.purple,
                      onTap: _generateHistoryData,
                    ),
                    _TestBtn(
                      icon: Icons.delete_forever,
                      label: 'Șterge Istoric',
                      color: Colors.grey,
                      onTap: _clearHistoryData,
                    ),
                    _TestBtn(
                      icon: Icons.monitor_heart,
                      label: 'Device Details',
                      color: Colors.teal,
                      onTap: _openDeviceDetails,
                    ),
                    _TestBtn(
                      icon: Icons.timeline,
                      label: 'History Page',
                      color: Colors.indigo,
                      onTap: _openHistory,
                    ),
                  ],
                ),

                _SectionHeader('Haptic & Stress'),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _TestBtn(
                      icon: Icons.vibration,
                      label: 'Light',
                      color: Colors.grey,
                      onTap: _hapticLight,
                    ),
                    _TestBtn(
                      icon: Icons.vibration,
                      label: 'Medium',
                      color: Colors.grey.shade300,
                      onTap: _hapticMedium,
                    ),
                    _TestBtn(
                      icon: Icons.vibration,
                      label: 'Heavy',
                      color: Colors.grey.shade100,
                      onTap: _hapticHeavy,
                    ),
                    _TestBtn(
                      icon: _stressRunning ? Icons.stop_circle : Icons.speed,
                      label: _stressRunning ? 'Stop Stress' : 'Stress Test',
                      color: _stressRunning ? Colors.red : Colors.deepPurple,
                      onTap: _toggleStressTest,
                    ),
                  ],
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),

          // ── Log consolă ──
          Container(
            height: 1,
            color: theme.colorScheme.outline.withOpacity(0.2),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: Row(
              children: [
                Icon(
                  Icons.terminal,
                  size: 16,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  'Log (${_log.length})',
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 2,
            child: Container(
              margin: const EdgeInsets.fromLTRB(16, 4, 16, 16),
              decoration: BoxDecoration(
                color: const Color(0xFF0D0D14),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: theme.colorScheme.outline.withOpacity(0.15),
                ),
              ),
              child: _log.isEmpty
                  ? const Center(
                      child: Text(
                        'Apasă un buton pentru a simula...',
                        style: TextStyle(color: Colors.white24, fontSize: 13),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(8),
                      itemCount: _log.length,
                      itemBuilder: (_, i) {
                        final e = _log[i];
                        final ts =
                            '${e.ts.hour.toString().padLeft(2, '0')}:${e.ts.minute.toString().padLeft(2, '0')}:${e.ts.second.toString().padLeft(2, '0')}';
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 1),
                          child: Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  text: '$ts  ',
                                  style: const TextStyle(
                                    color: Colors.white24,
                                    fontSize: 11,
                                    fontFamily: 'monospace',
                                  ),
                                ),
                                TextSpan(
                                  text: e.msg,
                                  style: TextStyle(
                                    color: e.color,
                                    fontSize: 12,
                                    fontFamily: 'monospace',
                                  ),
                                ),
                              ],
                            ),
                          ),
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

class _LogEntry {
  final DateTime ts;
  final String msg;
  final Color color;
  const _LogEntry(this.ts, this.msg, this.color);
}

class _SectionHeader extends StatelessWidget {
  final String text;
  const _SectionHeader(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 8),
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          fontWeight: FontWeight.w700,
          color: Theme.of(context).colorScheme.primary,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _TestBtn extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _TestBtn({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: color.withOpacity(0.12),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
