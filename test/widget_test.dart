// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:music_player4/main.dart';
import 'package:music_player4/audio_handler.dart';

void main() {
  testWidgets('Music player app smoke test', (WidgetTester tester) async {
    // 创建一个音频处理器实例
    final audioHandler = MusicPlayerHandler();
    
    // Build our app and trigger a frame.
    await tester.pumpWidget(MyApp(audioHandler: audioHandler));

    // Verify that the app title is displayed
    expect(find.text('音乐控制器'), findsOneWidget);
    
    // Verify that the main title is displayed
    expect(find.text('音乐播放控制器'), findsOneWidget);
    
    // Verify that volume control is displayed
    expect(find.text('音量控制'), findsOneWidget);
    
    // Verify that media control buttons are displayed
    expect(find.byIcon(Icons.skip_previous), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    expect(find.byIcon(Icons.pause), findsOneWidget);
    expect(find.byIcon(Icons.stop), findsOneWidget);
    expect(find.byIcon(Icons.skip_next), findsOneWidget);
  });
}