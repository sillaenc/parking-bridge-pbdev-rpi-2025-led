import 'dart:typed_data';

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
