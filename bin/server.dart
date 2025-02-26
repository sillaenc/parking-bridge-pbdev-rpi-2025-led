import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

// 전역 변수
String? lastCombinedCommand;
Map<String, dynamic> settings = {};
String? restrictionOverride;

// 공휴일 정보를 저장할 집합: "YYYYMMDD" 문자열, TEXT 형태로 옴..
final Set<String> holidaySet = {};

// 설정 파일 로드 (assets/setting.json)
Future<Map<String, dynamic>> loadSettings() async {
  try {
    String content = await File('assets/setting.json').readAsString();
    return json.decode(content);
  } catch (e) {
    print("Error loading assets/setting.json: $e");
    return {};
  }
}

/// 공휴일 정보 업데이트 함수
/// db_url로 POST 요청: body => {"transaction":[{"query":"#holimoli"}]}
/// 응답 예시: [{"uid":"holy0001","name":"신정","date":"20250101"}, ...]
Future<void> updateHolidayInfo() async {
  String? url = settings["db_url"]?.toString();
  if (url == null || url.isEmpty) {
    print("No db_url in settings. Skipping holiday update.");
    return;
  }

  var headers = {'Content-Type': 'application/json'};
  var body = {
    "transaction": [
      {"query": "#holimoli"}
    ]
  };

  try {
    var resp = await http.post(
      Uri.parse(url),
      headers: headers,
      body: jsonEncode(body),
    );

    print("공휴일 api 응답코드: ${resp.statusCode}");
    print("공휴일 API 내용: ${resp.body}");

    if (resp.statusCode == 200) {
      // 최상위 JSON 파싱
      var raw = jsonDecode(resp.body);
      // raw: { "results": [ { "success":true, "resultSet": [...], ... } ] }
      // 결과 배열 찾기
      if (raw is Map && raw["results"] is List) {
        List<dynamic> results = raw["results"];
        if (results.isNotEmpty && results[0] is Map) {
          Map firstResult = results[0];
          // firstResult: { "success":true, "resultSet":[...], ... }
          if (firstResult["resultSet"] is List) {
            List<dynamic> resultSet = firstResult["resultSet"];
            // resultSet: [{ "uid":1,"name":"1월1일","date":"20250101"}, ... ]
            holidaySet.clear();
            for (var item in resultSet) {
              if (item is Map && item["date"] is String) {
                String dateStr = item["date"].trim(); // "20250101"
                if (dateStr.length == 8) {
                  holidaySet.add(dateStr);
                }
              }
            }
            print("공휴일 정보 업데이트 완료: $holidaySet");
          } else {
            print("공휴일 정보 없음. 에러!1");
          }
        } else {
          print("공휴일 정보 없음. 에러!2");
        }
      } else {
        print("R공휴일 정보 없음. 에러!3");
      }
    } else {
      print("공휴일 정보 없음. 에러!4");
    }
  } catch (e) {
    print("공휴일 정보 업데이트 예외상황 발생: $e");
  }
}

/// 웹서버 (포트 8888) → GET ?value=10/11/20 등으로 override
/// 10은 짝수, 11은 홀수, 20은 다시 5부제로 돌아가는 명령어
void startOverrideServer() async {
  int listenPort = int.tryParse(settings["listen_port"]?.toString() ?? "") ?? 8888;
  try {
    var server = await HttpServer.bind(InternetAddress.anyIPv4, listenPort);
    print("$listenPort 포트로 웹서버 실행중");
    await for (HttpRequest request in server) {
      try {
        String? value = request.uri.queryParameters["value"];
        if (value != null) {
          restrictionOverride = value;
          print("Override set to $value");
          request.response.write("Override set to $value");
        } else {
          request.response.write("No value provided");
        }
      } catch (e) {
        request.response.statusCode = HttpStatus.internalServerError;
        request.response.write("Error: $e");
      } finally {
        await request.response.close();
      }
    }
  } catch (e) {
    print("웹서버 시작 에러 발생: $e");
  }
}

// line{n}Text → n
int extractLineNumber(String key) {
  RegExp regExp = RegExp(r'line(\d+)Text');
  Match? match = regExp.firstMatch(key);
  if (match != null) {
    return int.parse(match.group(1)!);
  }
  return 0;
}

Future<void> main() async {
  // 설정 파일 로드
  settings = await loadSettings();
  // 공휴일 정보 업데이트 (프로그램 시작 시 1회)
  await updateHolidayInfo();

  // override 웹서버 시작
  startOverrideServer();

  // 2초마다 실행
  Timer.periodic(Duration(seconds: 2), (timer) async {
    await runPeriodicTask();
  });
}

/// 주기적으로 실행되는 메인 로직
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

    // line 설정
    Map<String, dynamic> lineSettings = settings["line"] ?? {};
    List<MapEntry<String, dynamic>> entries = lineSettings.entries.toList();
    entries.sort((a, b) => extractLineNumber(a.key).compareTo(extractLineNumber(b.key)));

    // 각 줄에 대한 명령문 생성
    List<String> commands = [];
    for (var entry in entries) {
      int lineNum = extractLineNumber(entry.key);
      String settingValue = entry.value.toString();

      // 줄 텍스트 (비동기)
      String text = await getLineText(settingValue, mainData);

      // 색상
      String defaultColor = "C${lineNum.toString().padLeft(2, '0')}";
      String color = getLineColor(settingValue, defaultColor: defaultColor);

      // 명령문
      String command = constructCommand(lineNum, text, color);
      commands.add(command);
    }

    String combinedCommand = commands.join("");
    // print("Combined command: $combinedCommand");
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

