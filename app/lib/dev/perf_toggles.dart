import 'package:flutter/foundation.dart';

/// 排查"卡"时用的运行时开关（2026-11-27）。
///
/// 光栅层的卡只能一个一个关掉来定位：关掉某一项以后 drop 明显下降，就是它。
/// 默认全开（和正常一样），只在 设置 → 性能 里手动点。

/// 顶栏那几颗玻璃圆钮不做背景采样（它们的底图是正在滚动的列表）。
final devNoHeaderBlur = ValueNotifier<bool>(false);

/// 输入条上方那条渐隐带不画（它跟着输入条高度每帧重画）。
final devNoVeil = ValueNotifier<bool>(false);
