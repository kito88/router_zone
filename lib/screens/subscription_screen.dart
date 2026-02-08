import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'home_screen.dart';

class SubscriptionScreen extends StatelessWidget {
  const SubscriptionScreen({super.key});

  // Cores da Marca GP Roteiriza
  final Color _corPrimaria = const Color(0xFF4E2C22); // Marrom
  final Color _corDestaque = const Color(0xFFD45D3A); // Laranja/Terracota

  // Função temporária para simular a compra
  void _simularAssinatura(BuildContext context) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      // Atualiza o status no Firestore
      await FirebaseFirestore.instance
          .collection('usuarios')
          .doc(user.uid)
          .update({'isPro': true});

      if (!context.mounted) return;
      
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Assinatura confirmada! O elo forte da sua logística."),
          backgroundColor: Colors.green,
        ),
      );

      // Reinicia para a Home com os recursos Pro liberados
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (context) => const HomeScreen()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          // Gradiente profissional usando as cores da GP Cargo
          gradient: LinearGradient(
            colors: [_corPrimaria, Colors.black],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              const SizedBox(height: 30),
              
              // ÍCONE E TÍTULO
              Container(
                padding: const EdgeInsets.all(15),
                decoration: BoxDecoration(
                  color: _corDestaque.withOpacity(0.2),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.verified_user, size: 70, color: _corDestaque),
              ),
              const SizedBox(height: 20),
              const Text(
                "GP ROTEIRIZA PRO",
                style: TextStyle(
                  fontSize: 26, 
                  fontWeight: FontWeight.bold, 
                  color: Colors.white,
                  letterSpacing: 1.5,
                ),
              ),
              const SizedBox(height: 10),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 40),
                child: Text(
                  "Seu período de 7 dias grátis terminou.\nAssine para manter sua logística em alta performance.",
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70, fontSize: 15, height: 1.4),
                ),
              ),
              
              const SizedBox(height: 40),
              
              // LISTA DE BENEFÍCIOS (FOCO EM LOGÍSTICA)
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 35),
                  children: [
                    _FeatureItem(
                      icon: Icons.auto_fix_high, 
                      title: "Inteligência de Rotas", 
                      subtitle: "Otimize 20+ paradas em segundos.",
                      accentColor: _corDestaque,
                    ),
                    _FeatureItem(
                      icon: Icons.cloud_upload, 
                      title: "Nuvem GP Cargo", 
                      subtitle: "Salve e recupere rotas em qualquer lugar.",
                      accentColor: _corDestaque,
                    ),
                    _FeatureItem(
                      icon: Icons.mic, 
                      title: "Mãos no Volante", 
                      subtitle: "Busca por voz e comandos avançados.",
                      accentColor: _corDestaque,
                    ),
                    _FeatureItem(
                      icon: Icons.block, // Alterado de ad_units_off para block
                      title: "Foco Total", 
                      subtitle: "Experiência limpa, sem anúncios.",
                      accentColor: _corDestaque,
                    ),
                  ],
                ),
              ),

              // CARD DE PREÇO E BOTÃO
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 25, vertical: 10),
                padding: const EdgeInsets.all(25),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(25),
                  border: Border.all(color: Colors.white10),
                ),
                child: Column(
                  children: [
                    const Text(
                      "PLANO MENSAL",
                      style: TextStyle(color: Colors.white70, fontSize: 13, letterSpacing: 1),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: const [
                        Padding(
                          padding: EdgeInsets.only(top: 8),
                          child: Text("R\$", style: TextStyle(color: Colors.white, fontSize: 18)),
                        ),
                        Text(" 19,90", style: TextStyle(color: Colors.white, fontSize: 42, fontWeight: FontWeight.bold)),
                        Padding(
                          padding: EdgeInsets.only(top: 20),
                          child: Text("/mês", style: TextStyle(color: Colors.white54, fontSize: 16)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 25),
                    SizedBox(
                      width: double.infinity,
                      height: 55,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _corDestaque,
                          foregroundColor: Colors.white,
                          elevation: 5,
                          shadowColor: _corDestaque.withOpacity(0.5),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
                        ),
                        onPressed: () => _simularAssinatura(context),
                        child: const Text(
                          "ATIVAR AGORA", 
                          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                    const SizedBox(height: 15),
                    const Text(
                      "Cancele a qualquer momento.",
                      style: TextStyle(color: Colors.white38, fontSize: 12),
                    ),
                  ],
                ),
              ),

              // BOTÃO VOLTAR / SAIR
              TextButton(
                onPressed: () => FirebaseAuth.instance.signOut().then((_) => Navigator.pop(context)),
                child: const Text(
                  "Acessar com outra conta", 
                  style: TextStyle(color: Colors.white54, decoration: TextDecoration.underline),
                ),
              ),
              const SizedBox(height: 10),
            ],
          ),
        ),
      ),
    );
  }
}

// Widget auxiliar para os itens de benefícios com mais detalhes
class _FeatureItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color accentColor;

  const _FeatureItem({
    required this.icon, 
    required this.title, 
    required this.subtitle,
    required this.accentColor,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: accentColor, size: 26),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title, 
                  style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                ),
                Text(
                  subtitle, 
                  style: const TextStyle(color: Colors.white60, fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}