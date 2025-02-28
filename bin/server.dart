import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

/// --------------------------
///  SettingsManager
/// --------------------------
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

/// --------------------------
///  OverrideServer (CORS + 설정 업데이트 + override)
/// --------------------------
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
            // setting.json 존재 여부
            bool exists = File('assets/setting.json').existsSync();
            request.response.write(exists ? '1' : '0');
            await request.response.close();
          } 
          else if (request.uri.path == '/updateSetting' && request.method == 'POST') {
            // POST로 전달된 JSON -> setting.json 갱신
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

/// --------------------------
///  HolidayManager (공휴일 업데이트/판별)
/// --------------------------
class HolidayManager {
  final Set<String> holidaySet = {};

  Future<void> updateHolidayInfo(Map<String, dynamic> settings) async {
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

  bool isPublicHoliday(DateTime date) {
    String yyyymmdd = _formatYYYYMMDD(date);
    return holidaySet.contains(yyyymmdd);
  }

  String _formatYYYYMMDD(DateTime date) {
    return "${date.year}${date.month.toString().padLeft(2,'0')}${date.day.toString().padLeft(2,'0')}";
  }
}

/// --------------------------
///  PacketUtils (패킷 구성, UTF-16LE, 명령문 등)
/// --------------------------
class PacketUtils {
  static Uint8List buildPacketWithType(String command, int type) {
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

  static List<int> utf16leEncode(String input) {
    List<int> bytes = [];
    for (int codeUnit in input.codeUnits) {
      bytes.add(codeUnit & 0xFF);
      bytes.add((codeUnit >> 8) & 0xFF);
    }
    return bytes;
  }

  static String constructCommand(int line, String text, String colorCode) {
    return "RST=1,LNE=$line,YSZ=1,EFF=090009000900,FIX=0,TXT=\$$colorCode\$F00\$A00$text,";
  }

  static String bytesToHex(List<int> bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(" ");
  }
}

/// --------------------------
///  PacketSender (TCP 전송)
/// --------------------------
class PacketSender {
  Future<void> sendPacket(Map<String, dynamic> settings, Uint8List packet) async {
    String ip = settings["IP"] ?? "192.168.0.214";
    int port = int.tryParse(settings["PORT"]?.toString() ?? "5000") ?? 5000;
    try {
      Socket socket = await Socket.connect(ip, port, timeout: Duration(seconds: 3));
      print("Socket connected to $ip:$port");
      print("Sending packet: ${PacketUtils.bytesToHex(packet)}");
      socket.add(packet);
      await socket.flush();
      socket.listen((data) {
        print("Received: ${PacketUtils.bytesToHex(data)}");
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
}

/// --------------------------
///  TaskRunner (주기적 로직) - floor를 POST + JSON으로 전송
/// --------------------------
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

/// 설정 문자열 파싱
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

/// --------------------------
/// BillboardApp (전체 흐름 관리)
/// --------------------------
class BillboardApp {
  final SettingsManager settingsManager = SettingsManager();
  final OverrideServer overrideServer = OverrideServer();
  final HolidayManager holidayManager = HolidayManager();
  final TaskRunner taskRunner = TaskRunner();

  Future<void> run() async {
    // 1) listen_port.json 로드
    int listenPort = await settingsManager.loadListenPort();
    // 2) 웹서버 시작
    overrideServer.start(listenPort, settingsManager);

    // 3) setting.json 로드 (없으면 1분마다 재시도)
    await settingsManager.loadSettingsLoop();

    // 4) 공휴일 업데이트
    await holidayManager.updateHolidayInfo(settingsManager.settings);

    // 5) 2초마다 메인 로직
    Timer.periodic(Duration(seconds: 2), (timer) async {
      await taskRunner.run(
        settingsManager.settings,
        overrideServer.restrictionOverride,
        holidayManager,
        (newVal) => overrideServer.restrictionOverride = newVal,
      );
    });
  }
}

/// --------------------------
/// main() - 프로그램 시작점
/// --------------------------
Future<void> main() async {
  BillboardApp app = BillboardApp();
  await app.run();
}
