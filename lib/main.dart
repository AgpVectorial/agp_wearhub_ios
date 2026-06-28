import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';

import 'theme.dart';
import 'core/features/home/home_page.dart';
import 'core/features/auth/login_page.dart';
import 'core/storage/user_repository.dart';
import 'core/services/background_service.dart';
import 'core/services/log_service.dart';
import 'core/errors/app_error.dart';
import 'core/sdk/sdk_provider.dart' as sdk_prov;

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // Inițializare servicii globale
  LogService.instance.init();
  NotificationService.instance.initialize();

  runApp(const ProviderScope(child: AgpWearHubApp()));
}

class AgpWearHubApp extends StatelessWidget {
  const AgpWearHubApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AGP Wear Hub',
      debugShowCheckedModeBanner: false,
      theme: appDarkTheme(),
      home: const _AppLifecycleManager(child: _PermissionGate()),
    );
  }
}

/// Gestionează lifecycle-ul aplicației: deconectează brățara la închidere,
/// dar o păstrează conectată în background.
class _AppLifecycleManager extends ConsumerStatefulWidget {
  const _AppLifecycleManager({required this.child});
  final Widget child;

  @override
  ConsumerState<_AppLifecycleManager> createState() =>
      _AppLifecycleManagerState();
}

class _AppLifecycleManagerState extends ConsumerState<_AppLifecycleManager>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      // Aplicația se închide complet — deconectează brățara
      final sdk = ref.read(sdk_prov.sdkProvider);
      sdk.disconnect();
    }
    // paused / inactive / hidden = background — NU deconectăm
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Cere TOATE permisiunile necesare la pornire, apoi deschide HomePage.
class _PermissionGate extends StatefulWidget {
  const _PermissionGate();

  @override
  State<_PermissionGate> createState() => _PermissionGateState();
}

class _PermissionGateState extends State<_PermissionGate> {
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _requestAllPermissions();
  }

  Future<void> _requestAllPermissions() async {
    if (Platform.isAndroid) {
      final deviceInfo = await DeviceInfoPlugin().androidInfo;
      final sdkInt = deviceInfo.version.sdkInt ?? 30;

      final List<Permission> perms = [];

      if (sdkInt >= 31) {
        perms.addAll([Permission.bluetoothScan, Permission.bluetoothConnect]);
      } else {
        perms.add(Permission.bluetooth);
      }

      perms.addAll([
        Permission.notification,
        Permission.locationWhenInUse,
        Permission.phone,
      ]);

      await perms.request();
    } else if (Platform.isIOS) {
      await [Permission.bluetooth, Permission.notification].request();
    }

    if (mounted) setState(() => _ready = true);
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    return const _AuthGate();
  }
}

/// Gate de autentificare.
///
/// - Utilizator activ → HomePage
/// - Nimeni logat → LoginPage (creare cont, selectare, ștergere)
class _AuthGate extends ConsumerStatefulWidget {
  const _AuthGate();

  @override
  ConsumerState<_AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends ConsumerState<_AuthGate> {
  bool _initDone = false;

  @override
  void initState() {
    super.initState();
    _initSession();
  }

  Future<void> _initSession() async {
    // Așteptăm ca UserSession să se inițializeze
    final session = ref.read(userSessionProvider.notifier);
    // Polling simplu – așteptăm să se termine _init()
    while (!session.initialized) {
      await Future.delayed(const Duration(milliseconds: 50));
    }
    if (mounted) {
      // Delay modification to after the widget tree finishes building
      Future(() {
        if (mounted) {
          ref.read(sessionInitializedProvider.notifier).state = true;
          setState(() => _initDone = true);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(userSessionProvider);

    if (!_initDone) {
      return Scaffold(
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    // Utilizatorul e logat → HomePage
    if (user != null) {
      return const _ErrorBannerWrapper(child: HomePage());
    }

    // Nimeni logat → LoginPage
    return const LoginPage();
  }
}

/// Wrapper care afișează erori critice ca banner deasupra conținutului.
class _ErrorBannerWrapper extends ConsumerWidget {
  const _ErrorBannerWrapper({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Afișează snackbar la erori noi
    ref.listen<AsyncValue<AppError>>(errorStreamProvider, (prev, next) {
      next.whenData((error) {
        if (error.severity == AppErrorSeverity.critical ||
            error.severity == AppErrorSeverity.warning) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(error.message),
              backgroundColor: error.severity == AppErrorSeverity.critical
                  ? Colors.red
                  : Colors.orange,
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              duration: Duration(
                seconds: error.severity == AppErrorSeverity.critical ? 5 : 3,
              ),
            ),
          );
        }
      });
    });

    return child;
  }
}
