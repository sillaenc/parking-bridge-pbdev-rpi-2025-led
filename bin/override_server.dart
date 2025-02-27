import 'dart:io';
import 'dart:convert';
import 'config.dart'; // settings

String? restrictionOverride;

/// 웹서버 시작
/// 라우터:
///   - /checkSetting : setting.json 존재 여부 (1/0)
///   - /updateSetting (POST) : body JSON -> setting.json 갱신
///   - ?value=10/11/20 : override
void startOverrideServer(int listenPort) async {
  try {
    var server = await HttpServer.bind(InternetAddress.anyIPv4, listenPort);
    print("$listenPort 포트로 웹서버 실행중");
    await for (HttpRequest request in server) {
      try {
        request.response.headers.add('Access-Control-Allow-Origin', '*');
        request.response.headers.add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
        request.response.headers.add('Access-Control-Allow-Headers', 'Content-Type');
        
        if (request.uri.path == '/checkSetting') {
          bool exists = File('assets/setting.json').existsSync();
          request.response.write(exists ? '1' : '0');
          await request.response.close();
        }
        else if (request.uri.path == '/updateSetting' && request.method == 'POST') {
          // body JSON -> setting.json 갱신
          String body = await utf8.decoder.bind(request).join();
          try {
            var newCfg = jsonDecode(body);
            await File('assets/setting.json').writeAsString(jsonEncode(newCfg));
            settings = newCfg;
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
