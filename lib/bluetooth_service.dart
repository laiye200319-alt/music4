import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';

class AmpBluetoothService {
  static final AmpBluetoothService _instance = AmpBluetoothService._internal();
  factory AmpBluetoothService() => _instance;
  AmpBluetoothService._internal();

  BluetoothDevice? connectedDevice;
  BluetoothCharacteristic? writeCharacteristic;
  BluetoothCharacteristic? readCharacteristic;

  // 连接状态流控制器
  final StreamController<bool> _connectionStatusController =
      StreamController<bool>.broadcast();
  Stream<bool> get connectionStatusStream => _connectionStatusController.stream;

  // 设备状态流控制器
  final StreamController<Map<String, dynamic>> _deviceStateController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get deviceStateStream =>
      _deviceStateController.stream;

  // 添加设备连接状态监听器
  StreamSubscription<BluetoothConnectionState>? _deviceStateSubscription;

  // 添加蓝牙适配器状态监听器
  StreamSubscription<BluetoothAdapterState>? _adapterStateSubscription;

  // 定义服务UUID
  final String serviceUuid = "0000ae30-0000-1000-8000-00805f9b34fb";
  final String writeCharUuid = "0000ae01-0000-1000-8000-00805f9b34fb";
  final String readCharUuid = "0000ae02-0000-1000-8000-00805f9b34fb";

  // 上次音量值
  int _lastVolume = 16;

  // 添加一个计时器用于定期检查连接状态
  Timer? _connectionCheckTimer;

