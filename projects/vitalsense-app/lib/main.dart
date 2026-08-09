import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:google_fonts/google_fonts.dart';
import 'providers/vital_sense_provider.dart';
import 'screens/dashboard_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    ChangeNotifierProvider(
      create: (_) => VitalSenseProvider(),
      child: const VitalSenseApp(),
    ),
  );
}

class VitalSenseApp extends StatelessWidget {
  const VitalSenseApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VitalSense',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: const ColorScheme.light(
          primary: Color(0xFF21638D),
          primaryContainer: Color(0xFF90CAF9),
          onPrimaryContainer: Color(0xFF08557E),
          secondary: Color(0xFF006398),
          secondaryContainer: Color(0xFF6CBDFE),
          onSecondaryContainer: Color(0xFF004B75),
          tertiary: Color(0xFF006D36),
          tertiaryContainer: Color(0xFF4ADE80),
          surface: Color(0xFFF9F9FF),
          onSurface: Color(0xFF111C2D),
          onSurfaceVariant: Color(0xFF41474E),
          outline: Color(0xFF71787F),
          outlineVariant: Color(0xFFC1C7CF),
          error: Color(0xFFBA1A1A),
        ),
        textTheme: GoogleFonts.interTextTheme(),
        scaffoldBackgroundColor: const Color(0xFFF9F9FF),
        appBarTheme: AppBarTheme(
          backgroundColor: const Color(0xFFF9F9FF),
          foregroundColor: const Color(0xFF21638D),
          elevation: 0,
          titleTextStyle: GoogleFonts.inter(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: const Color(0xFF21638D),
          ),
        ),
      ),
      home: const DashboardScreen(),
    );
  }
}
