import 'dart:async';
import 'package:flutter/material.dart';
// Importe sua tela de login ou a próxima tela do app
// import 'package:seu_projeto/screens/login_screen.dart';
import 'package:router_zone/main.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({Key? key}) : super(key: key);

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  // Cores baseadas na sua logo
  final Color _backgroundColor = const Color(0xFF4E2C22); // Marrom escuro do fundo
  final Color _accentColor = const Color(0xFFD45D3A);     // Laranja/Terracota dos detalhes
  final Color _textColor = Colors.white;                  // Branco para texto e logo principal

  @override
  void initState() {
    super.initState();
    // Simula um tempo de carregamento de 3 segundos antes de ir para a próxima tela
    Timer(const Duration(seconds: 3), () {
      // Removido o 'const' de AuthWrapper e corrigido os parênteses
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(builder: (context) => AuthWrapper()),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _backgroundColor,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // --- LOGO ---
            // Certifique-se de que o caminho está correto no pubspec.yaml
            Image.asset(
              'assets/icon/icon.png',
              width: 180, // Ajuste o tamanho conforme necessário
              fit: BoxFit.contain,
            ),
            const SizedBox(height: 30), // Espaço entre logo e texto

            // --- NOME DO APP ---
            Text(
              'GP ROTEIRIZA',
              style: TextStyle(
                color: _textColor,
                fontSize: 28,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Sua rota otimizada.',
              style: TextStyle(
                color: _textColor.withOpacity(0.8),
                fontSize: 16,
                fontStyle: FontStyle.italic,
              ),
            ),

            const SizedBox(height: 60), // Espaço para o indicador de carregamento

            // --- INDICADOR DE CARREGAMENTO ---
            CircularProgressIndicator(
              valueColor: AlwaysStoppedAnimation<Color>(_accentColor),
            ),
          ],
        ),
      ),
    );
  }
}