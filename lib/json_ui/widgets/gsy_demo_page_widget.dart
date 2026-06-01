import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../interpreter.dart';
import 'base_widget.dart';

const String _gsyCatUrl =
    'https://myapp-oss-endpoint.dapangyu.work/json-app-assets/gsy_flutter_demo/static/gsy_cat.png';

class JsonGsyDemoPageWidget extends JsonBaseWidget {
  @override
  Widget build(
    BuildContext context,
    Map<String, dynamic> json,
    JsonInterpreter interpreter,
  ) {
    final demo = interpreter.resolveTemplate(json['demo']?.toString() ?? '');
    return SizedBox.expand(child: _GsyDemoHost(demo: demo));
  }
}

class _GsyDemoHost extends StatelessWidget {
  final String demo;

  const _GsyDemoHost({required this.demo});

  @override
  Widget build(BuildContext context) {
    return switch (demo.padLeft(3, '0')) {
      '023' => const _TextSizeDemoPage(),
      '024' => const _RichTextDemoPage(),
      '025' => const _RichTextDemoPage2(),
      '026' => const _ViewPagerDemoPage(),
      '027' => const _SliverListDemoPage(),
      '028' => const _VerificationCodeInputDemoPage(masked: false),
      '029' => const _VerificationCodeInputDemoPage(masked: true),
      '030' => const _CustomMultiRenderDemoPage(),
      '031' => const _CloudDemoPage(),
      '032' => const _StickDemoPage(),
      '033' => const _StickExpandDemoPage(),
      '034' => const _SliverStickListDemoPage(),
      '035' => const _InputBottomDemoPage(),
      '036' => const _BlurDemoPage(),
      '037' => const _AnimationContainerDemoPage(),
      '038' => const _TickClickDemoPage(),
      '039' => const _AnimaDemoPage4(),
      '040' => const _ListAnimDemoPage(variant: 1),
      '041' => const _ListAnimDemoPage(variant: 2),
      '042' => const _DropSelectDemoPage(),
      '043' => const _AnimaDemoPage5(),
      '044' => const _ScrollHeaderDemoPage(),
      '045' => const _CustomViewportPage(),
      '046' => const _AnimTipDemoPage(),
      '047' => const _StickSliverListDemoPage(),
      '048' => const _OverflowImagePage(),
      '049' => const _AlignDemoPage(),
      '050' => const _CardItemPage(),
      '051' => const _SliverTabDemoPage(variant: 1),
      '052' => const _SliverTabDemoPage(variant: 2),
      _ => Scaffold(
        appBar: AppBar(title: Text('GSY Demo $demo')),
        body: Center(child: Text('GSY demo $demo is not registered.')),
      ),
    };
  }
}

Widget _catImage({double? width, double? height, BoxFit fit = BoxFit.cover}) {
  return Image.network(
    _gsyCatUrl,
    width: width,
    height: height,
    fit: fit,
    errorBuilder: (_, __, ___) {
      return Container(
        width: width,
        height: height,
        color: Colors.black12,
        alignment: Alignment.center,
        child: const Icon(Icons.image, color: Colors.black45),
      );
    },
  );
}

Widget _simpleScaffold({
  required String title,
  required Widget body,
  Color? backgroundColor,
  Widget? floatingActionButton,
  List<Widget>? actions,
  List<Widget>? persistentFooterButtons,
}) {
  return Scaffold(
    appBar: AppBar(title: Text(title), actions: actions),
    backgroundColor: backgroundColor,
    body: body,
    floatingActionButton: floatingActionButton,
    persistentFooterButtons: persistentFooterButtons,
  );
}

class _TextSizeDemoPage extends StatefulWidget {
  const _TextSizeDemoPage();

  @override
  State<_TextSizeDemoPage> createState() => _TextSizeDemoPageState();
}

class _TextSizeDemoPageState extends State<_TextSizeDemoPage> {
  double _scale = 1;

  static const _content =
      'This document describes the rationale for and changes to the slots syntax proposed for Vue 2.6.0. '
      'It is based on the discussions in the RFC issue and tries to balance explicitness, readability, '
      'and backwards compatibility with existing slot usage.';

