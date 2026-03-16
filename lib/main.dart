import 'package:flutter/material.dart';
import 'package:vector_math/vector_math_64.dart' show radians;
import 'package:flutter/services.dart';
import 'dart:math' as math;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'bluetooth_service.dart';
import 'package:flutter/foundation.dart';
import 'dart:async';
import 'package:audio_service/audio_service.dart'; // 添加audio_service
import 'audio_handler.dart'; // 需要创建这个文件

void main() async {
  // 确保WidgetsFlutterBinding初始化
  WidgetsFlutterBinding.ensureInitialized();

  // 初始化音频服务
  late AudioHandler audioHandler;
  try {
    audioHandler = await AudioService.init(
      builder: () => MusicPlayerHandler(),
      config: const AudioServiceConfig(
        androidNotificationChannelId:
            'com.example.digital_signal_processor.channel.audio',
        androidNotificationChannelName: 'Music playback',
        androidNotificationOngoing: true,
        androidShowNotificationBadge: true,
      ),
    );
  } catch (e) {
    // 如果音频服务初始化失败，则创建一个基本的处理器
    print("AudioService initialization failed: $e");
    audioHandler = MusicPlayerHandler();
  }

  runApp(MyApp(audioHandler: audioHandler));
}

class MyApp extends StatelessWidget {
  final AudioHandler audioHandler;

  const MyApp({super.key, required this.audioHandler});

  @override
  Widget build(BuildContext context) {
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.dark,
        systemNavigationBarColor: Colors.white,
        systemNavigationBarIconBrightness: Brightness.dark,
      ),
    );

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Digital Signal Processor',
      theme: ThemeData(
        fontFamily: 'Roboto',
        brightness: Brightness.light,
        primaryColor: const Color(0xFF2E7D32),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF2E7D32),
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF5F7FA),
        textTheme: const TextTheme(
          displayLarge: TextStyle(
            fontSize: 32,
            fontWeight: FontWeight.bold,
            color: Color(0xFF1A1A1A),
          ),
          displayMedium: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w600,
            color: Color(0xFF1A1A1A),
          ),
          bodyLarge: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.normal,
            color: Color(0xFF4A4A4A),
          ),
          bodyMedium: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.normal,
            color: Color(0xFF6B6B6B),
          ),
        ),
        useMaterial3: true,
        cardTheme: CardThemeData(
          elevation: 2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: Color(0xFFE0E0E0), width: 1),
          ),
        ),
      ),
      builder: (context, child) {
        final mediaQuery = MediaQuery.of(context);
        // 固定字体缩放为1.0，确保App内容不受系统字体设置影响
        return MediaQuery(
          data: mediaQuery.copyWith(textScaleFactor: 1.0),
          child: child!,
        );
      },
      home: AudioControllerScreen(audioHandler: audioHandler), // 传递audioHandler
    );
  }

  // 构建自适应布局以适应大字体
  Widget _buildAdaptiveLayout(Widget child) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // 计算基于屏幕宽度的缩放比例
        final scale = math.min(1.0, constraints.maxWidth / 400.0);

        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Transform.scale(
              scale: scale,
              child: OverflowBox(
                maxWidth: constraints.maxWidth / scale,
                maxHeight: constraints.maxHeight / scale,
                child: child,
              ),
            ),
          ),
        );
      },
    );
  }
}

class AudioControllerScreen extends StatefulWidget {
  final AudioHandler audioHandler;

  const AudioControllerScreen({super.key, required this.audioHandler});

  @override
  State<AudioControllerScreen> createState() => _AudioControllerScreenState();
}

