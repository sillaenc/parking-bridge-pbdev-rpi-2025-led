import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'config.dart';         // loadListenPort, loadSettingsLoop, settings
import 'holiday.dart';        // updateHolidayInfo, holidaySet, isPublicHoliday
import 'override_server.dart';// startOverrideServer, restrictionOverride
import 'line_logic.dart';     // getLineText, getLineColor, ...
import 'packet.dart';         // sendPacket, buildPacketWithType, ...

String? lastCombinedCommand;  // 이전 패킷 내용

Future<void> main() async {
  // 1) listen_port.json에서 포트 불러오기
  int listenPort = await loadListenPort();

  // 2) override 웹서버 시작(해당 포트)
  startOverrideServer(listenPort);

  // 3) setting.json 로드 (없으면 1분마다 재시도)
  settings = await loadSettingsLoop();

  // 4) 공휴일 정보 업데이트
  await updateHolidayInfo();

  // 5) 2초마다 메인 로직 실행
  Timer.periodic(Duration(seconds: 2), (timer) async {
    await runPeriodicTask();
  });
}

/// 2초마다 실행되는 주기적 작업
Future<void> runPeriodicTask() async {
  try {
    // floor 설정
    String floor = settings["floor"]?.toString() ?? "F1";

    // 메인 API 호출
    final response = await HttpClient()
        .getUrl(Uri.parse("http://localhost:8080/billboard/$floor"))
        .then((req) => req.close());
    String responseBody = await response.transform(utf8.decoder).join();
    List<dynamic> mainData = json.decode(responseBody);

    // line: 배열 -> 각 요소 {"text":"..."}
    List lineList = settings["line"] as List? ?? [];

    List<String> commands = [];
    for (int i = 0; i < lineList.length; i++) {
      var item = lineList[i];
      if (item is Map && item.containsKey("text")) {
        String settingValue = item["text"].toString();
        int lineNum = i + 1;

        // 줄 텍스트
        String text = await getLineText(settingValue, mainData);
        // 색상
        String defaultColor = "C${lineNum.toString().padLeft(2, '0')}";
        String color = getLineColor(settingValue, defaultColor);

        // 명령문
        String command = constructCommand(lineNum, text, color);
        commands.add(command);
      }
    }

    String combinedCommand = commands.join("");
    print("패킷 내용: $combinedCommand");

    if (combinedCommand == lastCombinedCommand) {
      print("API data 변화 없음, 전송 안함");
      return;
    }
    lastCombinedCommand = combinedCommand;

    // 패킷 전송
    Uint8List packet = buildPacketWithType(combinedCommand, 0x84);
    await sendPacket(packet);
  } catch (e) {
    print("Error in runPeriodicTask: $e");
  }
}
