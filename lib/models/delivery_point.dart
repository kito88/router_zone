import 'package:google_maps_flutter/google_maps_flutter.dart';

class DeliveryPoint {
  final String id;
  final String address;
  final LatLng location;
  final String tipo; 
  bool concluida; // Removido o 'final' para permitir alteração

  DeliveryPoint({
    required this.id,
    required this.address,
    required this.location,
    this.tipo = 'ENTREGA',
    this.concluida = false, // Padrão sempre começa como não concluída
  });
}