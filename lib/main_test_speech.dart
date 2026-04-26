import 'package:flutter/material.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

void main() {
  runApp(const TestSpeechApp());
}

class TestSpeechApp extends StatelessWidget {
  const TestSpeechApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Speech Test',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const TestSpeechPage(),
    );
  }
}

class TestSpeechPage extends StatefulWidget {
  const TestSpeechPage({Key? key}) : super(key: key);

  @override
  State<TestSpeechPage> createState() => _TestSpeechPageState();
}

class _TestSpeechPageState extends State<TestSpeechPage> {
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _speechInited = false;
  bool _isListening = false;
  String _text = '按住按钮开始说话';

  @override
  void initState() {
    super.initState();
    _initSpeech();
  }

  Future<void> _initSpeech() async {
    try {
      _speechInited = await _speech.initialize(
        onError: (error) {
          debugPrint('Speech error: ${error.errorMsg}');
          setState(() {
            _text = 'Error: ${error.errorMsg}';
          });
        },
        onStatus: (status) {
          debugPrint('Speech status: $status');
        },
      );
      debugPrint('Speech initialized: $_speechInited');
      if (!_speechInited) {
        setState(() {
          _text = '语音识别初始化失败';
        });
      }
    } catch (e) {
      debugPrint('Init error: $e');
      setState(() {
        _text = '初始化异常: $e';
      });
    }
  }

  void _startListening() {
    if (!_speechInited) {
      setState(() {
        _text = '语音识别未初始化';
      });
      return;
    }

    debugPrint('Starting to listen...');
    _speech.listen(
      onResult: (result) {
        debugPrint('Result: ${result.recognizedWords}');
        setState(() {
          _text = result.recognizedWords;
        });
      },
      localeId: 'zh_CN',
      listenFor: const Duration(seconds: 30),
      pauseFor: const Duration(seconds: 5),
      listenOptions: stt.SpeechListenOptions(
        listenMode: stt.ListenMode.dictation,
        cancelOnError: false,
        partialResults: true,
      ),
    );

    setState(() {
      _isListening = true;
    });
  }

  void _stopListening() {
    debugPrint('Stopping...');
    _speech.stop();
    setState(() {
      _isListening = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Speech Test'),
      ),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Padding(
              padding: const EdgeInsets.all(20),
              child: Text(
                _text,
                style: const TextStyle(fontSize: 24),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 50),
            GestureDetector(
              onLongPressStart: (_) => _startListening(),
              onLongPressEnd: (_) => _stopListening(),
              child: Container(
                width: 200,
                height: 200,
                decoration: BoxDecoration(
                  color: _isListening ? Colors.red : Colors.blue,
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Text(
                    _isListening ? '松开停止' : '按住说话',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 30),
            Text(
              'Initialized: $_speechInited',
              style: const TextStyle(fontSize: 14, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _speech.stop();
    super.dispose();
  }
}
