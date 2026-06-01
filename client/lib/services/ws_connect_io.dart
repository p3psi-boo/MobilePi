import 'dart:io';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// 原生平台实现：显式开启 permessage-deflate 压缩。
Future<WebSocketChannel> connectWs(String url) async {
  final socket = await WebSocket.connect(
    url,
    compression: CompressionOptions.compressionDefault,
  );
  return IOWebSocketChannel(socket);
}
