import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  runApp(const QuickTransferMobile());
}

class QuickTransferMobile extends StatelessWidget {
  const QuickTransferMobile({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '快传',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class Device {
  final String name;
  final String ip;
  final int port;

  Device({required this.name, required this.ip, required this.port});
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  List<Device> devices = [];
  Device? selectedDevice;
  bool isSearching = false;
  String? currentWifiIP;
  String deviceName = '手机';
  final TextEditingController _messageController = TextEditingController();
  final TextEditingController _clipboardController = TextEditingController();
  final TextEditingController _ipController = TextEditingController();
  final List<Map<String, dynamic>> _messages = [];
  final List<Map<String, dynamic>> _transferHistory = [];
  bool _isConnected = false;
  Timer? _pollTimer;
  String? _lastClipboard;
  
  // 当前选中的标签页: 0=消息, 1=剪贴板, 2=文件
  int _selectedTab = 0;
  
  // 已保存的设备列表
  List<Device> _savedDevices = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initPermissions();
    _getDeviceName();
    _getLocalIP();
    _loadSavedDevices();
    _startPolling();
    _startAutoConnect();
    _startClipboardMonitor();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pollTimer?.cancel();
    _messageController.dispose();
    _clipboardController.dispose();
    _ipController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // 恢复时检查剪贴板
      _checkClipboard();
    }
  }

  Future<void> _initPermissions() async {
    await [
      Permission.storage,
      Permission.photos,
      Permission.camera,
      Permission.notification,
    ].request();
  }

  Future<void> _getDeviceName() async {
    final deviceInfo = DeviceInfoPlugin();
    final androidInfo = await deviceInfo.androidInfo;
    setState(() {
      deviceName = androidInfo.brand + ' ' + androidInfo.model;
    });
  }

  Future<void> _getLocalIP() async {
    final networkInfo = NetworkInfo();
    final wifiIP = await networkInfo.getWifiIP();
    setState(() {
      currentWifiIP = wifiIP;
    });
  }

  // 加载已保存的设备
  Future<void> _loadSavedDevices() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedList = prefs.getStringList('saved_devices') ?? [];
      setState(() {
        _savedDevices = savedList.map((s) {
          final parts = s.split('|');
          return Device(name: parts[0], ip: parts[1], port: 8765);
        }).toList();
      });
    } catch (e) {
      print('加载设备失败: $e');
    }
  }

  // 保存设备到本地
  Future<void> _saveDevice(Device device) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedList = prefs.getStringList('saved_devices') ?? [];
      
      // 检查是否已存在
      final exists = savedList.any((s) => s.startsWith('${device.ip}|'));
      if (!exists) {
        savedList.add('${device.name}|${device.ip}');
        await prefs.setStringList('saved_devices', savedList);
        setState(() {
          _savedDevices.add(device);
        });
      }
    } catch (e) {
      print('保存设备失败: $e');
    }
  }

  // 自动连接已保存的设备
  void _startAutoConnect() {
    Timer.periodic(const Duration(seconds: 15), (_) {
      if (!_isConnected && _savedDevices.isNotEmpty) {
        _tryAutoConnect();
      }
    });
  }

  Future<void> _tryAutoConnect() async {
    for (var device in _savedDevices) {
      if (!mounted || _isConnected) break;
      
      try {
        final result = await http.get(
          Uri.parse('http://${device.ip}:8765/api/status'),
        ).timeout(const Duration(milliseconds: 500));
        
        if (result.statusCode == 200) {
          await _connectToDevice(device);
          break;
        }
      } catch (e) {
        // 忽略
      }
    }
  }

  // 剪贴板监控
  void _startClipboardMonitor() {
    Timer.periodic(const Duration(seconds: 2), (_) {
      _checkClipboard();
    });
  }

  Future<void> _checkClipboard() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (data?.text != null && data!.text != _lastClipboard && data.text!.isNotEmpty) {
        setState(() {
          _clipboardController.text = data.text!;
        });
      }
    } catch (e) {
      // 忽略
    }
  }

  void _startPolling() {
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (_isConnected) {
        _pollForMessages();
      }
    });
  }

  Future<void> _pollForMessages() async {
    if (selectedDevice == null) return;
    
    try {
      final response = await http.get(
        Uri.parse('http://${selectedDevice!.ip}:8765/api/messages'),
      ).timeout(const Duration(seconds: 2));
      
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data['messages'] != null) {
          for (var msg in data['messages']) {
            _handleMessage(msg);
          }
        }
      }
    } catch (e) {
      // 连接丢失
    }
  }

  Future<void> _searchDevices() async {
    setState(() => isSearching = true);
    
    final networkInfo = NetworkInfo();
    final wifiIP = await networkInfo.getWifiIP();
    
    if (wifiIP == null) {
      setState(() => isSearching = false);
      return;
    }

    currentWifiIP = wifiIP;
    final parts = wifiIP.split('.');
    final subnet = '${parts[0]}.${parts[1]}.${parts[2]}';
    
    devices.clear();
    
    // 并发搜索
    final futures = <Future>[];
    for (int i = 1; i < 255; i++) {
      if (!mounted) return;
      
      final ip = '$subnet.$i';
      if (ip == wifiIP) continue;
      
      futures.add(_checkDevice(ip));
    }
    
    await Future.wait(futures);
    setState(() => isSearching = false);
  }

  Future<void> _checkDevice(String ip) async {
    try {
      final result = await http.get(
        Uri.parse('http://$ip:8765/api/status'),
      ).timeout(const Duration(milliseconds: 100));
      
      if (result.statusCode == 200) {
        final data = jsonDecode(result.body);
        if (mounted) {
          setState(() {
            devices.add(Device(
              name: data['name'] ?? '电脑',
              ip: ip,
              port: 8765,
            ));
          });
        }
      }
    } catch (e) {
      // 忽略
    }
  }

  Future<void> _connectToDevice(Device device) async {
    try {
      final response = await http.post(
        Uri.parse('http://${device.ip}:8765/api/connect'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'name': deviceName,
          'deviceType': 'mobile',
        }),
      ).timeout(const Duration(seconds: 5));
      
      if (response.statusCode == 200) {
        selectedDevice = device;
        setState(() {
          _isConnected = true;
          isSearching = false;
        });
        
        // 保存设备
        await _saveDevice(device);
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已连接到 ${device.name}')),
          );
        }
      } else {
        throw Exception('连接失败');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('连接失败: $e')),
        );
      }
    }
  }

  Future<void> _connectToIP(String ip) async {
    if (ip.isEmpty) return;
    final device = Device(name: '电脑', ip: ip, port: 8765);
    await _connectToDevice(device);
  }

  void _handleMessage(Map<String, dynamic> msg) {
    final type = msg['type'];
    
    switch (type) {
      case 'text':
        setState(() {
          _messages.add({
            'from': '电脑',
            'content': msg['content'],
            'time': DateTime.now().toString().substring(11, 19),
            'isMine': false,
          });
        });
        break;
        
      case 'clipboard':
        _handleClipboard(msg['content']);
        break;
        
      case 'file':
        _receiveFile(msg);
        break;
    }
  }

  Future<void> _handleClipboard(String content) async {
    await Clipboard.setData(ClipboardData(text: content));
    _lastClipboard = content;
    
    setState(() {
      _clipboardController.text = content;
    });
    
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('剪贴板已同步')),
      );
    }
  }

  Future<void> _sendClipboard() async {
    if (!_isConnected || selectedDevice == null) return;
    
    final text = _clipboardController.text;
    if (text.isEmpty) return;
    
    _lastClipboard = text;
    
    try {
      await http.post(
        Uri.parse('http://${selectedDevice!.ip}:8765/api/send'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'type': 'clipboard',
          'content': text,
        }),
      );
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('剪贴板已发送')),
        );
      }
    } catch (e) {
      // 发送失败
    }
  }

  // 从系统读取剪贴板
  Future<void> _readClipboard() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (data?.text != null) {
        setState(() {
          _clipboardController.text = data!.text!;
        });
      }
    } catch (e) {
      print('读取剪贴板失败: $e');
    }
  }

  // 复制到系统剪贴板
  Future<void> _copyToClipboard() async {
    try {
      await Clipboard.setData(ClipboardData(text: _clipboardController.text));
      _lastClipboard = _clipboardController.text;
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已复制到剪贴板')),
        );
      }
    } catch (e) {
      print('复制失败: $e');
    }
  }

  Future<void> _receiveFile(Map<String, dynamic> msg) async {
    try {
      final fileName = msg['fileName'];
      final fileSize = msg['fileSize'];
      final base64Data = msg['data'];
      
      final directory = await getExternalStorageDirectory();
      final filePath = p.join(directory!.path, fileName);
      final file = File(filePath);
      await file.writeAsBytes(base64Decode(base64Data));
      
      setState(() {
        _transferHistory.insert(0, {
          'name': fileName,
          'size': _formatFileSize(fileSize),
          'direction': '接收',
          'time': DateTime.now().toString().substring(11, 19),
          'status': '完成',
          'path': filePath,
        });
      });
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('文件已保存到: $filePath')),
        );
      }
    } catch (e) {
      print('接收文件失败: $e');
    }
  }

  Future<void> _sendText() async {
    if (_messageController.text.isEmpty || !_isConnected || selectedDevice == null) return;
    
    try {
      await http.post(
        Uri.parse('http://${selectedDevice!.ip}:8765/api/send'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'type': 'text',
          'content': _messageController.text,
        }),
      );
      
      setState(() {
        _messages.add({
          'from': '我',
          'content': _messageController.text,
          'time': DateTime.now().toString().substring(11, 19),
          'isMine': true,
        });
      });
      
      _messageController.clear();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('发送失败: $e')),
        );
      }
    }
  }

  Future<void> _sendFile() async {
    if (!_isConnected || selectedDevice == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先连接设备')),
      );
      return;
    }
    
    final result = await FilePicker.platform.pickFiles();
    if (result == null || result.files.isEmpty) return;
    
    final file = File(result.files.single.path!);
    final fileName = result.files.single.name;
    final fileSize = result.files.single.size;
    
    setState(() {
      _transferHistory.insert(0, {
        'name': fileName,
        'size': _formatFileSize(fileSize),
        'direction': '发送',
        'time': DateTime.now().toString().substring(11, 19),
        'status': '传输中',
      });
    });
    
    try {
      final bytes = await file.readAsBytes();
      final base64Data = base64Encode(bytes);
      
      await http.post(
        Uri.parse('http://${selectedDevice!.ip}:8765/api/send'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'type': 'file',
          'fileName': fileName,
          'fileSize': fileSize,
          'data': base64Data,
        }),
      );
      
      setState(() {
        final index = _transferHistory.indexWhere((h) => h['name'] == fileName);
        if (index != -1) {
          _transferHistory[index]['status'] = '完成';
        }
      });
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('文件发送成功')),
        );
      }
    } catch (e) {
      setState(() {
        final index = _transferHistory.indexWhere((h) => h['name'] == fileName);
        if (index != -1) {
          _transferHistory[index]['status'] = '失败';
        }
      });
    }
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  void _showManualConnectDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('手动连接'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('我的 IP: ${currentWifiIP ?? "未连接"}'),
            const SizedBox(height: 16),
            TextField(
              controller: _ipController,
              decoration: const InputDecoration(
                labelText: '输入对方 IP 地址',
                hintText: '例如: 192.168.5.138',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            if (_savedDevices.isNotEmpty) ...[
              const Divider(),
              const Text('已保存的设备:', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              SizedBox(
                height: 120,
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _savedDevices.length,
                  itemBuilder: (context, index) {
                    final device = _savedDevices[index];
                    return ListTile(
                      leading: const Icon(Icons.computer),
                      title: Text(device.name),
                      subtitle: Text(device.ip),
                      onTap: () {
                        Navigator.pop(context);
                        _connectToDevice(device);
                      },
                    );
                  },
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              _connectToIP(_ipController.text);
            },
            child: const Text('连接'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Text('快传'),
            const SizedBox(width: 8),
            if (_isConnected)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.green,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Text('已连接', style: TextStyle(fontSize: 12)),
              ),
          ],
        ),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.link),
            onPressed: _showManualConnectDialog,
            tooltip: '手动连接',
          ),
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _searchDevices,
            tooltip: '搜索设备',
          ),
        ],
      ),
      body: Column(
        children: [
          // IP 和状态栏
          Container(
            padding: const EdgeInsets.all(12),
            color: Colors.blue[50],
            child: Row(
              children: [
                const Icon(Icons.wifi, size: 20),
                const SizedBox(width: 8),
                Text('我的 IP: ${currentWifiIP ?? "获取中..."}', 
                  style: const TextStyle(fontWeight: FontWeight.bold)),
                const Spacer(),
                if (_savedDevices.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.blue[100],
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '${_savedDevices.length}个已保存',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
              ],
            ),
          ),
          
          // 设备列表
          Container(
            padding: const EdgeInsets.all(16),
            color: Colors.grey[100],
            child: Row(
              children: [
                const Icon(Icons.computer),
                const SizedBox(width: 8),
                const Text('可用设备', style: TextStyle(fontWeight: FontWeight.bold)),
                const Spacer(),
                if (isSearching)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
          ),
          SizedBox(
            height: 80,
            child: devices.isEmpty && _savedDevices.isEmpty
                ? const Center(
                    child: Text('未发现设备\n点击右上角手动连接',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey),
                    ),
                  )
                : ListView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    children: [
                      // 已保存的设备
                      ..._savedDevices.map((device) => _buildDeviceChip(device, true)),
                      // 搜索到的设备
                      ...devices.where((d) => !_savedDevices.any((s) => s.ip == d.ip))
                          .map((device) => _buildDeviceChip(device, false)),
                    ],
                  ),
          ),
          
          // 功能按钮
          if (_isConnected)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _buildFeatureButton(Icons.chat, '消息', () => setState(() => _selectedTab = 0)),
                  _buildFeatureButton(Icons.content_paste, '剪贴板', () => setState(() => _selectedTab = 1)),
                  _buildFeatureButton(Icons.folder, '文件', () => setState(() => _selectedTab = 2)),
                  _buildFeatureButton(Icons.share, '发文件', _sendFile),
                ],
              ),
            ),
          
          const Divider(height: 1),
          
          // 内容区域
          Expanded(
            child: !_isConnected
                ? _buildDisconnectedView()
                : _buildContentPanel(),
          ),
          
          // 消息输入框
          if (_isConnected)
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.grey[100],
                border: Border(top: BorderSide(color: Colors.grey[300]!)),
              ),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.attach_file),
                    onPressed: _sendFile,
                    tooltip: '发送文件',
                  ),
                  Expanded(
                    child: TextField(
                      controller: _messageController,
                      decoration: const InputDecoration(
                        hintText: '输入消息...',
                        border: OutlineInputBorder(),
                        contentPadding: EdgeInsets.symmetric(horizontal: 12),
                      ),
                      onSubmitted: (_) => _sendText(),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.send),
                    onPressed: _sendText,
                    tooltip: '发送',
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildDeviceChip(Device device, bool isSaved) {
    final isSelected = selectedDevice?.ip == device.ip;
    return GestureDetector(
      onTap: () => _connectToDevice(device),
      child: Container(
        width: 120,
        margin: const EdgeInsets.symmetric(horizontal: 4),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: isSelected ? Colors.blue[50] : Colors.white,
          border: Border.all(
            color: isSelected ? Colors.blue : isSaved ? Colors.green : Colors.grey[300]!,
            width: isSelected ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.computer, 
              color: isSelected ? Colors.blue : Colors.grey[600]),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (isSaved) 
                  const Icon(Icons.star, size: 12, color: Colors.amber),
                Flexible(
                  child: Text(
                    device.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFeatureButton(IconData icon, String label, VoidCallback onTap) {
    final isSelected = (_selectedTab == 0 && label == '消息') ||
                       (_selectedTab == 1 && label == '剪贴板') ||
                       (_selectedTab == 2 && label == '文件');
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isSelected ? Colors.blue[100] : Colors.blue[50],
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: Colors.blue),
          ),
          const SizedBox(height: 4),
          Text(label, style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }

  Widget _buildDisconnectedView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.cloud_off, size: 64, color: Colors.grey),
          const SizedBox(height: 16),
          const Text('等待连接...',
            style: TextStyle(color: Colors.grey, fontSize: 18)),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: _showManualConnectDialog,
            icon: const Icon(Icons.link),
            label: const Text('手动连接'),
          ),
          const SizedBox(height: 16),
          if (_savedDevices.isNotEmpty)
            ElevatedButton.icon(
              onPressed: _tryAutoConnect,
              icon: const Icon(Icons.sync),
              label: const Text('尝试自动连接'),
            ),
        ],
      ),
    );
  }

  Widget _buildContentPanel() {
    switch (_selectedTab) {
      case 0:
        return _buildMessagePanel();
      case 1:
        return _buildClipboardPanel();
      case 2:
        return _buildFilePanel();
      default:
        return _buildMessagePanel();
    }
  }

  Widget _buildMessagePanel() {
    if (_messages.isEmpty) {
      return const Center(
        child: Text('暂无消息', style: TextStyle(color: Colors.grey)),
      );
    }
    
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _messages.length,
      itemBuilder: (context, index) {
        final msg = _messages[index];
        return Align(
          alignment: msg['isMine'] 
              ? Alignment.centerRight 
              : Alignment.centerLeft,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 4),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: msg['isMine'] ? Colors.blue : Colors.grey[200],
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  msg['content'],
                  style: TextStyle(
                    color: msg['isMine'] ? Colors.white : Colors.black,
                  ),
                ),
                Text(
                  msg['time'],
                  style: TextStyle(
                    fontSize: 10,
                    color: msg['isMine'] ? Colors.white70 : Colors.grey,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildClipboardPanel() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.content_paste, size: 20),
              const SizedBox(width: 8),
              const Text('剪贴板', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const Spacer(),
              IconButton(
                icon: const Icon(Icons.refresh),
                onPressed: _readClipboard,
                tooltip: '刷新',
              ),
              IconButton(
                icon: const Icon(Icons.copy),
                onPressed: _copyToClipboard,
                tooltip: '复制到系统剪贴板',
              ),
              ElevatedButton.icon(
                onPressed: _sendClipboard,
                icon: const Icon(Icons.send, size: 16),
                label: const Text('发送到电脑'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.grey[100],
                border: Border.all(color: Colors.grey[300]!),
                borderRadius: BorderRadius.circular(8),
              ),
              child: TextField(
                controller: _clipboardController,
                maxLines: null,
                expands: true,
                decoration: const InputDecoration(
                  hintText: '点击"刷新"读取剪贴板内容，或直接输入文本...',
                  border: InputBorder.none,
                ),
                style: const TextStyle(fontSize: 14),
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Text('💡 电脑发送的剪贴板内容会自动显示在这里',
            style: TextStyle(color: Colors.grey, fontSize: 12)),
        ],
      ),
    );
  }

  Widget _buildFilePanel() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.folder, size: 20),
              const SizedBox(width: 8),
              const Text('文件管理', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const Spacer(),
              ElevatedButton.icon(
                onPressed: _sendFile,
                icon: const Icon(Icons.upload_file, size: 16),
                label: const Text('发送文件'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: _transferHistory.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.folder_open, size: 64, color: Colors.grey),
                        const SizedBox(height: 8),
                        const Text('暂无文件', style: TextStyle(color: Colors.grey)),
                        const SizedBox(height: 16),
                        ElevatedButton.icon(
                          onPressed: _sendFile,
                          icon: const Icon(Icons.add),
                          label: const Text('发送文件'),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    itemCount: _transferHistory.length,
                    itemBuilder: (context, index) {
                      final item = _transferHistory[index];
                      return Card(
                        child: ListTile(
                          leading: Icon(
                            _getFileIcon(item['name']),
                            color: Colors.blue,
                            size: 40,
                          ),
                          title: Text(item['name']),
                          subtitle: Text('${item['size']} • ${item['time']} • ${item['direction']}'),
                          trailing: Text(
                            item['status'],
                            style: TextStyle(
                              color: item['status'] == '完成' ? Colors.green : Colors.orange,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  IconData _getFileIcon(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();
    switch (ext) {
      case 'jpg':
      case 'jpeg':
      case 'png':
      case 'gif':
      case 'bmp':
      case 'webp':
        return Icons.image;
      case 'mp4':
      case 'avi':
      case 'mkv':
      case 'mov':
        return Icons.video_file;
      case 'mp3':
      case 'wav':
      case 'flac':
      case 'aac':
        return Icons.audio_file;
      case 'pdf':
        return Icons.picture_as_pdf;
      case 'doc':
      case 'docx':
        return Icons.description;
      case 'xls':
      case 'xlsx':
        return Icons.table_chart;
      case 'zip':
      case 'rar':
      case '7z':
        return Icons.folder_zip;
      default:
        return Icons.insert_drive_file;
    }
  }
}
