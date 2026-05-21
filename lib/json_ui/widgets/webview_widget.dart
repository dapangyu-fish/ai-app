// WebView 控件 — 嵌入网页
// 支持: url (必填), height (默认 400), javascriptEnabled, onMessageReceived
//
// 注意：Android 需要 INTERNET 权限（默认有），iOS 需要 NSAppTransportSecurity
// 配置（如要加载 http URL）
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'base_widget.dart';
import '../interpreter.dart';

class JsonWebViewWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final rawUrl = json['url']?.toString() ?? '';
    final url = interpreter.resolveTemplate(rawUrl);
    final height = (json['height'] as num?)?.toDouble() ?? 400;
    final javascriptEnabled = json['javascriptEnabled'] != false;

    if (url.isEmpty) {
      return SizedBox(
        height: height,
        child: const Center(child: Text('webview: url 为空')),
      );
    }

    return SizedBox(
      height: height,
      child: _WebViewInline(
        url: url,
        javascriptEnabled: javascriptEnabled,
      ),
    );
  }
}

class _WebViewInline extends StatefulWidget {
  final String url;
  final bool javascriptEnabled;

  const _WebViewInline({
    required this.url,
    required this.javascriptEnabled,
  });

  @override
  State<_WebViewInline> createState() => _WebViewInlineState();
}

class _WebViewInlineState extends State<_WebViewInline> {
  // web 上 webview_flutter 没有平台实现，构造 WebViewController 会抛异常，
  // 所以 web 上不创建 controller，build 时直接给占位。
  WebViewController? _controller;

  @override
  void initState() {
    super.initState();
    if (!kIsWeb) {
      _controller = WebViewController()
        ..setJavaScriptMode(widget.javascriptEnabled
            ? JavaScriptMode.unrestricted
            : JavaScriptMode.disabled)
        ..loadRequest(Uri.parse(widget.url));
    }
  }

  @override
  void didUpdateWidget(_WebViewInline old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) {
      _controller?.loadRequest(Uri.parse(widget.url));
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('WebView 在 Web 端不可用'),
        ),
      );
    }
    return WebViewWidget(controller: controller);
  }
}