class _AudioControllerScreenState extends State<AudioControllerScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  double volumeValue = 16.0;
  double effectValue = 16.0;
  String selectedEffect = 'Normal';
  bool isConnected = false;
  bool isScanning = false;
  bool isConnecting = false;
  List<dynamic> devices = [];
  Map<String, BluetoothConnectionState> deviceConnectionStates = {};

  // 新增状态变量
  String selectedInputSource = 'BT'; // FM, AUX, USB/SD, BT
  bool isPlaying = false;
  String selectedXBass = '1'; // 1, 2, 3
  String selectedEffectMode = 'MAN'; // MAN, GIRL, PRIORITY

  final AmpBluetoothService _bluetoothService = AmpBluetoothService();
  static double _sharedVolumeValue = 16.0;
  bool _isMuted = false; // 新增静音状态

  // FM频率相关状态
  double _fmFrequency = 88.0; // FM频率，单位MHz
  final double _minFMFrequency = 87.5; // 最小FM频率
  final double _maxFMFrequency = 108.0; // 最大FM频率
  final double _fmStep = 0.1; // FM频率步进

  static double get sharedVolumeValue => _sharedVolumeValue;
  static void setSharedVolumeValue(double value) {
    _sharedVolumeValue = value;
  }

  Offset? _volumeStartPos;
  Offset? _effectStartPos;
  double _volumeStartValue = 16.0;
  double _effectStartValue = 16.0;
  bool _isPageActive = true;
  final FocusNode _focusNode = FocusNode();

  late AnimationController _muteAnimationController;
  late Animation<double> _muteAnimation;

  bool _hasShownConnectionError = false;
  bool _shouldNavigateToBluetooth = false;

  Timer? _volumeThrottleTimer;
  Timer? _effectThrottleTimer;
  double _lastSentVolume = 16.0;
  double _lastSentEffect = 16.0;
  bool _isVolumeDragging = false;
  bool _isEffectDragging = false;

  bool _isReconnecting = false;

  bool _hasShownSyncSuccess = false;
  bool _hasShownSyncError = false;

  // 添加设备状态监听
  StreamSubscription<Map<String, dynamic>>? _deviceStateSubscription;
  bool _isReceivingDeviceState = false;
  bool _hasRequestedInitialState = false;
  bool _isBluetoothEnabled = true;
  StreamSubscription<BluetoothAdapterState>? _bluetoothAdapterSubscription;

  final List<String> soundEffects = [
    'Normal',
    '3D Normal',
    '3D Concert',
    '3D Bass',
    '3D Techno',
    'POP',
    'Classic',
    'Live',
    'Club',
  ];

  // 新增选项列表
  final List<String> inputSources = ['FM', 'AUX', 'USB/SD', 'BT'];
  final List<String> xbassOptions = ['1', '2', '3'];
  final List<String> effectModes = ['MAN', 'GIRL', 'PRIORITY'];

  StreamSubscription<bool>? _connectionStatusSubscription;
  StreamSubscription<BluetoothConnectionState>? _deviceConnectionSubscription;

  // 添加audio_service播放状态监听
  StreamSubscription<PlaybackState>? _playbackStateSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _muteAnimationController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );

    _muteAnimation = Tween<double>(begin: 1.0, end: 1.2).animate(
      CurvedAnimation(
        parent: _muteAnimationController,
        curve: Curves.easeInOut,
      ),
    );

    _initializeBluetoothListeners();
    _startBluetoothAdapterMonitoring();
    _initializeDeviceStateListener();

    // 添加连接健康监控
    _startConnectionHealthCheck();

    // 监听audio_service播放状态
    _initializeAudioServiceListeners();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshBluetoothState();

      Future.delayed(Duration(seconds: 3), () async {
        if (mounted) {
          print('🚀 Starting delayed auto-connect...');
          await _tryAutoConnectWithRetry();
        }
      });
    });
  }

  // 新增：初始化audio_service监听
  void _initializeAudioServiceListeners() {
    // 监听播放状态
    _playbackStateSubscription = widget.audioHandler.playbackState.listen((
      playbackState,
    ) {
      if (mounted) {
        setState(() {
          // 只在BT模式下使用audio_service状态，其他模式使用本地状态
          if (selectedInputSource == 'BT') {
            isPlaying = playbackState.playing;
            print(
              'AudioService状态更新: 播放中=$isPlaying, 位置=${playbackState.updatePosition?.inSeconds}秒',
            );
          }
        });
      }
    });

    // 监听媒体信息变化
    widget.audioHandler.mediaItem.listen((mediaItem) {
      if (mounted && selectedInputSource == 'BT') {
        print('AudioService媒体项更新: ${mediaItem?.title}');
      }
    });
  }

  // 新增：简化播放控制方法
  void _simplePlayPause() async {
    print('=== 播放控制按钮被点击 ===');
    print('当前输入源: $selectedInputSource');
    print('当前播放状态: $isPlaying');

    // 保存当前状态用于决定操作
    bool currentState = isPlaying;

    // 根据输入源执行不同的操作
    if (selectedInputSource == 'BT') {
      _simplePlayPauseWithAudioService(currentState);
    } else {
      await _simplePlayPauseWithBluetooth(currentState);
    }
  }

  // 简化BT模式播放控制
  void _simplePlayPauseWithAudioService(bool wasPlaying) {
    print('BT模式播放控制: ${wasPlaying ? "暂停" : "播放"}');

    try {
      if (wasPlaying) {
        widget.audioHandler.pause();
        // 移除暂停通知
      } else {
        widget.audioHandler.play();
        // 移除播放通知
      }

      // 更新UI状态
      setState(() {
        isPlaying = !wasPlaying;
      });
    } catch (e) {
      print('AudioService控制失败: $e');
      _showError('Control failed');
    }
  }

  // 简化蓝牙模式播放控制
  Future<void> _simplePlayPauseWithBluetooth(bool wasPlaying) async {
    print('蓝牙模式播放控制: ${wasPlaying ? "暂停" : "播放"}');

    if (!await _bluetoothService.isReallyConnected) {
      _showError('Device not connected');
      return;
    }

    try {
      if (wasPlaying) {
        await _bluetoothService.sendPauseCommand();
        // 移除暂停通知
      } else {
        await _bluetoothService.sendPlayCommand();
        // 移除播放通知
      }

      // 更新UI状态
      setState(() {
        isPlaying = !wasPlaying;
      });
    } catch (e) {
      print('蓝牙控制失败: $e');
      _showError('Control failed');
    }
  }

  // 新增：FM频率相关方法
  void _onFMFrequencyChanged(double value) {
    // 限制频率到指定范围，并保留一位小数
    double newFrequency = (value * 10).round() / 10.0;
    newFrequency = newFrequency.clamp(_minFMFrequency, _maxFMFrequency);

    setState(() {
      _fmFrequency = newFrequency;
    });

    _sendFMFrequencyCommand(newFrequency);
  }

  void _increaseFMFrequency() {
    double newFrequency = _fmFrequency + _fmStep;
    if (newFrequency <= _maxFMFrequency) {
      setState(() {
        _fmFrequency = newFrequency;
      });
      _sendFMFrequencyCommand(newFrequency);
    }
  }

  void _decreaseFMFrequency() {
    double newFrequency = _fmFrequency - _fmStep;
    if (newFrequency >= _minFMFrequency) {
      setState(() {
        _fmFrequency = newFrequency;
      });
      _sendFMFrequencyCommand(newFrequency);
    }
  }

  Future<void> _sendFMFrequencyCommand(double frequency) async {
    if (!await _bluetoothService.isReallyConnected) {
      _showError('Device not connected');
      return;
    }

    try {
      // 这里需要根据实际蓝牙协议发送FM频率指令
      print('Setting FM frequency to: ${frequency.toStringAsFixed(1)} MHz');
      // await _bluetoothService.sendFMFrequencyCommand(frequency);

      // 暂时使用提示
      _showSuccess('FM frequency set to ${frequency.toStringAsFixed(1)} MHz');
    } catch (e) {
      print('Failed to send FM frequency command: $e');
      _showError('Failed to set FM frequency');
    }
  }

  // 添加连接健康检查方法
  void _startConnectionHealthCheck() {
    Timer.periodic(Duration(seconds: 3), (timer) async {
      if (!mounted) {
        timer.cancel();
        return;
      }

      if (await _bluetoothService.isReallyConnected &&
          _bluetoothService.readCharacteristic != null) {
        // 检查通知是否仍然有效
        if (!_bluetoothService.readCharacteristic!.isNotifying) {
          print('⚠️ 通知特征已断开，尝试重新启用...');
          try {
            await _bluetoothService.readCharacteristic!.setNotifyValue(true);
            print('✅ 通知特征重新启用成功');
          } catch (e) {
            print('❌ 重新启用通知失败: $e');
          }
        }
      }
    });
  }

  // 新增：初始化设备状态监听
  void _initializeDeviceStateListener() {
    print('初始化设备状态监听器...');

    _deviceStateSubscription?.cancel();
    _deviceStateSubscription = _bluetoothService.deviceStateStream.listen(
      (state) {
        print('收到设备状态更新: $state');
        _updateUIFromDeviceState(state);
      },
      onError: (error) {
        print('设备状态监听错误: $error');
      },
    );
  }

  // 新增：根据设备状态更新UI
  void _updateUIFromDeviceState(Map<String, dynamic> state) {
    if (!mounted) return;

    print('根据设备状态更新UI: $state');

    setState(() {
      _isReceivingDeviceState = true;

      // 更新音量
      if (state.containsKey('volume')) {
        int volume = state['volume'];
        if (volume >= 0 && volume <= 32) {
          volumeValue = volume.toDouble();

          // 如果音量不为0，更新共享音量值（用于静音恢复）
          if (volume > 0) {
            setSharedVolumeValue(volume.toDouble());
          }

          print('📊 更新UI音量: $volume');
        }
      }

      // 更新效果强度
      if (state.containsKey('effect')) {
        int effect = state['effect'];
        if (effect >= 0 && effect <= 32) {
          effectValue = effect.toDouble();
          print('📊 更新UI效果强度: $effect');
        }
      }

      // 更新音效模式
      if (state.containsKey('effectMode')) {
        int effectMode = state['effectMode'];
        if (effectMode >= 0 && effectMode < soundEffects.length) {
          selectedEffect = soundEffects[effectMode];
          print('📊 更新UI音效模式: $selectedEffect (索引: $effectMode)');
        }
      }

      // 更新输入源
      if (state.containsKey('inputSource')) {
        String inputSource = state['inputSource'];
        if (inputSources.contains(inputSource)) {
          selectedInputSource = inputSource;
          print('📊 更新UI输入源: $inputSource');

          // 如果是FM模式，更新FM频率（如果有的话）
          if (inputSource == 'FM' && state.containsKey('fmFrequency')) {
            double fmFreq = state['fmFrequency'];
            if (fmFreq >= _minFMFrequency && fmFreq <= _maxFMFrequency) {
              _fmFrequency = fmFreq;
              print('📊 更新UI FM频率: $fmFreq MHz');
            }
          }
        }
      }

      // 更新播放状态（非FM模式，且非BT模式时使用设备状态）
      if (state.containsKey('isPlaying') &&
          selectedInputSource != 'FM' &&
          selectedInputSource != 'BT') {
        bool playing = state['isPlaying'];
        setState(() {
          isPlaying = playing;
        });
        print('📊 更新UI播放状态: $playing');
      }

      // 更新X.BASS
      if (state.containsKey('xBass')) {
        String xBass = state['xBass'];
        if (xbassOptions.contains(xBass)) {
          selectedXBass = xBass;
          print('📊 更新UI X.BASS: $xBass');
        }
      }

      // 更新效果模式
      if (state.containsKey('effectModeType')) {
        String effectModeType = state['effectModeType'];
        if (effectModes.contains(effectModeType)) {
          selectedEffectMode = effectModeType;
          print('📊 更新UI效果模式: $effectModeType');
        }
      }
    });

    // 显示状态同步成功提示（仅对完整状态响应）
    if (state['type'] == 'stateResponse' && !_hasShownSyncSuccess) {
      _showSuccess('Device status has been synchronized');
      _hasShownSyncSuccess = true;
    }

    // 重置状态接收标志
    Future.delayed(Duration(milliseconds: 500), () {
      if (mounted) {
        setState(() {
          _isReceivingDeviceState = false;
        });
      }
    });
  }

  // 新增：开始监控蓝牙适配器状态
  void _startBluetoothAdapterMonitoring() {
    _bluetoothAdapterSubscription?.cancel();
    _bluetoothAdapterSubscription = FlutterBluePlus.adapterState.listen((
      state,
    ) {
      print('Bluetooth adapter state change: $state');

      if (mounted) {
        setState(() {
          _isBluetoothEnabled = state == BluetoothAdapterState.on;
        });

        if (state == BluetoothAdapterState.off) {
          // 蓝牙被关闭，立即更新连接状态
          print(
            '❌ Bluetooth adapter is turned off, disconnect all connections',
          );
          _handleBluetoothDisabled();
        } else if (state == BluetoothAdapterState.on) {
          // 蓝牙重新开启，尝试重新连接
          print('✅ Bluetooth adapter is turned on, trying to reconnect');
          _handleBluetoothEnabled();
        }
      }
    });
  }

  // 处理蓝牙禁用
  void _handleBluetoothDisabled() {
    if (mounted) {
      setState(() {
        isConnected = false;
        _isReconnecting = false;
      });
    }

    // 清理蓝牙服务状态
    _bluetoothService.cleanup();

    _showError('Bluetooth is turned off, device connection is disconnected');
  }

  // 处理蓝牙启用
  void _handleBluetoothEnabled() {
    // 检查之前是否已连接设备
    _refreshBluetoothState();

    // 延迟尝试重新连接
    Future.delayed(Duration(seconds: 2), () {
      if (mounted && !isConnected) {
        _tryAutoConnectWithRetry();
      }
    });
  }

  Future<void> _tryAutoConnectWithRetry() async {
    print('🔄 Starting auto-connect with retry mechanism...');

    if (mounted) {
      setState(() {
        _isReconnecting = true;
        _hasRequestedInitialState = false; // 重置状态请求标志
      });
    }

    Timer reconnectTimeout;
    reconnectTimeout = Timer(Duration(seconds: 30), () {
      print('⏰ 自动重连超时，停止重连尝试');
      if (mounted) {
        setState(() {
          _isReconnecting = false;
        });
      }
    });

    try {
      bool isBluetoothOn = await FlutterBluePlus.isOn;
      if (!isBluetoothOn) {
        print('📱 Bluetooth is off, waiting for it to turn on...');
        await Future.delayed(Duration(seconds: 2));
        isBluetoothOn = await FlutterBluePlus.isOn;
        if (!isBluetoothOn) {
          print('❌ Bluetooth still off, cannot auto-connect');
          if (mounted) {
            setState(() {
              _isReconnecting = false;
            });
          }
          reconnectTimeout.cancel();
          return;
        }
      }

      Map<String, String>? lastDevice = await _bluetoothService
          .getLastConnectedDevice();
      if (lastDevice == null) {
        print('📱 No previous device found for auto-connect');
        if (mounted) {
          setState(() {
            _isReconnecting = false;
          });
        }
        reconnectTimeout.cancel();
        return;
      }

      print('🎯 Attempting to auto-connect to: ${lastDevice['name']}');

      bool autoConnected = await _bluetoothService.autoConnectToLastDevice();

      if (autoConnected && mounted) {
        print('✅ Auto-connect successful!');
        setState(() {
          isConnected = true;
          _isReconnecting = false;
        });

        // 自动连接成功后读取设备状态
        Future.delayed(Duration(seconds: 2), () {
          if (mounted && isConnected) {
            print('🔄 自动连接成功，读取设备状态...');
            _readDeviceCurrentState();
          }
        });
      } else {
        print('❌ Auto-connect failed, will retry in 5 seconds...');
        Future.delayed(Duration(seconds: 5), () {
          if (mounted && !isConnected && _isReconnecting) {
            _tryAutoConnectWithRetry();
          } else if (mounted) {
            setState(() {
              _isReconnecting = false;
            });
          }
        });
      }
    } catch (e) {
      print('❌ Auto-connect error: $e');
      if (mounted) {
        setState(() {
          _isReconnecting = false;
        });
      }
    } finally {
      reconnectTimeout.cancel();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _connectionStatusSubscription?.cancel();
    _deviceConnectionSubscription?.cancel();
    _deviceStateSubscription?.cancel(); // 新增：取消设备状态监听
    _bluetoothAdapterSubscription?.cancel();
    _muteAnimationController.dispose();

    _volumeThrottleTimer?.cancel();
    _effectThrottleTimer?.cancel();

    // 取消audio_service监听
    _playbackStateSubscription?.cancel();

    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    print('App lifecycle state changed: $state');

    if (state == AppLifecycleState.resumed) {
      print('App resumed, refreshing Bluetooth state...');
      _refreshBluetoothState();

      if (!isConnected) {
        Future.delayed(Duration(seconds: 2), () async {
          bool connected = await _bluetoothService.isReallyConnected;
          if (!connected && mounted) {
            print('Not connected on resume, retrying auto-connect...');
            await _bluetoothService.autoConnectToLastDevice();
          }
        });
      }
    }
  }

  void _initializeBluetoothListeners() {
    print('初始化蓝牙监听器...');

    // 启动蓝牙适配器状态监听
    _bluetoothService.startAdapterStateListener();

    _connectionStatusSubscription?.cancel();
    _deviceConnectionSubscription?.cancel();

    _connectionStatusSubscription = _bluetoothService.connectionStatusStream.listen(
      (connected) {
        print('蓝牙服务连接状态变化: $connected');
        if (mounted) {
          setState(() {
            isConnected = connected;
            if (!connected) {
              _isReconnecting = false;
              _hasRequestedInitialState = false; // 重置状态请求标志
            }
          });

          if (connected) {
            _hasShownSyncSuccess = false;
            _hasShownSyncError = false;
            print('Connection state change, reset prompt state');

            // 连接成功后读取设备状态
            if (!_hasRequestedInitialState) {
              print(
                'The device is connected, reading the current status of the device...',
              );
              Future.delayed(Duration(milliseconds: 2000), () {
                if (mounted && isConnected) {
                  _readDeviceCurrentState();
                }
              });
            }
          } else {
            print('The device has been disconnected');
            _isReconnecting = false;
            // 断开连接时显示提示
            if (!_hasShownConnectionError) {
              _showError('The device connection has been disconnected');
              _hasShownConnectionError = true;
            }
          }
        }
      },
      onError: (error) {
        print('Connection state listening error: $error');
        if (mounted) {
          setState(() {
            isConnected = false;
            _isReconnecting = false;
          });
        }
      },
    );

    _deviceConnectionSubscription = _bluetoothService.getConnectionState().listen(
      (state) {
        if (mounted) {
          print('Physical connection status change of the device: $state');
          bool connected = state == BluetoothConnectionState.connected;

          if (isConnected != connected) {
            setState(() {
              isConnected = connected;
              if (!connected) {
                _isReconnecting = false;
                _hasRequestedInitialState = false; // 重置状态请求标志
              }
            });
            print('Physical device state triggers UI update: $connected');
          }

          if (connected) {
            print('Physical device connection has been established');
            _hasShownConnectionError = false;

            // 物理连接建立后读取设备状态
            if (!_hasRequestedInitialState) {
              Future.delayed(Duration(milliseconds: 1500), () {
                if (mounted && isConnected) {
                  print('Physical device connection is stable, read status...');
                  _readDeviceCurrentState();
                }
              });
            }
          } else {
            print(
              'The physical connection of the device has been disconnected',
            );
            _isReconnecting = false;
            // 物理断开时显示提示
            if (!_hasShownConnectionError) {
              _showError(
                'The physical connection of the device has been disconnected',
              );
              _hasShownConnectionError = true;
            }
          }
        }
      },
      onError: (error) {
        print('Device status listening error: $error');
        if (mounted) {
          setState(() {
            isConnected = false;
            _isReconnecting = false;
          });
          _showError('Anomalies in device connection: $error');
        }
      },
    );

    print('Bluetooth listener initialized');
  }

  // 新增：读取设备当前状态
  Future<void> _readDeviceCurrentState() async {
    if (!await _bluetoothService.isReallyConnected) {
      print('❌ The device is not connected, unable to read status');
      return;
    }

    if (_hasRequestedInitialState) {
      print(
        '⏸️ Initial state has already been requested, skipping duplicate request',
      );
      return;
    }

    print('🔄 Read the current status of the device...');

    setState(() {
      _isReceivingDeviceState = true;
      _hasRequestedInitialState = true;
    });

    try {
      await _bluetoothService.readDeviceCurrentState();
      print('✅ Status read request has been sent');

      // 设置超时，防止状态读取失败
      Future.delayed(Duration(seconds: 5), () {
        if (mounted && _isReceivingDeviceState) {
          print('⏰ Status read timeout, reset status');
          setState(() {
            _isReceivingDeviceState = false;
          });
        }
      });
    } catch (e) {
      print('❌ Failed to send status read request: $e');
      if (mounted) {
        setState(() {
          _isReceivingDeviceState = false;
          _hasRequestedInitialState = false; // 允许重试
        });
      }
    }
  }

  void _refreshBluetoothState() async {
    try {
      print('=== 开始刷新蓝牙状态 ===');

      // 首先检查蓝牙适配器状态
      bool isBluetoothOn = await FlutterBluePlus.isOn;
      if (!isBluetoothOn) {
        print('❌ 蓝牙适配器未开启');
        if (mounted) {
          setState(() {
            isConnected = false;
            _isReconnecting = false;
          });
        }
        return;
      }

      bool reallyConnected = await _bluetoothService.isReallyConnected;
      print('真实连接状态: $reallyConnected');

      // 如果服务显示已连接但实际未连接，强制更新状态
      if (isConnected && !reallyConnected) {
        print('⚠️ 状态不一致，强制更新为未连接');
        if (mounted) {
          setState(() {
            isConnected = false;
            _isReconnecting = false;
          });
        }
        _bluetoothService.updateConnectionStatus(false);
      }

      bool deviceConnected =
          _bluetoothService.connectedDevice != null &&
          await _bluetoothService.connectedDevice!.isConnected;
      print('设备连接状态: $deviceConnected');

      bool hasWriteChar = _bluetoothService.writeCharacteristic != null;
      print('写入特征可用: $hasWriteChar');

      bool finalConnected = reallyConnected && deviceConnected && hasWriteChar;

      print('最终连接状态: $finalConnected');

      if (mounted) {
        if (isConnected != finalConnected) {
          setState(() {
            isConnected = finalConnected;
          });
        }
      }

      // 如果已经连接，读取设备状态
      if (finalConnected && !_hasRequestedInitialState) {
        print('设备已连接，读取设备当前状态...');
        Future.delayed(Duration(milliseconds: 1500), () {
          if (mounted && isConnected) {
            _readDeviceCurrentState();
          }
        });
      }
    } catch (e) {
      print('刷新蓝牙状态时出错: $e');
      if (mounted) {
        setState(() {
          isConnected = false;
          _isReconnecting = false;
        });
      }
    }
  }

  // 新增：输入源选择方法
  void _selectInputSource(String source) async {
    setState(() {
      selectedInputSource = source;
    });

    // 如果是BT模式，自动连接到audio_service并获取当前播放状态
    if (source == 'BT') {
      try {
        // 获取当前播放状态
        final playbackState = widget.audioHandler.playbackState.value;
        setState(() {
          isPlaying = playbackState.playing;
        });
        print('BT模式: AudioService播放状态 - $isPlaying');
      } catch (e) {
        print('获取AudioService播放状态失败: $e');
      }
    }

    if (!await _bluetoothService.isReallyConnected) {
      _showError('Device not connected');
      return;
    }

    try {
      // 发送输入源选择指令到设备
      print('Selecting input source: $source');
      // 这里需要根据实际蓝牙协议发送相应的指令
      int sourceIndex = inputSources.indexOf(source);
      if (sourceIndex != -1) {
        await _bluetoothService.sendInputSourceCommand(sourceIndex);
      }

      // 根据输入源切换UI逻辑
      if (source == 'FM') {
        // 切换到FM模式，自动设置播放状态为true
        isPlaying = true;
      } else if (source != 'BT') {
        // 其他模式（非BT，非FM），重置播放状态
        isPlaying = false;
      }

      _showSuccess('Input source changed to $source');
    } catch (e) {
      print('Failed to send input source command: $e');
      _showError('Failed to change input source');
    }
  }

  // 新增：播放控制方法
  void _playPause() async {
    // 根据输入源选择不同的控制方式
    if (selectedInputSource == 'BT') {
      // BT模式：使用audio_service控制设备上的音乐播放
      _playPauseWithAudioService();
    } else {
      // 其他模式：使用原来的蓝牙指令控制
      _playPauseWithBluetooth();
    }
  }

  // BT模式：使用audio_service控制播放
  void _playPauseWithAudioService() {
    try {
      // 先保存当前状态
      bool currentState = isPlaying;

      // 立即更新UI状态，提供即时反馈
      setState(() {
        isPlaying = !isPlaying;
      });

      // 根据当前状态决定操作（注意：isPlaying已经被反转）
      if (currentState) {
        // 当前是播放状态，需要暂停
        widget.audioHandler.pause();
        print('AudioService: Pausing playback (was playing)');
        _showSuccess('暂停');
      } else {
        // 当前是暂停状态，需要播放
        widget.audioHandler.play();
        print('AudioService: Starting playback (was paused)');
        _showSuccess('播放');
      }
    } catch (e) {
      print('Failed to control playback with AudioService: $e');
      // 操作失败时恢复状态
      setState(() {
        isPlaying = !isPlaying;
      });
      _showError('控制播放失败');
    }
  }

  // 其他模式：使用蓝牙指令控制
  void _playPauseWithBluetooth() async {
    // 先保存当前状态
    bool currentState = isPlaying;

    // 先更新UI状态
    setState(() {
      isPlaying = !isPlaying;
    });

    if (!await _bluetoothService.isReallyConnected) {
      _showError('Device not connected');
      // 连接失败时恢复状态
      setState(() {
        isPlaying = !isPlaying;
      });
      return;
    }

    try {
      // 根据当前状态决定操作（注意：isPlaying已经被反转）
      if (currentState) {
        // 当前是播放状态，需要暂停
        print('Sending pause command via Bluetooth (was playing)');
        await _bluetoothService.sendPauseCommand();
        _showSuccess('暂停');
      } else {
        // 当前是暂停状态，需要播放
        print('Sending play command via Bluetooth (was paused)');
        await _bluetoothService.sendPlayCommand();
        _showSuccess('播放');
      }
    } catch (e) {
      print('Failed to send play/pause command: $e');
      // 命令发送失败时恢复状态
      setState(() {
        isPlaying = !isPlaying;
      });
      _showError('控制播放失败');
    }
  }

  void _previousTrack() async {
    // 根据输入源选择不同的控制方式
    if (selectedInputSource == 'BT') {
      // BT模式：使用audio_service控制
      _previousTrackWithAudioService();
    } else {
      // 其他模式：使用原来的蓝牙指令控制
      _previousTrackWithBluetooth();
    }
  }

  void _previousTrackWithAudioService() {
    try {
      widget.audioHandler.skipToPrevious();
      print('AudioService: Skipping to previous track');
      _showSuccess('Previous track');
    } catch (e) {
      print('Failed to skip to previous track with AudioService: $e');
      _showError('Failed to go to previous track');
    }
  }

  void _previousTrackWithBluetooth() async {
    if (!await _bluetoothService.isReallyConnected) {
      _showError('Device not connected');
      return;
    }

    try {
      print('Sending previous track command via Bluetooth');
      // await _bluetoothService.sendPreviousTrackCommand();
      _showSuccess('Previous track');
    } catch (e) {
      print('Failed to send previous track command: $e');
      _showError('Failed to go to previous track');
    }
  }

  void _nextTrack() async {
    // 根据输入源选择不同的控制方式
    if (selectedInputSource == 'BT') {
      // BT模式：使用audio_service控制
      _nextTrackWithAudioService();
    } else {
      // 其他模式：使用原来的蓝牙指令控制
      _nextTrackWithBluetooth();
    }
  }

  void _nextTrackWithAudioService() {
    try {
      widget.audioHandler.skipToNext();
      print('AudioService: Skipping to next track');
      _showSuccess('Next track');
    } catch (e) {
      print('Failed to skip to next track with AudioService: $e');
      _showError('Failed to go to next track');
    }
  }

  void _nextTrackWithBluetooth() async {
    if (!await _bluetoothService.isReallyConnected) {
      _showError('Device not connected');
      return;
    }

    try {
      print('Sending next track command via Bluetooth');
      // await _bluetoothService.sendNextTrackCommand();
      _showSuccess('Next track');
    } catch (e) {
      print('Failed to send next track command: $e');
      _showError('Failed to go to next track');
    }
  }

  // 新增：X.BASS选择方法
  void _selectXBass(String xbass) async {
    setState(() {
      selectedXBass = xbass;
    });

    if (!await _bluetoothService.isReallyConnected) {
      _showError('Device not connected');
      return;
    }

    try {
      print('Selecting X.BASS: $xbass');
      // 根据实际蓝牙协议发送相应的指令
      int xbassValue = int.tryParse(xbass) ?? 1;
      await _bluetoothService.sendXBassCommand(xbassValue);
      _showSuccess('X.BASS set to $xbass');
    } catch (e) {
      print('Failed to send X.BASS command: $e');
      _showError('Failed to set X.BASS');
    }
  }

  // 新增：效果模式选择方法
  void _selectEffectMode(String mode) async {
    setState(() {
      selectedEffectMode = mode;
    });

    if (!await _bluetoothService.isReallyConnected) {
      _showError('Device not connected');
      return;
    }

    try {
      print('Selecting effect mode: $mode');
      // 根据实际蓝牙协议发送相应的指令
      int modeIndex = effectModes.indexOf(mode);
      if (modeIndex != -1) {
        await _bluetoothService.sendEffectModeCommand(modeIndex);
        _showSuccess('Effect mode set to $mode');
      } else {
        print('Unknown effect mode: $mode');
        _showError('Unknown effect mode');
      }
    } catch (e) {
      print('Failed to send effect mode command: $e');
      _showError('Failed to set effect mode');
    }
  }

  // 新增：音量旋转按钮回调
  void _onVolumeChanged(double value) {
    // 如果当前是静音状态，调整音量时取消静音
    if (_isMuted && value > 0) {
      setState(() {
        _isMuted = false;
      });
    }

    setState(() {
      volumeValue = value;
    });
    _updateVolume(value);
  }

  // 新增：效果强度旋转按钮回调
  void _onEffectChanged(double value) {
    setState(() {
      effectValue = value;
    });
    _updateEffect(value);
  }

  void _decreaseVolume() {
    double newVolume = (volumeValue - 1).clamp(0.0, 32.0);
    print('减少音量: $newVolume');

    // 如果当前是静音状态，调整音量时取消静音
    if (_isMuted && newVolume > 0) {
      setState(() {
        _isMuted = false;
      });
    }

    setState(() {
      volumeValue = newVolume;
    });

    _updateVolume(newVolume);
  }

  void _increaseVolume() {
    double newVolume = (volumeValue + 1).clamp(0.0, 32.0);
    print('增加音量: $newVolume');

    // 如果当前是静音状态，调整音量时取消静音
    if (_isMuted && newVolume > 0) {
      setState(() {
        _isMuted = false;
      });
    }

    setState(() {
      volumeValue = newVolume;
    });

    _updateVolume(newVolume);
  }

  void _decreaseEffect() {
    double newEffect = (effectValue - 1).clamp(0.0, 32.0);
    print('减少效果强度: $newEffect');

    setState(() {
      effectValue = newEffect;
    });

    _updateEffect(newEffect);
  }

  void _increaseEffect() {
    double newEffect = (effectValue + 1).clamp(0.0, 32.0);
    print('增加效果强度: $newEffect');

    setState(() {
      effectValue = newEffect;
    });

    _updateEffect(newEffect);
  }

  void _updateVolume(double newVolume) async {
    print('User requests to update volume to: $newVolume');

    setState(() {
      volumeValue = newVolume;
    });

    bool reallyConnected = await _bluetoothService.isReallyConnected;

    if (!reallyConnected) {
      print('❌ The device is not connected, unable to send volume commands');
      if (!_hasShownConnectionError) {
        _showError(
          'The device is not connected, unable to send volume commands',
        );
        _hasShownConnectionError = true;
      }
      return;
    }

    _hasShownConnectionError = false;

    if (_bluetoothService.writeCharacteristic == null) {
      print('❌ 写入特征不可用');
      _showError('写入特征不可用，请重新连接设备');
      return;
    }

    print('准备发送音量指令: ${newVolume.toInt()}');
    try {
      await _bluetoothService.sendVolumeCommand(newVolume.toInt());
      print('✅ 音量指令发送成功: ${newVolume.toInt()}');

      if (newVolume > 0) {
        setSharedVolumeValue(newVolume);
      }
    } catch (e) {
      print('❌ 发送失败: $e');
      _showError('发送音量指令失败: $e');
    }
  }

  void _updateEffect(double newEffect) async {
    print('User requested effect strength update to: $newEffect');

    bool reallyConnected = await _bluetoothService.isReallyConnected;

    if (!reallyConnected) {
      print('❌ Device not connected, cannot send effect command');
      if (!_hasShownConnectionError) {
        _showError('设备未连接，无法发送效果强度指令');
        _hasShownConnectionError = true;
      }
      return;
    }

    _hasShownConnectionError = false;

    if (_bluetoothService.writeCharacteristic == null) {
      print('❌ Write characteristic not available');
      _showError('写入特征不可用，请重新连接设备');
      return;
    }

    print('准备发送效果强度指令: ${newEffect.toInt()}');
    try {
      await _bluetoothService.sendEffectCommand(newEffect.toInt());
      print('✅ 效果强度指令发送成功: ${newEffect.toInt()}');
    } catch (e) {
      print('❌ 发送失败: $e');
      _showError('发送效果强度指令失败: $e');
    }
  }

  void _onEffectSelected(String effect) async {
    int effectIndex = soundEffects.indexOf(effect);
    if (effectIndex == -1) {
      print('❌ 无效的音效模式: $effect');
      return;
    }

    if (effect == 'Normal') {
      setState(() {
        effectValue = 0.0;
        selectedEffect = effect;
      });
      print('🎛️ 选择 Normal 模式，效果强度已重置为 0');
    } else {
      setState(() {
        selectedEffect = effect;
      });
    }

    try {
      _updateEffectMode(effectIndex);

      await Future.delayed(Duration(milliseconds: 100));

      _updateEffect(effectValue);

      print('✅ 音效设置完成: 模式=$effect, 强度=$effectValue');
    } catch (e) {
      print('❌ 发送音效设置失败: $e');
      _showError('发送音效设置失败: $e');
    }
  }

  void _updateEffectMode(int effectMode) async {
    print(
      'User requested effect mode update to: $effectMode (${soundEffects[effectMode]})',
    );

    bool reallyConnected = await _bluetoothService.isReallyConnected;

    if (!reallyConnected) {
      print('❌ Device not connected, cannot send effect mode command');
      if (!_hasShownConnectionError) {
        _showError('设备未连接，无法发送音效模式指令');
        _hasShownConnectionError = true;
      }
      return;
    }

    _hasShownConnectionError = false;

    if (_bluetoothService.writeCharacteristic == null) {
      print('❌ Write characteristic not available');
      _showError('写入特征不可用，请重新连接设备');
      return;
    }

    print('准备发送音效模式指令: $effectMode');
    try {
      await _bluetoothService.sendEffectModeCommand(effectMode);
      print('✅ 音效模式指令发送成功: $effectMode');
    } catch (e) {
      print('❌ 发送失败: $e');
      _showError('发送音效模式指令失败: $e');
    }
  }

  void _showError(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Colors.red,
          duration: Duration(seconds: 3),
        ),
      );
    }
  }

  void _showSuccess(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Colors.green,
          duration: Duration(seconds: 3),
        ),
      );
    }
  }

  void _toggleMute() {
    print('静音按钮被点击，当前音量: $volumeValue, 静音状态: $_isMuted');

    if (_muteAnimationController.isCompleted) {
      _muteAnimationController.reverse();
    } else {
      _muteAnimationController.forward();
    }

    if (_isMuted) {
      // 取消静音
      double restoreVolume = sharedVolumeValue > 0 ? sharedVolumeValue : 16.0;
      print('取消静音，恢复音量到: $restoreVolume');

      setState(() {
        _isMuted = false;
        volumeValue = restoreVolume;
      });

      _updateVolume(restoreVolume);
    } else {
      // 静音
      print('静音，保存当前音量: $volumeValue');
      setSharedVolumeValue(volumeValue);

      setState(() {
        _isMuted = true;
        volumeValue = 0.0;
      });

      _updateVolume(0.0);
    }
  }

  void _navigateToBluetoothPage() async {
    print('导航到蓝牙页面...');

    _isPageActive = false;

    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => BluetoothConnectionScreen()),
    );

    _isPageActive = true;
    print('从蓝牙页面返回，立即刷新状态...');

    _focusNode.requestFocus();

    _refreshBluetoothStateImmediately();

    Future.delayed(Duration(milliseconds: 1000), () async {
      if (mounted && _isPageActive) {
        bool connected = await _bluetoothService.isReallyConnected;
        if (connected) {
          print('返回后检测到设备已连接，开始同步状态...');
          _syncStateToDevice();
        }
      }
    });

    Future.delayed(Duration(milliseconds: 2000), () {
      if (mounted && _isPageActive) {
        _refreshBluetoothStateImmediately();
        _checkAndSyncState();
      }
    });
  }

  void _checkAndSyncState() async {
    if (mounted && _isPageActive) {
      bool connected = await _bluetoothService.isReallyConnected;
      if (connected) {
        print('二次检查：设备已连接，同步状态...');
        _syncStateToDevice();
      }
    }
  }

  bool _isAutoConnecting = false;

  void _tryAutoConnect() async {
    print('🔍 Attempting auto-connect to last device...');

    if (_isAutoConnecting) {
      print('⚠️ Auto-connect already in progress, skipping');
      return;
    }

    _isAutoConnecting = true;

    try {
      await Future.delayed(Duration(seconds: 2));

      while (!(await FlutterBluePlus.isOn)) {
        print('⏳ Waiting for Bluetooth to turn on...');
        await Future.delayed(Duration(milliseconds: 500));
      }

      print('✅ Bluetooth adapter is on');

      Map<String, String>? lastDevice = await _bluetoothService
          .getLastConnectedDevice();

      if (lastDevice == null) {
        print('📱 No previous device found for auto-connect');
        _isAutoConnecting = false;
        return;
      }

      String deviceId = lastDevice['id']!;
      String deviceName = lastDevice['name']!;

      print('🔍 Found last device: $deviceName ($deviceId)');

      List<BluetoothDevice> connectedDevices =
          await FlutterBluePlus.connectedDevices;
      BluetoothDevice? targetDevice;

      for (var device in connectedDevices) {
        if (device.id.id == deviceId) {
          targetDevice = device;
          print('✅ Device already connected: ${device.name}');
          break;
        }
      }

      if (targetDevice != null) {
        print('✅ Device already connected, initializing service...');
        bool initialized = await _initializeBluetoothService(targetDevice);
        if (initialized && mounted) {
          setState(() {
            isConnected = true;
          });
          _showSuccess('Automatically connected to $deviceName');
        }
        _isAutoConnecting = false;
        return;
      }

      print('🔌 Device not connected, starting scan...');

      const scanTimeout = Duration(seconds: 10);
      Timer? scanTimeoutTimer;

      await FlutterBluePlus.startScan(timeout: scanTimeout);

      scanTimeoutTimer = Timer(scanTimeout, () {
        FlutterBluePlus.stopScan();
        print('⏰ Auto-connect scan timeout');
        _isAutoConnecting = false;
      });

      StreamSubscription? scanSubscription;
      scanSubscription = FlutterBluePlus.scanResults.listen((results) async {
        for (var result in results) {
          if (result.device.id.id == deviceId) {
            print('🎯 Found target device in scan: ${result.device.name}');

            scanSubscription?.cancel();
            scanTimeoutTimer?.cancel();
            await FlutterBluePlus.stopScan();

            await _connectToDevice(result.device);
            _isAutoConnecting = false;
            break;
          }
        }
      });

      Future.delayed(scanTimeout, () {
        scanSubscription?.cancel();
        scanTimeoutTimer?.cancel();
        _isAutoConnecting = false;
      });
    } catch (e) {
      print('❌ Auto-connect failed: $e');
      _isAutoConnecting = false;
    }
  }

  void _refreshBluetoothStateImmediately() async {
    print('=== 立即刷新蓝牙状态 ===');
    try {
      bool reallyConnected = await _bluetoothService.isReallyConnected;
      print('立即检查结果: $reallyConnected');

      if (mounted) {
        setState(() {
          isConnected = reallyConnected;
        });
      }

      if (reallyConnected && _bluetoothService.writeCharacteristic == null) {
        print('连接但特征缺失，立即修复...');
        await _autoFixCharacteristicsImmediately();
      }
    } catch (e) {
      print('立即刷新失败: $e');
      if (mounted) {
        setState(() {
          isConnected = false;
        });
      }
    }
  }

  // 修复方法：立即自动修复特征
  Future<void> _autoFixCharacteristicsImmediately() async {
    print('🚨 尝试立即修复蓝牙特征...');

    if (_bluetoothService.connectedDevice == null) {
      print('❌ 没有已连接的设备，无法修复特征');
      return;
    }

    try {
      setState(() {
        _isReconnecting = true;
      });

      print('正在重新发现蓝牙服务...');

      // 先断开连接
      await _bluetoothService.connectedDevice!.disconnect();
      await Future.delayed(Duration(milliseconds: 500));

      // 重新连接
      await _bluetoothService.connectedDevice!.connect();
      await Future.delayed(Duration(milliseconds: 1000));

      // 重新初始化服务
      bool initialized = await _initializeBluetoothService(
        _bluetoothService.connectedDevice!,
      );

      if (initialized) {
        print('✅ 蓝牙特征修复成功');
        _showSuccess('蓝牙特征已修复');

        // 修复后立即刷新状态
        _refreshBluetoothStateImmediately();

        // 读取设备当前状态
        Future.delayed(Duration(seconds: 2), () {
          if (mounted && isConnected) {
            _readDeviceCurrentState();
          }
        });
      } else {
        print('❌ 蓝牙特征修复失败');
        _showError('蓝牙特征修复失败');
      }
    } catch (e) {
      print('❌ 修复蓝牙特征时出错: $e');
      _showError('修复蓝牙特征时出错: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isReconnecting = false;
        });
      }
    }
  }

  Future<void> _ensureGlobalStateUpdated() async {
    print('确保全局状态已更新...');

    for (int i = 0; i < 3; i++) {
      await _bluetoothService.refreshConnectionStatus();
      await Future.delayed(Duration(milliseconds: 300));
    }

    print('全局状态更新完成');
  }

  Future<void> _connectToDevice(
    BluetoothDevice device, {
    bool isAutoConnect = false,
  }) async {
    try {
      if (!isAutoConnect) {
        setState(() {
          isConnecting = true;
          _hasRequestedInitialState = false; // 重置状态请求标志
          deviceConnectionStates[device.id.id] =
              BluetoothConnectionState.connecting;
        });
      }

      print('Connecting to device: ${device.name} (${device.id})');

      await _bluetoothService.connectToDevice(device);

      print('✅ Connected to device: ${device.name}');

      if (!isAutoConnect) {
        setState(() {
          deviceConnectionStates[device.id.id] =
              BluetoothConnectionState.connected;
        });
      }

      bool serviceInitialized = await _initializeBluetoothService(device);

      if (serviceInitialized) {
        print('✅ Bluetooth service initialized, device ready');

        await _ensureGlobalStateUpdated();

        if (!isAutoConnect && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Successfully connected to ${device.name}'),
              backgroundColor: const Color(0xFF4CAF50),
              duration: const Duration(seconds: 2),
            ),
          );

          // 手动连接成功后读取设备状态
          Future.delayed(Duration(milliseconds: 1500), () {
            if (mounted && isConnected) {
              print('手动连接成功，读取设备状态...');
              _readDeviceCurrentState();
            }
          });

          Future.delayed(Duration(milliseconds: 1000), () {
            if (mounted) {
              Navigator.of(context).pop();
            }
          });
        } else if (isAutoConnect) {
          _showSuccess('Automatically connected to ${device.name}');
        }
      } else {
        print('❌ Bluetooth service initialization failed');
        if (!isAutoConnect) {
          _showError('Connected but service initialization failed');
        }
      }
    } catch (e) {
      print('❌ Connection failed: $e');

      if (!isAutoConnect) {
        setState(() {
          deviceConnectionStates[device.id.id] =
              BluetoothConnectionState.disconnected;
          isConnecting = false;
        });

        String errorMessage = 'Failed to connect to ${device.name}';
        if (e.toString().contains('timeout')) {
          errorMessage =
              'Connection timed out. Please make sure the device is nearby and in pairing mode.';
        }

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(errorMessage),
              backgroundColor: const Color(0xFFF44336),
              duration: const Duration(seconds: 3),
            ),
          );
        }
      }
    } finally {
      if (!isAutoConnect) {
        setState(() {
          isConnecting = false;
        });
      }
    }
  }

  void _triggerStateSync() {
    print('触发状态同步到设备...');

    Future.delayed(Duration(milliseconds: 500), () {
      print('状态同步已触发');
    });
  }

  Future<bool> _initializeBluetoothService(BluetoothDevice device) async {
    try {
      print('开始初始化蓝牙服务...');

      await Future.delayed(const Duration(milliseconds: 800));

      List<BluetoothService> services = await device.discoverServices().timeout(
        Duration(seconds: 15),
        onTimeout: () {
          throw Exception('Service discovery timed out');
        },
      );

      bool foundService = false;
      bool foundWriteChar = false;
      bool foundReadChar = false;

      for (BluetoothService service in services) {
        final serviceUuid = service.uuid.toString().toLowerCase();
        print('检查服务: $serviceUuid');

        if (serviceUuid == '0000ab00-0000-1000-8000-00805f9b34fb' ||
            serviceUuid.contains('ab00')) {
          foundService = true;
          print('✅ 找到目标服务: $serviceUuid');

          for (BluetoothCharacteristic characteristic
              in service.characteristics) {
            final charUuid = characteristic.uuid.toString().toLowerCase();
            print('检查特征: $charUuid, 属性: ${characteristic.properties}');

            if ((charUuid == '0000ab01-0000-1000-8000-00805f9b34fb' ||
                    charUuid.contains('ab01')) &&
                characteristic.properties.write) {
              _bluetoothService.writeCharacteristic = characteristic;
              foundWriteChar = true;
              print('✅ 找到并设置写入特征: $charUuid');
            }

            if ((charUuid == '0000ab02-0000-1000-8000-00805f9b34fb' ||
                    charUuid.contains('ab02')) &&
                characteristic.properties.notify) {
              _bluetoothService.readCharacteristic = characteristic;
              foundReadChar = true;
              print('✅ 找到读取特征: $charUuid');

              try {
                await characteristic.setNotifyValue(true);
                print('✅ 通知已启用');

                characteristic.value.listen(
                  (value) {
                    print('收到设备通知: $value');
                  },
                  onError: (error) {
                    print('通知监听错误: $error');
                  },
                );
              } catch (e) {
                print('⚠️ 启用通知失败: $e');
              }
            }
          }
        }
      }

      _bluetoothService.connectedDevice = device;

      await _bluetoothService.refreshConnectionStatus();

      bool success = foundService && foundWriteChar;
      print('蓝牙服务初始化结果: $success (服务: $foundService, 写入特征: $foundWriteChar)');

      return success;
    } catch (e) {
      print('❌ 蓝牙服务初始化失败: $e');
      return false;
    }
  }

  Future<void> _disconnectDevice(BluetoothDevice device) async {
    try {
      await device.disconnect();
      if (mounted) {
        setState(() {
          deviceConnectionStates[device.id.id] =
              BluetoothConnectionState.disconnected;
        });

        if (_bluetoothService.connectedDevice?.id.id == device.id.id) {
          _bluetoothService.connectedDevice = null;
          _bluetoothService.writeCharacteristic = null;
          _bluetoothService.readCharacteristic = null;

          _bluetoothService.clearSavedDevice();
        }

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Disconnected from ${device.name}'),
            backgroundColor: const Color(0xFF2E7D32),
          ),
        );
        print('Successfully disconnected from device: ${device.name}');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to disconnect from ${device.name}: $e'),
            backgroundColor: const Color(0xFFF44336),
          ),
        );
      }
    }
  }

  void _syncStateToDevice({bool forceShowSuccess = false}) async {
    if (!await _bluetoothService.isReallyConnected) {
      print('The device is not connected, unable to sync status');
      return;
    }

    // 如果正在接收设备状态，避免重复发送
    if (_isReceivingDeviceState) {
      print('⏸️ 正在接收设备状态，暂停同步到设备');
      return;
    }

    print('=== Start synchronizing status to device ===');
    print(
      'Current status - 音量: $volumeValue, 效果: $effectValue, 模式: $selectedEffect',
    );

    try {
      print('Sync volume: $volumeValue');
      await _bluetoothService.sendVolumeCommand(volumeValue.toInt());
      await Future.delayed(Duration(milliseconds: 200));

      print('Synchronization effect intensity: $effectValue');
      await _bluetoothService.sendEffectCommand(effectValue.toInt());
      await Future.delayed(Duration(milliseconds: 200));

      int effectIndex = soundEffects.indexOf(selectedEffect);
      if (effectIndex != -1) {
        print('Sync Sound Mode: $selectedEffect (Index: $effectIndex)');
        await _bluetoothService.sendEffectModeCommand(effectIndex);
      }

      print('✅ Status synchronization completed');

      if (forceShowSuccess || !_hasShownSyncSuccess) {
        _showSuccess('Device status has been synchronized');
        _hasShownSyncSuccess = true;
      }
    } catch (e) {
      print('❌ Failed to synchronize state: $e');

      if (!_hasShownSyncError) {
        _showError('Failed to synchronize state: $e');
        _hasShownSyncError = true;
      }

      print('Retry synchronization in 5 seconds...');
      Future.delayed(Duration(seconds: 5), () async {
        if (mounted && await _bluetoothService.isReallyConnected) {
          print('Start retrying sync status...');
          _syncStateToDevice(forceShowSuccess: true);
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    final screenWidth = MediaQuery.of(context).size.width;
    final isLargeScreen = screenWidth > 600; // 平板或大屏手机

    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      body: SafeArea(
        child: Column(
          children: [
            // 顶部标题区域 - 现代化设计
            GestureDetector(
              onTap: _navigateToBluetoothPage,
              child: Container(
                padding: EdgeInsets.symmetric(
                  horizontal: isLargeScreen ? 24 : 16,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: Colors.white,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.05),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    // Logo图标
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: const Color(0xFF2E7D32),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Center(
                        child: Text(
                          'DSP',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),

                    // 标题和连接状态
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Digital Signal Processor',
                            style: TextStyle(
                              color: Color(0xFF1A1A1A),
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: isConnected
                                      ? const Color(0xFF4CAF50)
                                      : (_isReconnecting
                                            ? Colors.orange
                                            : const Color(0xFFF44336)),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                isConnected
                                    ? 'Connected'
                                    : (_isReconnecting
                                          ? 'Connecting...'
                                          : 'Not Connected'),
                                style: TextStyle(
                                  color: isConnected
                                      ? const Color(0xFF4CAF50)
                                      : (_isReconnecting
                                            ? Colors.orange
                                            : const Color(0xFFF44336)),
                                  fontSize: 14,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              if (_isReceivingDeviceState) ...[
                                const SizedBox(width: 8),
                                const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                      Color(0xFF2E7D32),
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),

                    // 蓝牙图标
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: const Color(0xFFE0E0E0),
                          width: 1,
                        ),
                      ),
                      child: const Icon(
                        Icons.bluetooth,
                        color: Color(0xFF2E7D32),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // 主要内容区域 - 自适应布局
            Expanded(
              child: SingleChildScrollView(
                child: Padding(
                  padding: EdgeInsets.all(isLargeScreen ? 16 : 8),
                  child: Column(
                    children: [
                      // 1. 输入源控制卡片（根据输入源显示不同内容）
                      _buildInputSourceControlCard(),

                      SizedBox(height: isLargeScreen ? 12 : 4),

                      // 2. 音量控制卡片（现在包含所有控制选项）
                      _buildVolumeControlCard(),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 输入源控制卡片（根据输入源显示不同内容）
  Widget _buildInputSourceControlCard() {
    final isLargeScreen = MediaQuery.of(context).size.width > 600;

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: Color(0xFFE0E0E0), width: 1),
      ),
      child: Padding(
        padding: EdgeInsets.all(isLargeScreen ? 16 : 8),
        child: Column(
          children: [
            // 输入源选择按钮 - 水平居中
            Center(
              child: Wrap(
                spacing: isLargeScreen ? 12 : 8,
                runSpacing: isLargeScreen ? 12 : 8,
                children: inputSources.map((source) {
                  final isSelected = selectedInputSource == source;

                  return GestureDetector(
                    onTap: () => _selectInputSource(source),
                    child: Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: isLargeScreen ? 16 : 12,
                        vertical: isLargeScreen ? 12 : 10,
                      ),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? const Color(0xFF2E7D32)
                            : Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isSelected
                              ? const Color(0xFF2E7D32)
                              : const Color(0xFFE0E0E0),
                          width: 2,
                        ),
                      ),
                      child: Text(
                        source,
                        style: TextStyle(
                          fontSize: isLargeScreen ? 14 : 13,
                          fontWeight: isSelected
                              ? FontWeight.w600
                              : FontWeight.normal,
                          color: isSelected
                              ? Colors.white
                              : const Color(0xFF4A4A4A),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ),

            SizedBox(height: isLargeScreen ? 16 : 8),

            // 根据输入源显示不同的控制模块
            if (selectedInputSource == 'FM')
              _buildFMFrequencyModule() // FM模式：显示频率选择模块
            else
              _buildPlaybackControlModule(), // 其他模式：显示播放控制模块
          ],
        ),
      ),
    );
  }

  // FM频率选择模块
  Widget _buildFMFrequencyModule() {
    final isLargeScreen = MediaQuery.of(context).size.width > 600;

    return Column(
      children: [
        // 频率显示和按钮
        Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // 减少频率按钮
              GestureDetector(
                onTap: _decreaseFMFrequency,
                child: Container(
                  width: isLargeScreen ? 45 : 35,
                  height: isLargeScreen ? 45 : 35,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: const Color(0xFFE0E0E0),
                      width: 2,
                    ),
                  ),
                  child: Icon(
                    Icons.remove,
                    color: const Color(0xFF2E7D32),
                    size: isLargeScreen ? 20 : 16,
                  ),
                ),
              ),

              // 频率显示
              Column(
                children: [
                  Text(
                    '${_fmFrequency.toStringAsFixed(1)} MHz',
                    style: TextStyle(
                      fontSize: isLargeScreen ? 20 : 16,
                      fontWeight: FontWeight.bold,
                      color: const Color(0xFF2E7D32),
                    ),
                  ),
                  const SizedBox(height: 4),
                  // const Text(
                  //   'FM Frequency',
                  //   style: TextStyle(
                  //     fontSize: 14,
                  //     color: Color(0xFF6B6B6B),
                  //   ),
                  // ),
                ],
              ),

              // 增加频率按钮
              GestureDetector(
                onTap: _increaseFMFrequency,
                child: Container(
                  width: isLargeScreen ? 45 : 35,
                  height: isLargeScreen ? 45 : 35,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: const Color(0xFFE0E0E0),
                      width: 2,
                    ),
                  ),
                  child: Icon(
                    Icons.add,
                    color: const Color(0xFF2E7D32),
                    size: isLargeScreen ? 20 : 16,
                  ),
                ),
              ),
            ],
          ),
        ),

        SizedBox(height: isLargeScreen ? 16 : 12),

        // 频率滑动条
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '${_minFMFrequency.toStringAsFixed(1)}',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF6B6B6B),
                    ),
                  ),
                  /* Text(
                  //   'Frequency',
                  //   style: const TextStyle(
                  //     fontSize: 14,
                  //     fontWeight: FontWeight.w600,
                  //     color: Color(0xFF1A1A1A),
                  //   ),
                  // ),*/
                  Text(
                    '${_maxFMFrequency.toStringAsFixed(1)}',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Color(0xFF6B6B6B),
                    ),
                  ),
                ],
              ),
            ),

            SizedBox(height: 4),

            // 自定义滑动条
            _buildFMFrequencySlider(),
          ],
        ),
      ],
    );
  }

  // 自定义FM频率滑动条
  Widget _buildFMFrequencySlider() {
    return Container(
      height: 60,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final sliderWidth = constraints.maxWidth;
          final position =
              ((_fmFrequency - _minFMFrequency) /
                  (_maxFMFrequency - _minFMFrequency)) *
              sliderWidth;

          return Stack(
            children: [
              // 背景轨道
              Container(
                height: 6,
                margin: const EdgeInsets.only(top: 26),
                decoration: BoxDecoration(
                  color: const Color(0xFFE0E0E0),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),

              // 已选择轨道
              Container(
                height: 6,
                margin: const EdgeInsets.only(top: 26),
                width: position,
                decoration: BoxDecoration(
                  color: const Color(0xFF2E7D32),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),

              // 刻度标记
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: List.generate(11, (index) {
                    double frequency =
                        _minFMFrequency +
                        (index * (_maxFMFrequency - _minFMFrequency) / 10);
                    bool isMajor = index % 5 == 0; // 每5个刻度一个主要刻度

                    return Column(
                      children: [
                        Container(
                          width: isMajor ? 2 : 1,
                          height: isMajor ? 12 : 8,
                          color: const Color(0xFF9E9E9E),
                        ),
                      ],
                    );
                  }),
                ),
              ),

              // 滑块
              Positioned(
                left: position - 15, // 减去滑块宽度的一半
                top: 11, // 调整垂直位置使其居中 (26 - 30/2 = 11，其中26是轨道的top值，30是滑块高度)
                child: GestureDetector(
                  onPanUpdate: (details) {
                    final renderBox = context.findRenderObject() as RenderBox;
                    final localPosition = renderBox.globalToLocal(
                      details.globalPosition,
                    );

                    double newPosition = localPosition.dx.clamp(
                      0.0,
                      sliderWidth,
                    );
                    double newFrequency =
                        _minFMFrequency +
                        (newPosition / sliderWidth) *
                            (_maxFMFrequency - _minFMFrequency);
                    newFrequency = (newFrequency * 10).round() / 10.0; // 保留一位小数

                    _onFMFrequencyChanged(newFrequency);
                  },
                  child: Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(8), // 改为圆角矩形而不是圆形
                      border: Border.all(
                        color: const Color(0xFF2E7D32),
                        width: 3,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.2),
                          blurRadius: 8,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Center(
                      child: Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: const Color(0xFF2E7D32),
                          borderRadius: BorderRadius.circular(2), // 改为圆角矩形而不是圆形
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  // 播放控制模块（用于AUX, USB/SD, BT）
  Widget _buildPlaybackControlModule() {
    final isLargeScreen = MediaQuery.of(context).size.width > 600;

    return Column(
      children: [
        // 播放控制按钮
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            // 上一首
            _buildPlaybackButton(
              icon: Icons.skip_previous,
              onPressed: _previousTrack,
              isLarge: isLargeScreen,
            ),

            // 播放/暂停
            _buildPlaybackButton(
              icon: isPlaying ? Icons.pause : Icons.play_arrow,
              onPressed: _simplePlayPause,
              isLarge: isLargeScreen,
              isPrimary: true,
            ),

            // 下一首
            _buildPlaybackButton(
              icon: Icons.skip_next,
              onPressed: _nextTrack,
              isLarge: isLargeScreen,
            ),
          ],
        ),

        SizedBox(height: isLargeScreen ? 12 : 8),

        // 播放状态显示
        Text(
          isPlaying ? 'Playing' : 'Paused',
          style: TextStyle(
            fontSize: isLargeScreen ? 14 : 12,
            color: const Color(0xFF6B6B6B),
            fontWeight: FontWeight.w500,
          ),
        ),

        // // 显示当前输入源
        // Text(
        //   'Mode: $selectedInputSource',
        //   style: TextStyle(
        //     fontSize: isLargeScreen ? 12 : 10,
        //     color: const Color(0xFF2E7D32),
        //     fontWeight: FontWeight.w500,
        //   ),
        // ),
      ],
    );
  }

  // 播放控制按钮
  Widget _buildPlaybackButton({
    required IconData icon,
    required VoidCallback onPressed,
    required bool isLarge,
    bool isPrimary = false,
  }) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        width: isLarge ? 60 : 50,
        height: isLarge ? 60 : 50,
        decoration: BoxDecoration(
          color: isPrimary ? const Color(0xFF2E7D32) : Colors.white,
          shape: BoxShape.circle,
          border: Border.all(
            color: isPrimary
                ? const Color(0xFF2E7D32)
                : const Color(0xFFE0E0E0),
            width: 2,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.1),
              blurRadius: 8,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Icon(
          icon,
          color: isPrimary ? Colors.white : const Color(0xFF2E7D32),
          size: isLarge ? 28 : 24,
        ),
      ),
    );
  }

  // 音量控制卡片（现在包含所有控制选项）
  Widget _buildVolumeControlCard() {
    final isLargeScreen = MediaQuery.of(context).size.width > 600;
    final screenWidth = MediaQuery.of(context).size.width;

    // 计算旋转按钮大小
    final double knobSize = isLargeScreen
        ? math.min(180.0, (screenWidth - 80) / 2)
        : math.min(140.0, (screenWidth - 60) / 2);

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.all(const Radius.circular(16)),
        side: const BorderSide(color: Color(0xFFE0E0E0), width: 1),
      ),
      child: Container(
        // 减少高度填充，原来的一半
        height:
            MediaQuery.of(context).size.height *
            0.63, // 占据屏幕60%的高度, // 根据实际情况调整
        padding: EdgeInsets.all(isLargeScreen ? 16 : 8),
        child: SingleChildScrollView(
          // 添加滚动以防内容过多
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 标题行 - 只有音量标题和静音按钮
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Volume Control',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF1A1A1A),
                    ),
                  ),
                  GestureDetector(
                    onTap: _toggleMute,
                    child: Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: _isMuted
                            ? const Color(0xFF9E9E9E).withOpacity(0.1)
                            : const Color(0xFF2E7D32).withOpacity(0.1),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        _isMuted ? Icons.volume_off : Icons.volume_up,
                        color: _isMuted
                            ? const Color(0xFF9E9E9E)
                            : const Color(0xFF2E7D32),
                        size: 24,
                      ),
                    ),
                  ),
                ],
              ),
              SizedBox(height: isLargeScreen ? 16 : 8),

              // 旋转按钮行 - 并排显示
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  // 音量旋转按钮
                  RotaryKnob(
                    initialValue: volumeValue,
                    label: 'VOLUME',
                    minValue: 0.0,
                    maxValue: 32.0,
                    onValueChanged: _onVolumeChanged,
                    activeColor: const Color(0xFF2E7D32),
                    size: knobSize,
                  ),

                  // 效果强度旋转按钮
                  RotaryKnob(
                    initialValue: effectValue,
                    label: 'KARAOKE',
                    minValue: 0.0,
                    maxValue: 32.0,
                    onValueChanged: _onEffectChanged,
                    activeColor: const Color(0xFF2E7D32),
                    size: knobSize,
                  ),
                ],
              ),

              SizedBox(height: isLargeScreen ? 16 : 12),

              // X.BASS 选择（独立一行）
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  // 将主轴对齐方式改为起始对齐，使X.BASS标签和选项都靠近左侧
                  mainAxisAlignment: MainAxisAlignment.start,
                  children: [
                    const Text(
                      'X.BASS',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF1A1A1A),
                      ),
                    ),

                    // 添加一些间距
                    SizedBox(width: 16),

                    // X.BASS 选项 - 左对齐
                    Row(
                      mainAxisAlignment: MainAxisAlignment.start,
                      children: xbassOptions.map((option) {
                        final isSelected = selectedXBass == option;

                        return GestureDetector(
                          onTap: () => _selectXBass(option),
                          child: Container(
                            margin: const EdgeInsets.symmetric(horizontal: 4),
                            width: isLargeScreen ? 50 : 40,
                            height: isLargeScreen ? 50 : 40,
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? const Color(0xFF2E7D32)
                                  : Colors.white,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: isSelected
                                    ? const Color(0xFF2E7D32)
                                    : const Color(0xFFE0E0E0),
                                width: 2,
                              ),
                            ),
                            child: Center(
                              child: Text(
                                option,
                                style: TextStyle(
                                  fontSize: isLargeScreen ? 16 : 14,
                                  fontWeight: isSelected
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                                  color: isSelected
                                      ? Colors.white
                                      : const Color(0xFF4A4A4A),
                                ),
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ),

              SizedBox(height: isLargeScreen ? 16 : 8),

              // Mode 选择（独立一行）
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Mic mode',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF1A1A1A),
                      ),
                    ),

                    // 效果模式选项
                    Row(
                      children: effectModes.map((mode) {
                        final isSelected = selectedEffectMode == mode;

                        return GestureDetector(
                          onTap: () => _selectEffectMode(mode),
                          child: Container(
                            margin: const EdgeInsets.symmetric(horizontal: 4),
                            padding: EdgeInsets.symmetric(
                              horizontal: isLargeScreen ? 16 : 12,
                              vertical: isLargeScreen ? 10 : 8,
                            ),
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? const Color(0xFF2E7D32)
                                  : Colors.white,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: isSelected
                                    ? const Color(0xFF2E7D32)
                                    : const Color(0xFFE0E0E0),
                                width: 2,
                              ),
                            ),
                            child: Text(
                              mode,
                              style: TextStyle(
                                fontSize: isLargeScreen ? 14 : 12,
                                fontWeight: isSelected
                                    ? FontWeight.w600
                                    : FontWeight.normal,
                                color: isSelected
                                    ? Colors.white
                                    : const Color(0xFF4A4A4A),
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                  ],
                ),
              ),

              SizedBox(height: isLargeScreen ? 16 : 8),

              // Sound Effects 选择 - 直接显示选项，每行3个
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Sound Effects',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF1A1A1A),
                    ),
                  ),
                  SizedBox(height: isLargeScreen ? 12 : 8),

                  // 使用GridView实现每行3个按钮，确保对齐
                  Container(
                    width: double.infinity,
                    child: GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3, // 每行3个
                        crossAxisSpacing: isLargeScreen ? 12 : 8,
                        mainAxisSpacing: isLargeScreen ? 12 : 8,
                        childAspectRatio: isLargeScreen
                            ? 2.8
                            : 2.5, // 调整宽高比，使按钮高度与mic mode一致
                      ),
                      itemCount: soundEffects.length,
                      itemBuilder: (context, index) {
                        final effect = soundEffects[index];
                        final isSelected = selectedEffect == effect;

                        return GestureDetector(
                          onTap: () => _onEffectSelected(effect),
                          child: Container(
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? const Color(0xFF2E7D32)
                                  : Colors.white,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: isSelected
                                    ? const Color(0xFF2E7D32)
                                    : const Color(0xFFE0E0E0),
                                width: 2,
                              ),
                              boxShadow: isSelected
                                  ? [
                                      BoxShadow(
                                        color: const Color(
                                          0xFF2E7D32,
                                        ).withOpacity(0.3),
                                        blurRadius: 4,
                                        offset: const Offset(0, 2),
                                      ),
                                    ]
                                  : [],
                            ),
                            child: Center(
                              child: Text(
                                effect,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: isLargeScreen ? 14 : 12,
                                  fontWeight: isSelected
                                      ? FontWeight.w600
                                      : FontWeight.normal,
                                  color: isSelected
                                      ? Colors.white
                                      : const Color(0xFF4A4A4A),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),

              // 添加一个Spacer或者SizedBox来推到底部
              SizedBox(height: isLargeScreen ? 16 : 8),
            ],
          ),
        ),
      ),
    );
  }
}

