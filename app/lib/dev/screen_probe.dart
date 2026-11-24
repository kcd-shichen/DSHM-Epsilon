// SPDX-FileCopyrightText: 2026 CikeSeven
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.

import 'dart:async';
import 'dart:io';

import 'package:flutter/scheduler.dart';
import 'package:path_provider/path_provider.dart';

/// 输入条性能探针（§84）。**定位完就删。**
///
/// 为什么不用 `dev/frame_probe.dart`：那个只在 debug 下开、结果走 logcat；这台机器上
/// 没有 logcat 可读。这个把两类数据——每帧耗时、每帧里几个具体开销点各花了多少——
/// 每两秒一行写进 `<app files>/perf_probe.txt`，用文件工具直接读。
///
/// 和上一版（§25 的 `ScreenProbe`）的差别只有一处，但那一处正是这次要回答的问题：
/// **帧按"形变中 / 其余"分开统计**。收键盘那 280ms 和静止的帧混在一起取平均，
/// 等于什么都没量——平均会被大量静止帧稀释成"很流畅"。
class ScreenProbe {
  ScreenProbe._();

  /// 采样窗口。够他把两种会话（有环 / 无环）都开合十几次。
  static const _lifetime = Duration(minutes: 30);
  static const _period = Duration(seconds: 2);

  /// `_open` 在动（收/开键盘那一段）时为 true。由 composer 设。
  static bool morphing = false;

  static final Map<String, _Phase> _buckets = <String, _Phase>{};
  static final Map<String, Stopwatch> _watches = <String, Stopwatch>{};

  static Timer? _timer;
  static bool _started = false;
  static File? _file;
  static int _seq = 0;

  static Future<void> start() async {
    if (_started) return;
    _started = true;
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File('${dir.path}/perf_probe.txt');
      // 每次启动清空：读的时候不用数行号，也不会把上一包的数字混进来。
      file.writeAsStringSync('');
      _file = file;
    } on Object {
      _file = null;
    }
    SchedulerBinding.instance.addTimingsCallback((timings) {
      final phase = _current();
      phase.frames.addAll(timings);
      if (phase.frames.length > 400) phase.frames.removeRange(0, phase.frames.length - 400);
    });
    _timer = Timer.periodic(_period, (_) => _flush());
    Timer(_lifetime, () {
      _flush();
      _timer?.cancel();
      _timer = null;
    });
  }

  /// 一次重建记一次。名字短，方便按列对比。
  static void hit(String name) {
    if (!_started) return;
    final phase = _current();
    phase.hits[name] = (phase.hits[name] ?? 0) + 1;
  }

  /// 圈住一段同步代码，累计它的耗时（微秒）。同名嵌套不重复计。
  static T time<T>(String name, T Function() body) {
    if (!_started) return body();
    final watch = _watches.putIfAbsent(name, Stopwatch.new);
    if (watch.isRunning) return body();
    watch
      ..reset()
      ..start();
    try {
      return body();
    } finally {
      watch.stop();
      _current().stats.putIfAbsent(name, _Stat.new).add(watch.elapsedMicroseconds);
    }
  }

  static _Phase _current() => _buckets.putIfAbsent(morphing ? 'morph' : 'rest', _Phase.new);

  static void _flush() {
    final file = _file;
    if (file == null || _buckets.isEmpty) return;
    final out = StringBuffer();
    for (final entry in _buckets.entries) {
      out.write('${++_seq} p=${entry.key} ${entry.value.report()}');
    }
    _buckets.clear();
    try {
      file.writeAsStringSync(out.toString(), mode: FileMode.append, flush: true);
    } on Object {
      // 探针坏了不该影响应用。
    }
  }
}

/// 一个阶段（形变中 / 其余）的累计。
class _Phase {
  final List<FrameTiming> frames = <FrameTiming>[];
  final Map<String, int> hits = <String, int>{};
  final Map<String, _Stat> stats = <String, _Stat>{};

  String report() {
    final build = <double>[for (final f in frames) f.buildDuration.inMicroseconds / 1000.0]..sort();
    final raster = <double>[for (final f in frames) f.rasterDuration.inMicroseconds / 1000.0]..sort();
    final buffer = StringBuffer('f=${frames.length}');
    if (frames.isNotEmpty) {
      buffer.write(' build=${build.last.toStringAsFixed(1)}/${_avg(build).toStringAsFixed(1)}');
      buffer.write(' raster=${raster.last.toStringAsFixed(1)}/${_avg(raster).toStringAsFixed(1)}');
    }
    if (stats.isNotEmpty) {
      buffer.write(' |');
      for (final entry in stats.entries) {
        buffer.write(' ${entry.key}=${entry.value.peak}/${entry.value.avg}');
      }
    }
    if (hits.isNotEmpty) {
      buffer.write(' |');
      for (final entry in hits.entries) {
        buffer.write(' ${entry.key}=${entry.value}');
      }
    }
    buffer.write('\n');
    return buffer.toString();
  }

  static double _avg(List<double> sorted) =>
      sorted.isEmpty ? 0 : sorted.reduce((a, b) => a + b) / sorted.length;
}

class _Stat {
  int _count = 0;
  int _sum = 0;
  int _max = 0;

  void add(int micros) {
    _count++;
    _sum += micros;
    if (micros > _max) _max = micros;
  }

  /// 单次峰值（毫秒）。
  String get peak => (_max / 1000.0).toStringAsFixed(2);

  /// 单次均值（毫秒）。
  String get avg => _count == 0 ? '0.00' : (_sum / _count / 1000.0).toStringAsFixed(3);
}
