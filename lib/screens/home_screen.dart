import 'dart:convert';
import 'dart:math' show cos, sqrt, asin, min, max;
import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:flutter_typeahead/flutter_typeahead.dart';
import 'package:http/http.dart' as http;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'dart:typed_data'; // Necessário para o Uint8List
import 'package:flutter/services.dart'; // Necessário para ByteData e rootBundle
import 'package:shared_preferences/shared_preferences.dart';
import 'package:maps_toolkit/maps_toolkit.dart' as mt; // 'mt' de maps toolkit
import 'package:google_maps_flutter/google_maps_flutter.dart'; // Mantém o original

// Importações do seu projeto
import '../models/delivery_point.dart';
import '../services/google_maps_service.dart';
import 'subscription_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  _HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // ---------------------------------------------------------------------------
  // CONTROLADORES E SERVIÇOS
  // ---------------------------------------------------------------------------
  final TextEditingController _valorRotaController = TextEditingController();
  final GoogleMapsService _mapsService = GoogleMapsService();
  final TextEditingController _searchController = TextEditingController();
  GoogleMapController? _mapController;

  // Variáveis de Voz
  late stt.SpeechToText _speech;
  bool _isListening = false;

  // Pontos de Rota
  DeliveryPoint? _pontoPartida;
  DeliveryPoint? _pontoDestino;
  List<DeliveryPoint> _paradasIntermediarias = [];

  // Mapas e Marcadores
  Set<Marker> _markers = {};
  Set<Polyline> _polylines = {};
  final Map<int, BitmapDescriptor> _customIcons = {};

  // Estado da Rota e Regras de Negócio
  String _statusPlano = "Verificando...";
  String? _rotaAtivaDocId;
  bool _usuarioEhPro = false;
  bool _estaOtimizando = false;
  int _indiceEntregaAtual = -1;
  double _kmTotal = 0.0;
  String _tipoSelecionado = "ENTREGA"; // ENTREGA ou COLETA
  double _valorDaRotaAtiva = 0.0; // Adicione esta linha
  String _tempoTotalEstimado = "0h 0min";
  bool _listaExpandida = false; // Controla o tamanho do mapa

  // Configurações de tempo
  int _tempoPorParadaMin = 10;
  int _tempoPausaMin = 0;

  // Cores da Marca GP Roteiriza
  final Color _corPrimaria = const Color(0xFF4E2C22); // Marrom
  final Color _corDestaque = const Color(0xFFD45D3A); // Laranja

  Future<void> _atualizarOrdemNoFirebase() async {
    // Se não houver uma rota ativa carregada, não há nada para atualizar no servidor
    if (_rotaAtivaDocId == null) return;

    try {
      await FirebaseFirestore.instance
          .collection('rotas')
          .doc(_rotaAtivaDocId)
          .update({
        'paradas': _paradasIntermediarias.map((p) => {
          'id': p.id,
          'address': p.address,
          'lat': p.location.latitude,
          'lng': p.location.longitude,
          'tipo': p.tipo,
          'concluida': p.concluida,
        }).toList(),
      });
      // Opcional: Notificar o utilizador que a ordem foi guardada
      debugPrint("Ordem sincronizada com o Firebase");
    } catch (e) {
      debugPrint("Erro ao atualizar ordem: $e");
      _notificar("Erro ao guardar a nova ordem no servidor.");
    }
  }

  Future<void> _padronizarBancoDeDados() async {
    try {
      _notificar("Padronizando banco... Aguarde.", cor: Colors.blue);

      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;

      // Busca TODAS as rotas do usuário
      final query = await FirebaseFirestore.instance
          .collection('rotas')
          .where('userId', isEqualTo: user.uid)
          .get();

      int atualizados = 0;

      for (var doc in query.docs) {
        final dados = doc.data();

        // Criamos um mapa apenas com o que falta
        Map<String, dynamic> atualizacao = {};

        if (!dados.containsKey('valorExtras')) atualizacao['valorExtras'] = 0.0;
        if (!dados.containsKey('valorDespesasRota'))
          atualizacao['valorDespesasRota'] = 0.0;
        if (!dados.containsKey('concluida')) atualizacao['concluida'] = false;

        // Só envia pro Firebase se houver algo para mudar
        if (atualizacao.isNotEmpty) {
          await doc.reference.update(atualizacao);
          atualizados++;
        }
      }

      _notificar(
        "Sucesso! $atualizados rotas foram padronizadas.",
        cor: Colors.green,
      );
    } catch (e) {
      debugPrint("Erro na manutenção: $e");
      _notificar("Erro ao padronizar banco de dados.");
    }
  }

// Função Buscar Pelo CEP

Future<String?> _buscarEnderecoPorCep(String cep) async {
  // Remove traços ou espaços do CEP
  final cleanCep = cep.replaceAll(RegExp(r'[^0-9]'), '');
  print("🔍 Iniciando busca para o CEP: $cleanCep"); // DEBUG 1

  if (cleanCep.length != 8) {
    _notificar("CEP inválido. Digite os 8 números.");
    return null;
  }

  try {
    // Feedback visual: Muda o texto para "Buscando..."
    String textoOriginal = _searchController.text;
    final response = await http.get(Uri.parse('https://viacep.com.br/ws/$cleanCep/json/'));
      
    if (response.statusCode == 200) {
      final dados = json.decode(response.body);
      
      if (dados.containsKey('erro')) {
        _notificar("CEP não encontrado.");
        return null;
      }
      // Retorno único e organizado
      return "${dados['logradouro']}, ${dados['bairro']}, ${dados['localidade']} - ${dados['uf']}";
    }
  } catch (e) {
    _notificar("Erro ao conectar no ViaCEP.");
  }
  return null;
}

