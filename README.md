# 📍 Router Zone - Otimização Inteligente de Rotas

O **Router Zone** é um aplicativo mobile desenvolvido em Flutter focado em logística e gestão de transporte (TMS). Ele permite que motoristas e frotistas organizem suas entregas de forma eficiente, reduzindo custos de combustível e tempo de percurso através de algoritmos de roteirização.



## 🚀 Funcionalidades Principais

* **Roteirização Inteligente:** Algoritmo de proximidade (Nearest Neighbor) para ordenar paradas automaticamente.
* **Gestão de Itinerário:** Reordenação manual via *Drag and Drop* com persistência em tempo real no Firebase.
* **Busca Avançada:** Integração com API ViaCEP para localização por CEP e OpenStreetMap para endereços.
* **Comandos de Voz:** Adição de destinos via reconhecimento de voz para maior segurança ao dirigir.
* **Dashboard Financeiro:** Controle diário de ganhos líquidos, extras e despesas de rota.
* **Relatórios Profissionais:** Geração de fechamentos mensais e detalhes de rota em PDF.
* **Integração com GPS:** Atalho direto para navegação via Google Maps ou Waze.

## 🛠️ Tecnologias Utilizadas

* **Framework:** [Flutter](https://flutter.dev/)
* **Backend:** [Firebase](https://firebase.google.com/) (Firestore & Auth)
* **Mapas:** [Google Maps Flutter SDK](https://pub.dev/packages/google_maps_flutter)
* **Geolocalização:** [Geolocator](https://pub.dev/packages/geolocator) & [Geocoding](https://pub.dev/packages/geocoding)
* **APIs Externas:** ViaCEP (Brasil) & Nominatim (OSM)
* **Persistência Local:** SharedPreferences

## 📦 Como rodar o projeto

1. **Clone o repositório:**
   ```bash
   git clone [https://github.com/kito88/router_zone.git](https://github.com/kito88/router_zone.git)

#2. instale as Dependencias

flutter pub get

#3. Configure o Firebase:

* Crie um projeto no console do Firebase.

* Adicione os arquivos google-services.json (Android) e GoogleService-Info.plist (iOS).

#4. Adicione sua chave do Google Maps:

Insira sua API Key nos arquivos AndroidManifest.xml e AppDelegate.swift.

Execute o app:

flutter run



Desenvolvido por ##Francisco Gonçalves## - Focado em transformar a logística através da tecnologia.