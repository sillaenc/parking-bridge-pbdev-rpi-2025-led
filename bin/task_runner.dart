import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'packet_sender.dart';
import 'packet_utils.dart';
import 'holiday_manager.dart';
import 'override_server.dart'; // for restrictionOverride type
import 'settings_manager.dart'; // for settings

class TaskRunner {
  String? lastCombinedCommand;
  final PacketSender packetSender = PacketSender();

  Future<void> run(
    Map<String, dynamic> settings,
    String? restrictionOverride,
    HolidayManager holidayManager,
    void Function(String?) updateRestriction,
  ) async {
    try {
      // floor
      String floor = settings["floor"]?.toString() ?? "F1";

      // 1) POST 요청으로 {"floor": floor} 전송
      HttpClient client = HttpClient();
      HttpClientRequest request = await client.postUrl(
        Uri.parse("http://localhost:8080/billboard"),
      );
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode({"floor": floor}));

      HttpClientResponse resp = await request.close();
      String responseBody = await resp.transform(utf8.decoder).join();
      client.close();

      // 응답을 List<dynamic>로 파싱
      List<dynamic> mainData = json.decode(responseBody);

      // line 배열
      List lineList = settings["line"] as List? ?? [];
      List<String> commands = [];

      for (int i = 0; i < lineList.length; i++) {
        var item = lineList[i];
        if (item is Map && item.containsKey("text")) {
          String settingValue = item["text"].toString();
          int lineNum = i + 1;

          // 줄 텍스트
          String text = await getLineText(
              settingValue, settings, mainData, holidayManager, restrictionOverride, updateRestriction);
          // 색상
          String defaultColor = "C${lineNum.toString().padLeft(2, '0')}";
          String color = getLineColor(settingValue, defaultColor);
          // 명령문
          String command = PacketUtils.constructCommand(lineNum, text, color);
          commands.add(command);
        }
      }

      String combinedCommand = commands.join("");
      var time = DateTime.now();
      print(time);
      print("패킷 내용: $combinedCommand");

      if (combinedCommand == lastCombinedCommand) {
        print("API data 변화 없음, 전송 안함");
        return;
      }
      lastCombinedCommand = combinedCommand;

      // 패킷 생성/전송
      Uint8List packet = PacketUtils.buildPacketWithType(combinedCommand, 0x84);
      await packetSender.sendPacket(settings, packet);
    } catch (e) {
      print("Error in runPeriodicTask: $e");
    }
  }

  /// 줄 텍스트 결정
  Future<String> getLineText(
    String settingValue,
    Map<String, dynamic> settings,
    List<dynamic> mainData,
    HolidayManager holidayManager,
    String? restrictionOverride,
    void Function(String?) updateRestriction,
  ) async {
    int digits = int.tryParse(settings["digits"]?.toString() ?? "") ?? 3;
    ParsedSetting parsed = parseLineSetting(settingValue);

    if (parsed.lotParts.any((lot) => lot.trim().toLowerCase() == "5부제")) {
      return getFiveRestrictionText(restrictionOverride, updateRestriction, holidayManager);
    }

    int sum = 0;
    for (String lot in parsed.lotParts) {
      sum += await getLotCount(lot, mainData);
    }
    return sum.toString().padLeft(digits, '0');
  }

  /// lot_type 합산 (F/B -> 별도 API)
  Future<int> getLotCount(String lotTypeStr, List<dynamic> mainData) async {
    String trimmed = lotTypeStr.trim();
    if (trimmed.isEmpty) return 0;

    if (trimmed.startsWith("F") || trimmed.startsWith("B")) {
      HttpClient client = HttpClient();
      HttpClientRequest req = await client.postUrl(Uri.parse("http://localhost:8080/billboard"));
      req.headers.contentType = ContentType.json;
      // F2, B2 등 lotTypeStr를 JSON으로 전송
      req.write(jsonEncode({"floor": trimmed})); 
      // (만약 서버에서 billboard로 POST 시 "floor"를 key로 받는다면)

      HttpClientResponse r = await req.close();
      String body = await r.transform(utf8.decoder).join();
      client.close();

      List<dynamic> subData = json.decode(body);
      int sum = 0;
      for (var item in subData) {
        if (item is Map && item.containsKey('count')) {
          sum += (item['count'] is int)
              ? item['count'] as int
              : int.tryParse(item['count'].toString()) ?? 0;
        }
      }
      return sum;
    } else {
      // 일반 lot_type -> mainData
      int sum = 0;
      for (var item in mainData) {
        if (item is Map && item.containsKey('lot_type') && item.containsKey('count')) {
          String itemLotTypeStr = item['lot_type'].toString();
          if (itemLotTypeStr == trimmed) {
            sum += (item['count'] is int)
                ? item['count'] as int
                : int.tryParse(item['count'].toString()) ?? 0;
          }
        }
      }
      return sum;
    }
  }

  /// 색상 결정
  String getLineColor(String settingValue, String defaultColor) {
    ParsedSetting parsed = parseLineSetting(settingValue);
    return parsed.color.isNotEmpty ? parsed.color : defaultColor;
  }

  /// 5부제 + override
  String getFiveRestrictionText(
    String? restrictionOverride,
    void Function(String?) updateRestriction,
    HolidayManager holidayManager,
  ) {
    if (restrictionOverride != null) {
      if (restrictionOverride == "10") {
        return "짝수";
      } else if (restrictionOverride == "11") {
        return "홀수";
      } else if (restrictionOverride == "20") {
        updateRestriction(null);
      }
    }
    DateTime now = DateTime.now();
    if (holidayManager.isPublicHoliday(now)) {
      return "휴일";
    }
    switch (now.weekday) {
      case DateTime.monday:
        return "1/6";
      case DateTime.tuesday:
        return "2/7";
      case DateTime.wednesday:
        return "3/8";
      case DateTime.thursday:
        return "4/9";
      case DateTime.friday:
        return "5/0";
      default:
        return "XXX";
    }
  }
}
class ParsedSetting {
  List<String> lotParts;
  String color;
  ParsedSetting({required this.lotParts, required this.color});
}

ParsedSetting parseLineSetting(String settingStr) {
  List<String> parts = settingStr.split(',');
  if (parts.isEmpty) {
    return ParsedSetting(lotParts: [], color: "");
  }
  String color = parts.last.trim();
  String lotPart = "";
  if (parts.length > 1) {
    lotPart = parts.sublist(0, parts.length - 1).join(',').trim();
  }
  if (lotPart.isEmpty) {
    return ParsedSetting(lotParts: [], color: color);
  }
  List<String> lotList = lotPart.split('+').map((s) => s.trim()).toList();
  return ParsedSetting(lotParts: lotList, color: color);
}