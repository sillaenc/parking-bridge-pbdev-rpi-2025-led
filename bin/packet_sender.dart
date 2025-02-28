import 'dart:typed_data';
import 'dart:io';
import 'packet_utils.dart';
import 'settings_manager.dart';

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