/// 줄 텍스트 결정
/// - "5부제"가 포함되어 있으면 5부제 로직
/// - 그 외 lot_type들 합산 (F/B로 시작하면 서브 API)
Future<String> getLineText(String settingValue, List<dynamic> mainData) async {
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
  return sum.toString().padLeft(3, '0');
}

/// lot_type이 F/B로 시작 → 서브 API
/// 아니면 mainData에서 합산
Future<int> getLotCount(String lotTypeStr, List<dynamic> mainData) async {
  String trimmed = lotTypeStr.trim();
  if (trimmed.isEmpty) return 0;

  // F/B로 시작하면 서브 API
  if (trimmed.startsWith("F") || trimmed.startsWith("B")) {
    final resp = await HttpClient()
        .getUrl(Uri.parse("http://localhost:8080/billboard/$trimmed"))
        .then((req) => req.close());
    String body = await resp.transform(utf8.decoder).join();
    List<dynamic> subData = json.decode(body);
    // subData 모든 count 합산
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

/// 색상 결정
String getLineColor(String settingValue, {String defaultColor = "C01"}) {
  ParsedSetting parsed = parseLineSetting(settingValue);
  bool hasFiveBuJe = parsed.lotParts.any((lot) => lot.trim().toLowerCase() == "5부제");
  
  // 5부제여도 사용자 지정 색상이 있으면 그걸 쓰고,
  // 없으면 defaultColor 사용.
  if (hasFiveBuJe) {
    return parsed.color.isNotEmpty ? parsed.color : defaultColor;
  } else {
    return parsed.color.isNotEmpty ? parsed.color : defaultColor;
  }
}

/// 5부제 (요일)
String getFiveRestrictionText() {
  // override 처리
  if (restrictionOverride != null) {
    if (restrictionOverride == "10") {
      return "짝수";
    } else if (restrictionOverride == "11") {
      return "홀수";
    } else if (restrictionOverride == "20") {
      // override 해제
      restrictionOverride = null;
      // 이어서 원래 5부제 로직 적용
    }
  }
  
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

/// 공휴일 판별 (holidaySet 사용)
/// holidaySet에는 "YYYYMMDD" 형태로 저장
bool isPublicHoliday(DateTime date) {
  String yyyymmdd = formatYYYYMMDD(date); 
  return holidaySet.contains(yyyymmdd);
}

/// 날짜를 "YYYYMMDD"로 포매팅
String formatYYYYMMDD(DateTime date) {
  return "${date.year}${date.month.toString().padLeft(2,'0')}${date.day.toString().padLeft(2,'0')}";
}

/// 설정 문자열 파싱 ("1+4, C03" → lotParts=["1","4"], color="C03")
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
  // '+'로 분리
  List<String> lotList = lotPart.split('+').map((s) => s.trim()).toList();
  return ParsedSetting(lotParts: lotList, color: color);
}

/// 파싱된 설정
class ParsedSetting {
  List<String> lotParts;
  String color;
  ParsedSetting({required this.lotParts, required this.color});
}

/// TCP 소켓 전송
Future<void> sendPacket(Uint8List packet) async {
  String ip = settings["IP"] ?? "192.168.0.214";
  int port = int.tryParse(settings["PORT"] ?? "5000") ?? 5000;
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

/// 패킷 생성
Uint8List buildPacketWithType(String command, int type) {
  List<int> dataBytes = utf16leEncode(command);
  int dataLength = dataBytes.length;
  List<int> packet = [];
  const int STX = 0x02;
  packet.add(STX);
  packet.add(type);
  packet.add(dataLength & 0xFF);
  packet.add((dataLength >> 8) & 0xFF);
  packet.addAll(dataBytes);
  int checksum = (STX +
      type +
      (dataLength & 0xFF) +
      ((dataLength >> 8) & 0xFF) +
      dataBytes.fold<int>(0, (prev, byte) => prev + byte)) &
      0xFF;
  packet.add(checksum);
  packet.add(0x03);
  return Uint8List.fromList(packet);
}

/// UTF-16LE 인코딩
List<int> utf16leEncode(String input) {
  List<int> bytes = [];
  for (int codeUnit in input.codeUnits) {
    bytes.add(codeUnit & 0xFF);       
    bytes.add((codeUnit >> 8) & 0xFF); 
  }
  return bytes;
}

/// 광고 명령문
String constructCommand(int line, String text, String colorCode) {
  return "RST=1,LNE=$line,YSZ=1,EFF=090009000900,FIX=0,TXT=\$$colorCode\$F00\$A00$text,";
}

/// 바이트 배열 → 16진수 (디버깅용)
String _bytesToHex(List<int> bytes) {
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(" ");
}