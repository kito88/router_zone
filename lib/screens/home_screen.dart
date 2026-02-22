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
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import '../main.dart'; // 🎯 Isso faz a home_screen enxergar a chave global

// Importações do seu projeto
import '../models/delivery_point.dart';
import '../services/google_maps_service.dart';
import 'subscription_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  _HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
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
  Map<String, Offset> _posicoesMarcadoresNoEcran = {}; // Guarda a posição dos marcadores no ecrã para o modo desenho

  // Mapas e Marcadores
  Set<Marker> _markers = {};
  Set<Polyline> _polylines = {};
  final Map<int, BitmapDescriptor> _customIcons = {};

  // --- ESTADO DO MODO DESENHO ---
  bool _isProcessingIntersection = false; // Para evitar travamentos
  bool _isDrawingMode = false; // Ativa/desativa o vidro transparente
  List<Offset> _drawPathPoints = []; // Os pontos exatos onde o dedo passou na tela
  List<DeliveryPoint> _tempReorderedList = []; // Para mostrar a ordem temporária enquanto o usuário arrasta
  List<List<DeliveryPoint>> _gruposLassos = []; // Lista de sequências (Lasso 1, 2...)
  List<Offset> _centrosDosLassos = []; // Para desenhar o número 1, 2, 3 no mapa
  Set<String> _capturedIds = {}; // Para garantir que não pegamos o mesmo ponto duas vezes
  List<List<Offset>> _historicoCaminhosLassos = []; // Guarda os desenhos anteriores
  bool _lockMap = true; // Inicia travado para desenho.
  // Adicione esta variável no topo da sua classe
  List<List<LatLng>> _historicoLassosGPS = []; // Os laços convertidos para GPS
  // Guardará as áreas desenhadas convertidas para o mapa
  Set<Polygon> _polygonsLassos = {};

  // Guardará as coordenadas GPS de onde cada número (1, 2, 3) deve flutuar
  List<LatLng> _centrosLassosGPS = [];
  

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
  String? _enderecoInicio; //Endereço de Partida
  String? _enderecoFim; // Endereço de Destino
  


  // --- FUNÇÕES AUXILIARES DE DATA (Mantenha apenas ESTE bloco) ---

  String _obterNomeMes(int mes) {
    const meses = [
      'Janeiro',
      'Fevereiro',
      'Março',
      'Abril',
      'Maio',
      'Junho',
      'Julho',
      'Agosto',
      'Setembro',
      'Outubro',
      'Novembro',
      'Dezembro',
    ];
    return meses[mes - 1];
  }

  DateTime _inicioDoDia(DateTime d) =>
      DateTime(d.year, d.month, d.day, 0, 0, 0);
  DateTime _fimDoDia(DateTime d) =>
      DateTime(d.year, d.month, d.day, 23, 59, 59);
  DateTime _inicioDoMes(DateTime d) => DateTime(d.year, d.month, 1);
  DateTime _fimDoMes(DateTime d) =>
      DateTime(d.year, d.month + 1, 0, 23, 59, 59);

  // --------------------------------------------------------------

  // Configurações de tempo
  int _tempoPorParadaMin = 10;
  int _tempoPausaMin = 0;

  
  // Cores da Marca GP Roteiriza
  final Color _corPrimaria = const Color(0xFF4E2C22); // Marrom
  final Color _corDestaque = const Color(0xFFD45D3A); // Laranja

  // 1. ATUALIZAÇÃO NO FIREBASE
  Future<void> _atualizarOrdemNoFirebase() async {
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
          'concluida': p.concluida, // Verifique se no seu modelo é 'concluida' ou 'completed'
        }).toList(),
      });
      debugPrint("Ordem sincronizada com o Firebase");
    } catch (e) {
      debugPrint("Erro ao atualizar ordem: $e");
      _notificar("Erro ao guardar a nova ordem no servidor.");
    }
  }

  void _mostrarPopupRelatorio(String titulo, double ganhos, double despesas) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(titulo),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.arrow_upward, color: Colors.green),
              title: Text("Ganhos"),
              trailing: Text("R\$ ${ganhos.toStringAsFixed(2)}"),
            ),
            ListTile(
              leading: Icon(Icons.arrow_downward, color: Colors.red),
              title: Text("Despesas"),
              trailing: Text("R\$ ${despesas.toStringAsFixed(2)}"),
            ),
            Divider(),
            Text(
              "Saldo: R\$ ${(ganhos - despesas).toStringAsFixed(2)}",
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text("Fechar"),
          ),
        ],
      ),
    );
  }

  //Função de Gerar Relatorio Diario
  Future<void> _gerarRelatorioDiario() async {
    // 1. O nome da variável DEVE ser 'dataSelecionada' aqui
    DateTime? dataSelecionada = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(2024),
      lastDate: DateTime.now(),
    );

    // 2. Só avançamos se o usuário escolheu uma data
    if (dataSelecionada != null) {
      // 3. Agora o Dart vai reconhecer o nome 'dataSelecionada' nestas linhas
      await _gerarRelatorioPDF(
        inicio: _inicioDoDia(dataSelecionada),
        fim: _fimDoDia(dataSelecionada),
        tituloPeriodo:
            "RELATÓRIO DIÁRIO - ${dataSelecionada.day}/${dataSelecionada.month}",
      );
    }
  }
  
  // Função auxiliar para solicitar o endereço de início ou fim
  Future<void> _solicitarEndereco(bool isInicio) async {
    print("🚨 Abrindo diálogo para: ${isInicio ? 'INÍCIO' : 'FIM'}");
    TextEditingController _controller = TextEditingController();

    // Se já existir um endereço, ele já aparece no campo para editar
    _controller.text = isInicio
        ? (_enderecoInicio ?? "")
        : (_enderecoFim ?? "");

    return showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(isInicio ? "📍 Ponto de Início" : "🏁 Destino Final"),
          content: TextField(
            controller: _controller,
            decoration: const InputDecoration(
              hintText: "Digite o endereço ou cidade...",
              border: OutlineInputBorder(),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text(
                "CANCELAR",
                style: TextStyle(color: Colors.grey),
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: isInicio ? Colors.green : Colors.red,
              ),
              onPressed: () {
                setState(() {
                  if (isInicio) {
                    _enderecoInicio = _controller.text;
                  } else {
                    _enderecoFim = _controller.text;
                  }
                });
                print("✅ Salvo: ${_controller.text}");
                Navigator.pop(context); // Fecha a caixinha
                _notificar("Local definido com sucesso!");
              },
              child: const Text("CONFIRMAR"),
            ),
          ],
        );
      },
    );
  }


  //Função de Gerar Relatorio Mensal
  Future<void> _gerarRelatorioMensal(BuildContext context) async {
    // 1. Abre o seletor de data
    final DateTime? escolhida = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(2023), // De onde começam seus registros
      lastDate: DateTime.now(),
      helpText: "SELECIONE UM DIA DO MÊS DESEJADO",
      cancelText: "CANCELAR",
      confirmText: "GERAR RELATÓRIO",
    );

    // 2. Se o usuário não cancelou, calcula o intervalo do mês inteiro
    if (escolhida != null) {
      // Primeiro dia do mês escolhido
      DateTime inicioMes = DateTime(escolhida.year, escolhida.month, 1);

      // Último dia do mês escolhido
      DateTime fimMes = DateTime(
        escolhida.year,
        escolhida.month + 1,
        0,
        23,
        59,
        59,
      );

      _notificar(
        "Gerando relatório de ${escolhida.month}/${escolhida.year}...",
      );

      // 3. Chama a função do PDF que já está validada
      await _gerarRelatorioPDF(
        inicio: inicioMes,
        fim: fimMes,
        tituloPeriodo:
            "FECHAMENTO MENSAL - ${escolhida.month}/${escolhida.year}",
      );
    }
  }


  //Função Padronização do banco de Dados
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
                            tituloPeriodo: "DETALHES DA ROTA"
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
    WidgetsBinding.instance.addObserver(this);
    _speech = stt.SpeechToText();
    _carregarRascunhoLocal();
    _verificarStatusAssinatura();
    _inicializarLocalizacaoComFoco();
    _searchController.addListener(_ouvinteDeCep);
  }

  @override
  void dispose() {
    // 🎯 IMPORTANTE: Remove o observador ao fechar a tela para não dar erro
    WidgetsBinding.instance.removeObserver(this);
    _searchController.dispose();
    super.dispose();
  }

  // 🎯 O XEQUE-MATE: Esta função limpa a barra fixa assim que o app volta a aparecer
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // No segundo que o Dr. Kito voltar para o app, a mensagem some!
      messengerKey.currentState?.clearSnackBars();
    }
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
              decoration: const InputDecoration(labelText: "CEP (apenas números)", hintText: "Digite o CEP..."),
            ),
            TextField(
              controller: numCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: "Número", hintText: "Digite o número do local..."),
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
                setState(() {
                  if (tipoPonto == "partida") {
                    _enderecoInicio = enderecoCompleto;
                  } else if (tipoPonto == "destino") {
                    _enderecoFim = enderecoCompleto;
                  }
                });
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
  void _processarResultadoGeocoding(List<Location> locs, String end, String tipo) {
    if (locs.isNotEmpty && mounted) {
      LatLng novaLoc = LatLng(locs.first.latitude, locs.first.longitude);

      // VERIFICAÇÃO DE DUPLICIDADE: Checa se já existe um ponto nestas coordenadas
      bool jaExiste = _paradasIntermediarias.any((p) => 
        (p.location.latitude == novaLoc.latitude && p.location.longitude == novaLoc.longitude)
      );

      if (jaExiste && tipo == "parada") {
        _notificar("Este endereço já está na sua lista.", cor: Colors.orange);
        return;
      }

      var novo = DeliveryPoint(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        address: end,
        location: novaLoc,
        tipo: _tipoSelecionado,
        concluida: false,
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


  

  void _limparVariaveisDesenho() {
    setState(() {
      _gruposLassos = [];
      _polygonsLassos = {}; // Remove os laços laranjas
      _centrosLassosGPS = []; // Remove os números 1, 2, 3
      _capturedIds = {};
      _drawPathPoints = [];
      _lockMap = true; // Trava o mapa para o próximo uso
    });
  }

  //funcao otimizacao automatica
  void _otimizarAutomatico() async {
    if (_paradasIntermediarias.length < 2) {
      _notificar("Adicione pelo menos 2 paradas.");
      return;
    }

    setState(() => _estaOtimizando = true);

    // 1. Separa quem já foi entregue de quem falta entregar
    List<DeliveryPoint> pendentes = _paradasIntermediarias.where((p) => !p.concluida).toList();
    List<DeliveryPoint> concluidas = _paradasIntermediarias.where((p) => p.concluida).toList();
    List<DeliveryPoint> otimizada = [];
    
    LatLng ref = _pontoPartida?.location ?? const LatLng(-23.5505, -46.6333);

    // 2. Algoritmo de Vizinho Próximo
    while (pendentes.isNotEmpty) {
      pendentes.sort((a, b) {
        double distA = _calcularDistancia(ref, a.location);
        double distB = _calcularDistancia(ref, b.location);
        return distA.compareTo(distB);
      });

      var proximo = pendentes.removeAt(0);
      otimizada.add(proximo);
      ref = proximo.location;
    }

    // 3. ATUALIZA O ESTADO COM A NOVA ORDEM
    setState(() {
      _paradasIntermediarias = [...otimizada, ...concluidas];
      _estaOtimizando = false;
      print("Otimização automática concluída. ${_paradasIntermediarias.length} Nova ordem aplicada.");
    });

    // 4. ESSENCIAL: DIZ AO MAPA PARA REDESENHAR TUDO
    await _atualizarMarcadores(); // Atualiza os números (1, 2, 3...)
    _carregarRotaNoMapa();        // Traça a nova linha azul/laranja
    _atualizarOrdemNoFirebase(); // Salva no banco de dados
    
    _notificar("Rota otimizada com sucesso!", cor: Colors.green);
  }


  // 2. Esta função "congela" onde cada endereço está na tela no momento que você toca nela
  void _prepararCapturaDePontos(Offset posicao) async {
    _posicoesMarcadoresNoEcran.clear();
    double pixelRatio = MediaQuery.of(context).devicePixelRatio;

    for (var parada in _paradasIntermediarias) {
      // Não pega quem já foi laçado ou concluído
      if (_capturedIds.contains(parada.id) || parada.concluida) continue;

      ScreenCoordinate screenCoord = await _mapController!.getScreenCoordinate(
        parada.location,
      );

      // Converte a posição do GPS para pixels da tela do celular
      _posicoesMarcadoresNoEcran[parada.id] = Offset(
        screenCoord.x.toDouble() / pixelRatio,
        screenCoord.y.toDouble() / pixelRatio,
      );
    }
  }

  // 3. Esta função checa se o seu dedo passou perto de algum endereço (Muito rápida!)
  void _detectarIntersecaoRapida(Offset dedoPos) {
    const double hitRadius = 45.0; // Sensibilidade do toque

    _posicoesMarcadoresNoEcran.forEach((id, markerPos) {
      if (!_capturedIds.contains(id)) {
        double distance = (dedoPos - markerPos).distance;

        if (distance < hitRadius) {
          // Encontra o endereço na sua lista pelo ID
          var parada = _paradasIntermediarias.firstWhere((p) => p.id == id);

          setState(() {
            _tempReorderedList.add(parada);
            _capturedIds.add(id);
          });
          HapticFeedback.selectionClick(); // Vibração leve ao capturar
        }
      }
    });
  }

  double _calcularDistanciaSimples(LatLng p1, LatLng p2) {
    return (p1.latitude - p2.latitude).abs() +
        (p1.longitude - p2.longitude).abs();
  }



  // Função auxiliar para cálculo de distância
  double _calcularDistancia(LatLng p1, LatLng p2) {
    return (p1.latitude - p2.latitude).abs() +
        (p1.longitude - p2.longitude).abs();
  }

  //BOTÃO DE OPCAO CORRIGIDO
  void _confirmarSequenciaLassos() async {
    // 1. Usamos uma lista auxiliar para garantir que cada ponto entre apenas UMA VEZ
    final List<DeliveryPoint> novaOrdemLimpa = [];
    final Set<String> idsJaAdicionados = {};

    for (var grupo in _gruposLassos) {
      for (var ponto in grupo) {
        // Só adiciona se o ponto ainda não estiver na nova lista
        if (!idsJaAdicionados.contains(ponto.id)) {
          novaOrdemLimpa.add(ponto);
          idsJaAdicionados.add(ponto.id);
        }
      }
    }

    // 2. Pegamos quem SOBROU (quem você NÃO laçou)
    List<DeliveryPoint> restantes = _paradasIntermediarias
        .where((p) => !idsJaAdicionados.contains(p.id) && !p.concluida)
        .toList();

    // 3. Pegamos as concluídas
    List<DeliveryPoint> concluidas = _paradasIntermediarias
        .where((p) => p.concluida)
        .toList();

    // 4. Montamos a lista oficial SEM DUPLICADOS
    setState(() {
      _paradasIntermediarias = [...novaOrdemLimpa, ...restantes, ...concluidas];
      _isDrawingMode = false;
      _limparVariaveisDesenho();
    });

    // 5. ATUALIZAÇÃO VISUAL (Obrigatória para os números 1, 2, 3...)
    _customIcons.clear();
    await _atualizarMarcadores();
    _carregarRotaNoMapa();
    await _atualizarOrdemNoFirebase();

    _notificar("Roteiro reordenado!", cor: Colors.blue);
  }
  


  // funcao Otimizar
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
    _notificar("Rota otimizada!", cor: const ui.Color.fromARGB(255, 223, 219, 15));
  }



  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // O segredo está aqui: ValueKey faz o Flutter resetar o estado ao mudar o modo
      body: KeyedSubtree(
        key: ValueKey(_isDrawingMode),
        child: _isDrawingMode ? _buildMapaFull() : _buildLayoutPadrao(),
      ),

      drawer: _isDrawingMode ? null : _buildDrawer(),

      appBar: AppBar(
        title: Text(_isDrawingMode ? "Sequenciando Rota..." : "Router Zone"),
        backgroundColor: _isDrawingMode ? Colors.orange : _corPrimaria,
        leading: _isDrawingMode
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => setState(() {
                  _isDrawingMode = false;
                  _limparVariaveisDesenho();
                }),
              )
            : null,
        actions: !_isDrawingMode
            ? [
                IconButton(
                  icon: const Icon(Icons.more_vert),
                  onPressed: _mostrarOpcoesOtimizacao,
                ),
              ]
            : null,
      ),

      floatingActionButton: _isDrawingMode && _gruposLassos.isNotEmpty
          ? FloatingActionButton.extended(
              backgroundColor: Colors.green,
              onPressed:
                  _confirmarSequenciaLassos, // Função que organiza a lista
              label: Text("Finalizar e Roteirizar (${_gruposLassos.length})"),
              icon: const Icon(Icons.check_circle),
            )
          : null,
    );
  }

  //BUILD MAPA 100% (TELA CHEIA)
  


  Widget _buildNumerosSeguindoMapa() {
    return FutureBuilder(
      future: Future.wait(_centrosLassosGPS.map((gps) async {
        return await _mapController?.getScreenCoordinate(gps);
      })),
      builder: (context, snapshot) {
        if (!snapshot.hasData || snapshot.data == null) return const SizedBox();
        
        var coordenadas = snapshot.data as List<ScreenCoordinate?>;
        List<Widget> badges = [];

        for (int i = 0; i < coordenadas.length; i++) {
          var coord = coordenadas[i];
          if (coord == null) continue;
          
          badges.add(
            Positioned(
              // Dividimos pelo pixelRatio para alinhar com o Flutter
              left: (coord.x / MediaQuery.of(context).devicePixelRatio) - 15,
              top: (coord.y / MediaQuery.of(context).devicePixelRatio) - 15,
              child: CircleAvatar(
                radius: 15,
                backgroundColor: Colors.blue.withOpacity(0.9),
                child: Text("${i + 1}", style: const TextStyle(color: Colors.white, fontSize: 12)),
              ),
            ),
          );
        }
        return Stack(children: badges);
      },
    );
  }

  Widget _buildNumerosSobrepostos() {
    return StreamBuilder(
      // Este stream "ouve" o movimento da câmara para reposicionar os números
      stream: Stream.periodic(const Duration(milliseconds: 100)),
      builder: (context, snapshot) {
        return Stack(
          children: List.generate(_centrosLassosGPS.length, (index) {
            return FutureBuilder<ScreenCoordinate?>(
              future: _mapController?.getScreenCoordinate(
                _centrosLassosGPS[index],
              ),
              builder: (context, coordSnapshot) {
                if (!coordSnapshot.hasData || coordSnapshot.data == null)
                  return const SizedBox();

                double pixelRatio = MediaQuery.of(context).devicePixelRatio;
                return Positioned(
                  left: (coordSnapshot.data!.x / pixelRatio) - 15,
                  top: (coordSnapshot.data!.y / pixelRatio) - 15,
                  child: CircleAvatar(
                    radius: 15,
                    backgroundColor: Colors.blue,
                    child: Text(
                      "${index + 1}",
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  ),
                );
              },
            );
          }),
        );
      },
    );
  }

  //Mapa tela Cheia
  Widget _buildMapaFull() {
    return Stack(
      children: [
        // 1. O MAPA NATIVO
        Positioned.fill(
          child: GoogleMap(
            key: const ValueKey("MAPA_INTERATIVO_LASSO_PRO"),
            initialCameraPosition: CameraPosition(
              target:
                  _pontoPartida?.location ?? const LatLng(-23.5505, -46.6333),
              zoom: 14,
            ),
            onMapCreated: (controller) => _mapController = controller,
            markers: _markers,
            polylines: _polylines,
            polygons: _polygonsLassos,
            myLocationEnabled: true,
            scrollGesturesEnabled: !_lockMap,
            zoomGesturesEnabled: !_lockMap,
          ),
        ),

        // 2. CAMADA VISUAL DO DESENHO (O rastro azul do dedo)
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(painter: RouteDrawingPainter(_drawPathPoints)),
          ),
        ),

        // 3. CAPTURA DE TOQUE (SÓ ATIVO SE LOCKMAP FOR TRUE)
        if (_lockMap)
          Positioned.fill(
            child: GestureDetector(
              onPanStart: (details) {
                setState(() {
                  _drawPathPoints = [details.localPosition];
                  _tempReorderedList = [];
                });
                _prepararCapturaDePontos(details.localPosition);
              },
              onPanUpdate: (details) {
                setState(() => _drawPathPoints.add(details.localPosition));
                _detectarIntersecaoRapida(details.localPosition);
              },
              onPanEnd: (details) async {
                if (_drawPathPoints.length > 5) {
                  double pixelRatio = MediaQuery.of(context).devicePixelRatio;
                  List<LatLng> caminhoGPS = [];
                  for (Offset ponto in _drawPathPoints) {
                    LatLng? latLng = await _mapController?.getLatLng(
                      ScreenCoordinate(
                        x: (ponto.dx * pixelRatio).toInt(),
                        y: (ponto.dy * pixelRatio).toInt(),
                      ),
                    );
                    if (latLng != null) caminhoGPS.add(latLng);
                  }

                  setState(() {
                    _gruposLassos.add(List.from(_tempReorderedList));
                    _polygonsLassos.add(
                      Polygon(
                        polygonId: PolygonId(
                          "Lasso_${DateTime.now().millisecondsSinceEpoch}",
                        ),
                        points: caminhoGPS,
                        strokeWidth: 2,
                        strokeColor: Colors.orange,
                        fillColor: Colors.orange.withOpacity(0.15),
                      ),
                    );
                    if (caminhoGPS.isNotEmpty)
                      _centrosLassosGPS.add(caminhoGPS.first);
                    _tempReorderedList = [];
                    _drawPathPoints = [];
                  });
                  HapticFeedback.mediumImpact();
                } else {
                  if (_capturedIds.length ==_paradasIntermediarias.where((p) => !p.concluida).length) {
                    _notificar("Todos os pontos já foram capturados!");
                  } 
                }
              },
            ),
          ),

        // 4. CAMADA DE NÚMEROS (Badges 1, 2, 3...)
        _buildNumerosSobreMapa(),

        // 5. BOTÃO DE TRAVA (Cadeado/Lápis)
        Positioned(
          top: 20,
          right: 20,
          child: FloatingActionButton(
            mini: true,
            backgroundColor: _lockMap ? Colors.blue : Colors.grey[800],
            onPressed: () => setState(() => _lockMap = !_lockMap),
            child: Icon(
              _lockMap ? Icons.edit : Icons.pan_tool,
              color: Colors.white,
            ),
          ),
        ),

        // 6. BOTÃO DESFAZER (Aparece apenas se houver laços feitos)
        if (_isDrawingMode && _gruposLassos.isNotEmpty)
          Positioned(
            top: 80,
            right: 20,
            child: FloatingActionButton(
              mini: true,
              backgroundColor: Colors.redAccent,
              onPressed: _desfazerUltimoLasso,
              child: const Icon(Icons.undo, color: Colors.white),
            ),
          ),
      ],
    );
  }


  //Widget dos Numeros
  Widget _buildNumerosSobreMapa() {
    return Stack(
      children: List.generate(_centrosLassosGPS.length, (index) {
        return FutureBuilder<ScreenCoordinate?>(
          future: _mapController?.getScreenCoordinate(_centrosLassosGPS[index]),
          builder: (context, snapshot) {
            if (!snapshot.hasData || snapshot.data == null)
              return const SizedBox();
            double pixelRatio = MediaQuery.of(context).devicePixelRatio;
            return Positioned(
              left: (snapshot.data!.x / pixelRatio) - 15,
              top: (snapshot.data!.y / pixelRatio) - 15,
              child: CircleAvatar(
                radius: 15,
                backgroundColor: Colors.blue,
                child: Text(
                  "${index + 1}",
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              ),
            );
          },
        );
      }),
    );
  }


  Widget _buildInterfaceSobreposta() {
    return Stack(
      children: [
        // Números dos Lassos
        for (int i = 0; i < _centrosDosLassos.length; i++)
          Positioned(
            left: _centrosDosLassos[i].dx - 20,
            top: _centrosDosLassos[i].dy - 20,
            child: CircleAvatar(
              radius: 20,
              backgroundColor: Colors.orange.withOpacity(0.9),
              child: Text(
                "${i + 1}",
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),

        // Botão Flutuante de Controle (Lápis / Mão)
        Positioned(
          top: 100,
          right: 20,
          child: FloatingActionButton(
            mini: true,
            backgroundColor: _lockMap ? Colors.blue : Colors.grey[800],
            child: Icon(
              _lockMap ? Icons.edit : Icons.pan_tool,
              color: Colors.white,
            ),
            onPressed: () {
              setState(() => _lockMap = !_lockMap);
              _notificar(_lockMap ? "Modo Desenho" : "Modo Zoom/Mapa");
            },
          ),
        ),
      ],
    );
  }

  Widget _buildLayoutPadrao() {
    return Column(
      children: [
        _buildBarraBusca(),
        _buildBotoesAcao(),
        Expanded(
          child: Stack(
            children: [
              // Adicionamos uma Key única aqui
              Positioned.fill(
                child: _buildAreaMapa(key: const ValueKey("MAPA_REDUZIDO")),
              ),
              _buildListaDeslizante(),
            ],
          ),
        ),
        _buildPainelInferior(),
      ],
    );
  }


  //Função Criar Lassos
  void _limparLassos() {
    setState(() {
      _isDrawingMode = false;
      _gruposLassos = [];
      _capturedIds = {};
      _drawPathPoints = [];
      _historicoCaminhosLassos = []; // Se ainda usar

      // ADICIONE ESTAS DUAS:
      _polygonsLassos = {};
      _centrosLassosGPS = [];

      _lockMap = true;
    });
  }

  //Finalizar e Roteirizar (A Sequência Correcta)
  


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
    DateTime? inicio,
    DateTime? fim,
    required String tituloPeriodo,
  }) async {
    final pdf = pw.Document();
    final user = FirebaseAuth.instance.currentUser;

    // Função para garantir que o valor seja Double
    double toD(dynamic v) => (v is num) ? v.toDouble() : 0.0;

    final List<List<String>> dadosTabela = [
      ['Data', 'Endereço', 'Recebido', 'Despesa'], // Cabeçalho
    ];

    try {
      double ganhosTotais = 0;
      double despesasTotais = 0;

      // 1. BUSCA NAS ROTAS (Usando os nomes do PRINT)
      var snapRotas = await FirebaseFirestore.instance
          .collection('rotas') // Nome minúsculo do seu print
          .where('userId', isEqualTo: user?.uid)
          .where(
            'dataExecucao',
            isGreaterThanOrEqualTo: Timestamp.fromDate(inicio!),
          )
          .where('dataExecucao', isLessThanOrEqualTo: Timestamp.fromDate(fim!))
          .get();

      for (var d in snapRotas.docs) {
        final dados = d.data() as Map<String, dynamic>;
        DateTime dt = (dados['dataExecucao'] as Timestamp).toDate();

        // Soma os valores que estão no DOCUMENTO (como mostra o seu print)
        double valorRota =
            toD(dados['valorRecebido']) + toD(dados['valorExtras']);
        double despesaRota = toD(dados['valorDespesasRota']);

        ganhosTotais += valorRota;
        despesasTotais += despesaRota;

        dadosTabela.add([
          "${dt.day}/${dt.month}/${dt.year}",
          dados['address'] ??
              'Sem endereço', // Usei 'address' que vi no seu print
          "R\$ ${valorRota.toStringAsFixed(2)}",
          "R\$ ${despesaRota.toStringAsFixed(2)}",
        ]);
      }

      // 2. MONTAGEM DA PÁGINA
      pdf.addPage(
        pw.Page(
          build: (context) => pw.Column(
            children: [
              pw.Text(
                tituloPeriodo,
                style: pw.TextStyle(
                  fontSize: 20,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
              pw.SizedBox(height: 20),
              pw.TableHelper.fromTextArray(context: context, data: dadosTabela),
              pw.SizedBox(height: 20),
              pw.Row(
                mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                children: [
                  pw.Text(
                    "Total Ganhos: R\$ ${ganhosTotais.toStringAsFixed(2)}",
                  ),
                  pw.Text(
                    "Total Despesas: R\$ ${despesasTotais.toStringAsFixed(2)}",
                  ),
                  pw.Text(
                    "Saldo: R\$ ${(ganhosTotais - despesasTotais).toStringAsFixed(2)}",
                    style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
                  ),
                ],
              ),
            ],
          ),
        ),
      );

      // 3. SALVAR E COMPARTILHAR (A parte nova)
      // Primeiro, geramos os bytes do PDF
      final bytes = await pdf.save();

      // Pegamos a pasta temporária do celular
      final dir = await getTemporaryDirectory();
      final nomeArquivo =
          'Relatorio_${DateTime.now().millisecondsSinceEpoch}.pdf';
      final arquivo = File('${dir.path}/$nomeArquivo');

      // Gravamos o arquivo
      await arquivo.writeAsBytes(bytes);

      // Abre a janela para escolher WhatsApp, E-mail, etc.
      await Share.shareXFiles([
        XFile(arquivo.path),
      ], text: 'Segue o $tituloPeriodo do GPCargo.');

      await Printing.layoutPdf(onLayout: (format) async => pdf.save());
    } catch (e) {
      print("🆘 Erro Final: $e");
    }
  }


  // ---------------------------------------------------------------------------
  // NAVEGAÇÃO E FINALIZAÇÃO
  // ---------------------------------------------------------------------------


  void _desfazerUltimaEntrega() async {
    // Só podemos desfazer se o índice for maior que 0
    if (_indiceEntregaAtual <= 0) return;

    setState(() {
      // 1. Volta o índice para a entrega anterior
      _indiceEntregaAtual--;
      
      // 2. Marca a entrega anterior como NÃO concluída
      _paradasIntermediarias[_indiceEntregaAtual].concluida = false;
    });

    // 3. Sincroniza com o Firebase
    if (_rotaAtivaDocId != null) {
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
    }
    
    _notificar("Ação desfeita!", cor: Colors.orange);
  }

  // 1. SALVAR: Chama isso toda vez que adicionar ou remover algo
  

  void _avancarParaProximaEntrega() async {
    print("🚀 Função ativa. Índice atual: $_indiceEntregaAtual");
    if (_paradasIntermediarias.isEmpty) return;

    // 1. LIMPEZA INICIAL: Mata qualquer mensagem "zumbi" antes de começar
    // Usamos os dois comandos para garantir faxina total na messengerKey
    messengerKey.currentState?.removeCurrentSnackBar();
    messengerKey.currentState?.clearSnackBars();

    // 2. ATUALIZAÇÃO VISUAL (Traço cinza aparece na hora)
    if (_indiceEntregaAtual >= 0 && _indiceEntregaAtual < _paradasIntermediarias.length) {
      setState(() {
        _paradasIntermediarias[_indiceEntregaAtual].concluida = true;
      });

      // Envia para o Firebase em segundo plano (sem await para não travar a tela)
      if (_rotaAtivaDocId != null) {
        FirebaseFirestore.instance
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
        }).catchError((e) => print("Erro ao sincronizar Firebase: $e"));
      }
    }

    // 3. PREPARA O SNACKBAR (Mensagem flutuante com botão DESFAZER)
    final snackBar = SnackBar(
      content: const Text("Entrega marcada como concluída"),
      duration: const Duration(seconds: 4), // Tempo ideal para o motorista ler
      behavior: SnackBarBehavior.floating,   // Flutua sobre os botões
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      action: SnackBarAction(
        label: "DESFAZER",
        textColor: Colors.yellow,
        onPressed: () {
          messengerKey.currentState?.hideCurrentSnackBar();
          _desfazerUltimaEntrega();
        },
      ),
    );

    // 4. AVANÇA O ÍNDICE
    setState(() {
      _indiceEntregaAtual++;
    });

    // 5. NAVEGAÇÃO OU FINALIZAÇÃO
    if (_indiceEntregaAtual < _paradasIntermediarias.length) {
      WakelockPlus.enable();
      LatLng dest = _paradasIntermediarias[_indiceEntregaAtual].location;

      // Exibe a mensagem usando a Chave Global do main.dart
      messengerKey.currentState?.showSnackBar(snackBar);

      // 🎯 RESPIRO TÉCNICO: Aguarda o Android processar a barra antes de abrir o Maps
      await Future.delayed(const Duration(milliseconds: 600));

      final url = "google.navigation:q=${dest.latitude},${dest.longitude}&mode=d";
      
      if (await canLaunchUrl(Uri.parse(url))) {
        // Abre o Maps sem 'await' para o Flutter continuar rodando o timer da msg
        launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      }
    } else {
      // Roteiro finalizado
      WakelockPlus.disable();
      _notificar("Roteiro finalizado com sucesso!", cor: Colors.green);
      
      if (_rotaAtivaDocId != null) {
        _dialogConcluirRota();
      }
      
      setState(() {
        _indiceEntregaAtual = -1; 
      });
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
 
 
  Future<void> _checkIntersectionWithMarkers(Offset fingerPos) async {
    if (_mapController == null || _paradasIntermediarias.isEmpty) return;

    double pixelRatio = MediaQuery.of(context).devicePixelRatio;
    const double hitRadius = 50.0;

    for (var parada in _paradasIntermediarias) {
      if (_capturedIds.contains(parada.id) || parada.concluida) continue;

      ScreenCoordinate screenCoord = await _mapController!.getScreenCoordinate(
        parada.location,
      );

      // Converte de FÍSICO (Mapa) para LÓGICO (Dedo)
      Offset markerPos = Offset(
        screenCoord.x.toDouble() / pixelRatio,
        screenCoord.y.toDouble() / pixelRatio,
      );

      double distance = (fingerPos - markerPos).distance;

      if (distance < hitRadius) {
        setState(() {
          _tempReorderedList.add(parada);
          _capturedIds.add(parada.id);
        });
        HapticFeedback.selectionClick();
      }
    }
  }


  void _desfazerUltimoLasso() {
    if (_gruposLassos.isEmpty) return;

    setState(() {
      // 1. Pega o último grupo capturado
      List<DeliveryPoint> ultimoGrupo = _gruposLassos.removeLast();

      // 2. Remove os IDs desse grupo da lista de "bloqueados"
      for (var ponto in ultimoGrupo) {
        _capturedIds.remove(ponto.id);
      }

      // 3. Remove o desenho (polígono) e o número flutuante correspondente
      if (_polygonsLassos.isNotEmpty) {
        _polygonsLassos.remove(_polygonsLassos.last);
      }
      if (_centrosLassosGPS.isNotEmpty) {
        _centrosLassosGPS.removeLast();
      }
    });

    _notificar("Último laço removido", cor: Colors.orange);
  }


  void _aplicarNovaOrdemDesenhada() async {
    // 1. Verificação de segurança
    if (_tempReorderedList.isEmpty) {
      setState(() => _isDrawingMode = false);
      return;
    }

    // 2. Filtramos usando o tipo CORRETO (DeliveryPoint)
    // Pegamos quem não foi laçado e não está concluído
    List<DeliveryPoint> restantes = _paradasIntermediarias
        .where((p) => !_capturedIds.contains(p.id) && !p.concluida)
        .toList();

    // Pegamos quem já estava concluído (cinza)
    List<DeliveryPoint> concluidos = _paradasIntermediarias
        .where((p) => p.concluida)
        .toList();

    setState(() {
      // Nova ordem: Laçados -> Restantes -> Concluídos
      _paradasIntermediarias = [
        ..._tempReorderedList,
        ...restantes,
        ...concluidos,
      ];
      _isDrawingMode = false;
      _drawPathPoints = [];
    });

    // 3. Sincroniza com o Firebase
    await _atualizarOrdemNoFirebase();

    // 4. Feedback visual
    _notificar("Rota reordenada manualmente!", cor: Colors.blue);
  }

  
  

  // DINAMICAR PERGUNTAR AO FORMA DE OTIMIZAR
  void _mostrarOpcoesOtimizacao() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.auto_fix_high, color: Colors.blue),
              title: const Text("Otimização Automática"),
              subtitle: const Text("O algoritmo calcula a rota mais rápida."),
              onTap: () async {
                Navigator.pop(context);
                print("🖱️ Clique detectado na Otimização Automática");
                // Aguarda um milissegundo para o modal fechar e não travar a UI
                await Future.delayed(const Duration(milliseconds: 100));
                _otimizarAutomatico();   // Garante que os marcadores estão atualizados antes de otimizar
              },
            ),
            ListTile(
              leading: const Icon(Icons.gesture, color: Colors.orange),
              title: const Text("Desenhar Roteiro (Lasso)"),
              subtitle: const Text("Selecione os pontos desenhando no mapa."),
              onTap: () {
                Navigator.pop(context);
                // 1. Antes de expandir o mapa, garante que os marcadores foram criados
                _atualizarMarcadores();
                setState(() {
                  _isDrawingMode = true;
                  // A mágica: Ativamos o modo desenho e o mapa expande
                  // 2. Dá um pequeno tempo para o mapa expandir e ajusta a visão
                  Future.delayed(const Duration(milliseconds: 300), () {
                    _ajustarCameraMapa();
                  });
                });
              },
            ),
          ],
        );
      },
    );
  }


  

  Future<void> _atualizarMarcadores() async {
    print("🔄 Atualizando Marcadores numerados...");
    _customIcons.clear(); // Limpa os ícones personalizados para evitar acúmulo
    Set<Marker> newMarkers = {};

    // 1. MARCADOR DE PARTIDA (Verde)
    if (_pontoPartida != null) {
      newMarkers.add(
        Marker(
          markerId: const MarkerId('partida'),
          position: _pontoPartida!.location,
          infoWindow: const InfoWindow(title: "Início"),
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueGreen),
        ),
      );
    }

    // 2. MARCADORES DAS PARADAS (Numerados e Sequenciais)
    // Como usamos o índice 'i', a numeração SEMPRE seguirá a ordem da lista
    // PARADAS (Numeradas estritamente de 1 até o total da lista)
    for (int i = 0; i < _paradasIntermediarias.length; i++) {
      final ponto = _paradasIntermediarias[1];
      final icon = await _gerarIconeNumerado(i + 1); // Garante a sequência 1, 2, 3...
      newMarkers.add(Marker(
        markerId: MarkerId(_paradasIntermediarias[i].id),
        position: _paradasIntermediarias[i].location,
        icon: icon,
        infoWindow: InfoWindow(title: "Parada ${i + 1}"),
      ));
    }

    if (mounted) {
      setState(() => _markers = newMarkers);
    }
  
    // 3. MARCADOR DE DESTINO FINAL (Vermelho - Opcional)
    if (_pontoDestino != null) {
      newMarkers.add(
        Marker(
          markerId: const MarkerId('destino'),
          position: _pontoDestino!.location,
          infoWindow: const InfoWindow(title: "Destino Final"),
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
        ),
      );
    }

    if (mounted) {
      setState(() {
        _markers = newMarkers;
      });
    }
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
                      hintText: "Buscar por CEP ou Endereço...",
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
                onPressed: _mostrarOpcoesOtimizacao,
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
            // Localize o seu _buildBotoesAcao e mude apenas estas duas linhas:
            // No seu Row de botões:
            _botaoPequeno(
              _enderecoInicio != null ? "INÍCIO OK" : "INÍCIO",
              () => _dialogBuscaCep("partida"), // Chama a sua função de CEP
              Colors.green,
            ),

            const SizedBox(width: 5),

            _botaoPequeno(
              "+ PARADA",
              () => _dialogBuscaCep("parada"),
              _corPrimaria,
            ),

            const SizedBox(width: 5),

            _botaoPequeno(
              _enderecoFim != null ? "FIM OK" : "FIM",
              () => _dialogBuscaCep("destino"), // Chama a sua função de CEP
              Colors.red,
            ),
            
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
                      key: ValueKey(ponto.id),
                      dense: true,
                      // 🎯 CLIQUE PARA DESFAZER
                      onTap: () {
                        if (ponto.concluida) {
                          _dialogDesfazerEntrega(i);
                        }
                      },
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
                          decoration: ponto.concluida ? TextDecoration.lineThrough : TextDecoration.none,
                          color: ponto.concluida ? Colors.grey : Colors.black,
                        ),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (!ponto.concluida)
                            IconButton(
                              icon: const Icon(Icons.remove_circle_outline, color: Colors.red, size: 20),
                              onPressed: () {
                                setState(() {
                                  _paradasIntermediarias.removeAt(i);
                                });
                                _carregarRotaNoMapa();
                                _atualizarOrdemNoFirebase();
                              },
                            ),
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

  // Adicionamos o {Key? key} entre chaves para torná-lo um parâmetro nomeado opcional
  Widget _buildAreaMapa({required Key key}) {
    // Exigimos a Key agora
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.30,
      child: GoogleMap(
        key: const ValueKey("mapa_reduzido_padrao"),
        initialCameraPosition: CameraPosition(
          target: _pontoPartida?.location ?? const LatLng(-23.5505, -46.6333),
          zoom: 12,
        ),
        onMapCreated: (controller) => _mapController = controller,
        markers: _markers,
        polylines: _polylines,
        myLocationEnabled: true,
      ),
    );
  }



  Widget _buildAreaMapaFull() {
    return GoogleMap(
      key: const ValueKey("MAPA_ESTATICO_NORMAL_PRO"),
      initialCameraPosition: CameraPosition(
        target: _pontoPartida?.location ?? const LatLng(-23.5505, -46.6333),
        zoom: 14,
      ),
      onMapCreated: (controller) {
        _mapController = controller;
        // No modo full, damos um ajuste de câmera imediato
        Future.delayed(const Duration(milliseconds: 300), () {
          _ajustarCameraMapa();
        });
      },
      // IMPORTANTE: Manter os mesmos markers e polylines para os endereços aparecerem
      markers: _markers,
      polylines: _polylines,
      myLocationEnabled: true,
      // No modo desenho, o mapa fica "congelado" para o dedo riscar a tela
      scrollGesturesEnabled: !_lockMap,
      zoomGesturesEnabled: !_lockMap,
      rotateGesturesEnabled: false,
      tiltGesturesEnabled: false,
    );
  }

  //funcao desfazer endereço marcado como concluido
  void _dialogDesfazerEntrega(int index) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Desfazer Conclusão?"),
        content: Text(
          "Deseja marcar a entrega em '${_paradasIntermediarias[index].address}' como pendente novamente?",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("CANCELAR"),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
            onPressed: () async {
              Navigator.pop(context); // Fecha o diálogo

              setState(() {
                _paradasIntermediarias[index].concluida = false;
                // Opcional: ajustar o índice atual para voltar a esta entrega
                _indiceEntregaAtual = index;
              });

              // Atualiza o Firebase para persistir a mudança
              if (_rotaAtivaDocId != null) {
                try {
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
                  _notificar("Entrega reaberta com sucesso!");
                } catch (e) {
                  print("Erro ao desfazer no Firebase: $e");
                }
              }
            },
            child: const Text("SIM, DESFAZER"),
          ),
        ],
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
                    // 🎯 MUDANÇA AQUI: Interceptamos o clique para mostrar o aviso de privacidade
                    onPressed: () async {
                      if (textoBotao == "INICIAR") {
                        // 1. Abre a "memória" do celular
                        final prefs = await SharedPreferences.getInstance();
                        
                        // 2. Verifica se ele já aceitou a privacidade (valor padrão é false)
                        bool jaAceitouPrivacidade = prefs.getBool('privacidade_aceita') ?? false;

                        if (jaAceitouPrivacidade) {
                          // Se já aceitou antes, vai direto para a verificação técnica/GPS
                          _solicitarPermissaoTecnica();
                        } else {
                          // Se é a primeira vez, mostra o aviso da GP Solução
                          _exibirAvisoPrivacidade(context);
                        }
                      } else {
                        _avancarParaProximaEntrega();
                      }
                    },
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
              final ponto = _paradasIntermediarias[i];

              return ListTile(
                key: ValueKey(ponto.id),
                // 🎯 CLIQUE PARA DESFAZER (Sincronizado)
                onTap: () {
                  if (ponto.concluida) {
                    _dialogDesfazerEntrega(i);
                  }
                },
                leading: CircleAvatar(
                  backgroundColor: ponto.concluida
                      ? Colors.grey
                      : (ponto.tipo == "COLETA" ? Colors.green : _corDestaque),
                  child: ponto.concluida
                      ? const Icon(Icons.check, color: Colors.white, size: 15)
                      : Text("${i + 1}", style: const TextStyle(color: Colors.white, fontSize: 12)),
                ),
                title: Text(
                  ponto.address,
                  style: TextStyle(
                    fontSize: 12,
                    color: ponto.concluida ? Colors.grey : Colors.black,
                    decoration: ponto.concluida ? TextDecoration.lineThrough : TextDecoration.none,
                  ),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
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
              _gerarRelatorioDiario();
            },
          ),
          ListTile(
            leading: const Icon(Icons.calendar_month, color: Colors.red),
            title: const Text("Relatório Mensal (Fechamento)"),
            onTap: () {
              Navigator.pop(context);
              // Gera do mês atual começando no dia 1
              _gerarRelatorioMensal(context);//
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


  // FUNCAO EXIBIR AVISO DE PRIVACIDADE ANTES DE INICIAR A ROTA
  void _exibirAvisoPrivacidade(BuildContext context) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(15),
          ),
          title: const Text("🛡️ GP Roteiriza - Privacidade"),
          content: const Text(
            "Para o funcionamento do GP Roteiriza, a GP Solução coleta dados de localização para permitir "
            "o monitoramento da carga e a atualização do status de entrega em tempo real para o TMS, "
            "inclusive quando o app está fechado ou não está em uso (em segundo plano).\n\n"
            "Deseja permitir a coleta para iniciar a rota?",
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text(
                "AGORA NÃO",
                style: TextStyle(color: Colors.grey),
              ),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue[900],
              ),
              onPressed: () async {
                // 1. Salva na memória que o usuário aceitou
                final prefs = await SharedPreferences.getInstance();
                await prefs.setBool('privacidade_aceita', true);
                Navigator.pop(context);
                // 🚀 Após concordar, o app inicia a rota de fato!
                _solicitarPermissaoTecnica();
              },
              child: const Text("CONCORDAR E INICIAR"),
              
            ),
          ],
        );
      },
    );
  }

  //FUNCAO PARA SOLICITAR PERMISSÃO DE LOCALIZAÇÃO (APÓS O USUÁRIO CONCORDAR COM O AVISO)
  Future<void> _solicitarPermissaoTecnica() async {
    print("🚨 Aguardando foco da janela...");
    
    // 1. Dá um tempo para o diálogo fechar e o foco voltar para a MainActivity
    await Future.delayed(const Duration(milliseconds: 500));

    // 2. Tenta pedir a permissão básica
    var statusInUse = await Permission.locationWhenInUse.request();
    print("📡 Status 'Durante o uso' após delay: $statusInUse");

    if (statusInUse.isGranted) {
      // 3. Pede a de segundo plano (Sempre permitir)
      var statusAlways = await Permission.locationAlways.request();
      
      if (statusAlways.isGranted) {
        _avancarParaProximaEntrega();
      } else {
        _mostrarAvisoConfiguracaoManual();
      }
    } 
    else if (statusInUse.isPermanentlyDenied) {
      // Se o usuário negou várias vezes, o Android trava. Temos que abrir as configurações.
      _mostrarAvisoConfiguracaoManual();
    }
    else {
      _notificar("O Android negou o pedido. Tente clicar em INICIAR novamente.", cor: Colors.orange);
    }
  }

  void _mostrarAvisoConfiguracaoManual() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
        title: const Text("⚠️ Ação Necessária"),
        content: const Text(
          "Para o GP Roteiriza funcionar, você precisa ativar a localização manualmente:\n\n"
          "1. Clique em 'ABRIR CONFIGURAÇÕES'\n"
          "2. Vá em 'Permissões'\n"
          "3. Selecione 'Localização'\n"
          "4. Marque 'PERMITIR O TEMPO TODO'",
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.blue[800]),
            onPressed: () async {
              // 🎯 Adicionamos o async
              Navigator.pop(context); // Fecha o diálogo

              // Aguarda um milésimo de segundo para o diálogo fechar totalmente
              await Future.delayed(const Duration(milliseconds: 200));

              // Chama o comando de abrir as configurações
              bool abriu = await openAppSettings();

              if (!abriu) {
                _notificar(
                  "Não foi possível abrir as configurações automaticamente.",
                  cor: Colors.red,
                );
              }
            },
            child: const Text(
              "ABRIR CONFIGURAÇÕES",
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
  
  // funçao limpar rota total
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
  void _notificar(String msg, {Color cor = Colors.blue}) {
    // 🎯 Usa a chave global para garantir que NADA fique travado
    messengerKey.currentState?.clearSnackBars(); 
    messengerKey.currentState?.showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: cor,
        duration: const Duration(seconds: 3),
        behavior: SnackBarBehavior.floating, // Flutua para não bugar com o teclado
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


class RouteDrawingPainter extends CustomPainter {
  final List<Offset> currentPath;

  RouteDrawingPainter(this.currentPath);

  @override
  void paint(Canvas canvas, Size size) {
    if (currentPath.length < 2) return;

    final paint = Paint()
      ..color = Colors.blue
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = 4.0;

    Path path = Path()..moveTo(currentPath.first.dx, currentPath.first.dy);
    for (var point in currentPath) {
      path.lineTo(point.dx, point.dy);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant RouteDrawingPainter oldDelegate) => true;
}
