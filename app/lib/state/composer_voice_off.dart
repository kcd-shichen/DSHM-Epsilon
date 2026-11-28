// 输入条那颗键：只留 ↑，还是要语音。
//
// `true`（默认）= **不要语音**：输入条上永远是那颗 ↑；没字时是灰的（和 1.2/1.3 一样），
// 不接语音控制器，也不画语音键。
// `false` = 空草稿时 ↑ 变成麦克风，点下去开始听写。
//
// He 2026-11-28 定：默认开（＝关闭语音）。设置位置在 设置 → 界面 → 文本选择工具栏下方。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 没存过任何值时用哪个默认。测试里覆盖它就能决定"语音默认开还是关"。
final composerVoiceOffDefaultProvider = Provider<bool>((ref) => true);

class ComposerVoiceOff extends Notifier<bool> {
  static const key = 'composer_voice_off';

  late Future<void> _loaded;

  @override
  bool build() {
    _loaded = _load();
    return ref.read(composerVoiceOffDefaultProvider);
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!ref.mounted) return;
      state = prefs.getBool(key) ?? ref.read(composerVoiceOffDefaultProvider);
    } catch (_) {
      // 没有偏好设置的底层：这一次运行用默认值。
    }
  }

  Future<void> setOff(bool value) async {
    await _loaded;
    if (!ref.mounted) return;
    state = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(key, value);
    } catch (_) {
      // 存不下就只影响这一次运行。
    }
  }
}

final composerVoiceOffProvider = NotifierProvider<ComposerVoiceOff, bool>(ComposerVoiceOff.new);
