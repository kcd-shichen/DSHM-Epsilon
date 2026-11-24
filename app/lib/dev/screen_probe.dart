// SPDX-FileCopyrightText: 2026 CikeSeven
// SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md.

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:ui' show FramePhase;

import 'package:flutter/scheduler.dart';
import 'package:path_provider/path_provider.dart';

/// 输入条性能探针（§84）。**定位完就删。**
///
/// v2 修的是 v1 的硬伤：`FrameTiming` 是**延迟投递**的，v1 按"投递那一刻在不在
/// 形变"分桶，于是 62 段形变里有 37 段 `f=0`——整批帧都塌进了 `rest` 桶。
/// 这里改成**按帧自己归桶**：每帧开始时把当时的阶段压进队列，`timings` 到达时
/// 按顺序配对，投递再晚也归对。
class ScreenProbe {
  ScreenProbe._();

  static const _lifetime = Duration(minutes: 30);
  static const _period = Duration(seconds: 2);
  static const _queueCap = 600;

  /// `_open` 在动（收/开键盘那一段）时为 true。由 composer 设。
  static bool morphing = false;

  /// 每帧开始时的阶段，等 `timings` 来配对。
  static final Queue<bool> _pending = Queue<bool>();

  static final Map<String, _Phase> _buckets = <String, _Phase>{};
  static final Map<String, Stopwatch> _watches = <String, Stopwatch>{};
  static final Map<String, bool> _flags = <String, bool>{};

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
      file.writeAsStringSync('');
      _file = file;
    } on Object {
      _file = null;
    }
    // persistent callback 只在有帧时跑，不会自己要帧。
    SchedulerBinding.instance.addPersistentFrameCallback((_) {
      _pending.addLast(morphing);
      if (_pending.length > _queueCap) _pending.removeFirst();
    });
    SchedulerBinding.instance.addTimingsCallback((timings) {
      for (final timing in timings) {
        final phase = _pending.isNotEmpty ? _pending.removeFirst() : morphing;
        _buckets.putIfAbsent(phase ? 'morph' : 'rest', _Phase.new).add(timing);
      }
    });
    _timer = Timer.periodic(_period, (_) => _flush());
    Timer(_lifetime, () {
      _flush();
      _timer?.cancel();
      _timer = null;
    });
  }

  static void hit(String name) {
    if (!_started) return;
    final phase = _current();
    phase.hits[name] = (phase.hits[name] ?? 0) + 1;
  }

  /// 一个持续性的状态（有环 / 无环），每个窗口取最后一次的值。
  static void flag(String name, bool value) {
    if (!_started) return;
    _flags[name] = value;
  }

  /// 一个瞬时数值（例如输入条的面积），每窗口记一次峰值和均值。
  static void sample(String name, double value) {
    if (!_started) return;
    _current().samples.putIfAbsent(name, _Num.new).add(value);
  }

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
    final transient = SchedulerBinding.instance.transientCallbackCount;
    final flags = StringBuffer();
    for (final entry in _flags.entries) {
      flags.write(' ${entry.key}=${entry.value ? 1 : 0}');
    }
    flags.write(' tick=$transient');
    final out = StringBuffer();
    for (final entry in _buckets.entries) {
      out.write('${++_seq} p=${entry.key} ${entry.value.report()}$flags\n');
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
  final Map<String, _Num> samples = <String, _Num>{};

  void add(FrameTiming timing) {
    frames.add(timing);
    if (frames.length > 600) frames.removeRange(0, frames.length - 600);
  }

  String report() {
    final build = <double>[for (final f in frames) f.buildDuration.inMicroseconds / 1000.0]..sort();
    final raster = <double>[for (final f in frames) f.rasterDuration.inMicroseconds / 1000.0]..sort();
    // 相邻两帧的起始时间差 = 真正跑出来的帧间隔（刷新率骗不了它）。
    final interval = <double>[];
    for (var i = 1; i < frames.length; i++) {
      final delta = frames[i].timestampInMicroseconds(FramePhase.buildStart) -
          frames[i - 1].timestampInMicroseconds(FramePhase.buildStart);
      if (delta > 0 && delta < 200000) interval.add(delta / 1000.0);
    }
    interval.sort();
    final buffer = StringBuffer('f=${frames.length}');
    if (frames.isNotEmpty) {
      buffer.write(' build=${build.last.toStringAsFixed(1)}/${_avg(build).toStringAsFixed(1)}');
      buffer.write(' raster=${raster.last.toStringAsFixed(1)}/${_avg(raster).toStringAsFixed(1)}');
    }
    if (interval.isNotEmpty) {
      buffer.write(' iv=${interval[interval.length ~/ 2].toStringAsFixed(1)}/${interval.first.toStringAsFixed(1)}');
    }
    if (stats.isNotEmpty) {
      buffer.write(' |');
      for (final entry in stats.entries) {
        buffer.write(' ${entry.key}=${entry.value.peak}/${entry.value.avg}');
      }
    }
    if (samples.isNotEmpty) {
      buffer.write(' |');
      for (final entry in samples.entries) {
        buffer.write(' ${entry.key}=${entry.value.peak}/${entry.value.avg}');
      }
    }
    if (hits.isNotEmpty) {
      buffer.write(' |');
      for (final entry in hits.entries) {
        buffer.write(' ${entry.key}=${entry.value}');
      }
    }
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

  String get peak => (_max / 1000.0).toStringAsFixed(2);

  String get avg => _count == 0 ? '0.00' : (_sum / _count / 1000.0).toStringAsFixed(3);
}

class _Num {
  int _count = 0;
  double _sum = 0;
  double _max = 0;

  void add(double value) {
    _count++;
    _sum += value;
    if (value > _max) _max = value;
  }

  String get peak => _max.toStringAsFixed(0);

  String get avg => _count == 0 ? '0' : (_sum / _count).toStringAsFixed(0);
}
