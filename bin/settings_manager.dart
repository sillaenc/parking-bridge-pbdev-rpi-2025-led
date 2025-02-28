import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 설정 파일 관련 처리
class SettingsManager {
  Map<String, dynamic> settings = {};

  /// listen_port.json에서 포트를 읽어옴. 없으면 기본 8888
  Future<int> loadListenPort() async {
    try {
      String content = await File('assets/listen_port.json').readAsString();
      Map<String, dynamic> obj = jsonDecode(content);
      int port = int.tryParse(obj["listen_port"]?.toString() ?? "") ?? 8888;
      print("listen_port.json에서 포트=$port 로드됨");
      return port;
    } catch (e) {
      print("listen_port.json 없거나 오류. 기본 포트 8888 사용. 에러: $e");
      return 8888;
    }
  }

  /// setting.json 로드 (없으면 1분마다 재시도)
  Future<Map<String, dynamic>> loadSettingsLoop() async {
    while (true) {
      try {
        String content = await File('assets/setting.json').readAsString();
        Map<String, dynamic> cfg = jsonDecode(content);
        print("setting.json 로드 성공");
        settings = cfg;
        return cfg;
      } catch (e) {
        print("setting.json 없음. 1분 뒤 재시도... 에러: $e");
        await Future.delayed(Duration(minutes: 1));
      }
    }
  }
}
