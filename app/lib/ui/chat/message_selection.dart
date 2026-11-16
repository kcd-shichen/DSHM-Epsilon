import 'package:flutter_riverpod/flutter_riverpod.dart';

/// R4：当前被「已勾选」的那一条消息（消息的 `item.key`）。null = 没在勾选态。
///
/// 放在页级而不是每个消息自己一个 bool：勾选是**唯一**的（勾了这条，上一条自动退），
/// 消息之间不用互相通知，也不会两条同时亮着。
class PickedMessage extends Notifier<String?> {
  @override
  String? build() => null;

  void pick(String key) => state = key;

  void clear() => state = null;
}

final pickedMessageProvider = NotifierProvider<PickedMessage, String?>(PickedMessage.new);
