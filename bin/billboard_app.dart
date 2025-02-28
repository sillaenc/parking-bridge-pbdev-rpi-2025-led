import 'dart:async';

import 'settings_manager.dart';
import 'override_server.dart';
import 'holiday_manager.dart';
import 'task_runner.dart';

/// 메인 애플리케이션: 각 매니저들을 생성하고 전체 흐름을 제어
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

    // 5) 2초마다 메인 로직 실행
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