// ==============================================
// 旋转按钮组件
// ==============================================

// 旋转按钮常量
const double kRotaryMin = 0.0;
const double kRotaryMax = 32.0;
const double kRotaryRange = kRotaryMax - kRotaryMin; // 32.0

class RotaryKnob extends StatefulWidget {
  final double initialValue;
  final String label;
  final double minValue;
  final double maxValue;
  final ValueChanged<double>? onValueChanged;
  final Color activeColor;
  final double size;

  const RotaryKnob({
    Key? key,
    this.initialValue = 0.0,
    required this.label,
    this.minValue = 0.0,
    this.maxValue = 32.0,
    this.onValueChanged,
    this.activeColor = const Color(0xFF2E7D32),
    this.size = 160.0,
  }) : super(key: key);

  @override
  _RotaryKnobState createState() => _RotaryKnobState();
}

class _RotaryKnobState extends State<RotaryKnob> {
  late double _currentValue;
  bool _isDragging = false;

  @override
  void initState() {
    super.initState();
    _currentValue = widget.initialValue.clamp(widget.minValue, widget.maxValue);
  }

  @override
  void didUpdateWidget(RotaryKnob oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 当外部值变化且不在拖动时，更新内部值
    if (!_isDragging && widget.initialValue != oldWidget.initialValue) {
      setState(() {
        _currentValue = widget.initialValue.clamp(
          widget.minValue,
          widget.maxValue,
        );
      });
    }
  }

