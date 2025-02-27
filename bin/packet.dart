import 'dart:typed_data';
import 'dart:io';
import 'dart:convert';
import 'config.dart'; // settings

/// TCP 소켓 전송
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

/// 패킷 생성
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
