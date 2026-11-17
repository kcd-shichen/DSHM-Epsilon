// SPDX-FileCopyrightText: 2026 CikeSeven
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/scheduler.dart';
import 'package:path_provider/path_provider.dart';

/// 一次性的性能探针（B1）。**定位完就删。**
///
/// 为什么不用 `dev/frame_probe.dart`：那个只在 debug 下开、结果走 logcat；这台机器上
/// 我看不到 logcat，也不能给 release 加 dart-define。这个把同样的两类数据——
/// 每帧耗时、每帧里谁 rebuild 了多少次——两秒一行写进
/// `<app files>/perf_probe.txt`，用文件工具直接读。
class ScreenProbe {
  /// 只在这段时间内采样，之后自动停：既不会一直占着计时器，也避免文件无限长。
  static const _lifetime = Duration(minutes: 6);
  static const _period = Duration(seconds: 2);

  static final Map<String, int> _hits = <String, int>{};
  static final List<FrameTiming> _frames = <FrameTiming>[];

  static Timer? _timer;
  static Timer? _stop;
  static String? _path;
  static bool _started = false;

  static void start() {
    if (_started) return;
    _started = true;
    SchedulerBinding.instance.addTimingsCallback((timings) {
      _frames.addAll(timings);
      if (_frames.length > 400) _frames.removeRange(0, _frames.length - 400);
    });
    _timer = Timer.periodic(_period, (_) => _flush());
    _stop = Timer(_lifetime, () {
      _flush();
      _timer?.cancel();
      _timer = null;
    });
  }

  /// 一次 build 记一次。名字短，方便按列对比。
  static void hit(String name) {
    if (!_started) return;
    _hits[name] = (_hits[name] ?? 0) + 1;
  }

  static Future<void> _flush() async {
    if (_frames.isEmpty && _hits.isEmpty) return;
    final builds = [for (final t in _frames) t.buildDuration.inMicroseconds / 1000.0]..sort();
    final rasters = [for (final t in _frames) t.rasterDuration.inMicroseconds / 1000.0]..sort();
    double avg(List<double> v) => v.isEmpty ? 0 : v.reduce((a, b) => a + b) / v.length;
    double at(List<double> v, double p) => v.isEmpty ? 0 : v[math.min(v.length - 1, (v.length * p).floor())];
    final hits = _hits.entries.map((e) => '${e.key}=${e.value}').join(' ');
    final line =
        'frames=${_frames.length} '
        'build_avg=${avg(builds).toStringAsFixed(1)} '
        'build_p95=${at(builds, 0.95).toStringAsFixed(1)} '
        'build_max=${(builds.isEmpty ? 0 : builds.last).toStringAsFixed(1)} '
        'raster_avg=${avg(rasters).toStringAsFixed(1)} '
        'raster_max=${(rasters.isEmpty ? 0 : rasters.last).toStringAsFixed(1)} '
        '| $hits\n';
    _frames.clear();
    _hits.clear();
    try {
      _path ??= '${(await getApplicationSupportDirectory()).path}/perf_probe.txt';
      File(_path!).writeAsStringSync(line, mode: FileMode.append, flush: true);
    } on Object {
      // 探针坏了不该影响应用。
    }
  }

  static void dispose() {
    _timer?.cancel();
    _stop?.cancel();
    _timer = null;
    _stop = null;
    _started = false;
  }
}
