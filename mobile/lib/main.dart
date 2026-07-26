import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'screens/chat_screen.dart';
import 'screens/onboarding_screen.dart';
import 'services/api_service.dart';
import 'theme/app_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Color(0xFF020203),
  ));
  runApp(const EchoApp());
}

class EchoApp extends StatelessWidget {
  const EchoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Echo',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      home: const AppRouter(),
    );
  }
}

class AppRouter extends StatefulWidget {
  const AppRouter({super.key});

  @override
  State<AppRouter> createState() => _AppRouterState();
}

class _AppRouterState extends State<AppRouter> {
  bool _loading = true;
  bool _configured = false;

  @override
  void initState() {
    super.initState();
    _checkConfig();
  }

  Future<void> _checkConfig() async {
    final api = ApiService();
    final configured = await api.isConfigured();
    setState(() {
      _configured = configured;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    if (!_configured) {
      return OnboardingScreen(onComplete: () {
        setState(() => _configured = true);
      });
    }
    return const ChatScreen();
  }
}
