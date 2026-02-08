import 'package:flutter_polyline_points/flutter_polyline_points.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../models/delivery_point.dart';

class GoogleMapsService {
  // 1. A chave agora deve ser passada aqui na inicialização do PolylinePoints
  final PolylinePoints _polylinePoints = PolylinePoints(
    apiKey: "AIzaSyAwZp_mX8-qMREHcGVA-K5tk2wVhKddHWc", 
  );

  Future<List<LatLng>> getRoutePoints(List<DeliveryPoint> points) async {
    if (points.length < 2) return [];

    List<LatLng> polylineCoordinates = [];

    for (int i = 0; i < points.length - 1; i++) {
      // 2. O método getRouteBetweenCoordinates NÃO precisa mais da chave aqui dentro
      PolylineResult result = await _polylinePoints.getRouteBetweenCoordinates(
        request: PolylineRequest(
          origin: PointLatLng(points[i].location.latitude, points[i].location.longitude),
          destination: PointLatLng(points[i+1].location.latitude, points[i+1].location.longitude),
          mode: TravelMode.driving,
        ),
      );

      if (result.points.isNotEmpty) {
        for (var point in result.points) {
          polylineCoordinates.add(LatLng(point.latitude, point.longitude));
        }
      }
    }
    return polylineCoordinates;
  }
}