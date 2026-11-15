import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// S1 探针：把原生的 Termux 终端视图挂成 Flutter 的 platform view。
///
/// 这一版**不接任何 channel**——原生侧只会灌一段固定的 ANSI 样例，用来验证
/// 「能不能编、能不能注册、能不能上屏」。真正的 pty 字节要等 S2。
///
/// 开关是编译期常量：[bool.fromEnvironment] 的 `DSH_NATIVE_TERM`，
/// 由构建命令的 `--dart-define` 决定，默认关闭，正常包不受影响。
class NativeTerminalView extends StatelessWidget {
  const NativeTerminalView({super.key});

  /// 必须与 `TerminalPlatformView.VIEW_TYPE` 一致。
  static const String viewType = 'dsh/terminal';

  @override
  Widget build(BuildContext context) {
    if (defaultTargetPlatform != TargetPlatform.android) {
      return const SizedBox.shrink();
    }
    return AndroidView(
      viewType: viewType,
      // 终端自己处理滚动/长按/选择，所以让原生视图直接吃掉所有手势。
      gestureRecognizers: <Factory<OneSequenceGestureRecognizer>>{
        Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new),
      },
    );
  }
}