  // 扫描设备
  Stream<List<ScanResult>> scanDevices() {
    FlutterBluePlus.stopScan();
    FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));
    return FlutterBluePlus.scanResults;
  }

  // 停止扫描
  void stopScan() {
    FlutterBluePlus.stopScan();
  }

  // 连接设备 - 完全重写版本
  Future<void> connectToDevice(BluetoothDevice device) async {
    print('=== Connecting to device ===');
    print('Device name: ${device.name}');
    print('Device ID: ${device.id}');

    try {
      // 取消之前的监听
      _deviceStateSubscription?.cancel();

      // 🚨 关键修复：优化连接参数
      print('🔧 配置连接参数...');
      await device.connect(
        timeout: const Duration(seconds: 45), // 延长连接超时时间
        autoConnect: false, // 禁用自动连接，避免冲突
        mtu: 512, // 设置合适的MTU大小
      );

      connectedDevice = device;
      print('✅ Connected to device: ${device.name}');

      // 保存设备信息
      await saveConnectedDevice(device);

      // 开始监听设备连接状态变化
      _startDeviceStateListener(device);

      // 🚨 关键修复：添加服务发现重试机制
      print('开始发现服务...');
      List<BluetoothService> services = [];
      int serviceDiscoveryAttempts = 0;

      while (services.isEmpty && serviceDiscoveryAttempts < 3) {
        try {
          services = await device.discoverServices();
          if (services.isEmpty) {
            serviceDiscoveryAttempts++;
            print('⚠️ 服务发现为空，第 $serviceDiscoveryAttempts 次重试...');
            await Future.delayed(Duration(seconds: 2));
          }
        } catch (e) {
          serviceDiscoveryAttempts++;
          print('❌ 服务发现失败，第 $serviceDiscoveryAttempts 次重试: $e');
          await Future.delayed(Duration(seconds: 2));
        }
      }

      print('发现 ${services.length} 个服务');

      if (services.isEmpty) {
        throw Exception('无法发现任何服务，请检查设备是否支持蓝牙服务');
      }

      bool foundService = false;
      bool foundWriteChar = false;
      bool foundReadChar = false;

      // 🚨 关键修复：改进服务匹配逻辑
      print('🔍 开始匹配服务...');
      for (BluetoothService service in services) {
        String serviceUuidLower = service.uuid.toString().toLowerCase();
        print('检查服务: $serviceUuidLower');

        // 更宽松的匹配逻辑，支持多种常见蓝牙服务
        bool isTargetService =
            serviceUuidLower == serviceUuid.toLowerCase() ||
            serviceUuidLower.contains('ab00') ||
            serviceUuidLower.contains('ffe0') || // 常见服务UUID
            serviceUuidLower.contains('180a') || // 设备信息服务
            serviceUuidLower.contains('180f'); // 电池服务

        if (isTargetService) {
          foundService = true;
          print('✅ 找到目标服务: ${service.uuid}');

          // 🚨 关键修复：改进特征匹配逻辑
          for (BluetoothCharacteristic characteristic
              in service.characteristics) {
            String charUuid = characteristic.uuid.toString().toLowerCase();
            print('检查特征: $charUuid, 属性: ${characteristic.properties}');

            // 更宽松的特征匹配，支持多种常见特征
            bool isWriteChar =
                (charUuid == writeCharUuid.toLowerCase() ||
                charUuid.contains('ab01') ||
                charUuid.contains('ffe1') || // 常见写入特征
                charUuid.contains('2a00') || // 设备名称特征
                characteristic.properties.write);

            bool isReadChar =
                (charUuid == readCharUuid.toLowerCase() ||
                charUuid.contains('ab02') ||
                charUuid.contains('ffe2') || // 常见通知特征
                charUuid.contains('2a01') || // 外观特征
                characteristic.properties.notify ||
                characteristic.properties.indicate);

            // 检查写入特征
            if (isWriteChar && characteristic.properties.write) {
              writeCharacteristic = characteristic;
              foundWriteChar = true;
              print('✅ 找到写入特征: ${characteristic.uuid}');
            }

            // 检查通知特征
            if (isReadChar &&
                (characteristic.properties.notify ||
                    characteristic.properties.indicate)) {
              readCharacteristic = characteristic;
              foundReadChar = true;
              print('✅ 找到通知特征: ${characteristic.uuid}');

              // 启用通知
              try {
                bool notificationEnabled = await _enableNotificationsWithRetry(
                  characteristic,
                );
                if (notificationEnabled) {
                  print('✅ 通知已启用');

                  characteristic.value.listen(
                    (value) {
                      if (value.isNotEmpty) {
                        // 🚨 关键修改：以十六进制格式完整打印收到的数据
                        print(
                          '📝 Received raw data (Hex): ${value.map((e) => e.toRadixString(16).padLeft(2, '0')).join(' ')}',
                        );
                        print('📝 Received data length: ${value.length}');

                        try {
                          print('📱 收到设备实时数据: $value');
                          print(
                            '数据十六进制: ${value.map((b) => '0x${b.toRadixString(16).padLeft(2, '0')}').join(', ')}',
                          );
                          _parseDeviceResponse(value);
                        } catch (e) {
                          print('❌ Error parsing device state data: $e');
                        }
                      }
                    },
                    onError: (error) {
                      print('通知监听错误: $error');
                      // 尝试重新启用通知
                      _enableNotificationsWithRetry(characteristic);
                    },
                  );
                }
              } catch (e) {
                print('⚠️ 启用通知失败: $e');
              }

              // 【新增代码】：在发送状态请求前，等待 500ms
              await Future.delayed(Duration(milliseconds: 500));

              // 【新增代码】: 连接成功且设置通知后，立即请求初始状态
              await _requestInitialDeviceState();
            }
          }
        }
      }

      // 🚨 关键修复：改进连接状态判断和错误处理
      if (foundService && foundWriteChar) {
        print('✅ 连接完全建立，设备就绪');
        updateConnectionStatus(true);

        // 连接成功后立即读取设备状态
        if (foundReadChar) {
          print('🔄 连接成功，准备读取设备当前状态...');
          await Future.delayed(Duration(milliseconds: 1500));
          await readDeviceCurrentState();
        }

        // 启动连接状态检查定时器
        _startConnectionCheckTimer();

        // 发送连接成功确认
        await _sendConnectionSuccess();
      } else {
        print('❌ 服务或特征发现不完整');
        print(
          '找到服务: $foundService, 找到写入特征: $foundWriteChar, 找到读取特征: $foundReadChar',
        );

        // 🚨 关键修复：尝试备用连接策略
        if (!foundService) {
          print('⚠️ 未找到目标服务，尝试使用第一个可用服务...');
          await _tryFallbackConnection(services);
        } else if (!foundWriteChar) {
          print('⚠️ 未找到写入特征，尝试使用其他特征...');
          await _tryAlternativeCharacteristics(services);
        } else {
          updateConnectionStatus(false);
          throw Exception('设备服务不完整，无法建立完整连接');
        }
      }
    } catch (e) {
      print('❌ 连接失败: $e');
      updateConnectionStatus(false);

      // 🚨 关键修复：更详细的错误信息
      if (e.toString().contains('timeout')) {
        throw Exception('连接超时，请检查设备是否在范围内且可被发现');
      } else if (e.toString().contains('permission')) {
        throw Exception('蓝牙连接权限被拒绝，请在设置中授予权限');
      } else if (e.toString().contains('service')) {
        throw Exception('设备服务发现失败，请确认设备支持蓝牙服务');
      } else {
        throw Exception('连接失败: $e');
      }
    }
  }

  // 开始监听设备连接状态
  void _startDeviceStateListener(BluetoothDevice device) {
    _deviceStateSubscription?.cancel();
    _deviceStateSubscription = device.connectionState.listen(
      (state) {
        print('设备连接状态变化: $state');

        switch (state) {
          case BluetoothConnectionState.connected:
            print('✅ 设已连接');
            updateConnectionStatus(true);
            break;
          case BluetoothConnectionState.disconnected:
            print('❌ 设备已断开');
            updateConnectionStatus(false);
            cleanup(); // 清理资源
            break;
          case BluetoothConnectionState.connecting:
            print('🔄 设备连接中...');
            updateConnectionStatus(false);
            break;
          case BluetoothConnectionState.disconnecting:
            print('⏳ 设备断开中...');
            updateConnectionStatus(false);
            break;
        }
      },
      onError: (error) {
        print('设备状态监听错误: $error');
        updateConnectionStatus(false);
        cleanup();
      },
    );
  }

  // 启动连接状态检查定时器
  void _startConnectionCheckTimer() {
    _connectionCheckTimer?.cancel();
    _connectionCheckTimer = Timer.periodic(Duration(seconds: 5), (timer) async {
      if (connectedDevice != null) {
        try {
          bool isConnected = await connectedDevice!.isConnected;
          if (!isConnected) {
            print('❌ 检测到设备已断开连接');
            updateConnectionStatus(false);
            cleanup();
          }
        } catch (e) {
          print('❌ 检查连接状态时出错: $e');
        }
      }
    });
  }

  // 断开连接
  Future<void> disconnect() async {
    print('=== 断开设备连接 ===');
    if (connectedDevice != null) {
      print('断开设备: ${connectedDevice!.name}');
      try {
        await connectedDevice!.disconnect();
        print('✅ 设备断开成功');
      } catch (e) {
        print('⚠️ 断开设备时出错: $e');
      }
    }

    // 清理资源
    cleanup();
  }

  // 清理资源 - 改为公共方法
  void cleanup() {
    print('清理蓝牙服务资源');
    _deviceStateSubscription?.cancel();
    _deviceStateSubscription = null;
    _connectionCheckTimer?.cancel();
    _connectionCheckTimer = null;
    connectedDevice = null;
    writeCharacteristic = null;
    readCharacteristic = null;
    updateConnectionStatus(false);
  }

  // 发送指令到设备
  Future<void> sendCommand(List<int> command, {int maxRetries = 3}) async {
    print('发送指令: $command, 最大重试次数: $maxRetries');

    // 检查连接状态
    if (!await isReallyConnected) {
      print('❌ 设备未连接，无法发送指令');
      throw Exception('设备未连接');
    }

    if (writeCharacteristic == null) {
      print('❌ 写入特征不可用');
      throw Exception('写入特征不可用');
    }

    int attempts = 0;
    while (attempts < maxRetries) {
      attempts++;
      try {
        print('发送指令尝试: $attempts/$maxRetries');
        print(
          '指令十六进制: ${command.map((b) => '0x${b.toRadixString(16).padLeft(2, '0')}').join(', ')}',
        );

        // 检查设备连接状态
        bool deviceConnected = await connectedDevice!.isConnected;
        if (!deviceConnected) {
          throw Exception('设备在发送前断开连接');
        }

        // 根据特征属性选择写入方式
        if (writeCharacteristic!.properties.write) {
          await writeCharacteristic!.write(command, withoutResponse: false);
        } else if (writeCharacteristic!.properties.writeWithoutResponse) {
          await writeCharacteristic!.write(command, withoutResponse: true);
        } else {
          throw Exception('特征不支持写入操作');
        }

        print('✅ 指令发送成功');
        return;
      } catch (e, stackTrace) {
        print('❌ 发送指令失败 (尝试 $attempts/$maxRetries): $e');
        print('堆栈跟踪: $stackTrace');

        if (attempts >= maxRetries) {
          print('❌ 达到最大重试次数，放弃发送');
          rethrow;
        } else {
          // 增加重试间隔
          int delayMs = 200 * attempts;
          print('等待 ${delayMs}ms 后重试...');
          await Future.delayed(Duration(milliseconds: delayMs));

          // 重试前检查连接状态
          _checkAndUpdateConnectionStatus();
        }
      }
    }
  }

  // 发送音量控制指令
  Future<void> sendVolumeCommand(int volume) async {
    print('=== 发送音量指令 ===');
    print('目标音量: $volume');

    // 确保音量在有效范围内 (0-32)
    volume = volume.clamp(0, 32);
    print('音量已限制: $volume');

    // 保存上次音量（用于取消静音）
    if (volume > 0) {
      _lastVolume = volume;
    }

    // 构造指令包 - 移除Data Length字段，符合AE30协议规范
    final List<int> packet = [
      0xBE, // 包头
      0x01, // 音量指令
      volume, // 音量值
      0x00, // 校验位（临时）
    ];

    // 计算校验和：Header + Command + Data
    int checksum = packet[0] + packet[1] + packet[2];
    packet[3] = checksum & 0xFF;

    print('音量指令包: $packet');
    print(
      '十六进制: ${packet.map((b) => '0x${b.toRadixString(16).padLeft(2, '0')}').join(', ')}',
    );

    await sendCommand(packet, maxRetries: 3);
    print('✅ 音量指令发送完成');
  }

  // 发送音效强度指令
  Future<void> sendEffectCommand(int effectMode) async {
    print('发送音效强度指令: $effectMode');

    // 构造指令包
    final List<int> packet = [
      0xBE, // 包头
      0x02, // 音效指令
      0x01, // 数据长度
      effectMode, // 音效值
      0x00, // 校验位（临时）
    ];

    // 计算校验和
    int checksum = 0;
    for (int i = 1; i < packet.length - 1; i++) {
      checksum += packet[i];
    }
    packet[packet.length - 1] = checksum & 0xFF;

    print('音效指令包: $packet');
    await sendCommand(packet, maxRetries: 3);
  }

  // 发送音效模式指令
  Future<void> sendEffectModeCommand(int effectMode) async {
    print('发送音效模式指令: $effectMode');

    // 构造指令包
    final List<int> packet = [
      0xBE, // 包头
      0x03, // 音效模式指令
      0x01, // 数据长度
      effectMode, // 模式值
      0x00, // 校验位（临时）
    ];

    // 计算校验和
    int checksum = 0;
    for (int i = 1; i < packet.length - 1; i++) {
      checksum += packet[i];
    }
    packet[packet.length - 1] = checksum & 0xFF;

    print('音效模式指令包: $packet');
    await sendCommand(packet, maxRetries: 3);
  }

  // 发送播放命令
  Future<void> sendPlayCommand() async {
    print('=== 发送播放命令 ===');

    // 构造播放指令包
    final List<int> packet = [
      0xBE, // 包头
      0x04, // 播放指令
      0x01, // 数据长度
      0x01, // 播放命令值
      0x00, // 校验位（临时）
    ];

    // 计算校验和
    int checksum = 0;
    for (int i = 1; i < packet.length - 1; i++) {
      checksum += packet[i];
    }
    packet[packet.length - 1] = checksum & 0xFF;

    print('播放指令包: $packet');
    await sendCommand(packet, maxRetries: 3);
  }

  // 发送暂停命令
  Future<void> sendPauseCommand() async {
    print('=== 发送暂停命令 ===');

    // 构造暂停指令包
    final List<int> packet = [
      0xBE, // 包头
      0x04, // 播放控制指令
      0x01, // 数据长度
      0x00, // 暂停命令值
      0x00, // 校验位（临时）
    ];

    // 计算校验和
    int checksum = 0;
    for (int i = 1; i < packet.length - 1; i++) {
      checksum += packet[i];
    }
    packet[packet.length - 1] = checksum & 0xFF;

    print('暂停指令包: $packet');
    await sendCommand(packet, maxRetries: 3);
  }

  // 新增：读取设备当前状态
  Future<void> readDeviceCurrentState() async {
    print('=== 读取设备当前状态 ===');

    if (!await isReallyConnected) {
      print('❌ 设备未连接，无法读取状态');
      return;
    }

    if (writeCharacteristic == null) {
      print('❌ 写入特征不可用');
      return;
    }

    try {
      // 构造读取状态指令包
      final List<int> packet = [
        0xBE, // 包头
        0x04, // 读取状态指令
        0x00, // 数据长度
        0x00, // 校验位（临时）
      ];

      // 计算校验和
      int checksum = 0;
      for (int i = 1; i < packet.length - 1; i++) {
        checksum += packet[i];
      }
      packet[packet.length - 1] = checksum & 0xFF;

      print('读取状态指令包: $packet');
      print(
        '十六进制: ${packet.map((b) => '0x${b.toRadixString(16).padLeft(2, '0')}').join(', ')}',
      );

      await sendCommand(packet, maxRetries: 2);
      print('✅ 状态读取指令发送完成');
    } catch (e) {
      print('❌ 发送状态读取指令失败: $e');
      rethrow;
    }
  }

  // 发送静音指令
  Future<void> sendMuteCommand(bool mute) async {
    print('发送静音指令: $mute');

    if (mute) {
      // 静音：设置音量为0
      await sendVolumeCommand(0);
    } else {
      // 取消静音：恢复上次音量
      await sendVolumeCommand(_lastVolume);
    }
  }

  // 发送输入源切换指令 - 使用AE30协议的0x30指令码
  Future<void> sendInputSourceCommand(int source) async {
    print('发送输入源切换指令: $source');

    // 构造指令包 - 无Data Length字段，符合AE30协议规范
    final List<int> packet = [
      0xBE, // 包头
      0x30, // 输入源切换指令
      source, // 输入源值 (0=FM, 1=AUX, 2=USB/SD, 3=BT)
      0x00, // 校验位（临时）
    ];

    // 计算校验和：Command + Data
    int checksum = packet[1] + packet[2];
    packet[3] = checksum & 0xFF;

    print('输入源切换指令包: $packet');
    await sendCommand(packet, maxRetries: 3);
  }

  // 发送X.BASS控制指令 - 使用AE30协议的0x06指令码
  Future<void> sendXBassCommand(int xbass) async {
    print('发送X.BASS控制指令: $xbass');

    // 构造指令包 - 无Data Length字段，符合AE30协议规范
    final List<int> packet = [
      0xBE, // 包头
      0x06, // X.BASS指令
      xbass, // X.BASS值 (1, 2, 3)
      0x00, // 校验位（临时）
    ];

    // 计算校验和：Command + Data
    int checksum = packet[1] + packet[2];
    packet[3] = checksum & 0xFF;

    print('X.BASS指令包: $packet');
    await sendCommand(packet, maxRetries: 3);
  }

  // 发送播放/暂停指令 - 使用AE30协议的0x31指令码，无数据无校验和
  Future<void> sendPlayPauseCommand() async {
    print('发送播放/暂停指令');

    // 构造指令包 - 无数据指令，不包含校验和
    final List<int> packet = [
      0xBE, // 包头
      0x31, // 播放/暂停指令
    ];

    print('播放/暂停指令包: $packet');
    await sendCommand(packet, maxRetries: 3);
  }

  // 假设这是一个用于请求设备所有当前状态的命令
  static const List<int> _READ_ALL_STATE_COMMAND = [0xBE, 0x00, 0xBE];

  /// 向设备发送请求初始状态的命令
  Future<void> _requestInitialDeviceState() async {
    print('Requesting initial device state...');

    // 确保写入特征值可用
    if (writeCharacteristic != null) {
      try {
        await writeCharacteristic!.write(
          _READ_ALL_STATE_COMMAND,
          withoutResponse: false,
        );
        print('✅ Sent read initial state command');
        // 设备收到命令后，应通过 readCharacteristic (通知) 返回当前状态。
      } catch (e) {
        print('❌ Failed to request initial device state: $e');
      }
    } else {
      print('❌ writeCharacteristic is null, cannot request initial state.');
    }
  }

  // 解析设备响应数据
  void _parseDeviceResponse(List<int> data) {
    print('=== 收到设备数据包 ===');
    print('原始数据: $data');
    print(
      '十六进制: ${data.map((b) => '0x${b.toRadixString(16).padLeft(2, '0')}').join(', ')}',
    );

    if (data.length < 4) {
      print('❌ 数据长度不足，无法解析');
      return;
    }

    // 检查数据包头
    if (data[0] != 0xBE) {
      print('❌ 无效的数据包头');
      return;
    }

    int command = data[1];
    print('指令: 0x${command.toRadixString(16)}');

    // 当命令类型为 0x00 (Sync) 且数据长度足够时，是一个完整的状态包
    // 设备返回格式: BE 00 Volume MusicVB 3D MusicEQ MicVolume MicEQ Checksum
    if (command == 0x00 && data.length >= 9) {
      // 直接按字段位置解析，不假设Data Length
      final int volume = data[2];
      final int musicVB = data[3]; // 播放状态
      final int effect3d = data[4];
      final int musicEQ = data[5];
      final int micVolume = data[6];
      final int micEQ = data[7];

      final Map<String, dynamic> newState = {
        'volume': volume,
        'effect': effect3d,
        'effectMode': musicEQ,
        'micVolume': micVolume,
        'micEQ': micEQ,
        'isPlaying': musicVB == 1, // 假设1表示播放，0表示暂停
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'type': 'initialState',
        'source': 'device',
        'rawData': data,
      };

      print('解析设备状态: $newState');
      
      // 将解析后的状态推送到流中，供控制页更新 UI
      if (!_deviceStateController.isClosed) {
        _deviceStateController.add(newState);
      }
      
      // 打印解析出的状态值
      print(
        '✅ Full state parsed and updated. Volume: $volume, Effect: $effect3d, Effect Mode: $musicEQ, Mic Volume: $micVolume, Mic EQ: $micEQ, Is Playing: ${musicVB == 1}',
      );
    } else {
      // 处理其他类型的指令
      print(
        'ℹ️ Received other data type or incomplete package (Type: ${command.toRadixString(16)}).',
      );
      switch (command) {
        case 0x00: // Sync指令
          _handleSyncCommand(data, 0); // 不再使用dataLength
          break;
        case 0x02: // 音效强度响应（新增）
          _handleEffectResponse(data, 0); // 不再使用dataLength
          break;
        case 0x05: // 状态响应
          _handleStateResponse(data, 0); // 不再使用dataLength
          break;
        case 0x06: // 音量变化通知
          _handleVolumeChange(data, 0); // 不再使用dataLength
          break;
        case 0x07: // 效果变化通知
          _handleEffectChange(data, 0); // 不再使用dataLength
          break;
        case 0x08: // 音效模式变化通知
          _handleEffectModeChange(data, 0); // 不再使用dataLength
          break;
        default:
          print('ℹ️ 收到未知指令类型: 0x${command.toRadixString(16)}');
      }
    }
  }

  // 新增：处理Sync指令 (0x00)
  void _handleSyncCommand(List<int> data, int dataLength) {
    print('=== 处理Sync指令数据 ===');
    print('原始数据: $data');
    print('数据长度: ${data.length}');

    // 更宽松的长度检查
    if (data.length < 9) {
      print('⚠️ Sync指令数据长度不足，无法解析: ${data.length}');
      return;
    }

    try {
      // 直接按字段位置解析
      int volume = data[2];
      int musicVB = data[3];
      int effect3d = data[4];
      int musicEQ = data[5];
      int micVolume = data[6];
      int micEQ = data[7];

      // 数据验证
      volume = volume.clamp(0, 32);
      effect3d = effect3d.clamp(0, 32);
      musicEQ = musicEQ.clamp(0, 8);
      micVolume = micVolume.clamp(0, 32);
      micEQ = micEQ.clamp(0, 8);

      print('🔄 设备主动同步 - 音量: $volume, 3D效果: $effect3d, 音效模式: $musicEQ, 麦克风音量: $micVolume, 麦克风EQ: $micEQ, 播放状态: ${musicVB == 1 ? '播放' : '暂停'}');

      Map<String, dynamic> state = {
        'volume': volume,
        'effect': effect3d,
        'effectMode': musicEQ,
        'micVolume': micVolume,
        'micEQ': micEQ,
        'isPlaying': musicVB == 1,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'type': 'sync',
        'source': 'device',
        'rawData': data,
      };

      if (!_deviceStateController.isClosed) {
        _deviceStateController.add(state);
        print('✅ Sync状态已发送到UI');
      }
    } catch (e) {
      print('❌ 解析Sync指令失败: $e');
      print('错误数据: $data');
    }
  }

  // 处理状态响应
  void _handleStateResponse(List<int> data, int dataLength) {
    print('处理状态响应数据');

    if (dataLength < 3) {
      print('❌ 状态响应数据长度不足: $dataLength');
      return;
    }

    try {
      // 数据内容从索引3开始
      int volume = data[3]; // Volume
      int effect = data[4]; // Effect
      int effectMode = data[5]; // Sound Effects

      print(
        '📊 Current status - Volume: $volume, Effect intensity: $effect, Sound mode: $effectMode',
      );

      // 发布状态到流
      Map<String, dynamic> state = {
        'volume': volume,
        'effect': effect,
        'effectMode': effectMode,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'type': 'stateResponse',
        'rawData': data, // 添加原始数据
      };

      if (!_deviceStateController.isClosed) {
        _deviceStateController.add(state);
      }
    } catch (e) {
      print('❌ Failed to parse status response: $e');
    }
  }

  // 处理音量变化通知
  void _handleVolumeChange(List<int> data, int dataLength) {
    if (dataLength < 1) {
      return;
    }

    // 数据内容从索引3开始
    int volume = data[3];
    print('🔊 Device volume change: $volume');

    Map<String, dynamic> state = {
      'volume': volume,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'type': 'volumeChange',
      'rawData': data, // 添加原始数据
    };

    if (!_deviceStateController.isClosed) {
      _deviceStateController.add(state);
    }
  }

  // 处理效果强度变化通知
  void _handleEffectChange(List<int> data, int dataLength) {
    if (dataLength < 1) {
      return;
    }

    // 数据内容从索引3开始
    int effect = data[3];
    print('🎛️ Device effect intensity variation: $effect');

    Map<String, dynamic> state = {
      'effect': effect,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'type': 'effectChange',
      'rawData': data, // 添加原始数据
    };

    if (!_deviceStateController.isClosed) {
      _deviceStateController.add(state);
    }
  }

  // 处理音效模式变化通知
  void _handleEffectModeChange(List<int> data, int dataLength) {
    if (dataLength < 1) {
      return;
    }

    // 数据内容从索引3开始
    int effectMode = data[3];
    print('🎵 Device sound effect mode change: $effectMode');

    Map<String, dynamic> state = {
      'effectMode': effectMode,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'type': 'effectModeChange',
      'rawData': data, // 添加原始数据
    };

    if (!_deviceStateController.isClosed) {
      _deviceStateController.add(state);
    }
  }

  // 新增：处理音效强度响应
  void _handleEffectResponse(List<int> data, int dataLength) {
    print('处理音效强度响应');

    if (data.length >= 4) {
      int effectValue = data[3]; // 音效强度值
      print('设备确认音效强度设置为: $effectValue');

      // 更新UI状态
      Map<String, dynamic> state = {
        'effect': effectValue,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'type': 'effectResponse',
        'source': 'device',
        'rawData': data,
      };

      if (!_deviceStateController.isClosed) {
        _deviceStateController.add(state);
      }
    }
  }

  // 检查连接状态
  Stream<BluetoothConnectionState> getConnectionState() {
    if (connectedDevice != null) {
      return connectedDevice!.connectionState;
    }
    return Stream.value(BluetoothConnectionState.disconnected);
  }

  // 检查蓝牙是否可用
  Stream<bool> get isBluetoothAvailable {
    return FlutterBluePlus.adapterState.map((state) {
      return state == BluetoothAdapterState.on;
    });
  }

  // 更新连接状态 - 改为公共方法
  void updateConnectionStatus(bool connected) {
    print('Update connection status: $connected');
    if (!_connectionStatusController.isClosed) {
      _connectionStatusController.add(connected);
    }
  }

  // 检查并更新连接状态
  void _checkAndUpdateConnectionStatus() {
    try {
      isReallyConnected.then((reallyConnected) {
        print('Check connection status result: $reallyConnected');
        updateConnectionStatus(reallyConnected);
      });
    } catch (e) {
      print('Error occurred when checking connection status: $e');
      updateConnectionStatus(false);
    }
  }

  // 检查是否已连接（简单检查）
  bool get isConnected {
    return connectedDevice != null && writeCharacteristic != null;
  }

  // 获取真实的连接状态（详细检查）
  Future<bool> get isReallyConnected async {
    if (connectedDevice == null) {
      print('❌ No connected devices');
      return false;
    }

    try {
      // 检查设备物理连接状态
      bool deviceConnected = await connectedDevice!.isConnected;
      if (!deviceConnected) {
        print('❌ The physical connection of the device has been disconnected');
        return false;
      }

      // 检查写入特征是否可用
      bool writeCharAvailable = writeCharacteristic != null;
      if (!writeCharAvailable) {
        print('❌ Write-in features not available');
      }

      // 只有设备连接且写入特征可用才认为是真正连接
      bool reallyConnected = deviceConnected && writeCharAvailable;
      print(
        'True connection status: $reallyConnected (Device connection: $deviceConnected, Write features: $writeCharAvailable)',
      );

      return reallyConnected;
    } catch (e) {
      print('❌ Error checking the real connection status: $e');
      return false;
    }
  }

  // 手动刷新连接状态
  Future<void> refreshConnectionStatus() async {
    print('Manually refresh connection status');
    _checkAndUpdateConnectionStatus();
  }

  // 重新发现服务（用于修复连接）
  Future<bool> rediscoverServices() async {
    print('Rediscover the service');

    if (connectedDevice == null) {
      print('❌ No connected devices, unable to rediscover services');
      return false;
    }

    try {
      // 清理现有特征
      writeCharacteristic = null;
      readCharacteristic = null;

      // 重新发现服务
      List<BluetoothService> services = await connectedDevice!
          .discoverServices();

      bool foundWriteChar = false;
      bool foundReadChar = false;

      for (BluetoothService service in services) {
        String serviceUuidLower = service.uuid.toString().toLowerCase();

        if (serviceUuidLower.contains('ab00')) {
          for (BluetoothCharacteristic characteristic
              in service.characteristics) {
            String charUuid = characteristic.uuid.toString().toLowerCase();

            // 查找写入特征
            if ((charUuid.contains('ab01') || charUuid.contains('ffe1')) &&
                characteristic.properties.write) {
              writeCharacteristic = characteristic;
              foundWriteChar = true;
              print('✅ 重新找到写入特征');
            }

            // 查找读取特征
            if ((charUuid.contains('ab02') || charUuid.contains('ffe2')) &&
                characteristic.properties.notify) {
              readCharacteristic = characteristic;
              foundReadChar = true;
              print('✅ 重新找到读取特征');

              // 启用通知
              try {
                await characteristic.setNotifyValue(true);
                print('✅ 重新启用通知');
              } catch (e) {
                print('⚠️ 重新启用通知失败: $e');
              }
            }
          }
        }
      }

      // 更新连接状态
      bool success = foundWriteChar && foundReadChar;
      updateConnectionStatus(success);

      if (success) {
        print('✅ 服务重新发现成功');
      } else {
        print('❌ 服务重新发现失败，未找到写入特征或读取特征');
        print('找到写入特征: $foundWriteChar, 找到读取特征: $foundReadChar');
      }

      return success;
    } catch (e) {
      print('❌ 重新发现服务时出错: $e');
      updateConnectionStatus(false);
      return false;
    }
  }

  // 读取设备状态（占位方法）
  Future<Map<String, dynamic>?> readDeviceState() async {
    print('读取设备状态 - 当前未实现');
    return null;
  }

  // 释放资源
  void dispose() {
    print('释放蓝牙服务资源');
    _connectionStatusController.close();
    _deviceStateController.close();
    _deviceStateSubscription?.cancel();
    _adapterStateSubscription?.cancel();
    _connectionCheckTimer?.cancel();
    _deviceStateSubscription = null;
    _adapterStateSubscription = null;
    _connectionCheckTimer = null;
  }

  // 保存连接的设备信息
  Future<void> saveConnectedDevice(BluetoothDevice device) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('last_connected_device_id', device.id.id);
      await prefs.setString('last_connected_device_name', device.name);
      print('✅ Saved device info: ${device.name} (${device.id.id})');
    } catch (e) {
      print('❌ Failed to save device info: $e');
    }
  }

  // 获取最后连接的设备信息
  Future<Map<String, String>?> getLastConnectedDevice() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final deviceId = prefs.getString('last_connected_device_id');
      final deviceName = prefs.getString('last_connected_device_name');

      if (deviceId != null && deviceName != null) {
        print('📱 Found last connected device: $deviceName ($deviceId)');
        return {'id': deviceId, 'name': deviceName};
      }
      print('📱 No last connected device found');
      return null;
    } catch (e) {
      print('❌ Failed to get last connected device: $e');
      return null;
    }
  }

  // 清除保存的设备信息
  Future<void> clearSavedDevice() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('last_connected_device_id');
      await prefs.remove('last_connected_device_name');
      print('✅ Cleared saved device info');
    } catch (e) {
      print('❌ Failed to clear saved device: $e');
    }
  }

  // 自动连接到最后一次连接的设备
  Future<bool> autoConnectToLastDevice() async {
    try {
      print('=== Starting auto-connect to last device ===');

      // 获取保存的设备信息
      Map<String, String>? lastDevice = await getLastConnectedDevice();
      if (lastDevice == null) {
        print('❌ No last device found for auto-connect');
        return false;
      }

      String deviceId = lastDevice['id']!;
      String deviceName = lastDevice['name']!;

      print('🔍 Looking for device: $deviceName ($deviceId)');

      // 检查蓝牙状态
      bool isBluetoothOn = await FlutterBluePlus.isOn;
      if (!isBluetoothOn) {
        print('❌ Bluetooth is not available');
        return false;
      }

      // 首先检查已连接的设备
      List<BluetoothDevice> connectedDevices =
          await FlutterBluePlus.connectedDevices;
      for (BluetoothDevice device in connectedDevices) {
        if (device.id.id == deviceId) {
          print('✅ Device already connected, initializing...');
          connectedDevice = device;

          // 重新发现服务
          bool success = await rediscoverServices();
          if (success) {
            updateConnectionStatus(true);
            print('✅ Auto-connect successful');
            return true;
          }
          break;
        }
      }

      // 如果未连接，开始扫描
      print('🔍 Scanning for device...');
      await FlutterBluePlus.startScan(timeout: Duration(seconds: 8));

      Completer<bool> completer = Completer<bool>();
      StreamSubscription? scanSubscription;
      Timer? timeoutTimer;

      timeoutTimer = Timer(Duration(seconds: 8), () {
        scanSubscription?.cancel();
        FlutterBluePlus.stopScan();
        if (!completer.isCompleted) {
          print('❌ Auto-connect timeout');
          completer.complete(false);
        }
      });

      scanSubscription = FlutterBluePlus.scanResults.listen((results) async {
        for (ScanResult result in results) {
          if (result.device.id.id == deviceId) {
            print('🎯 Found device, connecting...');

            scanSubscription?.cancel();
            timeoutTimer?.cancel();
            await FlutterBluePlus.stopScan();

            try {
              await connectToDevice(result.device);
              if (!completer.isCompleted) {
                completer.complete(true);
              }
            } catch (e) {
              print('❌ Auto-connect failed: $e');
              if (!completer.isCompleted) {
                completer.complete(false);
              }
            }
            break;
          }
        }
      });

      return await completer.future;
    } catch (e) {
      print('❌ Auto-connect error: $e');
      return false;
    }
  }

  // 添加重试方法
  Future<bool> _enableNotificationsWithRetry(
    BluetoothCharacteristic characteristic,
  ) async {
    for (int i = 0; i < 3; i++) {
      try {
        await characteristic.setNotifyValue(true);
        await Future.delayed(Duration(milliseconds: 300));
        if (characteristic.isNotifying) {
          return true;
        }
      } catch (e) {
        print('启用通知重试 ${i + 1}/3 失败: $e');
      }
    }
    return false;
  }

  // 🚨 关键修复：添加备用连接策略方法

  // 发送连接成功确认
  Future<void> _sendConnectionSuccess() async {
    try {
      if (writeCharacteristic != null) {
        // 发送连接成功确认指令
        List<int> successCommand = [0xAA, 0x55, 0x01]; // 示例确认指令
        await writeCharacteristic!.write(
          successCommand,
          withoutResponse: false,
        );
        print('✅ 发送连接成功确认');
      }
    } catch (e) {
      print('⚠️ 发送连接成功确认失败: $e');
    }
  }

  // 备用连接策略：使用第一个可用服务
  Future<void> _tryFallbackConnection(List<BluetoothService> services) async {
    try {
      print('🔄 尝试备用连接策略...');

      if (services.isNotEmpty) {
        BluetoothService firstService = services.first;
        print('使用第一个服务: ${firstService.uuid}');

        // 尝试使用该服务的特征
        for (BluetoothCharacteristic characteristic
            in firstService.characteristics) {
          if (characteristic.properties.write) {
            writeCharacteristic = characteristic;
            print('✅ 找到备用写入特征: ${characteristic.uuid}');
          }

          if (characteristic.properties.notify ||
              characteristic.properties.indicate) {
            readCharacteristic = characteristic;
            print('✅ 找到备用通知特征: ${characteristic.uuid}');

            // 启用通知
            await _enableNotificationsWithRetry(characteristic);
          }
        }

        if (writeCharacteristic != null) {
          updateConnectionStatus(true);
          _startConnectionCheckTimer();
          print('✅ 备用连接策略成功');
          return;
        }
      }

      throw Exception('备用连接策略失败');
    } catch (e) {
      print('❌ 备用连接策略失败: $e');
      updateConnectionStatus(false);
      throw e;
    }
  }

  // 尝试使用其他特征
  Future<void> _tryAlternativeCharacteristics(
    List<BluetoothService> services,
  ) async {
    try {
      print('🔄 尝试使用其他特征...');

      for (BluetoothService service in services) {
        for (BluetoothCharacteristic characteristic
            in service.characteristics) {
          if (characteristic.properties.write && writeCharacteristic == null) {
            writeCharacteristic = characteristic;
            print('✅ 找到替代写入特征: ${characteristic.uuid}');
          }

          if ((characteristic.properties.notify ||
                  characteristic.properties.indicate) &&
              readCharacteristic == null) {
            readCharacteristic = characteristic;
            print('✅ 找到替代通知特征: ${characteristic.uuid}');

            // 启用通知
            await _enableNotificationsWithRetry(characteristic);
          }
        }
      }

      if (writeCharacteristic != null) {
        updateConnectionStatus(true);
        _startConnectionCheckTimer();
        print('✅ 替代特征策略成功');
        return;
      }

      throw Exception('替代特征策略失败');
    } catch (e) {
      print('❌ 替代特征策略失败: $e');
      updateConnectionStatus(false);
      throw e;
    }
  }

  // 启动蓝牙适配器状态监听
  void startAdapterStateListener() {
    _adapterStateSubscription?.cancel();
    _adapterStateSubscription = FlutterBluePlus.adapterState.listen((
      state,
    ) async {
      print('蓝牙适配器状态变化: $state');

      switch (state) {
        case BluetoothAdapterState.on:
          print('✅ 蓝牙已开启');
          // 蓝牙开启后尝试重新连接
          await _attemptReconnectAfterBluetoothEnabled();
          break;
        case BluetoothAdapterState.off:
          print('❌ 蓝牙已关闭');
          // 蓝牙关闭时清理连接
          cleanup();
          break;
        default:
          print('ℹ️ 蓝牙状态变化: $state');
      }
    });
  }

  // 蓝牙开启后尝试重新连接
  Future<void> _attemptReconnectAfterBluetoothEnabled() async {
    try {
      // 延迟一段时间等待蓝牙完全初始化
      await Future.delayed(Duration(seconds: 2));

      // 尝试自动连接到最后一个设备
      bool success = await autoConnectToLastDevice();
      if (success) {
        print('✅ 蓝牙重新开启后自动连接成功');
      } else {
        print('⚠️ 蓝牙重新开启后自动连接失败');
      }
    } catch (e) {
      print('❌ 蓝牙重新开启后尝试连接时发生错误: $e');
    }
  }
}
