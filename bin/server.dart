import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

// --------------------- 전역 변수 ---------------------
Map<String, dynamic> settings = {};          // setting.json의 내용
String? restrictionOverride;                // override 값
String? lastCombinedCommand;                // 이전 패킷

final Set<String> holidaySet = {};          // 공휴일(YYYYMMDD)

// --------------------- main 함수 ---------------------
Future<void> main() async {
  // 1) listen_port.json에서 포트 읽기
  int listenPort = await loadListenPort();

  // 2) 웹서버 시작 (override, /updateSetting, /checkSetting 라우터)
  startOverrideServer(listenPort);

  // 3) setting.json 로드 (없으면 1분마다 재시도)
  settings = await loadSettingsLoop();

  // 4) 공휴일 정보 업데이트
  await updateHolidayInfo();

  // 5) 2초마다 메인 로직
  Timer.periodic(Duration(seconds: 2), (timer) async {
    await runPeriodicTask();
  });
}

// --------------------- 1) listen_port.json 로드 ---------------------
Future<int> loadListenPort() async {
  try {
    String content = await File('assets/listen_port.json').readAsString();
    Map<String, dynamic> obj = jsonDecode(content);
    int p = int.tryParse(obj["listen_port"]?.toString() ?? "") ?? 8888;
    print("listen_port.json에서 포트=$p 로드됨");
    return p;
  } catch (e) {
    print("listen_port.json 없거나 오류. 기본 포트 8888 사용. 에러: $e");
    return 8888;
  }
}

