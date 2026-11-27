import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// 打开就在屏幕左上角画两行数：UI / 光栅各自的毫秒，和最近这一窗里掉了几帧。
///
/// 只在定位「卡」的时候打开（设置 → 性能 → 帧耗时 HUD）。它自己每帧只写几个数、
/// 每 [sample] 帧才 setState 一次，量它自己不会把画面拖慢。
final frameHudOn = ValueNotifier<bool>(false);

class FrameHud extends StatefulWidget {
  const FrameHud({super.key, this.window = 60});

  /// 统计窗口（帧）。
  final int window;

  @override
  State<FrameHud> createState() => _FrameHudState();
}

class _FrameHudState extends State<FrameHud> {
  final _ui = <double>[];
  final _raster = <double>[];
  int _jank = 0;
  int _seen = 0;

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
  }

  @override
  void dispose() {
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    super.dispose();
  }

  /// 这一块屏幕的刷新间隔（毫秒）。120Hz 是 8.33，60Hz 是 16.7——按 17ms 判会漏掉
  /// 一整类掉帧，所以预算跟着实际刷新率走。
  static double get _budget {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isEmpty) return 16.7;
    final rate = views.first.display.refreshRate;
    return rate > 1 ? 1000 / rate : 16.7;
  }

  void _onTimings(List<FrameTiming> timings) {
    final budget = _budget;
    for (final t in timings) {
      _ui.add(t.buildDuration.inMicroseconds / 1000);
      _raster.add(t.rasterDuration.inMicroseconds / 1000);
      // 只看"这一帧的活干完了没有"：UI + 光栅超过一个刷新间隔，就是掉了一帧。
      final work = (t.buildDuration + t.rasterDuration).inMicroseconds / 1000;
      if (work > budget) _jank++;
    }
    while (_ui.length > widget.window) {
      _ui.removeAt(0);
      _raster.removeAt(0);
      // 掉帧数也只数这个窗口里的，不然它会一路累加，读不出"现在"。
      if (_jank > 0) _jank--;
    }
    if (++_seen % 15 == 0 && mounted) setState(() {});
  }

  double get _avgUi => _ui.isEmpty ? 0 : _ui.reduce((a, b) => a + b) / _ui.length;
  double get _avgRaster => _raster.isEmpty ? 0 : _raster.reduce((a, b) => a + b) / _raster.length;
  double get _maxRaster => _raster.isEmpty ? 0 : _raster.reduce((a, b) => a > b ? a : b);

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: frameHudOn,
      builder: (context, on, _) {
        if (!on) return const SizedBox.shrink();
        final worst = _avgUi > _avgRaster ? _avgUi : _avgRaster;
        final color = worst > 16 ? const Color(0xFFFF5252) : const Color(0xFF69F0AE);
        return IgnorePointer(
          child: Align(
            alignment: Alignment.topLeft,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.only(left: 6, top: 4),
                child: DecoratedBox(
                  decoration: const BoxDecoration(color: Color(0xCC000000)),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                    child: DefaultTextStyle(
                      style: TextStyle(color: color, fontSize: 11, height: 1.2, fontFamily: 'monospace'),
                      child: Text(
                        'UI ${_avgUi.toStringAsFixed(1)}  R ${_avgRaster.toStringAsFixed(1)}  '
                        'maxR ${_maxRaster.toStringAsFixed(0)}\n'
                        'drop $_jank/${_ui.length}f  budget ${_budget.toStringAsFixed(1)}ms',
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
