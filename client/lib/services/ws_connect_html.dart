import 'package:web_socket_channel/html.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Web 平台实现：浏览器自动协商 permessage-deflate（当服务端 offer 时）。
Future<WebSocketChannel> connectWs(String url) async =>
    HtmlWebSocketChannel.connect(url);