  // 处理拖动手势开始
  void _handlePanStart(DragStartDetails details) {
    _isDragging = true;
  }

  // 处理拖动手势结束
  void _handlePanEnd(DragEndDetails details) {
    _isDragging = false;
  }

  // 处理拖动手势更新
  void _handlePanUpdate(DragUpdateDetails details) {
    final RenderBox renderBox = context.findRenderObject() as RenderBox;
    final Offset center = renderBox.size.center(Offset.zero);

    final Offset vector = details.localPosition - center;

    // 计算当前触摸点相对于中心点和水平向右方向的角度（-pi到pi）
    double touchAngle = math.atan2(vector.dy, vector.dx);

    // 旋转范围：从左下方到右下方的3/4圆弧旋转
    // 起始角度：-1.25 * math.pi (315度/-45度)
    // 结束角度： 0.25 * math.pi (45度)
    // 总旋转弧度：1.5 * math.pi (270度)

    final double startAngleRad = -math.pi * 1.25; // -225度
    final double endAngleRad = math.pi * 0.25; // 45度

    // 确保touchAngle在有效的2*pi范围内，方便处理
    if (touchAngle < 0) touchAngle += 2 * math.pi;

    // 将startAngleRad和endAngleRad也转换为0-2*pi范围，方便比较
    double normalizedStartAngle = startAngleRad;
    if (normalizedStartAngle < 0) normalizedStartAngle += 2 * math.pi;

    double normalizedEndAngle = endAngleRad;
    if (normalizedEndAngle < 0) normalizedEndAngle += 2 * math.pi;

    // 计算触摸点相对于旋钮起始角度的偏移量
    double angleOffset;
    if (normalizedEndAngle > normalizedStartAngle) {
      // 正常顺时针弧度
      if (touchAngle >= normalizedStartAngle &&
          touchAngle <= normalizedEndAngle) {
        angleOffset = touchAngle - normalizedStartAngle;
      } else if (touchAngle < normalizedStartAngle) {
        // 触摸点在起始点之前
        angleOffset = 0.0;
      } else {
        // 触摸点在结束点之后
        angleOffset = math.pi * 1.5; // 最大弧度
      }
    } else {
      // 跨越0/2*pi边界 (例如从315度到45度)
      if (touchAngle >= normalizedStartAngle ||
          touchAngle <= normalizedEndAngle) {
        if (touchAngle >= normalizedStartAngle) {
          angleOffset = touchAngle - normalizedStartAngle;
        } else {
          // 例如 touchAngle = 30度, normalizedStartAngle = 315度
          angleOffset = (2 * math.pi - normalizedStartAngle) + touchAngle;
        }
      } else {
        // 触摸点在非有效区域
        // 靠近哪个边界就取哪个边界
        if ((touchAngle - normalizedEndAngle).abs() <
            (touchAngle - normalizedStartAngle).abs()) {
          angleOffset = math.pi * 1.5;
        } else {
          angleOffset = 0.0;
        }
      }
    }

    // 限制偏移量在0到总旋转弧度之间
    angleOffset = angleOffset.clamp(0.0, math.pi * 1.5);

    // 将角度偏移量映射到值
    double newValue =
        (angleOffset / (math.pi * 1.5)) * (widget.maxValue - widget.minValue) +
        widget.minValue;

    // 确保值在范围内
    newValue = newValue.clamp(widget.minValue, widget.maxValue);

    if (newValue.round() != _currentValue.round()) {
      // 避免频繁更新
      setState(() {
        _currentValue = newValue;
      });
      widget.onValueChanged?.call(_currentValue);
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onPanStart: _handlePanStart,
      onPanUpdate: _handlePanUpdate,
      onPanEnd: _handlePanEnd,
      child: CustomPaint(
        size: Size(widget.size, widget.size),
        painter: _RotaryKnobPainter(
          _currentValue,
          widget.label,
          widget.activeColor,
          widget.minValue,
          widget.maxValue,
        ),
      ),
    );
  }
}