// --------------------- 2) 웹서버 시작 ---------------------
void startOverrideServer(int listenPort) async {
  try {
    var server = await HttpServer.bind(InternetAddress.anyIPv4, listenPort);
    print("$listenPort 포트로 웹서버 실행중");

    await for (HttpRequest request in server) {
      try {
        // 라우터 구분
        request.response.headers.add('Access-Control-Allow-Origin', '*');
        request.response.headers.add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
        request.response.headers.add('Access-Control-Allow-Headers', 'Content-Type');
        
        if (request.uri.path == '/checkSetting') {
          // setting.json 존재 여부 확인
          bool exists = File('assets/setting.json').existsSync();
          request.response.write(exists ? '1' : '0');
          await request.response.close();
        }
        else if (request.uri.path == '/updateSetting' && request.method == 'POST') {
          // body의 JSON으로 setting.json 갱신
          String body = await utf8.decoder.bind(request).join();
          try {
            var newCfg = jsonDecode(body);
            // 파일에 덮어쓰기
            await File('assets/setting.json').writeAsString(jsonEncode(newCfg));
            // 메모리상 settings도 갱신
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

// --------------------- 3) setting.json 로드(재시도) ---------------------
Future<Map<String, dynamic>> loadSettingsLoop() async {
  while (true) {
    try {
      String content = await File('assets/setting.json').readAsString();
      Map<String, dynamic> cfg = jsonDecode(content);
      print("setting.json 로드 성공");
      return cfg;
    } catch (e) {
      print("setting.json 없음. 1분 뒤 재시도... 에러: $e");
      await Future.delayed(Duration(minutes: 1));
    }
  }
}

// --------------------- 4) 공휴일 업데이트 ---------------------
Future<void> updateHolidayInfo() async {
  String? url = settings["db_url"]?.toString();
  if (url == null || url.isEmpty) {
    print("db_url 없음, 공휴일 업데이트 스킵");
    return;
  }

  var headers = {'Content-Type': 'application/json'};
  var body = {
    "transaction": [
      {"query": "#holimoli"}
    ]
  };

  try {
    var resp = await http.post(Uri.parse(url), headers: headers, body: jsonEncode(body));
    print("공휴일 API 응답코드: ${resp.statusCode}");
    print("공휴일 API 내용: ${resp.body}");

    if (resp.statusCode == 200) {
      var raw = jsonDecode(resp.body);
      if (raw is Map && raw["results"] is List) {
        List<dynamic> results = raw["results"];
        if (results.isNotEmpty && results[0] is Map) {
          Map firstResult = results[0];
          if (firstResult["resultSet"] is List) {
            List<dynamic> resultSet = firstResult["resultSet"];
            holidaySet.clear();
            for (var item in resultSet) {
              if (item is Map && item["date"] is String) {
                String dateStr = item["date"].trim();
                if (dateStr.length == 8) {
                  holidaySet.add(dateStr);
                }
              }
            }
            print("공휴일 업데이트 완료: $holidaySet");
          }
        }
      }
    }
  } catch (e) {
    print("공휴일 업데이트 예외상황: $e");
  }
}

// --------------------- 5) 2초마다 실행되는 메인 로직 ---------------------
Future<void> runPeriodicTask() async {
  try {
    String floor = settings["floor"]?.toString() ?? "F1";
    // 메인 API 호출
    final response = await HttpClient()
        .getUrl(Uri.parse("http://localhost:8080/billboard/$floor"))
        .then((req) => req.close());
    String responseBody = await response.transform(utf8.decoder).join();
    List<dynamic> mainData = json.decode(responseBody);

    // line은 배열. ex: [ {"text":"5부제, C01"}, {"text":"1, C03"}, ... ]
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

    // 패킷 생성/전송
    Uint8List packet = buildPacketWithType(combinedCommand, 0x84);
    await sendPacket(packet);
  } catch (e) {
    print("Error in runPeriodicTask: $e");
  }
}

// --------------------- 줄 텍스트 결정 ---------------------
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

// --------------------- lot_type 합산 ---------------------
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
    int sum = 0;
    for (var item in mainData) {
      if (item is Map && item.containsKey('lot_type') && item.containsKey('count')) {
        String itemLotTypeStr = item['lot_type'].toString();
        if (itemLotTypeStr == trimmed) {
          if (item['count'] is int) {
            sum += item['count'] as int;
          } else {
            sum += int.tryParse(item['count'].toString()) ?? 0;
          }
        }
      }
    }
    return sum;
  }
}

// --------------------- 색상 결정 ---------------------
String getLineColor(String settingValue, String defaultColor) {
  ParsedSetting parsed = parseLineSetting(settingValue);
  bool hasFiveBuJe = parsed.lotParts.any((lot) => lot.trim().toLowerCase() == "5부제");
  if (hasFiveBuJe) {
    // 5부제도 사용자 지정 색상 있으면 그걸 사용
    return parsed.color.isNotEmpty ? parsed.color : defaultColor;
  } else {
    return parsed.color.isNotEmpty ? parsed.color : defaultColor;
  }
}

// --------------------- 5부제 + override 로직 ---------------------
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

// --------------------- 공휴일 판별 ---------------------
bool isPublicHoliday(DateTime date) {
  String yyyymmdd = formatYYYYMMDD(date);
  return holidaySet.contains(yyyymmdd);
}

String formatYYYYMMDD(DateTime date) {
  return "${date.year}${date.month.toString().padLeft(2,'0')}${date.day.toString().padLeft(2,'0')}";
}

// --------------------- 설정 문자열 파싱 ---------------------
ParsedSetting parseLineSetting(String settingStr) {
  // 예: "5부제, C01" → lotPart="5부제", color="C01"
  // 예: "1+4, C03"  → lotPart="1+4", color="C03"
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

class ParsedSetting {
  List<String> lotParts;
  String color;
  ParsedSetting({required this.lotParts, required this.color});
}

// --------------------- TCP 소켓 전송 ---------------------
Future<void> sendPacket(Uint8List packet) async {
  String ip = settings["IP"] ?? "192.168.0.214";
  int port = int.tryParse(settings["PORT"]?.toString() ?? "5000") ?? 5000;
  try {
    Socket socket = await Socket.connect(ip, port, timeout: Duration(seconds: 3));
    print("Socket connected to $ip:$port");
    print("Sending packet: ${_bytesToHex(packet)}");
    socket.add(packet);
    await socket.flush();
    socket.listen((data) {
      print("Received: ${_bytesToHex(data)}");
    }, onError: (e) {
      print("Socket error: $e");
    }, onDone: () {
      print("Socket closed");
    });
    await Future.delayed(Duration(seconds: 1));
    socket.destroy();
    print("Socket destroyed");
  } catch (e) {
    print("Socket error: $e");
  }
}

// --------------------- 패킷 생성 ---------------------
Uint8List buildPacketWithType(String command, int type) {
  List<int> dataBytes = utf16leEncode(command);
  int dataLength = dataBytes.length;
  List<int> packet = [];
  const int STX = 0x02;
  packet.add(STX);
  packet.add(type);
  // LENGTH(2바이트, little-endian)
  packet.add(dataLength & 0xFF);
  packet.add((dataLength >> 8) & 0xFF);
  packet.addAll(dataBytes);

  int checksum = (STX +
      type +
      (dataLength & 0xFF) +
      ((dataLength >> 8) & 0xFF) +
      dataBytes.fold<int>(0, (prev, b) => prev + b)) &
      0xFF;
  packet.add(checksum);
  packet.add(0x03);
  return Uint8List.fromList(packet);
}

// --------------------- UTF-16LE 인코딩 ---------------------
List<int> utf16leEncode(String input) {
  List<int> bytes = [];
  for (int codeUnit in input.codeUnits) {
    bytes.add(codeUnit & 0xFF);       // 하위 바이트
    bytes.add((codeUnit >> 8) & 0xFF); // 상위 바이트
  }
  return bytes;
}

// --------------------- 광고 명령문 ---------------------
String constructCommand(int line, String text, String colorCode) {
  return "RST=1,LNE=$line,YSZ=1,EFF=090009000900,FIX=0,TXT=\$$colorCode\$F00\$A00$text,";
}

// --------------------- 바이트 배열 → 16진수 (디버깅용) ---------------------
String _bytesToHex(List<int> bytes) {
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(" ");
}
