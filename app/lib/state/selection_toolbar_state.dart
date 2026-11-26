// 选字工具条：长按选字后浮在选区上方那一行按钮。存两件事——有哪几项、按什么顺序。
// 只存我们自己放进去的那几项；系统自己塞进来的（查询、翻译之类）不在此列。

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 工具条上由我们摆放的项。
enum SelectionToolbarItem {
  /// 复制选中的文字。
  copy,

  /// 引用这一段（接进输入框）。
  quote,

  /// 全选这条消息。
  selectAll,

  /// 把这一段念出来（跳开其中的密钥）。
  announce,

  /// ⓘ：打开这条消息自己的菜单（二级）。
  menu,

  /// 分享。默认不打勾——要用自己在设置里勾。
  share,
}

class SelectionToolbarPrefs {
  const SelectionToolbarPrefs({this.items = defaultItems});

  /// 一次都没改过的安装看到的样子。
  static const defaultItems = [
    SelectionToolbarItem.copy,
    SelectionToolbarItem.quote,
    SelectionToolbarItem.selectAll,
    // ⓘ 排第四（He 2026-11-22 定的）：系统会往这一行后面再塞两格，
    // 折叠从尾巴往前折，第四位还轮不到它。
    SelectionToolbarItem.menu,
  ];

  /// 工具条上按这个顺序摆，只摆其中的项。
  final List<SelectionToolbarItem> items;

  bool get available => items.isNotEmpty;

  SelectionToolbarPrefs copyWith({List<SelectionToolbarItem>? items}) =>
      SelectionToolbarPrefs(items: items ?? this.items);
}

class SelectionToolbarController extends Notifier<SelectionToolbarPrefs> {
  static const itemsKey = 'selection_toolbar_items';

  late Future<void> _loaded;

  @override
  SelectionToolbarPrefs build() {
    _loaded = _load();
    return const SelectionToolbarPrefs();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!ref.mounted) return;
      final stored = prefs.getStringList(itemsKey);
      state = SelectionToolbarPrefs(
        // 一个没人认领的名字（旧版本删掉的项）直接丢掉。
        items: stored == null
            ? SelectionToolbarPrefs.defaultItems
            : {for (final id in stored) ?SelectionToolbarItem.values.asNameMap()[id]}.toList(),
      );
    } catch (_) {
      // 没有偏好设置的底层：这一次运行用默认值。
    }
  }

  /// 等存着的值读完再改，免得启动后紧接着的改动被迟到的读取盖掉。
  Future<void> setItems(List<SelectionToolbarItem> items) async {
    await _loaded;
    if (!ref.mounted) return;
    state = state.copyWith(items: List.unmodifiable(items));
    try {
      await (await SharedPreferences.getInstance()).setStringList(itemsKey, [for (final i in items) i.name]);
    } catch (_) {
      // 只保留到这次运行结束。
    }
  }
}

final selectionToolbarProvider = NotifierProvider<SelectionToolbarController, SelectionToolbarPrefs>(
  SelectionToolbarController.new,
);