class _RotaryKnobPainter extends CustomPainter {
  final double currentValue;
  final String label;
  final Color activeColor;
  final double minValue;
  final double maxValue;

  _RotaryKnobPainter(
    this.currentValue,
    this.label,
    this.activeColor,
    this.minValue,
    this.maxValue,
  );

  @override
  void paint(Canvas canvas, Size size) {
    final double radius = size.width / 2;
    final Offset center = Offset(size.width / 2, size.height / 2);

    // 绘制背景圆盘
    final Paint backgroundPaint = Paint()
      ..color = const Color(0xFF202225)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, radius, backgroundPaint);

    // 绘制外层光圈
    final Paint outerGlowPaint = Paint()
      ..color = activeColor.withOpacity(0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4.0
      ..maskFilter = MaskFilter.blur(BlurStyle.outer, 5.0);
    canvas.drawCircle(center, radius - 2, outerGlowPaint);

    // 绘制主圆环
    final Paint ringPaint = Paint()
      ..color = const Color(0xFF1A1C1F)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 8.0;
    canvas.drawCircle(center, radius - 10, ringPaint);

    // 绘制刻度线
    final Paint tickPaint = Paint()
      ..color = Colors.grey[700]!
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;

    final Paint activeTickPaint = Paint()
      ..color = activeColor
      ..strokeWidth = 3.0
      ..strokeCap = StrokeCap.round;

    // 刻度线的起始和结束角度
    final double startAngleRad = -math.pi * 1.25; // -225度
    final double sweepAngleRad = math.pi * 1.5; // 270度

    // 计算当前值对应的弧度
    final double valueRange = maxValue - minValue;
    final double valueAngleRad =
        ((currentValue - minValue) / valueRange) * sweepAngleRad;

    final int numberOfTicks = (valueRange).toInt() + 1; // 刻度数量，33个刻度(0-32)
    final double angleIncrement = sweepAngleRad / (numberOfTicks - 1);

    for (int i = 0; i < numberOfTicks; i++) {
      final double angle = startAngleRad + i * angleIncrement;
      // 判断是否激活
      final bool isActive =
          (i * angleIncrement) <= valueAngleRad ||
          (currentValue == maxValue && i == numberOfTicks - 1);

      // 刻度线的内外半径
      final double innerTickRadius = radius - 20;
      final double outerTickRadius = radius - 10;

      // 计算刻度线的起点和终点
      final Offset p1 = Offset(
        center.dx + innerTickRadius * math.cos(angle),
        center.dy + innerTickRadius * math.sin(angle),
      );
      final Offset p2 = Offset(
        center.dx + outerTickRadius * math.cos(angle),
        center.dy + outerTickRadius * math.sin(angle),
      );

      canvas.drawLine(p1, p2, isActive ? activeTickPaint : tickPaint);
    }

    // 绘制中心数值
    final TextPainter textPainter = TextPainter(
      text: TextSpan(
        text: currentValue.toStringAsFixed(0),
        style: TextStyle(
          color: Colors.white,
          fontSize: radius / 2,
          fontWeight: FontWeight.bold,
          shadows: [
            Shadow(color: activeColor.withOpacity(0.8), blurRadius: 8.0),
          ],
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();
    textPainter.paint(
      canvas,
      Offset(
        center.dx - textPainter.width / 2,
        center.dy - textPainter.height / 2 - 15,
      ),
    );

    // 绘制底部的标签
    final TextPainter labelPainter = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          color: Colors.white70,
          fontSize: 14.0,
          fontWeight: FontWeight.w500,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    labelPainter.layout();
    labelPainter.paint(
      canvas,
      Offset(center.dx - labelPainter.width / 2, center.dy + radius - 40),
    );
  }

  @override
  bool shouldRepaint(covariant _RotaryKnobPainter oldDelegate) {
    return oldDelegate.currentValue != currentValue ||
        oldDelegate.label != label ||
        oldDelegate.activeColor != activeColor;
  }
}

// BluetoothConnectionScreen 类
class BluetoothConnectionScreen extends StatefulWidget {
  const BluetoothConnectionScreen({super.key});

  @override
  State<BluetoothConnectionScreen> createState() =>
      _BluetoothConnectionScreenState();
}

class _BluetoothConnectionScreenState extends State<BluetoothConnectionScreen> {
  final AmpBluetoothService _bluetoothService = AmpBluetoothService();
  bool isScanning = false;
  bool isConnecting = false;
  List<BluetoothDevice> devices = [];
  Map<String, BluetoothConnectionState> deviceConnectionStates = {};
  StreamSubscription<List<ScanResult>>? _scanSubscription;
  StreamSubscription<bool>? _connectionStatusSubscription;
  StreamSubscription<BluetoothConnectionState>? _deviceConnectionSubscription;
  bool _isPageActive = true;

  @override
  void initState() {
    super.initState();
    _initializeBluetoothListeners();
    _startBluetoothScan();
  }

  @override
  void dispose() {
    _scanSubscription?.cancel();
    _connectionStatusSubscription?.cancel();
    _deviceConnectionSubscription?.cancel();
    FlutterBluePlus.stopScan();
    super.dispose();
  }

  void _initializeBluetoothListeners() {
    _connectionStatusSubscription = _bluetoothService.connectionStatusStream
        .listen(
          (connected) {
            if (mounted) {
              setState(() {});
            }
          },
          onError: (error) {
            print('Connection state listening error: $error');
          },
        );

    _deviceConnectionSubscription = _bluetoothService
        .getConnectionState()
        .listen(
          (state) {
            if (mounted) {
              setState(() {});
            }
          },
          onError: (error) {
            print('Device status listening error: $error');
          },
        );
  }

  void _startBluetoothScan() async {
    try {
      // 🚨 关键修复：Android 12+ 需要同时申请蓝牙权限和位置权限
      print('=== 开始申请蓝牙和位置权限 ===');

      // 1. 申请位置权限 (用于蓝牙扫描)
      var locationStatus = await Permission.locationWhenInUse.request();
      if (!locationStatus.isGranted) {
        print('❌ 位置权限被拒绝：$locationStatus');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Location permission is required to scan for Bluetooth devices',
              ),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }
      print('✅ 位置权限已授予');

      // 2. 申请蓝牙权限
      var bluetoothStatus = await Permission.bluetooth.request();
      if (!bluetoothStatus.isGranted) {
        print('❌ 蓝牙权限被拒绝：$bluetoothStatus');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Bluetooth permission denied'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }
      print('✅ 蓝牙权限已授予');

      // 3. 申请蓝牙连接权限 (Android 12+)
      var bluetoothConnectStatus = await Permission.bluetoothConnect.request();
      print('✅ 蓝牙连接权限状态：$bluetoothConnectStatus');

      // 4. 申请蓝牙扫描权限 (Android 12+)
      var bluetoothScanStatus = await Permission.bluetoothScan.request();
      print('✅ 蓝牙扫描权限状态：$bluetoothScanStatus');

      // 检查蓝牙是否开启
      bool isBluetoothOn = await FlutterBluePlus.isOn;
      if (!isBluetoothOn) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text('Please turn on Bluetooth'),
              backgroundColor: Colors.orange[700],
              action: SnackBarAction(
                label: 'Turn on',
                onPressed: () async {
                  await FlutterBluePlus.turnOn();
                },
              ),
            ),
          );
        }
        return;
      }

      setState(() {
        isScanning = true;
        devices.clear();
      });

      List<BluetoothDevice> connectedDevices =
          await FlutterBluePlus.connectedDevices;
      print('📱 已连接设备数量：${connectedDevices.length}');
      for (var device in connectedDevices) {
        if (!devices.any((d) => d.id.id == device.id.id)) {
          devices.add(device);
          deviceConnectionStates[device.id.id] =
              BluetoothConnectionState.connected;
          print('✅ 添加已连接设备：${device.name} (${device.id.id})');
        }
      }

      // 🚨 关键修复：配置扫描参数以提高发现率
      print('🔍 开始配置蓝牙扫描参数...');

      // 开始扫描新设备 - 添加详细日志
      _scanSubscription = FlutterBluePlus.scanResults.listen(
        (results) {
          if (results.isNotEmpty) {
            print('📡 扫描到 ${results.length} 个设备');
          }

          if (mounted) {
            setState(() {
              for (var result in results) {
                if (!devices.any(
                  (device) => device.id.id == result.device.id.id,
                )) {
                  devices.add(result.device);
                  deviceConnectionStates[result.device.id.id] =
                      BluetoothConnectionState.disconnected;
                  print(
                    '🆕 发现新设备：${result.device.name} (${result.device.id.id}), RSSI: ${result.rssi}',
                  );
                }
              }
            });
          }
        },
        onError: (error) {
          print('❌ 蓝牙扫描错误：$error');
        },
      );

      // 优化扫描参数
      print('🚀 开始蓝牙扫描...');
      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 15), // 延长扫描时间
        androidScanMode: AndroidScanMode.lowLatency, // 低延迟模式
      );

      // 显示扫描进度
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Scanning for Bluetooth devices...'),
            backgroundColor: Colors.green[700],
          ),
        );
      }

      // 扫描15秒后停止
      await Future.delayed(const Duration(seconds: 15));
      await FlutterBluePlus.stopScan();

      if (mounted) {
        setState(() {
          isScanning = false;
        });
      }

      print('✅ 蓝牙扫描完成，共发现 ${devices.length} 个设备');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Scanning completed, found ${devices.length} devices',
            ),
            backgroundColor: Colors.green[700],
          ),
        );
      }
    } catch (e) {
      print('扫描失败: $e');
      if (mounted) {
        setState(() {
          isScanning = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Scanning failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _connectToDevice(BluetoothDevice device) async {
    try {
      setState(() {
        isConnecting = true;
        deviceConnectionStates[device.id.id] =
            BluetoothConnectionState.connecting;
      });

      await _bluetoothService.connectToDevice(device);

      setState(() {
        deviceConnectionStates[device.id.id] =
            BluetoothConnectionState.connected;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Connected to ${device.name}'),
            backgroundColor: Colors.green,
          ),
        );
        // 返回上一页
        Navigator.pop(context, true);
      }
    } catch (e) {
      print('连接失败: $e');
      setState(() {
        deviceConnectionStates[device.id.id] =
            BluetoothConnectionState.disconnected;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Connection failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      setState(() {
        isConnecting = false;
      });
    }
  }

  void _disconnectDevice(BluetoothDevice device) async {
    try {
      await device.disconnect();
      setState(() {
        deviceConnectionStates[device.id.id] =
            BluetoothConnectionState.disconnected;
      });

      if (_bluetoothService.connectedDevice?.id.id == device.id.id) {
        _bluetoothService.connectedDevice = null;
        _bluetoothService.writeCharacteristic = null;
        _bluetoothService.readCharacteristic = null;
        _bluetoothService.clearSavedDevice();
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已断开与 ${device.name} 的连接'),
            backgroundColor: Colors.orange,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('断开连接失败: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Widget _buildDeviceItem(BluetoothDevice device) {
    final connectionState =
        deviceConnectionStates[device.id.id] ??
        BluetoothConnectionState.disconnected;
    final isConnected = connectionState == BluetoothConnectionState.connected;
    final isConnectingThisDevice =
        connectionState == BluetoothConnectionState.connecting;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: ListTile(
        leading: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: isConnected ? Colors.green : Colors.grey,
            shape: BoxShape.circle,
          ),
          child: Icon(Icons.bluetooth, color: Colors.white),
        ),
        title: Text(
          device.name.isNotEmpty ? device.name : 'Unknown Device',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: isConnected ? Colors.green : Colors.black,
          ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(device.id.id, style: TextStyle(fontSize: 12)),
            Text(
              _getConnectionStateText(connectionState),
              style: TextStyle(
                color: _getConnectionStateColor(connectionState),
              ),
            ),
          ],
        ),
        trailing: isConnected || isConnectingThisDevice
            ? IconButton(
                icon: isConnectingThisDevice
                    ? SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(Icons.link_off, color: Colors.red),
                onPressed: isConnectingThisDevice
                    ? null
                    : () => _disconnectDevice(device),
              )
            : ElevatedButton(
                onPressed: () => _connectToDevice(device),
                child: const Text('connect'),
              ),
        onTap: () {
          if (!isConnected && !isConnectingThisDevice) {
            _connectToDevice(device);
          }
        },
      ),
    );
  }

  String _getConnectionStateText(BluetoothConnectionState state) {
    switch (state) {
      case BluetoothConnectionState.connected:
        return 'Connected';
      case BluetoothConnectionState.connecting:
        return 'Connecting...';
      case BluetoothConnectionState.disconnected:
        return 'Not connected';
      case BluetoothConnectionState.disconnecting:
        return 'Disconnected...';
      default:
        return 'Unknown state';
    }
  }

  Color _getConnectionStateColor(BluetoothConnectionState state) {
    switch (state) {
      case BluetoothConnectionState.connected:
        return Colors.green;
      case BluetoothConnectionState.connecting:
        return Colors.orange;
      case BluetoothConnectionState.disconnected:
        return Colors.grey;
      case BluetoothConnectionState.disconnecting:
        return Colors.red;
      default:
        return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Bluetooth devices'),
        backgroundColor: const Color(0xFF2E7D32),
        elevation: 0,
        actions: [
          IconButton(
            icon: Icon(isScanning ? Icons.stop : Icons.refresh),
            onPressed: () {
              if (isScanning) {
                FlutterBluePlus.stopScan();
                setState(() {
                  isScanning = false;
                });
              } else {
                _startBluetoothScan();
              }
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // 状态栏
          Container(
            padding: const EdgeInsets.all(16),
            color: Colors.grey[100],
            child: Row(
              children: [
                Icon(Icons.bluetooth, color: const Color(0xFF2E7D32)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    isScanning
                        ? 'Scanning Bluetooth devices...'
                        : 'Find ${devices.length} device',
                    style: TextStyle(color: Colors.grey[700]),
                  ),
                ),
                if (isScanning)
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
          ),

          // 设备列表
          Expanded(
            child: devices.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.bluetooth_disabled,
                          size: 64,
                          color: Colors.grey[400],
                        ),
                        const SizedBox(height: 16),
                        Text(
                          isScanning
                              ? 'Searching for devices...'
                              : 'Bluetooth device not found',
                          style: TextStyle(
                            color: Colors.grey[600],
                            fontSize: 16,
                          ),
                        ),
                        if (!isScanning)
                          TextButton(
                            onPressed: _startBluetoothScan,
                            child: const Text('Rescan'),
                          ),
                      ],
                    ),
                  )
                : ListView.builder(
                    itemCount: devices.length,
                    itemBuilder: (context, index) {
                      return _buildDeviceItem(devices[index]);
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
