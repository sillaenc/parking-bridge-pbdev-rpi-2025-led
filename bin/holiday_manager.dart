import 'dart:convert';
import 'package:http/http.dart' as http;

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
