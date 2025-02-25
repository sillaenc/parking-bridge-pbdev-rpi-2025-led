import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// 이전에 전송한 광고 명령문을 저장하는 변수
String? lastCombinedCommand;

void main() {
  // 2초마다 API 호출 및 광고 명령문 전송
  Timer.periodic(Duration(seconds: 2), (timer) async {
    try {
      // API 호출 (예: http://localhost:8080/billboard/F1)
      final response = await HttpClient()
          .getUrl(Uri.parse('http://localhost:8080/billboard/F1'))
          .then((request) => request.close());
      String responseBody = await response.transform(utf8.decoder).join();
      List<dynamic> apiData = json.decode(responseBody);

      // 각 단에 표시할 텍스트 생성
      String line1Text = getCarRestrictionText(); // 승용차요일제 (LNE=1)
      String line2Text = getCountForLot(apiData, 1);
      String line3Text = getCountForLot(apiData, 2);
      String line4Text = getCountForLot(apiData, 3);
      String line5Text = getCountForLot(apiData, 4);
      String line6Text = getF2Value(apiData);

      // 각 광고 명령문 생성 (LNE=1~6, 색상코드는 C01 ~ C06)
      List<String> commands = [
        constructCommand(1, line1Text, "C01"),
        constructCommand(2, line2Text, "C02"),
        constructCommand(3, line3Text, "C03"),
        constructCommand(4, line4Text, "C04"),
        constructCommand(5, line5Text, "C05"),
        constructCommand(6, line6Text, "C06"),
      ];

      // 6줄의 명령문을 하나의 문자열로 결합
      String combinedCommand = commands.join("");
      print("Combined command: $combinedCommand");

      // API 내용이 이전과 동일하면 전송하지 않음
      if (combinedCommand == lastCombinedCommand) {
        print("API 데이터 변동 없음 -> 전광판 전송 생략");
        return;
      }

      // 새 명령문을 저장
      lastCombinedCommand = combinedCommand;

      // 단일 INSERT 패킷 생성 (타입 0x84)
      Uint8List packet = buildPacketWithType(combinedCommand, 0x84);

      // TCP 소켓(192.168.0.214:5000)으로 패킷 전송
      await sendPacket(packet);
    } catch (e) {
      print("API 호출 중 에러 발생: $e");
    }
  });
}

/// TCP 소켓을 열어 단일 패킷을 전송하는 함수
Future<void> sendPacket(Uint8List packet) async {
  String ip = "192.168.0.214";
  int port = 5000;
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

/// 바이트 배열을 16진수 문자열로 변환 (디버깅용)
String _bytesToHex(List<int> bytes) {
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(" ");
}

/// 주어진 명령 문자열과 타입에 따라 프로토콜 패킷 생성  
/// 패킷 구조: STX(0x02), TYPE(1B), LENGTH(2B, little-endian), DATA(UTF-16LE), CHECKSUM, ETX(0x03)
Uint8List buildPacketWithType(String command, int type) {
  List<int> dataBytes = utf16leEncode(command);
  int dataLength = dataBytes.length;
  List<int> packet = [];
  const int STX = 0x02;
  packet.add(STX);
  packet.add(type);
  // 데이터 길이 2바이트 (little-endian)
  packet.add(dataLength & 0xFF);
  packet.add((dataLength >> 8) & 0xFF);
  // DATA
  packet.addAll(dataBytes);
  // CHECKSUM: (STX + TYPE + LENGTH 바이트들 + DATA 바이트들의 합)의 하위 8비트
  int checksum = (STX +
          type +
          (dataLength & 0xFF) +
          ((dataLength >> 8) & 0xFF) +
          dataBytes.fold<int>(0, (prev, byte) => prev + byte)) &
      0xFF;
  packet.add(checksum);
  // ETX
  packet.add(0x03);
  return Uint8List.fromList(packet);
}

/// 문자열을 UTF-16LE로 인코딩 (각 문자 2바이트, 하위 바이트 우선)
List<int> utf16leEncode(String input) {
  List<int> bytes = [];
  for (int codeUnit in input.codeUnits) {
    bytes.add(codeUnit & 0xFF);
    bytes.add((codeUnit >> 8) & 0xFF);
  }
  return bytes;
}

/// 광고 명령문 생성 함수  
/// 형식:  
/// RST=1,LNE={line},YSZ=1,EFF=090009000900,FIX=0,TXT=\${colorCode}\$F00\$A00{text},
String constructCommand(int line, String text, String colorCode) {
  return "RST=1,LNE=$line,YSZ=1,EFF=090009000900,FIX=0,TXT=\$$colorCode\$F00\$A00$text,";
}

/// 승용차요일제 텍스트 생성 함수  
/// - 공휴일이면 "XXX" 반환  
/// - 평일이면 요일에 따라 반환 (예시에서는 월요일: "2/7", 화요일: "3/8", 수요일: "4/9", 목요일: "5/0", 금요일: "6/1")
String getCarRestrictionText() {
  DateTime now = DateTime.now();
  if (isPublicHoliday(now)) {
    return "XXX";
  } else {
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

/// 간단한 공휴일 판별 (고정 날짜 기준)
bool isPublicHoliday(DateTime date) {
  final List<Map<String, int>> holidays = [
    {'month': 1, 'day': 1},   // 신정
    {'month': 3, 'day': 1},   // 삼일절
    {'month': 5, 'day': 5},   // 어린이날
    {'month': 8, 'day': 15},  // 광복절
    {'month': 10, 'day': 3},  // 개천절
    {'month': 10, 'day': 9},  // 한글날
    {'month': 12, 'day': 25}, // 성탄절
  ];
  return holidays.any((holiday) =>
      holiday['month'] == date.month && holiday['day'] == date.day);
}

/// API 데이터에서 해당 lot_type의 count를 3자리 문자열로 반환 (없으면 "000")
String getCountForLot(List<dynamic> data, int lotType) {
  for (var item in data) {
    if (item is Map && item['lot_type'] == lotType) {
      int count = item['count'];
      return count.toString().padLeft(3, '0');
    }
  }
  return "000";
}

/// API 데이터에서 F2 값을 3자리 문자열로 반환 (없으면 "000")
String getF2Value(List<dynamic> data) {
  for (var item in data) {
    if (item is Map && item.containsKey("F2")) {
      int value = item["F2"];
      return value.toString().padLeft(3, '0');
    }
  }
  return "000";
}
