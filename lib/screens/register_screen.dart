import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});

  @override
  _RegisterScreenState createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _auth = FirebaseAuth.instance;

  bool _isLoading = false;
  bool _obscurePassword = true; // Controle do olho mágico

  final Color _corPrimaria = const Color(0xFF4E2C22);
  final Color _corDestaque = const Color(0xFFD45D3A);

  void _register() async {
    // 1. Captura e higienização dos dados
    String email = _emailController.text.trim().toLowerCase();
    String password = _passwordController.text.trim();
    String confirm = _confirmPasswordController.text.trim();

    if (email.isEmpty || password.isEmpty) { _notificar("Preencha todos os campos."); return; }
    if (password.length < 6) { _notificar("Mínimo 6 caracteres."); return; }
    if (password != confirm) { _notificar("As senhas não conferem."); return; }

    setState(() => _isLoading = true);

    try {
      // 3. Cria o login no Auth
      UserCredential userCredential = await _auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );

      // 4. Tentativa de gravar no Firestore
      try {
        await FirebaseFirestore.instance.collection('usuarios').doc(userCredential.user!.uid).set({
          'uid': userCredential.user!.uid,
          'email': email,
          'dataCadastro': FieldValue.serverTimestamp(),
          'isPro': false,
          'trialEndsAt': DateTime.now().add(const Duration(days: 7)),
          'saldo_total': 0.0,
          'total_despesas': 0.0,
          'paradas_concluidas': [],
          'historico_rotas': [],
        });
        
        // Se deu tudo certo, mostra o sucesso
        if (mounted) _mostrarDialogoSucesso(email);

      } catch (e) {
        // ERRO CRÍTICO: Login criado, mas perfil não. 
        // O ideal aqui é deletar o login para permitir que o usuário tente de novo.
        await userCredential.user?.delete(); 
        throw 'erro_firestore';
      }

    } on FirebaseAuthException catch (e) {
      if (e.code == 'weak-password') _notificar("Senha muito fraca.");
      else if (e.code == 'email-already-in-use') _notificar("Este e-mail já possui cadastro.");
      else _notificar("Erro: ${e.message}");
    } catch (e) {
      if (e == 'erro_firestore') {
        _notificar("Falha ao configurar perfil. Tente novamente.");
      } else {
        _notificar("Verifique sua conexão com a internet.");
      }
    } finally {
      // O finally é o "limpa trilhos": ele roda SEMPRE, 
      // economizando código e garantindo que o loading pare.
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _notificar(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Colors.redAccent),
    );
  }

  void _mostrarDialogoSucesso(String email) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text("Conta Criada!"),
        content: Text("Conta para $email criada com sucesso. Agora você tem 7 dias de acesso PRO!"),
        actions: [
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context); // Fecha o alerta
              Navigator.pop(context); // Volta para o Login
            },
            style: ElevatedButton.styleFrom(backgroundColor: _corDestaque),
            child: const Text("OK", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Widget _buildField(TextEditingController ctrl, String label, IconData icon, TextInputType type, {bool isPassword = false}) {
    return TextField(
      controller: ctrl,
      obscureText: isPassword ? _obscurePassword : false,
      keyboardType: type,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, color: _corDestaque),
        suffixIcon: isPassword 
          ? IconButton(
              icon: Icon(_obscurePassword ? Icons.visibility : Icons.visibility_off),
              onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
            )
          : null,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(15)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Criar Conta"),
        backgroundColor: _corPrimaria,
        foregroundColor: Colors.white,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(25),
        child: Column(
          children: [
            const Icon(Icons.person_add, size: 80, color: Color(0xFFD45D3A)),
            const SizedBox(height: 20),
            _buildField(_emailController, "E-mail", Icons.email, TextInputType.emailAddress),
            const SizedBox(height: 15),
            _buildField(_passwordController, "Senha (min. 6 dígitos)", Icons.lock, TextInputType.text, isPassword: true),
            const SizedBox(height: 15),
            _buildField(_confirmPasswordController, "Confirmar Senha", Icons.lock_outline, TextInputType.text, isPassword: true),
            const SizedBox(height: 30),
            _isLoading
                ? const CircularProgressIndicator()
                : SizedBox(
                    width: double.infinity,
                    height: 55,
                    child: ElevatedButton(
                      onPressed: _register,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _corDestaque,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                      ),
                      child: const Text("CADASTRAR", style: TextStyle(fontSize: 18, color: Colors.white, fontWeight: FontWeight.bold)),
                    ),
                  ),
          ],
        ),
      ),
    );
  }
}