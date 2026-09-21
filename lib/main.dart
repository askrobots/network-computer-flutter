import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'session_store.dart';
import 'connect_screen.dart';
import 'session_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = SessionStore();
  await store.init();
  runApp(ChangeNotifierProvider.value(value: store, child: const NetworkComputerApp()));
}

class NetworkComputerApp extends StatelessWidget {
  const NetworkComputerApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Network Computer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF4C8DFF), brightness: Brightness.dark),
        scaffoldBackgroundColor: const Color(0xFF0B0D10),
      ),
      home: Consumer<SessionStore>(
        builder: (_, store, __) => store.state == ConnState.connected
            ? const SessionScreen()
            : const ConnectScreen(),
      ),
    );
  }
}
