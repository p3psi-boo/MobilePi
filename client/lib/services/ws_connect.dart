import 'package:web_socket_channel/web_socket_channel.dart';

import 'ws_connect_io.dart'
    if (dart.library.html) 'ws_connect_html.dart' as impl;

/// 跨平台建立 WebSocket 连接。
///
/// - 原生（移动/桌面）：通过 `dart:io` 的 `WebSocket.connect` 显式开启
///   permessage-deflate 压缩（`WebSocketChannel.connect` 不暴露该选项）。
/// - Web：浏览器在服务端 offer 压缩时自动协商 deflate，无需额外处理。
///
/// 是否实际压缩由服务端（Hub）决定；客户端始终 offer，对端不支持时自动回退。
Future<WebSocketChannel> connectWs(String url) => impl.connectWs(url);
