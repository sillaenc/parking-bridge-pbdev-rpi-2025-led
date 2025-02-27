import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'holiday.dart';          // isPublicHoliday
import 'override_server.dart';  // restrictionOverride
import 'config.dart';           // settings

/// 5부제 + override
String getFiveRestrictionText() {
  if (restrictionOverride != null) {
    if (restrictionOverride == "10") {
      return "짝수";
    } else if (restrictionOverride == "11") {
      return "홀수";
    } else if (restrictionOverride == "20") {
      restrictionOverride = null;
    }
  }
  // 원래 5부제 로직
  DateTime now = DateTime.now();
  if (isPublicHoliday(now)) {
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

/// 줄 텍스트 결정
Future<String> getLineText(String settingValue, List<dynamic> mainData) async {
  int digits = int.tryParse(settings["digits"]?.toString() ?? "") ?? 3;
  ParsedSetting parsed = parseLineSetting(settingValue);

  // 5부제?
  if (parsed.lotParts.any((lot) => lot.trim().toLowerCase() == "5부제")) {
    return getFiveRestrictionText();
  }
  // 합산
  int sum = 0;
  for (String lot in parsed.lotParts) {
    sum += await getLotCount(lot, mainData);
  }
  return sum.toString().padLeft(digits, '0');
}

/// lot_type이 F/B로 시작하면 서브 API, 아니면 mainData에서 합산
Future<int> getLotCount(String lotTypeStr, List<dynamic> mainData) async {
  String trimmed = lotTypeStr.trim();
  if (trimmed.isEmpty) return 0;

  if (trimmed.startsWith("F") || trimmed.startsWith("B")) {
    final resp = await HttpClient()
        .getUrl(Uri.parse("http://localhost:8080/billboard/$trimmed"))
        .then((req) => req.close());
    String body = await resp.transform(utf8.decoder).join();
    List<dynamic> subData = json.decode(body);
    int sum = 0;
    for (var item in subData) {
      if (item is Map && item.containsKey('count')) {
        if (item['count'] is int) {
          sum += item['count'] as int;
        } else {
          sum += int.tryParse(item['count'].toString()) ?? 0;
        }
      }
    }
    return sum;
  } else {
    // 일반 lot_type → mainData에서 합산
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
  bool hasFiveBuJe = parsed.lotParts.any((lot) => lot.trim().toLowerCase() == "5부제");
  if (hasFiveBuJe) {
    // 5부제라도 사용자 지정 색상 있으면 그걸 사용
    return parsed.color.isNotEmpty ? parsed.color : defaultColor;
  } else {
    return parsed.color.isNotEmpty ? parsed.color : defaultColor;
  }
}

/// 설정 문자열 파싱
class ParsedSetting {
  List<String> lotParts;
  String color;
  ParsedSetting({required this.lotParts, required this.color});
}

ParsedSetting parseLineSetting(String settingStr) {
  // 예: "5부제, C01" → lotParts=["5부제"], color="C01"
  // 예: "1+4, C03"  → lotParts=["1","4"], color="C03"
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
  // '+'로 분리
  List<String> lotList = lotPart.split('+').map((s) => s.trim()).toList();
  return ParsedSetting(lotParts: lotList, color: color);
}
