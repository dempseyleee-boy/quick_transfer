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
  final TextEditingController _ipController = TextEditingController();
  final List<Map<String, dynamic>> _messages = [];
  final List<Map<String, dynamic>> _transferHistory = [];
  bool _isConnected = false;
  Timer? _pollTimer;
  String? _lastClipboard;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initPermissions();
    _getDeviceName();
    _getLocalIP();
    _startPolling();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pollTimer?.cancel();
    _messageController.dispose();
    _ipController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // 暂时禁用剪贴板检查
    }
  }

  Future<void> _initPermissions() async {
    await [Permission.storage, Permission.photos, Permission.camera].request();
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
      setState(() {
        _isConnected = false;
      });
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
    
    for (int i = 1; i < 255; i++) {
      if (!mounted) return;
      
      final ip = '$subnet.$i';
      if (ip == wifiIP) continue;
      
      try {
        final result = await http.get(
          Uri.parse('http://$ip:8765/api/status'),
        ).timeout(const Duration(milliseconds: 100));
        
        if (result.statusCode == 200) {
          final data = jsonDecode(result.body);
          setState(() {
            devices.add(Device(
              name: data['name'] ?? '电脑',
              ip: ip,
              port: 8765,
            ));
          });
        }
      } catch (e) {
        // 忽略
      }
    }
    
    setState(() => isSearching = false);
  }

  Future<void> _connectToDevice(Device device) async {
    try {
      // 尝试连接 - 发送注册请求
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
    
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('剪贴板已同步')),
      );
    }
  }

  Future<void> _sendClipboard() async {
    if (!_isConnected || selectedDevice == null) return;
    
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text == null) return;
    
    _lastClipboard = data!.text;
    
    try {
      await http.post(
        Uri.parse('http://${selectedDevice!.ip}:8765/api/send'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'type': 'clipboard',
          'content': data.text,
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
                TextButton.icon(
                  onPressed: _showManualConnectDialog,
                  icon: const Icon(Icons.link, size: 16),
                  label: const Text('手动连接'),
                ),
              ],
            ),
          ),
          
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
            child: devices.isEmpty
                ? const Center(
                    child: Text('未发现设备\n点击右上角手动连接',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey),
                    ),
                  )
                : ListView.builder(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    itemCount: devices.length,
                    itemBuilder: (context, index) {
                      final device = devices[index];
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
                              color: isSelected ? Colors.blue : Colors.grey[300]!,
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
                              Text(
                                device.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
          
          if (_isConnected)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _buildFeatureButton(Icons.content_paste, '剪贴板', _sendClipboard),
                  _buildFeatureButton(Icons.share, '发文件', _sendFile),
                ],
              ),
            ),
          
          const Divider(height: 1),
          
          Expanded(
            child: !_isConnected
                ? Center(
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
                      ],
                    ),
                  )
                : ListView.builder(
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
                  ),
          ),
          
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

  Widget _buildFeatureButton(IconData icon, String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.blue[50],
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
}
