import 'dart:convert';
import 'dart:io';

import 'settings_manager.dart';

/// 웹서버를 통해 override나 setting 업데이트를 처리
class OverrideServer {
  String? restrictionOverride;

  void start(int listenPort, SettingsManager settingsManager) async {
    try {
      var server = await HttpServer.bind(InternetAddress.anyIPv4, listenPort);
      print("$listenPort 포트로 웹서버 실행중");

      await for (HttpRequest request in server) {
        try {
          // CORS 헤더
          request.response.headers.add('Access-Control-Allow-Origin', '*');
          request.response.headers.add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
          request.response.headers.add('Access-Control-Allow-Headers', 'Content-Type');

          // OPTIONS(Preflight) 처리
          if (request.method == 'OPTIONS') {
            request.response.statusCode = HttpStatus.ok;
            await request.response.close();
            continue;
          }

          if (request.uri.path == '/checkSetting') {
            // setting.json 존재 여부 확인
            bool exists = File('assets/setting.json').existsSync();
            request.response.write(exists ? '1' : '0');
            await request.response.close();
          } 
          else if (request.uri.path == '/updateSetting' && request.method == 'POST') {
            // POST로 전달된 JSON으로 setting.json 갱신
            String body = await utf8.decoder.bind(request).join();
            try {
              var newCfg = jsonDecode(body);
              await File('assets/setting.json').writeAsString(jsonEncode(newCfg));
              settingsManager.settings = newCfg;
              print("setting.json 업데이트 + 재로드 완료");
              request.response.write("OK");
            } catch (e) {
              request.response.write("ERROR: $e");
            }
            await request.response.close();
          } 
          else {
            // ?value=10/11/20 override
            String? value = request.uri.queryParameters["value"];
            if (value != null) {
              restrictionOverride = value;
              print("Override set to $value");
              request.response.write("Override set to $value");
            } else {
              request.response.write("No value provided");
            }
            await request.response.close();
          }
        } catch (e) {
          request.response.statusCode = HttpStatus.internalServerError;
          request.response.write("Error: $e");
          await request.response.close();
        }
      }
    } catch (e) {
      print("웹서버 시작 에러: $e");
    }
  }
}