@override
void dispose() {
  // 1. Remove o ouvinte do CEP antes de fechar tudo
  _searchController.removeListener(_ouvinteDeCep);
  // 2. Fecha o controlador da barra de busca
  _searchController.dispose();
  // 3. Desliga o Wakelock (tela sempre acesa)
  WakelockPlus.disable();
  super.dispose();
}

  void _selecionarRotaPendente() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    showModalBottomSheet(
      context: context,
      isScrollControlled:
          true, // Permite que a lista cresça se houver muitas rotas
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => Container(
        padding: const EdgeInsets.all(16),
        height: MediaQuery.of(context).size.height * 0.6, // Ocupa 60% da tela
        child: Column(
          children: [
            Container(
              width: 40,
              height: 5,
              decoration: BoxDecoration(
                color: Colors.grey[300],
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              "QUAL ROTA VOCÊ QUER CONTINUAR?",
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 16,
                color: Color(0xFF4E2C22),
              ),
            ),
            const Divider(),
            Expanded(
              child: StreamBuilder<QuerySnapshot>(
                // IMPORTANTE: Removemos o .limit(1) para mostrar TODAS as pendentes
                stream: FirebaseFirestore.instance
                    .collection('rotas')
                    .where('userId', isEqualTo: user.uid)
                    .where('concluida', isEqualTo: false)
                    .orderBy('dataCriacao', descending: true)
                    .snapshots(),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting)
                    return const Center(child: CircularProgressIndicator());
                  if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                    return const Center(
                      child: Text("Nenhuma rota pendente encontrada."),
                    );
                  }

                  return ListView.builder(
                    itemCount: snapshot.data!.docs.length,
                    itemBuilder: (context, i) {
                      var doc = snapshot.data!.docs[i];
                      var dados = doc.data() as Map<String, dynamic>;

                      return ListTile(
                        leading: const Icon(
                          Icons.history,
                          color: Color(0xFFD45D3A),
                        ),
                        title: Text(
                          dados['nome'] ?? "Rota sem nome",
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        subtitle: Text(
                          "Criada em: ${dados['dataCriacao']?.toDate().day}/${dados['dataCriacao']?.toDate().month}",
                        ),
                        trailing: Text(
                          "R\$ ${(dados['valorRecebido'] ?? 0.0).toStringAsFixed(2)}",
                          style: const TextStyle(
                            color: Colors.green,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        onTap: () {
                          Navigator.pop(context); // Fecha a lista de escolha
                          _carregarDadosDaRota(
                            doc,
                          ); // Carrega os dados da rota escolhida
                        },
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  //Função exibirHistorico
  void _exibirHistoricoFinanceiro() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => Container(
        padding: const EdgeInsets.all(16),
        height: MediaQuery.of(context).size.height * 0.8,
        child: Column(
          children: [
            const Text(
              "HISTÓRICO FINANCEIRO",
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 18,
                color: Color(0xFF4E2C22),
              ),
            ),
            const Divider(),
            Expanded(
              child: StreamBuilder<QuerySnapshot>(
                stream: FirebaseFirestore.instance
                    .collection('rotas')
                    .where(
                      'userId',
                      isEqualTo: FirebaseAuth.instance.currentUser?.uid,
                    )
                    .orderBy('dataExecucao', descending: true)
                    .snapshots(),
                builder: (context, snapshot) {
                  if (!snapshot.hasData)
                    return const Center(child: CircularProgressIndicator());
                  return ListView.builder(
                    itemCount: snapshot.data!.docs.length,
                    itemBuilder: (context, i) {
                      var rotaDoc = snapshot.data!.docs[i];
                      var rota = rotaDoc.data() as Map<String, dynamic>;
                      double base = (rota.containsKey('valorRecebido'))
                          ? (rota['valorRecebido'] ?? 0.0).toDouble()
                          : 0.0;
                      double extras = (rota.containsKey('valorExtras'))
                          ? (rota['valorExtras'] ?? 0.0).toDouble()
                          : 0.0;
                      double despesas = (rota.containsKey('valorDespesasRota'))
                          ? (rota['valorDespesasRota'] ?? 0.0).toDouble()
                          : 0.0;
                      double liquido = (base + extras) - despesas;

                      return Card(
                        margin: const EdgeInsets.symmetric(vertical: 5),
                        child: ListTile(
                          leading: Icon(
                            Icons.picture_as_pdf,
                            color: Colors.red[300],
                          ),
                          onTap: () => _gerarRelatorioPDF(
                            rotaUnica: rotaDoc,
                          ), // Gera PDF desta rota
                          title: Text(
                            rota['nome'] ?? "Rota",
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          subtitle: Text(
                            "Líquido: R\$ ${liquido.toStringAsFixed(2)} | ${rota['kmTotal'] ?? 0}km",
                          ),
                          trailing: Text(
                            "R\$ ${liquido.toStringAsFixed(2)}",
                            style: TextStyle(
                              color: liquido >= 0 ? Colors.green : Colors.red,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Função auxiliar para carregar a rota selecionada
  void _carregarDadosDaRota(DocumentSnapshot doc) {
    // 1. Extraímos os dados brutos primeiro (fora do setState por performance)
    var dados = doc.data() as Map<String, dynamic>;

    // Função de segurança para garantir que vira Double
    double toD(dynamic v) {
      if (v is int) return v.toDouble();
      if (v is String) return double.tryParse(v) ?? 0.0;
      return (v ?? 0.0).toDouble();
    }

    // 2. Agora sim, atualizamos o estado da UI de uma vez só
    setState(() {
      _rotaAtivaDocId = doc.id;

      // Pegamos o faturamento da rota salva
      _valorDaRotaAtiva = toD(dados['valorRecebido']);

      var paradasRaw = List.from(dados['paradas'] ?? []);

      _paradasIntermediarias = paradasRaw
          .map(
            (p) => DeliveryPoint(
              id: p['id'].toString(),
              address: p['address'] ?? '',
              location: LatLng(toD(p['lat']), toD(p['lng'])),
              tipo: p['tipo'] ?? 'ENTREGA',
              concluida:
                  p['concluida'] ??
                  false, // Garante que carrega o que já foi feito
            ),
          )
          .toList();

      _indiceEntregaAtual = -1; // Reseta o GPS para o início da lista
    });

    // 3. Funções que disparam ações externas (fora do setState)
    _carregarRotaNoMapa();
    _notificar("Rota '${dados['nome']}' carregada!");
  }

  @override
  void initState() {
    WakelockPlus.disable();
    super.initState();
    _speech = stt.SpeechToText();
    _carregarRascunhoLocal();
    _verificarStatusAssinatura();
    _inicializarLocalizacaoComFoco();
    _searchController.addListener(_ouvinteDeCep);
  }

  void _dialogDespesas() {
    TextEditingController valorCtrl = TextEditingController();
    TextEditingController descCtrl = TextEditingController();

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text("Lançar Despesa"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: valorCtrl,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: const InputDecoration(
                labelText: "Valor (R\$)",
                prefixText: "R\$ ",
              ),
            ),
            TextField(
              controller: descCtrl,
              decoration: const InputDecoration(
                labelText: "Descrição (ex: Diesel, Pedágio)",
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("CANCELAR"),
          ),
          ElevatedButton(
            onPressed: () async {
              if (valorCtrl.text.trim().isEmpty) return;
              double valorFinal = double.parse(
                valorCtrl.text.replaceAll(',', '.'),
              );
              await FirebaseFirestore.instance.collection('despesas').add({
                'userId': FirebaseAuth.instance.currentUser?.uid,
                'rotaId': _rotaAtivaDocId,
                'valor': valorFinal,
                'descricao': descCtrl.text.trim(),
                'data': DateTime.now(),
              });
              Navigator.pop(context);
              _notificar(
                "Despesa de R\$ ${valorFinal.toStringAsFixed(2)} salva!",
                cor: Colors.orange,
              );
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
            child: const Text("SALVAR", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }
  //buscar o endereço ao digitar o cep
  void _ouvinteDeCep() async {
    String texto = _searchController.text.trim();
    // Limpa tudo que não é número
    String cepLimpo = texto.replaceAll(RegExp(r'[^0-9]'), '');

    // Só dispara se tiver exatamente 8 números e não for apenas o que já buscamos
    if (cepLimpo.length == 8) {
      // 1. Busca o endereço na API ViaCEP
      String? ruaEncontrada = await _buscarEnderecoPorCep(cepLimpo);

      if (ruaEncontrada != null) {
        // 2. Atualiza o campo de busca para mostrar ao usuário que o CEP "virou" endereço
        setState(() {
          _searchController.text = ruaEncontrada;
          // Coloca o cursor no final do texto
          _searchController.selection = TextSelection.fromPosition(
            TextPosition(offset: _searchController.text.length),
          );
        });

        // 3. Opcional: Já abrir o diálogo do número para facilitar
        _dialogConfirmarNumeroCep(cepLimpo, "parada");
      }
    }
  }

  void _dialogBuscaCep(String tipoPonto) {
    TextEditingController cepCtrl = TextEditingController();
    TextEditingController numCtrl = TextEditingController();
    

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Buscar por CEP"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: cepCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: "CEP (apenas números)", hintText: "03548000"),
            ),
            TextField(
              controller: numCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: "Número", hintText: "216"),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("CANCELAR")),
          ElevatedButton(
            onPressed: () async {
              String? enderecoBase = await _buscarEnderecoPorCep(cepCtrl.text);
              if (enderecoBase != null) {
                String enderecoCompleto = "$enderecoBase, ${numCtrl.text}";
                Navigator.pop(context);
                // Agora chama sua função de Geocoding original com o endereço completo
                _adicionarPontoDireto(enderecoCompleto, tipoPonto);
                String cepLimpo = enderecoCompleto.trim().replaceAll(RegExp(r'[^0-9]'), '');
              }
            },
            child: const Text("BUSCAR"),
          ),
        ],
      ),
    );
  }

  //REVERTER ROTA

  void _reverterRota() {
    if (_paradasIntermediarias.length < 2) {
      _notificar("Adicione pelo menos 2 paradas para inverter.");
      return;
    }
    setState(() {
      // Inverte a lista de paradas
      _paradasIntermediarias = _paradasIntermediarias.reversed.toList();
    });
    _carregarRotaNoMapa(); // Recalcula o traço no mapa
    _notificar("Ordem das paradas invertida!");
  }

  void _dialogAjustarFaturamento() {
    TextEditingController extraCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Adicional / Serviço Extra"),
        content: TextField(
          controller: extraCtrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            labelText: "Valor Extra (R\$)",
            prefixText: "R\$ ",
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("CANCELAR"),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
            onPressed: () async {
              double valorAdicional =
                  double.tryParse(extraCtrl.text.replaceAll(',', '.')) ?? 0.0;
              if (valorAdicional > 0 && _rotaAtivaDocId != null) {
                await FirebaseFirestore.instance
                    .collection('rotas')
                    .doc(_rotaAtivaDocId)
                    .update({
                      'valorExtras': FieldValue.increment(valorAdicional),
                    });
                Navigator.pop(context);
                _notificar("Ganhos atualizados!", cor: Colors.green);
              }
            },
            child: const Text(
              "ADICIONAR",
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDashboardFinanceiro() {
    final user = FirebaseAuth.instance.currentUser;
    final hoje = DateTime.now();
    final inicioDia = DateTime(hoje.year, hoje.month, hoje.day);

    return Positioned(
      top: 130,
      left: 15,
      right: 15,
      child: StreamBuilder<QuerySnapshot>(
        // 1. Monitora as Rotas de hoje
        stream: FirebaseFirestore.instance
            .collection('rotas')
            .where('userId', isEqualTo: user?.uid)
            .where(
              'dataExecucao',
              isGreaterThanOrEqualTo: Timestamp.fromDate(inicioDia),
            )
            .snapshots(),
        builder: (context, rotaSnap) {
          return StreamBuilder<QuerySnapshot>(
            // 2. Monitora todas as Despesas de hoje (Gerais e de Rotas)
            stream: FirebaseFirestore.instance
                .collection('despesas')
                .where('userId', isEqualTo: user?.uid)
                .where(
                  'data',
                  isGreaterThanOrEqualTo: Timestamp.fromDate(inicioDia),
                )
                .snapshots(),
            builder: (context, despesaSnap) {
              double ganhosTotais = 0;
              double gastosTotais = 0;

              // Função de segurança para evitar erros de tipo (int vs double)
              double toD(dynamic v) => (v is num) ? v.toDouble() : 0.0;

              // Lógica de Ganhos: Valor da Rota + Extras
              if (rotaSnap.hasData) {
                for (var d in rotaSnap.data!.docs) {
                  final dados = d.data() as Map<String, dynamic>;
                  ganhosTotais +=
                      toD(dados['valorRecebido']) + toD(dados['valorExtras']);
                }
              }

              // Lógica de Gastos: Tudo o que caiu na coleção "despesas"
              if (despesaSnap.hasData) {
                for (var d in despesaSnap.data!.docs) {
                  final dados = d.data() as Map<String, dynamic>;
                  gastosTotais += toD(dados['valor']);
                }
              }

              double saldoGeral = ganhosTotais - gastosTotais;

              return Container(
                padding: const EdgeInsets.all(15),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.95),
                  borderRadius: BorderRadius.circular(15),
                  boxShadow: const [
                    BoxShadow(
                      color: Colors.black26,
                      blurRadius: 10,
                      offset: Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _colunaFinanceira("GANHOS", ganhosTotais, Colors.green),
                    _colunaFinanceira("GASTOS", gastosTotais, Colors.red),
                    _colunaFinanceira(
                      "SALDO",
                      saldoGeral,
                      saldoGeral >= 0 ? Colors.blue : Colors.redAccent,
                      destaque: true,
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }

  Widget _colunaFinanceira(
    String titulo,
    double valor,
    Color cor, {
    bool destaque = false,
  }) {
    return Column(
      children: [
        Text(
          titulo,
          style: const TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.bold,
            color: Colors.grey,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          "R\$ ${valor.toStringAsFixed(2)}",
          style: TextStyle(
            fontSize: destaque ? 18 : 14,
            fontWeight: FontWeight.bold,
            color: cor,
          ),
        ),
      ],
    );
  }

  Widget _itemFinanceiro(String titulo, double valor, Color cor) {
    return Column(
      children: [
        Text(
          titulo,
          style: const TextStyle(
            fontSize: 9,
            fontWeight: FontWeight.bold,
            color: Colors.grey,
          ),
        ),
        Text(
          "R\$ ${valor.toStringAsFixed(2)}",
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: cor,
          ),
        ),
      ],
    );
  }


  // ---------------------------------------------------------------------------
  // LÓGICA DE FIREBASE E ASSINATURA
  // ---------------------------------------------------------------------------

  Future<void> _verificarStatusAssinatura() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;

      final userDoc = await FirebaseFirestore.instance
          .collection('usuarios')
          .doc(user.uid)
          .get();

      if (!mounted) return;

      if (userDoc.exists && userDoc.data() != null) {
        final Map<String, dynamic> data =
            userDoc.data() as Map<String, dynamic>;
        bool isPago = data['isPro'] == true;
        Timestamp? trialTimestamp = data['trialEndsAt'];
        DateTime agora = DateTime.now();

        String novoStatus = "PLANO GRATUITO";
        bool acessoLiberado = false;

        if (isPago) {
          novoStatus = "ASSINANTE PRO";
          acessoLiberado = true;
        } else if (trialTimestamp != null) {
          DateTime dataExpiracao = trialTimestamp.toDate();
          if (dataExpiracao.isAfter(agora)) {
            int diasRestantes = dataExpiracao.difference(agora).inDays + 1;
            novoStatus = "PERÍODO DE TESTE ($diasRestantes dias)";
            acessoLiberado = true;
          } else {
            novoStatus = "TESTE EXPIRADO";
            acessoLiberado = false;
          }
        }

        setState(() {
          _statusPlano = novoStatus;
          _usuarioEhPro = acessoLiberado;
        });
      }
    } catch (e) {
      debugPrint("Erro na verificação: $e");
    }
  }

  Future<void> _reutilizarRotaAnterior() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final query = await FirebaseFirestore.instance
        .collection('rotas')
        .where('userId', isEqualTo: user.uid)
        .where('concluida', isEqualTo: false)
        .orderBy('dataCriacao', descending: true)
        .limit(1)
        .get();

    if (query.docs.isEmpty) {
      _notificar("Nenhuma rota pendente encontrada.");
      return;
    }

    var doc = query.docs.first;
    var dados = doc.data();
    double toD(dynamic val) {
      if (val == null) return 0.0;
      if (val is double) return val;
      if (val is int) return val.toDouble();
      if (val is String)
        return double.tryParse(val) ?? 0.0; // Se for String, tenta converter
      return 0.0;
    }

    setState(() {
      _rotaAtivaDocId = doc.id;
      var paradasRaw = List.from(dados['paradas']);
      _paradasIntermediarias = paradasRaw
          .map(
            (p) => DeliveryPoint(
              id: p['id'].toString(),
              address: p['address'],
              location: LatLng(toD(p['lat']), toD(p['lng'])),
            ),
          )
          .toList();
    });

    _carregarRotaNoMapa();
    _notificar("Rota pendente carregada!", cor: Colors.blue);
  }

  Future<void> _fazerLogout() async {
    await FirebaseAuth.instance.signOut();
  }

  // ---------------------------------------------------------------------------
  // LOCALIZAÇÃO
  // ---------------------------------------------------------------------------

  Future<void> _inicializarLocalizacaoComFoco() async {
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return;
    }
    await _definirLocalizacaoAtualComoPartida();
  }

  Future<void> _definirLocalizacaoAtualComoPartida() async {
    try {
      Position pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 5),
      );

      String enderecoFinal = "Minha Localização";

      try {
        List<Placemark> pm = await placemarkFromCoordinates(
          pos.latitude,
          pos.longitude,
        ).timeout(const Duration(seconds: 3));

        if (pm.isNotEmpty) {
          String rua = pm.first.thoroughfare ?? "Local Atual";
          String numero = pm.first.subThoroughfare ?? "";
          enderecoFinal = numero.isNotEmpty ? "$rua, $numero" : rua;
        }
      } catch (e) {
        debugPrint("Geocoding demorou ou falhou.");
      }

      if (mounted) {
        setState(() {
          _pontoPartida = DeliveryPoint(
            id: 'partida',
            address: enderecoFinal,
            location: LatLng(pos.latitude, pos.longitude),
          );
        });
        _mapController?.animateCamera(
          CameraUpdate.newLatLngZoom(LatLng(pos.latitude, pos.longitude), 15),
        );
        _carregarRotaNoMapa();
      }
    } catch (e) {
      debugPrint("Erro crítico de GPS: $e");
    }
  }

  // ---------------------------------------------------------------------------
  // VOZ E BUSCA
  // ---------------------------------------------------------------------------

  Timer? _debounceTimer;

  void _sincronizarComAtraso() {
    if (_debounceTimer?.isActive ?? false) _debounceTimer!.cancel();
    _debounceTimer = Timer(const Duration(seconds: 2), () {
      _atualizarOrdemNoFirebase();
    });
  }


  void _ouvirVoz() async {
    if (!_isListening) {
      bool available = await _speech.initialize();
      if (available) {
        setState(() => _isListening = true);
        _speech.listen(
          onResult: (val) {
            setState(() {
              _searchController.text = val.recognizedWords;
            });
            if (val.finalResult) {
              setState(() => _isListening = false);
              _speech.stop();
            }
          },
          localeId: "pt_BR",
          listenFor: const Duration(seconds: 10),
          pauseFor: const Duration(seconds: 3),
        );
      }
    } else {
      setState(() => _isListening = false);
      _speech.stop();
    }
  }

  Future<List<Map<String, String>>> _buscarSugestoesOpenStreet(
    String query,
  ) async {
    if (query.length < 3) return [];
    final url = Uri.parse(
      "https://nominatim.openstreetmap.org/search?q=$query&format=json&addressdetails=1&countrycodes=br&limit=5",
    );
    try {
      final response = await http.get(
        url,
        headers: {'User-Agent': 'GPRoteiriza_App'},
      );
      if (response.statusCode == 200) {
        final List data = json.decode(response.body);
        return data.map<Map<String, String>>((item) {
          final Map<String, dynamic> addr = item['address'] ?? {};
          String rua = addr['road'] ?? "";
          String bairro = addr['suburb'] ?? addr['neighbourhood'] ?? "";
          String cidade = addr['city'] ?? addr['town'] ?? "";
          String estado = addr['state'] ?? "";
          List<String> comp = [
            rua,
            bairro,
            cidade,
            estado,
          ].where((s) => s.isNotEmpty).toList();
          return {
            "descricao": comp.join(", "),
            "lat": item['lat'],
            "lon": item['lon'],
          };
        }).toList();
      }
    } catch (e) {
      debugPrint(e.toString());
    }
    return [];
  }

  // ---------------------------------------------------------------------------
  // GESTÃO DE PONTOS
  // ---------------------------------------------------------------------------

  Future<void> _adicionarPontoDireto(String end, String tipo) async {
    if (end.isEmpty) return;

    // 1. MANTÉM: Verificação de limite para usuários gratuitos
    if (!_usuarioEhPro && tipo == "parada" && _paradasIntermediarias.length >= 5) {
      _notificar(
        "Limite de 5 paradas atingido. Assine o plano PRO!",
        cor: _corDestaque,
      );
      return;
    }

    // 2. NOVIDADE: Inteligência de CEP
    // Verifica se o texto digitado tem 8 números (ex: 03548000 ou 03548-000)
    String cepLimpo = end.replaceAll(RegExp(r'[^0-9]'), '');
    if (cepLimpo.length == 8) {
      _dialogConfirmarNumeroCep(cepLimpo, tipo); // Abre o diálogo do número
      return; // Interrompe aqui, pois o diálogo assume o comando
    }

    // 3. MANTÉM: Fluxo normal para endereços de texto
    try {
      List<Location> locs = await locationFromAddress(end);
      _processarResultadoGeocoding(locs, end, tipo);
    } catch (e) {
      // TENTATIVA 2 (Plano B): Tenta buscar apenas o texto puro do usuário
      try {
        List<Location> locs = await locationFromAddress(end);
        _processarResultadoGeocoding(locs, end, tipo);
      } catch (e) {
        _notificar("Endereço não encontrado. Tente incluir o bairro ou CEP.");
      }
    }
  }

  Future<void> _persistirRascunhoLocal() async {
    final prefs = await SharedPreferences.getInstance();
    
    // Criamos um mapa com o estado atual da tela
    Map<String, dynamic> rascunho = {
      'pontoPartida': _pontoPartida != null ? {'lat': _pontoPartida!.location.latitude, 'lng': _pontoPartida!.location.longitude, 'end': _searchController.text} : null,
      'paradas': _paradasIntermediarias.map((p) => {
        'lat': p.location.latitude, 
        'lng': p.location.longitude,
        'nome': p.address,
      }).toList(),
      'kmTotal': _kmTotal,
    };

    await prefs.setString('rascunho_rota', json.encode(rascunho));
  }

  // 2. RECUPERAR: Chama isso no initState
  Future<void> _carregarRascunhoLocal() async {
    final prefs = await SharedPreferences.getInstance();
    String? dadosRaw = prefs.getString('rascunho_rota');

    if (dadosRaw != null) {
      Map<String, dynamic> dados = json.decode(dadosRaw);
      setState(() {
        // Aqui você reconstrói suas variáveis com os dados salvos
        // Ex: _kmTotal = dados['kmTotal'];
        // Nota: Você precisará converter as Lat/Lng de volta para objetos LatLng ou paradas.
      });
      _notificar("Roteiro anterior recuperado!", cor: Colors.blueGrey);
    }
  }

  void _dialogConfirmarNumeroCep(String cep, String tipoPonto) {
    TextEditingController numCtrl = TextEditingController();

    showDialog(
      context: context,
      barrierDismissible: false, // Obriga a interagir com o diálogo
      builder: (context) => AlertDialog(
        title: Text("CEP $cep"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text("Encontramos o CEP! Agora, qual o número do local?", 
              style: TextStyle(fontSize: 12, color: Colors.grey)),
            const SizedBox(height: 15),
            TextField(
              controller: numCtrl,
              keyboardType: TextInputType.number,
              autofocus: true,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                labelText: "Número da residência/empresa",
                hintText: "Ex: 216",
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("CANCELAR")),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: _corPrimaria),
            onPressed: () async {
              if (numCtrl.text.isEmpty) {
                _notificar("Informe o número para precisão total.");
                return;
              }

              // Busca o nome da rua na API ViaCEP
              String? ruaEncontrada = await _buscarEnderecoPorCep(cep);
              
              if (ruaEncontrada != null) {
                Navigator.pop(context); // Fecha o diálogo
                
                // Monta o endereço "mastigado" para o Google Maps: "Rua X, Bairro, Cidade, Número"
                String enderecoFinal = "$ruaEncontrada, ${numCtrl.text}";
                
                try {
                  List<Location> locs = await locationFromAddress(enderecoFinal);
                  _processarResultadoGeocoding(locs, enderecoFinal, tipoPonto);
                  _searchController.clear(); // Limpa a barra de busca
                } catch (e) {
                  _notificar("Erro ao geolocalizar este CEP + Número.");
                }
              }
            },
            child: const Text("ADICIONAR À ROTA", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  // Criamos esta função auxiliar para não repetir código dentro do try/catch
  void _processarResultadoGeocoding(
    List<Location> locs,
    String end,
    String tipo,
  ) {
    if (locs.isNotEmpty && mounted) {
      var novo = DeliveryPoint(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        address: end,
        location: LatLng(locs.first.latitude, locs.first.longitude),
        tipo:
            _tipoSelecionado, // Garante que usa o Chip (Coleta/Entrega) selecionado
      );

      setState(() {
        if (tipo == "partida") {
          _pontoPartida = novo;
        } else if (tipo == "destino") {
          _pontoDestino = novo;
        } else {
          _paradasIntermediarias.add(novo);
        }
        _searchController.clear();
      });

      _carregarRotaNoMapa();
    }
  }

  double _calcularDistancia(LatLng p1, LatLng p2) {
    var p = 0.01745329;
    var a =
        0.5 -
        cos((p2.latitude - p1.latitude) * p) / 2 +
        cos(p1.latitude * p) *
            cos(p2.latitude * p) *
            (1 - cos((p2.longitude - p1.longitude) * p)) /
            2;
    return 12742 * asin(sqrt(a));
  }

  Future<void> _solicitarNumeroEAtualizar(String enderecoBase) async {
    TextEditingController numeroCtrl = TextEditingController();
    String? numero = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text("Qual o número?"),
        content: TextField(
          controller: numeroCtrl,
          autofocus: true,
          keyboardType: TextInputType.number,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, ""),
            child: const Text("Sem número"),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, numeroCtrl.text),
            child: const Text("Confirmar"),
          ),
        ],
      ),
    );
    String endFinal = (numero != null && numero.isNotEmpty)
        ? "$enderecoBase, $numero"
        : enderecoBase;
    _adicionarPontoDireto(endFinal, "parada");
  }

  void _otimizarRota() async {
    if (!_usuarioEhPro) {
      Navigator.push(
        context,
        MaterialPageRoute(builder: (context) => const SubscriptionScreen()),
      );
      return;
    }
    if (_paradasIntermediarias.isEmpty) return;
    setState(() => _estaOtimizando = true);
    await Future.delayed(const Duration(milliseconds: 600));
    List<DeliveryPoint> otimizada = [];
    List<DeliveryPoint> restantes = List.from(_paradasIntermediarias);
    LatLng ref = _pontoPartida?.location ?? restantes[0].location;
    while (restantes.isNotEmpty) {
      int proxIdx = 0;
      double minDist = _calcularDistancia(ref, restantes[0].location);
      for (int i = 1; i < restantes.length; i++) {
        double d = _calcularDistancia(ref, restantes[i].location);
        if (d < minDist) {
          minDist = d;
          proxIdx = i;
        }
      }
      var p = restantes.removeAt(proxIdx);
      otimizada.add(p);
      ref = p.location;
    }
    setState(() {
      _paradasIntermediarias = otimizada;
      _estaOtimizando = false;
    });
    _carregarRotaNoMapa();
    _notificar("Rota otimizada!", cor: Colors.green);
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      drawer: _buildDrawer(),
      appBar: AppBar(
        title: const Text("Router Zone", style: TextStyle(fontSize: 16, color: Colors.white)),
        backgroundColor: _corPrimaria,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      // A mágica acontece aqui:
      body: Column(
        children: [
          // 1. TOPO: Busca e Botões (Sempre visíveis)
          _buildBarraBusca(),
          _buildBotoesAcao(),

          // 2. MEIO: Mapa e Lista Deslizante (Um sobre o outro)
          Expanded(
            child: Stack(
              children: [
                // O mapa fica ao fundo preenchendo o espaço
                Positioned.fill(child: _buildAreaMapa()), 
                
                // A lista deslizante fica por cima do mapa
                _buildListaDeslizante(), 
              ],
            ),
          ),

          // 3. BASE: Painel Financeiro (Sempre fixo no rodapé)
          _buildPainelInferior(),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // PERSISTÊNCIA E SALVAMENTO
  // ---------------------------------------------------------------------------

  void _salvarRotaDialog() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    if (_paradasIntermediarias.isEmpty && _pontoPartida == null) return;

    // 1. Criamos os controladores aqui
    TextEditingController nomeRotaCtrl = TextEditingController();
    TextEditingController valorRotaCtrl =
        TextEditingController(); // Controlador para o valor
    String opcaoData = "hoje";
    DateTime dataSelecionada = DateTime.now();

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            title: const Text("Salvar Novo Roteiro"),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: nomeRotaCtrl,
                    decoration: const InputDecoration(
                      labelText: "Nome da Rota (Opcional)",
                    ),
                  ),
                  const SizedBox(height: 10),
                  // CAMPO DE VALOR COM O ESCAPE DO $
                  TextField(
                    controller: valorRotaCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: "Valor Total da Rota (R\$)",
                      prefixIcon: Icon(
                        Icons.monetization_on,
                        color: Colors.green,
                      ),
                    ),
                  ),
                  RadioListTile(
                    title: const Text("Hoje"),
                    value: "hoje",
                    groupValue: opcaoData,
                    onChanged: (v) => setDialogState(() {
                      opcaoData = v!;
                      dataSelecionada = DateTime.now();
                    }),
                  ),
                  RadioListTile(
                    title: const Text("Amanhã"),
                    value: "amanha",
                    groupValue: opcaoData,
                    onChanged: (v) => setDialogState(() {
                      opcaoData = v!;
                      dataSelecionada = DateTime.now().add(
                        const Duration(days: 1),
                      );
                    }),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text("CANCELAR"),
              ),
              ElevatedButton(
                onPressed: () {
                  // AQUI ESTÁ A CORREÇÃO: Passamos os 3 argumentos com os nomes corretos
                  _executarSalvamento(
                    nomeRotaCtrl.text,
                    dataSelecionada,
                    valorRotaCtrl.text,
                  );
                },
                style: ElevatedButton.styleFrom(backgroundColor: _corDestaque),
                child: const Text(
                  "CONFIRMAR",
                  style: TextStyle(color: Colors.white),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _executarSalvamento(
    String nome,
    DateTime dataRota,
    String valorTexto,
  ) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    String nomeFinal = nome.isEmpty
        ? "Rota ${dataRota.day}/${dataRota.month}"
        : nome;

    // Converte o texto para número de forma segura
    double valorConvertido =
        double.tryParse(valorTexto.replaceAll(',', '.')) ?? 0.0;

    try {
      var docRef = await FirebaseFirestore.instance.collection('rotas').add({
        'userId': user.uid,
        'nome': nomeFinal,
        'valorRecebido': valorConvertido,
        'valorExtras': 0.0,
        'valorDespesasRota': 0.0,
        'dataExecucao': Timestamp.fromDate(dataRota),
        'dataCriacao': FieldValue.serverTimestamp(),
        'concluida': false,
        'kmTotal': _kmTotal,
        'paradas': _paradasIntermediarias
            .map(
              (p) => {
                'address': p.address,
                'lat': p.location.latitude,
                'lng': p.location.longitude,
                'id': p.id,
                'concluida': false,
              },
            )
            .toList(),
      });

      setState(() => _rotaAtivaDocId = docRef.id);

      if (mounted) {
        Navigator.pop(context);
        _notificar("Rota agendada!", cor: Colors.green);
      }
    } catch (e) {
      _notificar("Erro ao salvar.");
    }
  }

  void _listarRotasSalvas() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('rotas')
            .where('userId', isEqualTo: user.uid)
            .orderBy('dataCriacao', descending: true)
            .snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData)
            return const Center(child: CircularProgressIndicator());
          var docs = snapshot.data!.docs;
          return ListView.builder(
            itemCount: docs.length,
            itemBuilder: (context, i) {
              var dados = docs[i].data() as Map<String, dynamic>;
              return ListTile(
                leading: const Icon(Icons.history, color: Color(0xFFD45D3A)),
                title: Text(dados['nome'] ?? "Rota"),
                trailing: IconButton(
                  icon: const Icon(Icons.delete, color: Colors.red),
                  onPressed: () => _confirmarExclusao(docs[i].id),
                ),
                onTap: () {
                  setState(() => _rotaAtivaDocId = docs[i].id);
                  Navigator.pop(context);
                  _restaurarRota(dados);
                },
              );
            },
          );
        },
      ),
    );
  }

  void _confirmarExclusao(String docId) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Excluir Rota?"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("NÃO"),
          ),
          ElevatedButton(
            onPressed: () {
              FirebaseFirestore.instance
                  .collection('rotas')
                  .doc(docId)
                  .delete();
              Navigator.pop(context);
            },
            child: const Text("SIM"),
          ),
        ],
      ),
    );
  }

  void _restaurarRota(Map<String, dynamic> dados) {
    double toD(dynamic v) => (v is int) ? v.toDouble() : (v ?? 0.0);
    setState(() {
      if (dados['paradas'] != null) {
        var lista = List.from(dados['paradas']);
        _paradasIntermediarias = lista
            .map(
              (p) => DeliveryPoint(
                id: p['id'].toString(),
                address: p['address'],
                location: LatLng(toD(p['lat']), toD(p['lng'])),
              ),
            )
            .toList();
      }
    });
    _carregarRotaNoMapa();
  }

  // Gerar RELATÓRIO PDF EXPORTAR FINANCEIRO
  Future<void> _gerarRelatorioPDF({
    DocumentSnapshot? rotaUnica,
    DateTime? mesSelecionado,
  }) async {
    try {
      _notificar("Gerando relatório profissional...", cor: Colors.blue);

      // 1. Carregamento do Logo dos Assets
      final ByteData bytes = await rootBundle.load('assets/icon/logo_gp.png');
      final Uint8List logoBytes = bytes.buffer.asUint8List();
      final pw.MemoryImage logoImage = pw.MemoryImage(logoBytes);

      final pdf = pw.Document();
      final hoje = DateTime.now();
      final user = FirebaseAuth.instance.currentUser;

      List<QueryDocumentSnapshot> rotas = [];
      String titulo = "Relatório de Performance";

      // 2. Lógica de Filtro (Rota Única ou Mensal)
      if (rotaUnica != null) {
        rotas = [rotaUnica as QueryDocumentSnapshot];
        titulo = "DETALHE DA ROTA: ${rotaUnica['nome']}";
      } else {
        DateTime inicio = mesSelecionado ?? DateTime(hoje.year, hoje.month, 1);
        final rSnap = await FirebaseFirestore.instance
            .collection('rotas')
            .where('userId', isEqualTo: user?.uid)
            .where(
              'dataExecucao',
              isGreaterThanOrEqualTo: Timestamp.fromDate(inicio),
            )
            .get();
        rotas = rSnap.docs;
        titulo = "FECHAMENTO MENSAL - ${inicio.month}/${inicio.year}";
      }

      // 3. Montagem do PDF
      pdf.addPage(
        pw.MultiPage(
          // MultiPage é melhor para relatórios longos que podem pular de página
          build: (pw.Context context) => [
            // CABEÇALHO COM LOGO
            pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              crossAxisAlignment: pw.CrossAxisAlignment.center,
              children: [
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      titulo,
                      style: pw.TextStyle(
                        fontSize: 20,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                    pw.Text(
                      "Gerado em: ${hoje.day}/${hoje.month}/${hoje.year}",
                      style: const pw.TextStyle(fontSize: 10),
                    ),
                    pw.Text(
                      "Usuário: ${user?.email ?? 'Não identificado'}",
                      style: const pw.TextStyle(fontSize: 10),
                    ),
                  ],
                ),
                pw.Container(width: 60, height: 60, child: pw.Image(logoImage)),
              ],
            ),
            pw.SizedBox(height: 10),
            pw.Divider(thickness: 1, color: PdfColors.grey300),
            pw.SizedBox(height: 15),

            // TABELA DE DADOS
            pw.TableHelper.fromTextArray(
              headerStyle: pw.TextStyle(
                fontWeight: pw.FontWeight.bold,
                color: PdfColors.white,
              ),
              headerDecoration: const pw.BoxDecoration(
                color: PdfColors.blueGrey700,
              ),
              cellAlignment: pw.Alignment.centerLeft,
              data: [
                ['Data', 'Rota', 'KM', 'Líquido'],
                ...rotas.map((r) {
                  final dados = r.data() as Map<String, dynamic>;

                  // Cálculos Seguros
                  double valorBase = (dados['valorRecebido'] ?? 0.0).toDouble();
                  double extras = (dados['valorExtras'] ?? 0.0).toDouble();
                  double despesas = (dados['valorDespesasRota'] ?? 0.0)
                      .toDouble();
                  double liquido = (valorBase + extras) - despesas;

                  String dataFormatada = "--/--";
                  if (dados['dataExecucao'] != null) {
                    DateTime dt = (dados['dataExecucao'] as Timestamp).toDate();
                    dataFormatada = "${dt.day}/${dt.month}";
                  }

                  return [
                    dataFormatada,
                    dados['nome'] ?? "Sem nome",
                    "${dados['kmTotal'] ?? 0} km",
                    "R\$ ${liquido.toStringAsFixed(2)}",
                  ];
                }).toList(),
              ],
            ),

            pw.SizedBox(height: 20),
            pw.Align(
              alignment: pw.Alignment.centerRight,
              child: pw.Text(
                "Router Zone - Otimização de Rotas",
                style: const pw.TextStyle(
                  fontSize: 8,
                  color: PdfColors.grey600,
                ),
              ),
            ),
          ],
        ),
      );

      // 4. Disparo do PDF
      await Printing.layoutPdf(
        onLayout: (PdfPageFormat format) async => pdf.save(),
      );
    } catch (e) {
      debugPrint("Erro ao gerar PDF: $e");
      _notificar(
        "Erro ao gerar PDF detalhado. Verifique o arquivo de logo.",
        cor: Colors.red,
      );
    }
  }
  // ---------------------------------------------------------------------------
  // NAVEGAÇÃO E FINALIZAÇÃO
  // ---------------------------------------------------------------------------


  // 1. SALVAR: Chama isso toda vez que adicionar ou remover algo
  

  void _avancarParaProximaEntrega() async {
    if (_paradasIntermediarias.isEmpty) return;

    // 1. Se já estávamos em uma entrega, marca ela como concluída antes de ir para a próxima
    if (_indiceEntregaAtual >= 0 &&
        _indiceEntregaAtual < _paradasIntermediarias.length) {
      setState(() {
        _paradasIntermediarias[_indiceEntregaAtual].concluida = true;
      });

      // Atualiza no Firebase para que, se o app fechar, a marcação continue lá
      if (_rotaAtivaDocId != null) {
        await FirebaseFirestore.instance
            .collection('rotas')
            .doc(_rotaAtivaDocId)
            .update({
              'paradas': _paradasIntermediarias
                  .map(
                    (p) => {
                      'id': p.id,
                      'address': p.address,
                      'lat': p.location.latitude,
                      'lng': p.location.longitude,
                      'tipo': p.tipo,
                      'concluida': p.concluida,
                    },
                  )
                  .toList(),
            });
      }
    }

    // 2. Avança o índice
    setState(() {
      _indiceEntregaAtual++;
    });

    // 3. Abre o GPS para o novo destino ou finaliza
    if (_indiceEntregaAtual < _paradasIntermediarias.length) {
      WakelockPlus.enable();
      LatLng dest = _paradasIntermediarias[_indiceEntregaAtual].location;

      // Abre Google Maps
      final url =
          "google.navigation:q=${dest.latitude},${dest.longitude}&mode=d";
      if (await canLaunchUrl(Uri.parse(url))) {
        await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      }
    } else {
      WakelockPlus.disable();
      _notificar("Roteiro finalizado com sucesso!", cor: Colors.green);
      if (_rotaAtivaDocId != null) _dialogConcluirRota();
      _indiceEntregaAtual = -1;
    }
  }

  void _dialogConcluirRota() {
    TextEditingController extrasCtrl = TextEditingController(text: "0.00");
    TextEditingController despesasCtrl = TextEditingController(text: "0.00");

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Finalizar Rota"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: extrasCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: "Ganhos Extras (R\$)",
                helperText: "Ex: Adicional de carga, bônus",
                prefixText: "R\$ ",
              ),
            ),
            const SizedBox(height: 15),
            TextField(
              controller: despesasCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: "Despesas da Rota (R\$)",
                helperText: "Ex: Pedágio, combustível",
                prefixText: "R\$ ",
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("CANCELAR"),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.green),
            onPressed: () async {
              double extras =
                  double.tryParse(extrasCtrl.text.replaceAll(',', '.')) ?? 0.0;
              double despesas =
                  double.tryParse(despesasCtrl.text.replaceAll(',', '.')) ??
                  0.0;

              // Atualiza a rota no Firebase
              if (_rotaAtivaDocId != null) {
                await FirebaseFirestore.instance
                    .collection('rotas')
                    .doc(_rotaAtivaDocId)
                    .update({
                      'concluida': true,
                      'valorExtras': extras,
                      'valorDespesasRota': despesas,
                      'dataFinalizacao': DateTime.now(),
                    });

                // Também lançamos a despesa na coleção global de despesas para o histórico geral
                if (despesas > 0) {
                  await FirebaseFirestore.instance.collection('despesas').add({
                    'userId': FirebaseAuth.instance.currentUser?.uid,
                    'valor': despesas,
                    'descricao': "Gasto na Rota: $_rotaAtivaDocId",
                    'data': DateTime.now(),
                  });
                }
              }

              Navigator.pop(context);
              _notificar("Rota finalizada com sucesso!", cor: Colors.green);
              _limparRotaTotal();
            },
            child: const Text(
              "CONCLUIR",
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
  // ---------------------------------------------------------------------------
  // AUXILIARES DE MAPA E UI
  // ---------------------------------------------------------------------------

  

  // 1. Calcula a distância entre dois pontos (Haversine)
  double calcularDistancia(LatLng p1, LatLng p2) {
    var p = 0.017453292519943295;
    var c = cos;
    var a = 0.5 - c((p2.latitude - p1.latitude) * p) / 2 +
        c(p1.latitude * p) * c(p2.latitude * p) *
        (1 - c((p2.longitude - p1.longitude) * p)) / 2;
    return 12742 * asin(sqrt(a)); // Retorna em KM
  }

  // 2. Otimiza a rota após você desenhar e selecionar os pontos
  Future<void> _otimizarRotaComBaseNaNovaOrdem() async {
    if (_paradasIntermediarias.isEmpty) return;
    
    // Aqui você chama a sua função que já existe de traçar a rota (API)
    Future<void> _tracarRota() async {
      if (_pontoPartida == null && _paradasIntermediarias.isEmpty) return;
      
      List<DeliveryPoint> rotaCompleta = [];
      if (_pontoPartida != null) rotaCompleta.add(_pontoPartida!);
      rotaCompleta.addAll(_paradasIntermediarias);

      try {
        final points = await _mapsService.getRoutePoints(rotaCompleta);
        setState(() {
          _polylines = {
            Polyline(
              polylineId: const PolylineId("rota"),
              points: points,
              color: _corPrimaria,
              width: 5,
            ),
          };
        });
        _atualizarResumoKmETempo(); // Atualiza KM e tempo
      } catch (e) {
        _notificar("Erro ao traçar rota.");
      }
    }
    // para que o Google Maps desenhe o caminho correto seguindo a nova lista
    _tracarRota(); 
    _notificar("Rota reordenada com sucesso!");
  }

  void _carregarRotaNoMapa() async {
    List<DeliveryPoint> rota = [];
    if (_pontoPartida != null) rota.add(_pontoPartida!);
    rota.addAll(_paradasIntermediarias);
    await _atualizarMarcadores();
    _atualizarResumoKmETempo();
    _ajustarCameraMapa();
    if (rota.length < 2) {
      setState(() => _polylines = {});
      return;
    }
    try {
      final points = await _mapsService.getRoutePoints(rota);
      if (mounted)
        setState(
          () => _polylines = {
            Polyline(
              polylineId: const PolylineId("r"),
              points: points,
              color: _corDestaque,
              width: 5,
            ),
          },
        );
    } catch (e) {
      debugPrint(e.toString());
    }
  }

  void _atualizarResumoKmETempo() {
    double dist = 0;
    List<DeliveryPoint> todos = [];
    if (_pontoPartida != null) todos.add(_pontoPartida!);
    todos.addAll(_paradasIntermediarias);
    for (int i = 0; i < todos.length - 1; i++)
      dist += _calcularDistancia(todos[i].location, todos[i + 1].location);
    int minT =
        ((dist / 30) * 60).toInt() + (_paradasIntermediarias.length * 10);
    setState(() {
      _kmTotal = double.parse(dist.toStringAsFixed(1));
      _tempoTotalEstimado = "${minT ~/ 60}h ${minT % 60}min";
    });
  }

  void _ajustarCameraMapa() {
    if (_mapController == null || _markers.isEmpty) return;
    List<LatLng> points = _markers.map((m) => m.position).toList();
    var bounds = LatLngBounds(
      southwest: LatLng(
        points.map((p) => p.latitude).reduce(min),
        points.map((p) => p.longitude).reduce(min),
      ),
      northeast: LatLng(
        points.map((p) => p.latitude).reduce(max),
        points.map((p) => p.longitude).reduce(max),
      ),
    );
    _mapController!.animateCamera(CameraUpdate.newLatLngBounds(bounds, 70));
  }

  Future<void> _atualizarMarcadores() async {
    Set<Marker> newMarkers = {};
    if (_pontoPartida != null)
      newMarkers.add(
        Marker(
          markerId: const MarkerId('p'),
          position: _pontoPartida!.location,
          icon: BitmapDescriptor.defaultMarkerWithHue(
            BitmapDescriptor.hueGreen,
          ),
        ),
      );
    for (int i = 0; i < _paradasIntermediarias.length; i++) {
      final icon = await _gerarIconeNumerado(i + 1);
      newMarkers.add(
        Marker(
          markerId: MarkerId(_paradasIntermediarias[i].id),
          position: _paradasIntermediarias[i].location,
          icon: icon,
        ),
      );
    }
    setState(() => _markers = newMarkers);
  }

  Future<BitmapDescriptor> _gerarIconeNumerado(int number) async {
    if (_customIcons.containsKey(number)) return _customIcons[number]!;
    final ui.PictureRecorder pictureRecorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(pictureRecorder);
    final Paint paint = Paint()..color = _corPrimaria;
    const double size = 80.0;
    canvas.drawCircle(const Offset(size / 2, size / 2), size / 2, paint);
    TextPainter painter = TextPainter(textDirection: TextDirection.ltr);
    painter.text = TextSpan(
      text: number.toString(),
      style: const TextStyle(
        fontSize: 32,
        color: Colors.white,
        fontWeight: FontWeight.bold,
      ),
    );
    painter.layout();
    painter.paint(
      canvas,
      Offset((size - painter.width) / 2, (size - painter.height) / 2),
    );
    final img = await pictureRecorder.endRecording().toImage(
      size.toInt(),
      size.toInt(),
    );
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    final icon = BitmapDescriptor.fromBytes(data!.buffer.asUint8List());
    _customIcons[number] = icon;
    return icon;
  }

  // ---------------------------------------------------------------------------
  // INTERFACE
  // ---------------------------------------------------------------------------


  Widget _buildBarraBusca() {
    return Padding(
      padding: const EdgeInsets.all(10),
      child: Column(
        children: [
          // PRIMEIRA LINHA: Campo de Busca e Microfone
          Row(
            children: [
              Expanded(
                child: TypeAheadField<Map<String, String>>(
                  controller: _searchController,
                  builder: (context, ctrl, node) => TextField(
                    controller: ctrl,
                    focusNode: node,
                    decoration: InputDecoration(
                      hintText: "Buscar endereço ou CEP...",
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 15),
                    ),
                  ),
                  suggestionsCallback: _buscarSugestoesOpenStreet,
                  itemBuilder: (context, s) => ListTile(
                    title: Text(s['descricao']!),
                  ),
                  onSelected: (s) => _solicitarNumeroEAtualizar(s['descricao']!),
                ),
              ),
              // BOTÃO DE MICROFONE CORRIGIDO
              IconButton(
                icon: Icon(
                  _isListening ? Icons.mic : Icons.mic_none,
                ),
                color: _isListening ? Colors.red : _corDestaque,
                onPressed: _ouvirVoz, 
              ),
              IconButton(
                icon: _estaOtimizando 
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.bolt),
                color: Colors.blue, // Cor azul para diferenciar da voz
                onPressed: _otimizarRota,
                tooltip: "Otimizar Rota",
              ),
            ],
          ),

          const SizedBox(height: 8),

          // SEGUNDA LINHA: Seleção de Coleta ou Entrega
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ChoiceChip(
                label: const Text("Coleta"),
                selected: _tipoSelecionado == "COLETA",
                onSelected: (val) {
                  if (val) setState(() => _tipoSelecionado = "COLETA");
                },
                selectedColor: Colors.green,
                labelStyle: TextStyle(
                  color: _tipoSelecionado == "COLETA" ? Colors.white : Colors.black,
                ),
              ),
              const SizedBox(width: 15),
              ChoiceChip(
                label: const Text("Entrega"),
                selected: _tipoSelecionado == "ENTREGA",
                onSelected: (val) {
                  if (val) setState(() => _tipoSelecionado = "ENTREGA");
                },
                selectedColor: _corDestaque,
                labelStyle: TextStyle(
                  color: _tipoSelecionado == "ENTREGA" ? Colors.white : Colors.black,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBotoesAcao() {
    return Container(
      color: Colors.grey[100],
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: SingleChildScrollView( // Garante que não quebre em telas pequenas
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            const SizedBox(width: 10),
            _botaoPequeno("INÍCIO", () => _adicionarPontoDireto(_searchController.text, "partida"), Colors.green),
            const SizedBox(width: 5),
            _botaoPequeno("+ PARADA", () => _adicionarPontoDireto(_searchController.text, "parada"), _corPrimaria),
            const SizedBox(width: 5),
            _botaoPequeno("FIM", () => _adicionarPontoDireto(_searchController.text, "destino"), Colors.red),
            
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 10),
              child: SizedBox(height: 20, child: VerticalDivider(color: Colors.grey)),
            ),

            // BOTÃO INVERTER
            _botaoComIconeSuperior(Icons.swap_vert, "Inverter", _reverterRota, Colors.blue),
            
            // BOTÃO SALVAR
            _botaoComIconeSuperior(Icons.save, "Salvar", _salvarRotaDialog, Colors.orange),
            
            const SizedBox(width: 10),
          ],
        ),
      ),
    );
  }

  // Função auxiliar para os novos botões com ícone
  Widget _botaoComIconeSuperior(IconData icone, String texto, VoidCallback acao, Color cor) {
    return InkWell(
      onTap: acao,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Column(
          children: [
            Icon(icone, color: cor, size: 20),
            Text(texto, style: TextStyle(color: cor, fontSize: 9, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }
  
  Widget _buildListaDeslizante() {
    return DraggableScrollableSheet(
      initialChildSize: 0.7, // Começa ocupando 30% da tela
      minChildSize: 0.15,    // Mínimo (só o puxadorzinho)
      maxChildSize: 1.0,     // Máximo (quase a tela toda)
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 10)],
          ),
          child: Column(
            children: [
              // O "Puxador" visual
              Container(
                margin: const EdgeInsets.symmetric(vertical: 10),
                width: 40,
                height: 5,
                decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(10)),
              ),
              const Text("PUXE PARA VER O ROTEIRO", style: TextStyle(fontSize: 10, color: Colors.grey)),
              
              // A LISTA (Agora usa o scrollController do Draggable)
              Expanded(
                child: ReorderableListView.builder(
                  scrollController: scrollController, // MUITO IMPORTANTE: Conecta o scroll ao arrasto
                  itemCount: _paradasIntermediarias.length,
                  onReorder: (int oldIndex, int newIndex) {
                    if (!_usuarioEhPro) {
                      _notificar("Assine o plano PRO para reordenar manualmente.");
                      return;
                    }
                    
                    setState(() {
                      if (newIndex > oldIndex) newIndex -= 1;
                      final item = _paradasIntermediarias.removeAt(oldIndex);
                      _paradasIntermediarias.insert(newIndex, item);
                    });

                    // 1. Atualiza o desenho da linha no mapa
                    _carregarRotaNoMapa();

                    // 2. Persiste a nova ordem no Firebase
                    _atualizarOrdemNoFirebase();                  
                    // ... Sua lógica de reorder que já existe ...
                  },
                  itemBuilder: (context, i) {
                    final ponto = _paradasIntermediarias[i];

                    return ListTile(
                      key: ValueKey(ponto.id), // Essencial para o Reorderable funcionar
                      dense: true,
                      leading: CircleAvatar(
                        radius: 12,
                        backgroundColor: ponto.concluida 
                            ? Colors.grey 
                            : (ponto.tipo == "COLETA" ? Colors.green : _corDestaque),
                        child: ponto.concluida 
                            ? const Icon(Icons.check, color: Colors.white, size: 12)
                            : Text("${i + 1}", style: const TextStyle(fontSize: 10, color: Colors.white)),
                      ),
                      title: Text(
                        ponto.address,
                        style: TextStyle(
                          fontSize: 11, 
                          decoration: ponto.concluida ? TextDecoration.lineThrough : null,
                          color: ponto.concluida ? Colors.grey : Colors.black,
                        ),
                      ),
                      
                      // --- OS BOTÕES QUE VOLTARAM: ---
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // BOTÃO EXCLUIR (Só aparece se a parada não estiver concluída)
                          if (!ponto.concluida)
                            IconButton(
                              icon: const Icon(Icons.remove_circle_outline, color: Colors.red, size: 20),
                              onPressed: () {
                                setState(() {
                                  _paradasIntermediarias.removeAt(i);
                                });
                                _carregarRotaNoMapa(); // Atualiza o mapa
                                _atualizarOrdemNoFirebase(); // Sincroniza exclusão no banco
                              },
                            ),
                          
                          // ÍCONE DE ARRASTAR (Indica que pode ordenar)
                          Icon(
                            _usuarioEhPro ? Icons.drag_handle : Icons.lock_outline,
                            color: Colors.grey[400],
                            size: 22,
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildAreaMapa() {
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.30, // Define 35% da tela para o mapa
      child: GoogleMap(
        initialCameraPosition: CameraPosition(
          target: _pontoPartida?.location ?? const LatLng(-23.5505, -46.6333),
          zoom: 12,
        ),
        onMapCreated: (controller) => _mapController = controller,
        polylines: _polylines,
        markers: _markers,
        myLocationEnabled: true,
      ),
    );
  }

  Widget _buildPainelInferior() {
    if (_rotaAtivaDocId == null) {
      return Container(
        color: _corPrimaria,
        padding: const EdgeInsets.all(15),
        child: const Center(
          child: Text(
            "Selecione ou inicie uma rota",
            style: TextStyle(color: Colors.white70),
          ),
        ),
      );
    }

    String textoBotao = "INICIAR";
    IconData iconeBotao = Icons.play_arrow;

    if (_indiceEntregaAtual >= 0) {
      if (_indiceEntregaAtual < _paradasIntermediarias.length - 1) {
        textoBotao = "PRÓXIMA";
        iconeBotao = Icons.skip_next;
      } else {
        textoBotao = "FINALIZAR";
        iconeBotao = Icons.check_circle;
      }
    }

    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance
          .collection('rotas')
          .doc(_rotaAtivaDocId)
          .snapshots(),
      builder: (context, rotaSnap) {
        if (rotaSnap.connectionState == ConnectionState.waiting) {
        return const LinearProgressIndicator(); // Mostra uma barrinha carregando
        }
        return StreamBuilder<QuerySnapshot>(
          stream: FirebaseFirestore.instance
              .collection('despesas')
              .where('rotaId', isEqualTo: _rotaAtivaDocId)
              .snapshots(),
          builder: (context, despesaSnap) {
            double totalDespesas = 0;
            if (despesaSnap.hasData) {
              for (var d in despesaSnap.data!.docs)
                totalDespesas += (d['valor'] ?? 0.0);
            }

            double valorBase = 0, valorExtras = 0;
            if (rotaSnap.hasData && rotaSnap.data!.exists) {
              var dados = rotaSnap.data!.data() as Map<String, dynamic>;
              // PEGANDO OS VALORES COM SEGURANÇA:
              valorBase = (dados.containsKey('valorRecebido'))
                  ? (dados['valorRecebido'] ?? 0.0).toDouble()
                  : 0.0;
              valorExtras = (dados.containsKey('valorExtras'))
                  ? (dados['valorExtras'] ?? 0.0).toDouble()
                  : 0.0;
            }
            double faturamentoLiquido =
                (valorBase + valorExtras) - totalDespesas;

            return Container(
              color: _corPrimaria,
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 15),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          "Distância: $_kmTotal km",
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                          ),
                        ),
                        Row(
                          children: [
                            Text(
                              "Líquido: R\$ ${faturamentoLiquido.toStringAsFixed(2)}",
                              style: TextStyle(
                                color: faturamentoLiquido >= 0
                                    ? Colors.greenAccent
                                    : Colors.redAccent,
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(width: 8),
                            GestureDetector(
                              onTap: _dialogAjustarFaturamento,
                              child: const Icon(
                                Icons.add_circle,
                                color: Colors.greenAccent,
                                size: 18,
                              ),
                            ),
                          ],
                        ),
                        Text(
                          "Gastos: R\$ ${totalDespesas.toStringAsFixed(2)} | Extras: R\$ ${valorExtras.toStringAsFixed(2)}",
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 9,
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(width: 10),
                ElevatedButton.icon(
                  onPressed: _avancarParaProximaEntrega,
                  icon: Icon(iconeBotao),
                  label: Text(textoBotao),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _corDestaque,
                    foregroundColor: Colors.white,
                  ),
                ),  
              ],
            ),
          );
        },
      );
    },
  );
}

  Widget _buildListaParadas() {
  return Expanded(
    child: Column(
      children: [
        // ESTA É A BARRA QUE O USUÁRIO VAI "SUBIR"
        GestureDetector(
          onTap: () => setState(() => _listaExpandida = !_listaExpandida),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              color: Colors.grey[200],
              borderRadius: const BorderRadius.vertical(top: Radius.circular(15)),
            ),
            child: Column(
              children: [
                Container(
                  width: 40,
                  height: 5,
                  decoration: BoxDecoration(
                    color: Colors.grey[400],
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  _listaExpandida ? "VER MAPA" : "VER ROTEIRO COMPLETO",
                  style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.grey),
                ),
              ],
            ),
          ),
        ),
        
        // Sua ReorderableListView original aqui embaixo
        Expanded(
          flex: 2,
          child: ReorderableListView.builder(
            itemCount: _paradasIntermediarias.length,
            onReorder: (oldIndex, newIndex) {
              if (!_usuarioEhPro) {
                _notificar("Assine o plano PRO para reordenar manualmente.");
                return;
              }
              setState(() {
                if (newIndex > oldIndex) newIndex -= 1;
                final item = _paradasIntermediarias.removeAt(oldIndex);
                _paradasIntermediarias.insert(newIndex, item);
              });
              _carregarRotaNoMapa();
            },
            itemBuilder: (context, i) {
              // Criamos uma referência local para facilitar a leitura
              final ponto = _paradasIntermediarias[i];

              return ListTile(
                key: ValueKey(ponto.id),
                // --- ÍCONE À ESQUERDA (Muda se estiver concluído) ---
                leading: CircleAvatar(
                  backgroundColor: ponto.concluida
                      ? Colors
                            .grey // Cinza se finalizado
                      : (ponto.tipo == "COLETA" ? Colors.green : _corDestaque),
                  child: ponto.concluida
                      ? const Icon(
                          Icons.check,
                          color: Colors.white,
                          size: 15,
                        ) // Check
                      : Text(
                          "${i + 1}",
                          style: const TextStyle(color: Colors.white, fontSize: 12),
                        ),
                ),

                // --- TEXTO DO ENDEREÇO (Risca se estiver concluído) ---
                title: Text(
                  ponto.address,
                  style: TextStyle(
                    fontSize: 12,
                    color: ponto.concluida ? Colors.grey : Colors.black,
                    decoration: ponto.concluida
                        ? TextDecoration.lineThrough
                        : null, // Efeito riscado
                  ),
                ),

                // --- ÍCONES À DIREITA ---
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Só mostramos o botão de excluir se a parada ainda não foi feita
                    if (!ponto.concluida)
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.red, size: 20),
                        onPressed: () {
                          setState(() {
                            _paradasIntermediarias.removeAt(i);
                          });
                          _carregarRotaNoMapa();
                        },
                      ),
                    // Ícone de Reordenação
                    Icon(
                      _usuarioEhPro ? Icons.drag_handle : Icons.lock_outline,
                      color: Colors.grey,
                      size: 20,
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    ),
  );
}
    

  Widget _buildDrawer() {
    final user = FirebaseAuth.instance.currentUser;

    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          // Cabeçalho com informações do Usuário e Plano
          UserAccountsDrawerHeader(
            decoration: BoxDecoration(color: _corPrimaria),
            accountName: Text(
              _statusPlano,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.orangeAccent,
              ),
            ),
            accountEmail: Text(user?.email ?? ""),
            currentAccountPicture: CircleAvatar(
              backgroundColor: Colors.white,
              child: Icon(
                _usuarioEhPro ? Icons.verified : Icons.timer,
                color: _corPrimaria,
              ),
            ),
          ),

          // --- SEÇÃO DE ROTAS ---
          ListTile(
            leading: const Icon(Icons.autorenew, color: Color(0xFFD45D3A)),
            title: const Text("Reutilizar Pendentes"),
            onTap: () {
              Navigator.pop(context);
              _selecionarRotaPendente();
            },
          ),
          ListTile(
            leading: const Icon(Icons.folder, color: Color(0xFFD45D3A)),
            title: const Text("Rotas Salvas"),
            onTap: () {
              Navigator.pop(context);
              _selecionarRotaPendente();
            },
          ),
          ListTile(
            leading: const Icon(Icons.add, color: Colors.green),
            title: const Text("Nova Rota"),
            onTap: () {
              Navigator.pop(context);
              _limparRotaTotal();
            },
          ),

          const Divider(),

          // --- SEÇÃO FINANCEIRA ---
          ListTile(
            leading: const Icon(Icons.money_off, color: Colors.redAccent),
            title: const Text("Lançar Despesa"),
            onTap: () {
              Navigator.pop(context);
              _dialogDespesas();
            },
          ),
          ListTile(
            leading: const Icon(Icons.assessment, color: Colors.blue),
            title: const Text("Histórico Financeiro"),
            onTap: () {
              Navigator.pop(context);
              _exibirHistoricoFinanceiro();
            },
          ),

          // --- SEÇÃO DE RELATÓRIOS PDF ---
          ListTile(
            leading: const Icon(Icons.picture_as_pdf, color: Colors.red),
            title: const Text("Relatório de Hoje"),
            onTap: () {
              Navigator.pop(context);
              _gerarRelatorioPDF();
            },
          ),
          ListTile(
            leading: const Icon(Icons.calendar_month, color: Colors.red),
            title: const Text("Relatório Mensal (Fechamento)"),
            onTap: () {
              Navigator.pop(context);
              // Gera do mês atual começando no dia 1
              DateTime agora = DateTime.now();
              _gerarRelatorioPDF(
                mesSelecionado: DateTime(agora.year, agora.month, 1),
              );
            },
          ),

          const Divider(),

          // --- SEÇÃO TÉCNICA / MANUTENÇÃO ---
          ListTile(
            leading: const Icon(Icons.cleaning_services, color: Colors.orange),
            title: const Text("Manutenção de Dados"),
            subtitle: const Text(
              "Corrige rotas antigas",
              style: TextStyle(fontSize: 10),
            ),
            onTap: () {
              Navigator.pop(context);
              _padronizarBancoDeDados(); // Script que criamos para corrigir o Firebase
            },
          ),

          ListTile(
            leading: const Icon(Icons.logout, color: Colors.grey),
            title: const Text("Sair"),
            onTap: _fazerLogout,
          ),
        ],
      ),
    );
  }

  void _limparRotaTotal() async {
    final prefs = await SharedPreferences.getInstance(); prefs.remove('rascunho_rota');
    setState(() {
      _pontoPartida = null;
      _paradasIntermediarias.clear();
      _polylines.clear();
      _markers.clear();
      _kmTotal = 0;
      _indiceEntregaAtual = -1;
      _rotaAtivaDocId = null;
    });
    _inicializarLocalizacaoComFoco();
    if (Navigator.canPop(context)) Navigator.pop(context);
  }

  // Função para mostrar mensagens (Snackbar)
  void _notificar(String msg, {Color cor = Colors.black87}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: cor,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  // Função para criar os botões de Início, Parada e Fim
  Widget _botaoPequeno(String texto, VoidCallback aoClicar, Color cor) {
    return ElevatedButton(
      onPressed: aoClicar,
      style: ElevatedButton.styleFrom(
        backgroundColor: cor,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        textStyle: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
      ),
      child: Text(texto),
    );
  }
}

//Desenhista customizado para desenhar linhas e áreas no mapa
class DesenhoPainter extends CustomPainter {
  final List<Offset> pontos;

  DesenhoPainter(this.pontos);

  @override
  void paint(Canvas canvas, Size size) {
    if (pontos.isEmpty) return;

    final paint = Paint()
      ..color = Colors.blue
          .withOpacity(0.6) // Cor da linha
      ..strokeCap = StrokeCap.round
      ..strokeWidth =
          5.0 // Grossura do traço
      ..style = PaintingStyle.stroke;

    final path = Path();
    path.moveTo(pontos.first.dx, pontos.first.dy);

    for (int i = 1; i < pontos.length; i++) {
      path.lineTo(pontos[i].dx, pontos[i].dy);
    }

    // Desenha a linha na tela
    canvas.drawPath(path, paint);

    // Opcional: Desenha um fundo levemente colorido dentro do laço
    final paintArea = Paint()
      ..color = Colors.blue.withOpacity(0.1)
      ..style = PaintingStyle.fill;
    canvas.drawPath(path, paintArea);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => true;
}

//AIzaSyAwZp_mX8-qMREHcGVA-K5tk2wVhKddHWc
