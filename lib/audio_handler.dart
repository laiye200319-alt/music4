import 'package:audio_service/audio_service.dart';
import 'package:flutter/services.dart';

/// 处理音频控制命令的类
class MusicPlayerHandler extends BaseAudioHandler {
  // 当前播放状态，默认为暂停
  bool _playing = false;

  // 当前音量，默认为50%
  double _volume = 0.5;

  // 与原生代码通信的通道
  static const platform = MethodChannel('media_controls');

  MusicPlayerHandler() {
    // 初始化播放状态
    playbackState.add(
      PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          MediaControl.play,
          MediaControl.pause,
          MediaControl.stop,
          MediaControl.skipToNext,
        ],
        systemActions: const {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        androidCompactActionIndices: const [0, 1, 3],
        processingState: AudioProcessingState.ready,
        playing: false,
      ),
    );
  }

  /// 播放音乐
  @override
  Future<void> play() async {
    _playing = true;
    // 发送播放命令到原生代码
    try {
      print("Sending play command to native code");
      final result = await platform.invokeMethod('play');
      print("Play command sent successfully, result: $result");
    } on PlatformException catch (e) {
      print("播放音乐失败 (PlatformException): ${e.message}");
    } catch (e) {
      print("播放音乐出现未知错误: $e");
    }
    broadcastState();
    print("播放音乐完成");
  }

  /// 暂停音乐
  @override
  Future<void> pause() async {
    _playing = false;
    // 发送暂停命令到原生代码
    try {
      print("Sending pause command to native code");
      final result = await platform.invokeMethod('pause');
      print("Pause command sent successfully, result: $result");
    } on PlatformException catch (e) {
      print("暂停音乐失败 (PlatformException): ${e.message}");
    } catch (e) {
      print("暂停音乐出现未知错误: $e");
    }
    broadcastState();
    print("暂停音乐完成");
  }

  /// 停止音乐
  @override
  Future<void> stop() async {
    _playing = false;
    // 发送停止命令到原生代码
    try {
      print("Sending stop command to native code");
      final result = await platform.invokeMethod('stop'); // 修改为调用 'stop' 方法
      print("Stop command sent successfully, result: $result");
    } on PlatformException catch (e) {
      print("停止音乐失败 (PlatformException): ${e.message}");
    } catch (e) {
      print("停止音乐出现未知错误: $e");
    }
    broadcastState();
    print("停止音乐完成");
  }

  /// 上一首
  @override
  Future<void> skipToPrevious() async {
    // 发送上一首命令到原生代码
    try {
      print("Sending previous command to native code");
      final result = await platform.invokeMethod('previous');
      print("Previous command sent successfully, result: $result");
    } on PlatformException catch (e) {
      print("切换到上一首失败 (PlatformException): ${e.message}");
    } catch (e) {
      print("切换到上一首出现未知错误: $e");
    }
    print("切换到上一首完成");
  }

  /// 下一首
  @override
  Future<void> skipToNext() async {
    // 发送下一首命令到原生代码
    try {
      print("Sending next command to native code");
      final result = await platform.invokeMethod('next');
      print("Next command sent successfully, result: $result");
    } on PlatformException catch (e) {
      print("切换到下一首失败 (PlatformException): ${e.message}");
    } catch (e) {
      print("切换到下一首出现未知错误: $e");
    }
    print("切换到下一首完成");
  }

  /// 设置音量 - 自定义方法
  Future<void> setVolume(double volume) async {
    _volume = volume.clamp(0.0, 1.0);
    // 发送设置音量命令到原生代码
    try {
      print("Sending volume command to native code: $volume");
      final result = await platform.invokeMethod('setVolume', {
        'level': volume,
      });
      print("Volume command sent successfully, result: $result");
    } on PlatformException catch (e) {
      print("设置音量失败 (PlatformException): ${e.message}");
    } catch (e) {
      print("设置音量出现未知错误: $e");
    }
    print("设置音量为: ${_volume.toStringAsFixed(2)}");
  }

  /// 广播当前状态
  void broadcastState() {
    final controls = [
      if (_playing) MediaControl.pause else MediaControl.play,
      MediaControl.stop,
      MediaControl.skipToPrevious,
      MediaControl.skipToNext,
    ];

    playbackState.add(
      playbackState.value.copyWith(controls: controls, playing: _playing),
    );
  }
}
