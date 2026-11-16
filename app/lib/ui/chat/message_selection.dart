import 'package:flutter_riverpod/flutter_riverpod.dart';

/// R4：当前被「已勾选」的那一条消息（消息的 `item.key`）。null = 没在勾选态。
///
/// 放在页级而不是每个消息自己一个 bool：勾选是**唯一**的（勾了这条，上一条自动退），
/// 消息自己不用通知别人，也不会两条同时亮着。
final pickedMessageProvider = StateProvider<String?>((ref) => null);