  @override
  Widget build(BuildContext context) {
    return _simpleScaffold(
      title: 'TextLineHeightDemoPage',
      body: Stack(
        children: [
          Container(
            margin: const EdgeInsets.all(20),
            color: Colors.blueGrey,
            alignment: Alignment.topLeft,
            padding: const EdgeInsets.all(12),
            child: Text(
              _content,
              style: TextStyle(fontSize: 14 * _scale, color: Colors.black),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 50),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  TextButton(
                    style: TextButton.styleFrom(
                      backgroundColor: Colors.redAccent,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: () => setState(() {
                      _scale = math.max(0.5, _scale - 0.2);
                    }),
                    child: const Text('-'),
                  ),
                  const SizedBox(width: 20),
                  TextButton(
                    style: TextButton.styleFrom(
                      backgroundColor: Colors.greenAccent,
                      foregroundColor: Colors.black,
                    ),
                    onPressed: () => setState(() {
                      _scale = math.min(3.0, _scale + 0.2);
                    }),
                    child: const Text('+'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RichTextDemoPage extends StatelessWidget {
  const _RichTextDemoPage();

  @override
  Widget build(BuildContext context) {
    void showLink() {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Link Clicked.'),
          action: SnackBarAction(
            label: 'ACTION',
            onPressed: () {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text("You pressed snackbar's action.")),
              );
            },
          ),
        ),
      );
    }

    Widget inlineImage({double margin = 0}) {
      return Padding(
        padding: EdgeInsets.symmetric(horizontal: margin),
        child: _catImage(width: 24, height: 24, fit: BoxFit.cover),
      );
    }

    Widget tapText(String text, TextStyle style) {
      return GestureDetector(
        onTap: showLink,
        child: Text(text, style: style),
      );
    }

    return _simpleScaffold(
      title: 'RichTextDemoPage',
      body: Container(
        margin: const EdgeInsets.all(10),
        alignment: Alignment.center,
        child: RichText(
          text: TextSpan(
            children: [
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: tapText(
                  'A Text Link',
                  const TextStyle(color: Colors.red, fontSize: 14),
                ),
              ),
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: inlineImage(),
              ),
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: inlineImage(margin: 10),
              ),
              const TextSpan(
                text: '哈哈哈',
                style: TextStyle(color: Colors.yellow, fontSize: 14),
              ),
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: tapText(
                  '@Somebody',
                  const TextStyle(
                    color: Colors.black,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: tapText(
                  ' #RealRichText# ',
                  const TextStyle(color: Colors.blue, fontSize: 14),
                ),
              ),
              const TextSpan(
                text: 'showing a bigger image',
                style: TextStyle(color: Colors.black, fontSize: 14),
              ),
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: inlineImage(margin: 5),
              ),
              const TextSpan(
                text: 'and seems working perfect……',
                style: TextStyle(color: Colors.black, fontSize: 14),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RichTextDemoPage2 extends StatefulWidget {
  const _RichTextDemoPage2();

  @override
  State<_RichTextDemoPage2> createState() => _RichTextDemoPage2State();
}

class _RichTextDemoPage2State extends State<_RichTextDemoPage2> {
  double _size = 50;

  @override
  Widget build(BuildContext context) {
    return _simpleScaffold(
      title: 'RichTextDemoPage',
      actions: [
        IconButton(
          onPressed: () => setState(() => _size += 10),
          icon: const Icon(Icons.add_circle_outline),
        ),
        IconButton(
          onPressed: () => setState(() => _size = math.max(0, _size - 10)),
          icon: const Icon(Icons.remove_circle_outline),
        ),
      ],
      body: SelectionArea(
        child: Container(
          margin: const EdgeInsets.all(10),
          alignment: Alignment.center,
          child: Text.rich(
            TextSpan(
              children: [
                const TextSpan(text: 'Flutter is'),
                const WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: SizedBox(
                    width: 120,
                    height: 50,
                    child: Card(
                      color: Colors.blue,
                      child: Center(child: Text('Hello World!')),
                    ),
                  ),
                ),
                WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: SizedBox(
                    width: _size,
                    height: _size,
                    child: _catImage(fit: BoxFit.cover),
                  ),
                ),
                const TextSpan(text: 'the best!'),
                const WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: SelectionContainer.disabled(child: Text(' not copy')),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ViewPagerDemoPage extends StatelessWidget {
  const _ViewPagerDemoPage();

  @override
  Widget build(BuildContext context) {
    return _simpleScaffold(
      title: 'ViewPagerDemoPage',
      backgroundColor: Theme.of(context).primaryColorDark,
      body: const Column(
        children: [
          Expanded(
            child: _TransformerPager(transformer: _PagerTransformer.none),
          ),
          Expanded(
            child: _TransformerPager(transformer: _PagerTransformer.accordion),
          ),
          Expanded(
            child: _TransformerPager(transformer: _PagerTransformer.threeD),
          ),
          Expanded(
            child: _TransformerPager(transformer: _PagerTransformer.depth),
          ),
        ],
      ),
    );
  }
}

enum _PagerTransformer { none, accordion, threeD, depth }

class _TransformerPager extends StatefulWidget {
  final _PagerTransformer transformer;

  const _TransformerPager({required this.transformer});

  @override
  State<_TransformerPager> createState() => _TransformerPagerState();
}

class _TransformerPagerState extends State<_TransformerPager> {
  late final PageController _controller = PageController();
  static const _colors = [
    Colors.redAccent,
    Colors.blueAccent,
    Colors.greenAccent,
  ];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PageView.builder(
      controller: _controller,
      itemCount: 3,
      itemBuilder: (context, index) {
        return AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            final page = _controller.hasClients && _controller.page != null
                ? _controller.page!
                : _controller.initialPage.toDouble();
            final delta = index - page;
            Matrix4 transform = Matrix4.identity();
            double opacity = 1;
            switch (widget.transformer) {
              case _PagerTransformer.none:
                break;
              case _PagerTransformer.accordion:
                transform = Matrix4.identity()
                  ..setEntry(3, 2, 0.001)
                  ..rotateY(delta * math.pi / 2);
                break;
              case _PagerTransformer.threeD:
                transform = Matrix4.identity()
                  ..setEntry(3, 2, 0.002)
                  ..rotateY(delta * 0.7);
                break;
              case _PagerTransformer.depth:
                final scale = (1 - delta.abs() * 0.25).clamp(0.7, 1.0);
                opacity = (1 - delta.abs() * 0.45).clamp(0.35, 1.0);
                transform = Matrix4.identity()
                  ..scaleByDouble(scale, scale, 1, 1);
                break;
            }
            return Opacity(
              opacity: opacity,
              child: Transform(
                transform: transform,
                alignment: delta >= 0
                    ? Alignment.centerLeft
                    : Alignment.centerRight,
                child: child,
              ),
            );
          },
          child: Container(
            margin: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: _colors[index],
              border: Border.all(color: Colors.white, width: 1),
            ),
            alignment: Alignment.center,
            child: Text(
              '$index',
              style: const TextStyle(color: Colors.white, fontSize: 80),
            ),
          ),
        );
      },
    );
  }
}

class _SliverListDemoPage extends StatelessWidget {
  const _SliverListDemoPage();

  @override
  Widget build(BuildContext context) {
    return _simpleScaffold(
      title: 'SliverListDemoPage',
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Container(height: 180, color: Colors.redAccent),
          ),
          SliverPersistentHeader(
            pinned: true,
            delegate: _FixedHeaderDelegate(
              height: 60,
              child: Container(
                color: Colors.orangeAccent,
                child: Row(
                  children: [
                    Expanded(
                      child: TextButton(
                        onPressed: () {},
                        child: const Text('按键1'),
                      ),
                    ),
                    Expanded(
                      child: TextButton(
                        onPressed: () {},
                        child: const Text('按键2'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          SliverList.builder(
            itemCount: 100,
            itemBuilder: (context, index) => Card(
              child: Container(
                height: 60,
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.only(left: 10),
                child: Text('Item $index'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _VerificationCodeInputDemoPage extends StatefulWidget {
  final bool masked;

  const _VerificationCodeInputDemoPage({required this.masked});

  @override
  State<_VerificationCodeInputDemoPage> createState() =>
      _VerificationCodeInputDemoPageState();
}

class _VerificationCodeInputDemoPageState
    extends State<_VerificationCodeInputDemoPage> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _simpleScaffold(
      title: 'VerificationCodeInputDemoPage',
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        child: Stack(
          children: [
            Center(
              child: widget.masked
                  ? _buildPaymentPin(context)
                  : _buildCodeCells(context),
            ),
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              height: 1,
              child: Opacity(
                opacity: 0.01,
                child: TextField(
                  controller: _controller,
                  focusNode: _focusNode,
                  autofocus: false,
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(6),
                  ],
                  onChanged: (value) {
                    setState(() {});
                    if (value.length >= 6) _focusNode.unfocus();
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCodeCells(BuildContext context) {
    final text = _controller.text;
    return GestureDetector(
      onTap: () => _focusNode.requestFocus(),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : MediaQuery.sizeOf(context).width;
          final cellSize = (width - 32) / 6;
          final normalSize = (cellSize - 20).clamp(28.0, 72.0);
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: List.generate(6, (index) {
                final filled = index < text.length;
                return Container(
                  width: normalSize,
                  height: normalSize,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    border: Border.all(color: Theme.of(context).primaryColor),
                  ),
                  child: Text(
                    filled ? text[index] : '',
                    style: TextStyle(
                      color: Theme.of(context).primaryColor,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                );
              }),
            ),
          );
        },
      ),
    );
  }

  Widget _buildPaymentPin(BuildContext context) {
    final text = _controller.text;
    return GestureDetector(
      onTap: () => _focusNode.requestFocus(),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 50),
            child: Row(
              children: [
                Text('支付', style: TextStyle(fontWeight: FontWeight.bold)),
                Spacer(),
                Text('支付'),
              ],
            ),
          ),
          const SizedBox(height: 5),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 50),
            child: Row(
              children: List.generate(6, (index) {
                final isFirst = index == 0;
                final isLast = index == 5;
                return Expanded(
                  child: Container(
                    height: 45,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: const Color(0xFF979797),
                        width: 0.5,
                      ),
                      borderRadius: BorderRadius.horizontal(
                        left: isFirst ? const Radius.circular(4) : Radius.zero,
                        right: isLast ? const Radius.circular(4) : Radius.zero,
                      ),
                    ),
                    child: Text(
                      index < text.length ? '•' : '',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),
        ],
      ),
    );
  }
}

class _CustomMultiRenderDemoPage extends StatefulWidget {
  const _CustomMultiRenderDemoPage();

  @override
  State<_CustomMultiRenderDemoPage> createState() =>
      _CustomMultiRenderDemoPageState();
}

class _CustomMultiRenderDemoPageState
    extends State<_CustomMultiRenderDemoPage> {
  int _count = 5;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return _simpleScaffold(
      title: 'CustomMultiRenderDemoPage',
      body: Center(
        child: Container(
          width: width,
          height: width,
          color: Colors.greenAccent,
          child: Stack(
            children: List.generate(_count, (index) {
              final angle =
                  -math.pi / 2 + index * 2 * math.pi / math.max(1, _count);
              const childSize = 66.0;
              const radius = 100.0;
              final x = width / 2 + math.cos(angle) * radius - childSize / 2;
              final y = width / 2 + math.sin(angle) * radius - childSize / 2;
              return Positioned(
                left: x,
                top: y,
                child: Material(
                  color: Theme.of(context).primaryColor,
                  shape: const CircleBorder(),
                  child: SizedBox(
                    width: childSize,
                    height: childSize,
                    child: Center(
                      child: Text(
                        '$index',
                        style: Theme.of(
                          context,
                        ).textTheme.titleLarge?.copyWith(color: Colors.white),
                      ),
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
      ),
      persistentFooterButtons: [
        TextButton(
          style: TextButton.styleFrom(backgroundColor: Colors.amberAccent),
          onPressed: () => setState(() => _count++),
          child: const Text('加', style: TextStyle(color: Colors.white)),
        ),
        TextButton(
          style: TextButton.styleFrom(backgroundColor: Colors.indigoAccent),
          onPressed: () => setState(() => _count = math.max(1, _count - 1)),
          child: const Text('减', style: TextStyle(color: Colors.white)),
        ),
      ],
    );
  }
}

class _CloudDemoPage extends StatelessWidget {
  const _CloudDemoPage();

  static const _items = <_CloudItem>[
    _CloudItem('CloudGSY11111', Colors.amberAccent, 10, false),
    _CloudItem('CloudGSY3333333T', Colors.limeAccent, 16, false),
    _CloudItem('CloudGSYXXXXXXX', Colors.black, 14, true),
    _CloudItem('CloudGSY55', Colors.black87, 33, false),
    _CloudItem('CloudGSYAA', Colors.blueAccent, 15, false),
    _CloudItem('CloudGSY44', Colors.indigoAccent, 16, false),
    _CloudItem('CloudGSYBWWWWWW', Colors.deepOrange, 12, true),
    _CloudItem('CloudGSY<<<', Colors.blue, 20, true),
    _CloudItem('FFFFFFFFFFFFFF', Colors.blue, 12, false),
    _CloudItem('BBBBBBBBBBB', Colors.deepPurpleAccent, 14, false),
    _CloudItem('CloudGSY%%%%', Colors.orange, 20, true),
    _CloudItem('CloudGSY%%%%%%%', Colors.blue, 12, false),
    _CloudItem('CloudGSY&&&&', Colors.indigoAccent, 10, false),
    _CloudItem('CloudGSYCCCC', Colors.yellow, 14, true),
    _CloudItem('CloudGSY****', Colors.blueAccent, 13, false),
    _CloudItem('CloudGSYRRRR', Colors.redAccent, 12, true),
    _CloudItem('CloudGSYFFFFF', Colors.blue, 12, false),
    _CloudItem('CloudGSYBBBBBBB', Colors.cyanAccent, 15, false),
    _CloudItem('CloudGSY222222', Colors.blue, 16, false),
    _CloudItem('CloudGSY1111111111111111', Colors.tealAccent, 19, false),
    _CloudItem('CloudGSY####', Colors.black54, 12, false),
    _CloudItem('CloudGSYFDWE', Colors.purpleAccent, 14, true),
    _CloudItem('CloudGSY22222', Colors.indigoAccent, 19, false),
    _CloudItem('CloudGSY44444', Colors.yellowAccent, 18, true),
    _CloudItem('CloudGSY33333', Colors.lightBlueAccent, 17, false),
    _CloudItem('CloudGSYXXXXXXXX', Colors.blue, 16, true),
    _CloudItem('CloudGSYFFFFFFFF', Colors.black26, 14, false),
    _CloudItem('CloudGSYZUuzzuuu', Colors.blue, 16, true),
    _CloudItem('CloudGSYVVVVVVVVV', Colors.orange, 12, false),
    _CloudItem('CloudGSY222223', Colors.black26, 13, true),
    _CloudItem('CloudGSYGFD', Colors.yellow, 14, true),
    _CloudItem('GGGGGGGGGG', Colors.deepPurpleAccent, 14, false),
    _CloudItem('CloudGSYFFFFFF', Colors.blueAccent, 10, true),
    _CloudItem('CloudGSY222', Colors.limeAccent, 12, false),
    _CloudItem('CloudGSY6666', Colors.blue, 20, true),
    _CloudItem('CloudGSY33333', Colors.teal, 14, false),
    _CloudItem('YYYYYYYYYYYYYY', Colors.deepPurpleAccent, 14, false),
    _CloudItem('CloudGSY  3  ', Colors.blue, 10, false),
    _CloudItem('CloudGSYYYYYY', Colors.black54, 17, true),
    _CloudItem('CloudGSYCC', Colors.lightBlueAccent, 11, false),
    _CloudItem('CloudGSYGGGGG', Colors.deepPurpleAccent, 10, false),
  ];

  @override
  Widget build(BuildContext context) {
    return _simpleScaffold(
      title: 'CloudDemoPage',
      body: Center(
        child: SizedBox.square(
          dimension: MediaQuery.sizeOf(context).width,
          child: FittedBox(
            child: Container(
              width: 430,
              height: 430,
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
              color: Colors.brown,
              child: Stack(
                clipBehavior: Clip.none,
                children: List.generate(_items.length, (index) {
                  final item = _items[index];
                  final angle = index * 2.399963229728653;
                  final radius = 8 + index * 4.35;
                  final x = 215 + math.cos(angle) * radius - 45;
                  final y = 215 + math.sin(angle) * radius - 10;
                  final text = Text(
                    item.text,
                    style: TextStyle(fontSize: item.size, color: item.color),
                  );
                  return Positioned(
                    left: x.clamp(0, 350).toDouble(),
                    top: y.clamp(0, 405).toDouble(),
                    child: item.rotate
                        ? RotatedBox(quarterTurns: 1, child: text)
                        : text,
                  );
                }),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CloudItem {
  final String text;
  final Color color;
  final double size;
  final bool rotate;

  const _CloudItem(this.text, this.color, this.size, this.rotate);
}

class _StickDemoPage extends StatelessWidget {
  const _StickDemoPage();

  @override
  Widget build(BuildContext context) {
    return _simpleScaffold(
      title: 'StickDemoPage',
      body: CustomScrollView(
        slivers: List.generate(100, (index) {
          return [
            SliverPersistentHeader(
              pinned: true,
              delegate: _FixedHeaderDelegate(
                height: 50,
                child: Container(
                  color: Colors.deepPurple,
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.only(left: 10),
                  child: Text(
                    '我的 $index 头啊',
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Container(
                height: 150,
                color: Colors.deepOrange,
                alignment: Alignment.centerLeft,
                child: Container(
                  margin: const EdgeInsets.only(left: 10),
                  height: 150,
                  color: Colors.pinkAccent,
                  alignment: Alignment.center,
                  child: Text(
                    '我的$index 内容 啊',
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ),
            ),
          ];
        }).expand((e) => e).toList(),
      ),
    );
  }
}

class _StickExpandDemoPage extends StatefulWidget {
  const _StickExpandDemoPage();

  @override
  State<_StickExpandDemoPage> createState() => _StickExpandDemoPageState();
}

class _StickExpandDemoPageState extends State<_StickExpandDemoPage> {
  final Set<int> _expanded = <int>{};

  @override
  Widget build(BuildContext context) {
    return _simpleScaffold(
      title: 'StickExpendDemoPage',
      body: CustomScrollView(
        slivers: List.generate(50, _groupSlivers).expand((e) => e).toList(),
      ),
    );
  }

  List<Widget> _groupSlivers(int index) {
    final count = 4 + (index * 7) % 8;
    final expanded = _expanded.contains(index);
    final visible = expanded ? count : math.min(3, count);
    return [
      SliverPersistentHeader(
        pinned: true,
        delegate: _FixedHeaderDelegate(
          height: 50,
          child: Container(
            color: Colors.deepPurple,
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.only(left: 10),
            child: Text(
              '我的 $index 头啊',
              style: const TextStyle(color: Colors.white),
            ),
          ),
        ),
      ),
      SliverList(
        delegate: SliverChildBuilderDelegate((context, childIndex) {
          if (childIndex < visible) {
            return _pinkContent('我的$index 内容 $childIndex 啊');
          }
          return InkWell(
            onTap: () => setState(() {
              if (expanded) {
                _expanded.remove(index);
              } else {
                _expanded.add(index);
              }
            }),
            child: Container(
              height: 44,
              color: Colors.grey.shade300,
              alignment: Alignment.center,
              child: Text(expanded ? '收起' : '查看更多'),
            ),
          );
        }, childCount: visible + (count > 3 ? 1 : 0)),
      ),
    ];
  }
}

class _SliverStickListDemoPage extends StatelessWidget {
  const _SliverStickListDemoPage();

  @override
  Widget build(BuildContext context) {
    return _simpleScaffold(
      title: 'SliverListDemoPage',
      body: CustomScrollView(
        slivers: List.generate(50, (index) {
          return [
            SliverPersistentHeader(
              pinned: true,
              delegate: _FixedHeaderDelegate(
                height: 60,
                child: Container(
                  color: Colors.redAccent,
                  alignment: Alignment.centerLeft,
                  padding: const EdgeInsets.only(left: 10),
                  child: Text(
                    'Header $index',
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Container(
                height: 120,
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.only(left: 10),
                child: Text('Content $index'),
              ),
            ),
          ];
        }).expand((e) => e).toList(),
      ),
    );
  }
}

Widget _pinkContent(String text) {
  return Container(
    height: 50,
    color: Colors.deepOrange,
    alignment: Alignment.centerLeft,
    child: Container(
      margin: const EdgeInsets.only(left: 10),
      height: 50,
      color: Colors.pinkAccent,
      alignment: Alignment.center,
      child: Text(text, style: const TextStyle(color: Colors.white)),
    ),
  );
}

class _InputBottomDemoPage extends StatelessWidget {
  const _InputBottomDemoPage();

  @override
  Widget build(BuildContext context) {
    return _simpleScaffold(
      title: 'KeyBoardDemoPage',
      body: Builder(
        builder: (context) {
          final keyboardVisible = MediaQuery.viewInsetsOf(context).bottom > 0;
          return GestureDetector(
            onTap: () => FocusScope.of(context).unfocus(),
            child: Stack(
              children: [
                const Center(
                  child: Text(
                    '测试，测试，测试，测试，测试，测试，测试，测试，测试，测试，测试，测试',
                    textAlign: TextAlign.center,
                  ),
                ),
                Align(
                  alignment: Alignment.bottomCenter,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.blueAccent),
                        ),
                        child: const TextField(
                          decoration: InputDecoration(
                            hintText: '请输入',
                            border: InputBorder.none,
                          ),
                        ),
                      ),
                      if (keyboardVisible)
                        Container(
                          height: 40,
                          color: Colors.grey,
                          alignment: Alignment.center,
                          child: const Text('bottom bar'),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _BlurDemoPage extends StatelessWidget {
  const _BlurDemoPage();

  @override
  Widget build(BuildContext context) {
    return _simpleScaffold(
      title: 'BlurDemoPage',
      body: Stack(
        fit: StackFit.expand,
        children: [
          _catImage(width: double.infinity, height: double.infinity),
          Center(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(15),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                child: Container(
                  width: 200,
                  height: 200,
                  color: Colors.white.withValues(alpha: 0.15),
                  alignment: Alignment.center,
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.ac_unit),
                      SizedBox(width: 8),
                      Text('哇！！'),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AnimationContainerDemoPage extends StatefulWidget {
  const _AnimationContainerDemoPage();

  @override
  State<_AnimationContainerDemoPage> createState() =>
      _AnimationContainerDemoPageState();
}

class _AnimationContainerDemoPageState
    extends State<_AnimationContainerDemoPage> {
  final math.Random _random = math.Random();
  double _width = 50;
  double _height = 50;
  double _radius = 8;
  Color _color = Colors.green;

  @override
  Widget build(BuildContext context) {
    return _simpleScaffold(
      title: 'AnimationContainerDemoPage Demo',
      body: Center(
        child: AnimatedContainer(
          width: _width,
          height: _height,
          duration: const Duration(seconds: 1),
          curve: Curves.fastOutSlowIn,
          decoration: BoxDecoration(
            color: _color,
            borderRadius: BorderRadius.circular(_radius),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => setState(() {
          _width = _random.nextDouble() * 299;
          _height = _random.nextDouble() * 299;
          _radius = _random.nextDouble() * 99;
          _color = Color.fromARGB(
            255,
            _random.nextInt(255),
            _random.nextInt(255),
            _random.nextInt(255),
          );
        }),
        child: const Icon(Icons.play_arrow),
      ),
    );
  }
}

class _TickClickDemoPage extends StatefulWidget {
  const _TickClickDemoPage();

  @override
  State<_TickClickDemoPage> createState() => _TickClickDemoPageState();
}

class _TickClickDemoPageState extends State<_TickClickDemoPage> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return _simpleScaffold(
      title: 'TickClickDemoPage',
      body: Center(
        child: Container(
          width: width,
          height: width,
          color: Colors.greenAccent,
          child: CustomPaint(painter: _TickClockPainter(DateTime.now())),
        ),
      ),
    );
  }
}

class _TickClockPainter extends CustomPainter {
  final DateTime time;

  const _TickClockPainter(this.time);

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..color = Colors.white.withValues(alpha: 0.75);
    for (final radius in [
      size.width * .18,
      size.width * .31,
      size.width * .44,
    ]) {
      canvas.drawCircle(center, radius, paint);
    }
    _drawRing(canvas, center, size.width * .18, 12, time.hour % 12, 'H');
    _drawRing(canvas, center, size.width * .31, 60, time.minute, 'M');
    _drawRing(canvas, center, size.width * .44, 60, time.second, 'S');
    _drawCentered(
      canvas,
      center.translate(0, -12),
      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:${time.second.toString().padLeft(2, '0')}',
      20,
      Colors.white,
    );
    _drawCentered(
      canvas,
      center.translate(0, 16),
      '${time.month}/${time.day}',
      13,
      Colors.white70,
    );
  }

  void _drawRing(
    Canvas canvas,
    Offset center,
    double radius,
    int count,
    int active,
    String prefix,
  ) {
    for (var i = 0; i < count; i++) {
      final angle = -math.pi / 2 + i / count * 2 * math.pi;
      final offset = center + Offset(math.cos(angle), math.sin(angle)) * radius;
      _drawCentered(
        canvas,
        offset,
        '$prefix$i',
        i == active ? 13 : 9,
        i == active ? Colors.redAccent : Colors.black87,
      );
    }
  }

  void _drawCentered(
    Canvas canvas,
    Offset center,
    String text,
    double size,
    Color color,
  ) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(fontSize: size, color: color),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    painter.paint(
      canvas,
      center - Offset(painter.width / 2, painter.height / 2),
    );
  }

  @override
  bool shouldRepaint(covariant _TickClockPainter oldDelegate) =>
      oldDelegate.time.second != time.second;
}

class _AnimaDemoPage4 extends StatefulWidget {
  const _AnimaDemoPage4();

  @override
  State<_AnimaDemoPage4> createState() => _AnimaDemoPage4State();
}

class _AnimaDemoPage4State extends State<_AnimaDemoPage4> {
  bool _showClear = true;

  @override
  Widget build(BuildContext context) {
    final icon = _showClear ? Icons.clear : Icons.add;
    return _simpleScaffold(
      title: 'AnimaDemoPage4',
      actions: [
        IconButton(
          onPressed: _toggle,
          icon: AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            transitionBuilder: (child, animation) =>
                ScaleTransition(scale: animation, child: child),
            child: Icon(icon, key: ValueKey(icon)),
          ),
        ),
      ],
      body: const SizedBox.expand(),
      floatingActionButton: FloatingActionButton(
        onPressed: _toggle,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          transitionBuilder: (child, animation) =>
              ScaleTransition(scale: animation, child: child),
          child: Icon(icon, key: ValueKey('fab-$icon')),
        ),
      ),
    );
  }

  void _toggle() => setState(() => _showClear = !_showClear);
}

class _ListAnimDemoPage extends StatefulWidget {
  final int variant;

  const _ListAnimDemoPage({required this.variant});

  @override
  State<_ListAnimDemoPage> createState() => _ListAnimDemoPageState();
}

class _ListAnimDemoPageState extends State<_ListAnimDemoPage> {
  double _pixels = 0;

  @override
  Widget build(BuildContext context) {
    final title = widget.variant == 1
        ? '列表滑动过程 item 停靠动画效果'
        : '列表滑动过程 item 停靠动画效果2';
    final alpha = (_pixels / 180).clamp(0.0, 1.0);
    final statusTop = MediaQuery.paddingOf(context).top;
    final dynamicValue = 300 - 40 - kToolbarHeight - statusTop;
    final marginEdge = _pixels >= dynamicValue
        ? math.max(0.0, 10 - (_pixels - dynamicValue))
        : (widget.variant == 1 ? 10.0 : 0.0);
    final showStick = _pixels >= dynamicValue && marginEdge == 0;

    return Stack(
      children: [
        Scaffold(
          appBar: AppBar(title: Text(title)),
          body: MediaQuery.removePadding(
            context: context,
            removeTop: true,
            child: NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                if (notification is ScrollUpdateNotification ||
                    notification is ScrollMetricsNotification) {
                  setState(() => _pixels = notification.metrics.pixels);
                }
                return false;
              },
              child: ListView.builder(
                physics: const AlwaysScrollableScrollPhysics(),
                itemCount: 100,
                itemBuilder: (context, index) {
                  if (index == 0) {
                    return SizedBox(
                      height: 300,
                      child: Stack(
                        children: [
                          _catImage(
                            width: MediaQuery.sizeOf(context).width,
                            height: 260,
                            fit: BoxFit.cover,
                          ),
                          Align(
                            alignment: Alignment.bottomCenter,
                            child: Container(
                              height: 60,
                              color: Colors.amber,
                              margin: EdgeInsets.symmetric(
                                horizontal: widget.variant == 1
                                    ? marginEdge
                                    : 10,
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                              ),
                              child: const Row(
                                children: [
                                  Text(
                                    'StickText',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 20,
                                    ),
                                  ),
                                  Spacer(),
                                  Icon(Icons.ac_unit, color: Colors.white),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }
                  return Card(
                    child: Container(
                      height: 60,
                      alignment: Alignment.centerLeft,
                      child: Text('Item ${[index]} FFFFF'),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
        _HeaderAppBarOverlay(
          alpha: alpha,
          showStick: showStick,
          variant: widget.variant,
        ),
      ],
    );
  }
}

class _HeaderAppBarOverlay extends StatelessWidget {
  final double alpha;
  final bool showStick;
  final int variant;

  const _HeaderAppBarOverlay({
    required this.alpha,
    required this.showStick,
    required this.variant,
  });

  @override
  Widget build(BuildContext context) {
    final statusTop = MediaQuery.paddingOf(context).top;
    const reactHeight = 30.0;
    final color = Theme.of(context).primaryColor.withValues(alpha: alpha);
    final stick = Container(
      key: const ValueKey('stickItem'),
      alignment: Alignment.centerLeft,
      width: MediaQuery.sizeOf(context).width,
      height: reactHeight,
      color: Colors.amber,
      padding: const EdgeInsets.only(left: 10),
      child: const Row(
        children: [
          Icon(Icons.ac_unit, color: Colors.white, size: 13),
          SizedBox(width: 10),
          Text('StickText', style: TextStyle(color: Colors.white)),
        ],
      ),
    );
    return Material(
      color: Colors.transparent,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(height: statusTop, color: color),
          Container(
            height: kToolbarHeight,
            color: color,
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  margin: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: Colors.white.withAlpha(125),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: InkWell(
                    onTap: () => Navigator.of(context).maybePop(),
                    child: const Icon(
                      Icons.arrow_back_ios,
                      color: Colors.white,
                    ),
                  ),
                ),
                Expanded(
                  child: Container(
                    height: kToolbarHeight - 15,
                    margin: const EdgeInsets.symmetric(horizontal: 20),
                    decoration: BoxDecoration(
                      color: Colors.white.withAlpha(125),
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (variant == 1)
            if (showStick) stick else const SizedBox.shrink()
          else
            AnimatedSwitcher(
              duration: Duration(milliseconds: showStick ? 500 : 1),
              transitionBuilder: (child, animation) {
                if (showStick) {
                  return SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, -0.5),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  );
                }
                return FadeTransition(opacity: animation, child: child);
              },
              child: showStick
                  ? stick
                  : const SizedBox(key: ValueKey('hideItem')),
            ),
        ],
      ),
    );
  }
}

class _DropSelectDemoPage extends StatefulWidget {
  const _DropSelectDemoPage();

  @override
  State<_DropSelectDemoPage> createState() => _DropSelectDemoPageState();
}

class _DropSelectDemoPageState extends State<_DropSelectDemoPage> {
  int? _active;
  final List<String> _titles = ['title1', 'title2', 'title3'];

  @override
  Widget build(BuildContext context) {
    return _simpleScaffold(
      title: 'DropSelectDemoPage',
      body: Stack(
        children: [
          Column(
            children: [
              Row(
                children: List.generate(3, (index) {
                  final selected = _active == index;
                  return Expanded(
                    child: InkWell(
                      onTap: () =>
                          setState(() => _active = selected ? null : index),
                      child: Container(
                        height: 48,
                        alignment: Alignment.center,
                        decoration: const BoxDecoration(
                          border: Border(
                            bottom: BorderSide(color: Colors.black12),
                          ),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(_titles[index]),
                            Icon(
                              selected ? Icons.expand_less : Icons.expand_more,
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                }),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: 100,
                  itemBuilder: (_, index) =>
                      ListTile(title: Text('Text $index')),
                ),
              ),
            ],
          ),
          if (_active != null) ...[
            Positioned.fill(
              top: 48,
              child: GestureDetector(
                onTap: () => setState(() => _active = null),
                child: Container(color: Colors.black.withValues(alpha: 0.25)),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              top: 48,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                child: _dropMenu(_active!),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _dropMenu(int index) {
    if (index == 2) {
      return Material(
        key: ValueKey(index),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(6, (i) {
            return ListTile(
              title: Text('single select $i'),
              trailing: i == 1 ? const Icon(Icons.check) : null,
              onTap: () => setState(() {
                _titles[index] = 'single select $i';
                _active = null;
              }),
            );
          }),
        ),
      );
    }
    return Material(
      key: ValueKey(index),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GridView.builder(
            shrinkWrap: true,
            padding: const EdgeInsets.all(12),
            itemCount: 12,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              childAspectRatio: 2.8,
              mainAxisSpacing: 8,
              crossAxisSpacing: 8,
            ),
            itemBuilder: (_, i) => OutlinedButton(
              onPressed: () {},
              child: Text(index == 0 ? '分类$i' : '区域$i'),
            ),
          ),
          Row(
            children: [
              Expanded(
                child: TextButton(onPressed: () {}, child: const Text('重置')),
              ),
              Expanded(
                child: FilledButton(
                  onPressed: () => setState(() => _active = null),
                  child: const Text('确定'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _AnimaDemoPage5 extends StatefulWidget {
  const _AnimaDemoPage5();

  @override
  State<_AnimaDemoPage5> createState() => _AnimaDemoPage5State();
}

class _AnimaDemoPage5State extends State<_AnimaDemoPage5>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1800),
  );
  bool _forward = true;

  static const _text = 'Hello GSY，欢迎你的交流';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _simpleScaffold(
      title: 'AnimaDemoPage5',
      body: Center(
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            return Wrap(
              alignment: WrapAlignment.center,
              children: List.generate(_text.characters.length, (index) {
                final start = index * 0.04;
                final value = ((_controller.value - start) / 0.35).clamp(
                  0.0,
                  1.0,
                );
                final eased = Curves.easeInOutExpo.transform(value);
                final char = _text.characters.elementAt(index);
                return Opacity(
                  opacity: eased,
                  child: Transform.translate(
                    offset: Offset(0, (1 - eased) * 5),
                    child: Text(char, style: const TextStyle(fontSize: 20)),
                  ),
                );
              }),
            );
          },
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          if (_forward) {
            _controller.forward(from: 0);
          } else {
            _controller.reverse(from: 1);
          }
          setState(() => _forward = !_forward);
        },
        child: Icon(_forward ? Icons.play_arrow : Icons.replay),
      ),
    );
  }
}

class _ScrollHeaderDemoPage extends StatefulWidget {
  const _ScrollHeaderDemoPage();

  @override
  State<_ScrollHeaderDemoPage> createState() => _ScrollHeaderDemoPageState();
}

class _ScrollHeaderDemoPageState extends State<_ScrollHeaderDemoPage> {
  bool _pinned = true;
  bool _minHeight = true;
  bool _autoBack = false;

  @override
  Widget build(BuildContext context) {
    return _simpleScaffold(
      title: 'ScrollHeaderDemoPage',
      body: CustomScrollView(
        slivers: [
          SliverPersistentHeader(
            pinned: _pinned,
            delegate: _ImageHeaderDelegate(
              minExtentValue: _minHeight ? 80 : 0,
              maxExtentValue: 260,
              autoBack: _autoBack,
            ),
          ),
          SliverGrid.builder(
            itemCount: 40,
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              mainAxisSpacing: 6,
              crossAxisSpacing: 6,
            ),
            itemBuilder: (context, index) => Card(
              color: Colors.primaries[index % Colors.primaries.length].shade100,
              child: Center(child: Text('Item $index')),
            ),
          ),
        ],
      ),
      persistentFooterButtons: [
        TextButton(
          onPressed: () => setState(() => _pinned = !_pinned),
          child: Text('Pinned: $_pinned'),
        ),
        TextButton(
          onPressed: () => setState(() => _minHeight = !_minHeight),
          child: Text('MinHeight: $_minHeight'),
        ),
        TextButton(
          onPressed: () => setState(() => _autoBack = !_autoBack),
          child: Text('AutoBack: $_autoBack'),
        ),
      ],
    );
  }
}

class _CustomViewportPage extends StatelessWidget {
  const _CustomViewportPage();

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: _simpleScaffold(
        title: 'CustomViewportPage',
        body: NestedScrollView(
          headerSliverBuilder: (_, __) => [
            SliverToBoxAdapter(
              child: Container(
                height: 110,
                color: Colors.blueGrey.shade100,
                alignment: Alignment.center,
                child: const Text('Custom Viewport Header'),
              ),
            ),
            SliverPersistentHeader(
              pinned: true,
              delegate: _FixedHeaderDelegate(
                height: 48,
                child: Container(
                  color: Colors.white,
                  child: const TabBar(
                    tabs: [
                      Tab(text: 'Tab 1'),
                      Tab(text: 'Tab 2'),
                      Tab(text: 'Tab 3'),
                    ],
                  ),
                ),
              ),
            ),
            SliverPersistentHeader(
              pinned: true,
              delegate: _FixedHeaderDelegate(
                height: 44,
                child: Container(
                  color: Colors.amber,
                  alignment: Alignment.center,
                  child: const Text('Second sticky sliver renders above list'),
                ),
              ),
            ),
          ],
          body: TabBarView(
            children: List.generate(3, (tab) {
              return GridView.builder(
                padding: const EdgeInsets.all(8),
                itemCount: 40,
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  mainAxisSpacing: 6,
                  crossAxisSpacing: 6,
                ),
                itemBuilder: (_, index) =>
                    Card(child: Center(child: Text('T$tab-$index'))),
              );
            }),
          ),
        ),
      ),
    );
  }
}

class _AnimTipDemoPage extends StatefulWidget {
  const _AnimTipDemoPage();

  @override
  State<_AnimTipDemoPage> createState() => _AnimTipDemoPageState();
}

class _AnimTipDemoPageState extends State<_AnimTipDemoPage> {
  bool _show = false;

  @override
  Widget build(BuildContext context) {
    return _simpleScaffold(
      title: 'AnimTipDemoPage',
      body: Stack(
        children: [
          Center(
            child: ElevatedButton(
              onPressed: () {
                setState(() => _show = true);
                Future<void>.delayed(const Duration(seconds: 1), () {
                  if (mounted) setState(() => _show = false);
                });
              },
              child: const Text('Click Me'),
            ),
          ),
          AnimatedSlide(
            offset: _show ? Offset.zero : const Offset(0, -1),
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
            child: AnimatedOpacity(
              opacity: _show ? 1 : 0,
              duration: const Duration(milliseconds: 300),
              child: Container(
                height: 70,
                color: Colors.amber,
                alignment: Alignment.center,
                child: const Text('Hello GSY', style: TextStyle(fontSize: 18)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StickSliverListDemoPage extends StatefulWidget {
  const _StickSliverListDemoPage();

  @override
  State<_StickSliverListDemoPage> createState() =>
      _StickSliverListDemoPageState();
}

class _StickSliverListDemoPageState extends State<_StickSliverListDemoPage> {
  final ScrollController _controller = ScrollController();
  final Set<int> _expanded = <int>{};
  int _current = 0;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      final next = (_controller.offset / 250).floor().clamp(0, 6);
      if (next != _current) setState(() => _current = next);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _simpleScaffold(
      title: 'StickSliverListDemoPage',
      body: Stack(
        children: [
          CustomScrollView(
            controller: _controller,
            slivers: List.generate(7, _groupSlivers).expand((e) => e).toList(),
          ),
          Align(
            alignment: Alignment.topCenter,
            child: Container(
              height: 44,
              color: Colors.deepPurple,
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.only(left: 10),
              child: Text(
                '我的 $_current 头啊',
                style: const TextStyle(color: Colors.white),
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          _controller.animateTo(
            _current * 250.0,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        },
        child: const Icon(Icons.vertical_align_top),
      ),
    );
  }

  List<Widget> _groupSlivers(int index) {
    final count = 5 + (index * 3) % 8;
    final expanded = _expanded.contains(index);
    final visible = expanded ? count : math.min(3, count);
    return [
      SliverPersistentHeader(
        pinned: true,
        delegate: _FixedHeaderDelegate(
          height: 50,
          child: Container(
            color: Colors.deepPurple,
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.only(left: 10),
            child: Text(
              '我的 $index 头啊',
              style: const TextStyle(color: Colors.white),
            ),
          ),
        ),
      ),
      SliverList(
        delegate: SliverChildBuilderDelegate((_, childIndex) {
          if (childIndex < visible) {
            return _pinkContent('我的$index 内容 $childIndex 啊');
          }
          return InkWell(
            onTap: () => setState(() {
              if (expanded) {
                _expanded.remove(index);
              } else {
                _expanded.add(index);
              }
            }),
            child: Container(
              height: 44,
              color: Colors.grey.shade300,
              alignment: Alignment.center,
              child: Text(expanded ? '收起' : '查看更多'),
            ),
          );
        }, childCount: visible + (count > 3 ? 1 : 0)),
      ),
    ];
  }
}

class _OverflowImagePage extends StatelessWidget {
  const _OverflowImagePage();

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return _simpleScaffold(
      title: 'OverflowImagePage',
      body: ListView(
        physics: const ClampingScrollPhysics(),
        children: [
          SizedBox(
            height: 100,
            child: OverflowBox(
              alignment: Alignment.center,
              maxHeight: MediaQuery.sizeOf(context).height,
              child: _catImage(
                width: width,
                height: width * 220 / 247,
                fit: BoxFit.fill,
              ),
            ),
          ),
          Container(
            color: Colors.blue,
            height: MediaQuery.sizeOf(context).height,
          ),
        ],
      ),
    );
  }
}

class _AlignDemoPage extends StatelessWidget {
  const _AlignDemoPage();

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return _simpleScaffold(
      title: 'AlignDemoPage',
      body: Center(
        child: SizedBox(
          width: width,
          height: width,
          child: Stack(
            children: List.generate(20, (index) {
              final x = index / 20 / 2;
              return Align(
                alignment: Alignment(
                  math.cos(x * math.pi),
                  math.sin(x * math.pi),
                ),
                child: Container(
                  height: 20,
                  width: 20,
                  decoration: BoxDecoration(
                    color: Colors.green,
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}

class _CardItemPage extends StatelessWidget {
  const _CardItemPage();

  @override
  Widget build(BuildContext context) {
    final itemHeight = MediaQuery.sizeOf(context).width / 6;
    final textSize = 15.0 * MediaQuery.sizeOf(context).width / 414.0;
    return _simpleScaffold(
      title: 'CardItemPage',
      backgroundColor: Colors.blueAccent,
      body: Column(
        children: [
          _cardRow(70, 15),
          _cardRow(itemHeight, textSize),
          _cardRow(70, 15, tinted: true),
          _cardRow(itemHeight, textSize, tinted: true),
        ],
      ),
    );
  }

  Widget _cardRow(double imageSize, double textSize, {bool tinted = false}) {
    return Card(
      margin: const EdgeInsets.all(5),
      child: Container(
        margin: const EdgeInsets.only(right: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            ClipRRect(
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(4),
                bottomLeft: Radius.circular(4),
              ),
              child: ColorFiltered(
                colorFilter: tinted
                    ? const ColorFilter.mode(Colors.indigo, BlendMode.modulate)
                    : const ColorFilter.mode(Colors.transparent, BlendMode.dst),
                child: _catImage(width: imageSize, height: imageSize),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF',
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: textSize),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SliverTabDemoPage extends StatelessWidget {
  final int variant;

  const _SliverTabDemoPage({required this.variant});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: _simpleScaffold(
        title: variant == 1 ? 'SliverTabDemoPage' : 'SliverTabDemoPage2',
        body: NestedScrollView(
          headerSliverBuilder: (context, innerBoxIsScrolled) => [
            SliverAppBar(
              pinned: true,
              expandedHeight: variant == 1 ? 210 : 240,
              flexibleSpace: FlexibleSpaceBar(
                background: Container(
                  color: Colors.blue,
                  alignment: Alignment.center,
                  child: Icon(
                    Icons.map,
                    color: Colors.white.withValues(alpha: 0.86),
                    size: variant == 1 ? 86 : 112,
                  ),
                ),
              ),
              bottom: const TabBar(
                tabs: [
                  Tab(text: 'Tab 1'),
                  Tab(text: 'Tab 2'),
                  Tab(text: 'Tab 3'),
                ],
              ),
            ),
          ],
          body: TabBarView(
            children: [_tabList(50), _tabList(30), _tabList(80)],
          ),
        ),
      ),
    );
  }

  Widget _tabList(int count) {
    return ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: count,
      itemBuilder: (_, index) => Card(
        child: Container(
          height: 56,
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.only(left: 16),
          child: Text('Item $index'),
        ),
      ),
    );
  }
}

class _FixedHeaderDelegate extends SliverPersistentHeaderDelegate {
  final double height;
  final Widget child;

  const _FixedHeaderDelegate({required this.height, required this.child});

  @override
  double get minExtent => height;

  @override
  double get maxExtent => height;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    return SizedBox.expand(child: child);
  }

  @override
  bool shouldRebuild(covariant _FixedHeaderDelegate oldDelegate) {
    return oldDelegate.height != height || oldDelegate.child != child;
  }
}

class _ImageHeaderDelegate extends SliverPersistentHeaderDelegate {
  final double minExtentValue;
  final double maxExtentValue;
  final bool autoBack;

  const _ImageHeaderDelegate({
    required this.minExtentValue,
    required this.maxExtentValue,
    required this.autoBack,
  });

  @override
  double get minExtent => minExtentValue;

  @override
  double get maxExtent => maxExtentValue;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final progress = (shrinkOffset / (maxExtent - minExtent).clamp(1, 9999))
        .clamp(0.0, 1.0);
    return Stack(
      fit: StackFit.expand,
      children: [
        _catImage(width: double.infinity, height: double.infinity),
        Container(color: Colors.red.withValues(alpha: 0.18 + progress * 0.5)),
        Align(
          alignment: Alignment.bottomLeft,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              autoBack ? 'Auto back header' : 'Custom Sliver Header',
              style: const TextStyle(color: Colors.white, fontSize: 20),
            ),
          ),
        ),
      ],
    );
  }

  @override
  bool shouldRebuild(covariant _ImageHeaderDelegate oldDelegate) {
    return oldDelegate.minExtentValue != minExtentValue ||
        oldDelegate.maxExtentValue != maxExtentValue ||
        oldDelegate.autoBack != autoBack;
  }
}
