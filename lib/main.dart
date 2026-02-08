import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'screens/home_screen.dart';
import 'screens/login_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(); // Inicia o motor do Firebase
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GP Roteiriza',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primaryColor: const Color(0xFF4E2C22),
        useMaterial3: true,
      ),
      // O segredo está aqui: o home é o seu StreamBuilder
      home: const AuthWrapper(), 
    );
  }
}

class AuthWrapper extends StatelessWidget {
  const AuthWrapper({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        // 1. Enquanto o Firebase verifica se há alguém logado...
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator(color: Color(0xFFD45D3A))),
          );
        }

        // 2. Se o usuário estiver logado, o snapshot terá dados (User)
        if (snapshot.hasData) {
          return const HomeScreen(); // Vai direto para o mapa em Guarulhos!
        }

        // 3. Se não houver ninguém logado, mostra a tela de login
        return const LoginScreen();
      },
    );
  }
}