import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  _ForgotPasswordScreenState createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _emailController = TextEditingController();
  bool _isLoading = false;

  final Color _corPrimaria = const Color(0xFF4E2C22);
  final Color _corDestaque = const Color(0xFFD45D3A);

  void _resetPassword() async {
    if (_emailController.text.isEmpty) {
      _notificar("Informe seu e-mail.");
      return;
    }

    setState(() => _isLoading = true);
    try {
      await FirebaseAuth.instance.sendPasswordResetEmail(
        email: _emailController.text.trim(),
      );
      _notificar("Link de recuperação enviado! Verifique seu e-mail.", cor: Colors.green);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      _notificar("Erro: Verifique se o e-mail está correto.");
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _notificar(String msg, {Color cor = Colors.redAccent}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: cor));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(backgroundColor: _corPrimaria, elevation: 0, foregroundColor: Colors.white),
      body: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          gradient: LinearGradient(colors: [_corPrimaria, Colors.black], begin: Alignment.topCenter, end: Alignment.bottomCenter),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 30),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.lock_reset, size: 80, color: _corDestaque),
              const SizedBox(height: 20),
              const Text("RECUPERAR SENHA", style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white)),
              const SizedBox(height: 10),
              const Text("Enviaremos um link para o seu e-mail cadastrado.", textAlign: TextAlign.center, style: TextStyle(color: Colors.white70)),
              const SizedBox(height: 40),
              TextField(
                controller: _emailController,
                style: const TextStyle(color: Colors.white),
                decoration: InputDecoration(
                  labelText: "E-mail cadastrado",
                  labelStyle: const TextStyle(color: Colors.white70),
                  prefixIcon: Icon(Icons.email_outlined, color: _corDestaque),
                  filled: true,
                  fillColor: Colors.white.withOpacity(0.1),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(15)),
                ),
              ),
              const SizedBox(height: 30),
              _isLoading
                  ? CircularProgressIndicator(color: _corDestaque)
                  : SizedBox(
                      width: double.infinity,
                      height: 55,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: _corDestaque, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15))),
                        onPressed: _resetPassword,
                        child: const Text("ENVIAR LINK", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
                      ),
                    ),
            ],
          ),
        ),
      ),
    );
  }
}