import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'dart:convert';

void main() {
  runApp(const QuickTransferDesktop());
}

class QuickTransferDesktop extends StatelessWidget {
  const QuickTransferDesktop({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '快传 - Ubuntu 端',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class ConnectedDevice {
  String name;
  String ip;
  DateTime? lastSeen;
  String? deviceType;

  ConnectedDevice({required this.name, required this.ip, this.lastSeen, this.deviceType});
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<ConnectedDevice> devices = [];
  ConnectedDevice? selectedDevice;
  String? localIP;
  final TextEditingController _messageController = TextEditingController();
  final TextEditingController _clipboardController = TextEditingController();
  final List<Map<String, dynamic>> _messages = [];
  final List<Map<String, dynamic>> _transferHistory = [];
  HttpServer? _httpServer;
  final Map<String, List<Map<String, dynamic>>> _deviceMessages = {};
  
  // 自动连接相关
  List<ConnectedDevice> _savedDevices = [];
  Timer? _autoConnectTimer;
  String? _currentWifiName;
  
  // 当前选中的标签页
  int _selectedTab = 0; // 0: 消息, 1: 剪贴板, 2: 文件

  @override
  void initState() {
    super.initState();
    _getLocalIP();
    _startServer();
    _loadSavedDevices();
    _startAutoConnect();
    _startClipboardMonitor();
  }

  @override
  void dispose() {
    _httpServer?.close();
    _messageController.dispose();
    _clipboardController.dispose();
    _autoConnectTimer?.cancel();
    super.dispose();
  }

  // 保存设备到本地文件
  Future<void> _saveDevices() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/quick_transfer_devices.json');
      final data = _savedDevices.map((d) => {
        'name': d.name,
        'ip': d.ip,
        'lastSeen': d.lastSeen?.toIso8601String(),
        'deviceType': d.deviceType,
      }).toList();
      await file.writeAsString(jsonEncode(data));
    } catch (e) {
      print('保存设备失败: $e');
    }
  }

  // 加载已保存的设备
  Future<void> _loadSavedDevices() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/quick_transfer_devices.json');
      if (await file.exists()) {
        final data = jsonDecode(await file.readAsString()) as List;
        setState(() {
          _savedDevices = data.map((d) => ConnectedDevice(
            name: d['name'],
            ip: d['ip'],
            lastSeen: d['lastSeen'] != null ? DateTime.parse(d['lastSeen']) : null,
            deviceType: d['deviceType'],
          )).toList();
        });
      }
    } catch (e) {
      print('加载设备失败: $e');
    }
  }

  // 自动连接定时器
  void _startAutoConnect() {
    _autoConnectTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _checkAutoConnect();
    });
  }

  // 检查并自动连接
  Future<void> _checkAutoConnect() async {
    if (_savedDevices.isEmpty || localIP == null) return;
    
    for (var savedDevice in _savedDevices) {
      try {
        final result = await http.get(
          Uri.parse('http://${savedDevice.ip}:8765/api/status'),
        ).timeout(const Duration(milliseconds: 500));
        
        if (result.statusCode == 200) {
          // 设备在线，自动连接
          if (!devices.any((d) => d.ip == savedDevice.ip)) {
            setState(() {
              devices.add(ConnectedDevice(
                name: savedDevice.name,
                ip: savedDevice.ip,
                lastSeen: DateTime.now(),
                deviceType: savedDevice.deviceType,
              ));
            });
            
            // 更新最后连接时间
            savedDevice.lastSeen = DateTime.now();
            await _saveDevices();
            
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('已自动连接: ${savedDevice.name}')),
              );
            }
          }
        }
      } catch (e) {
        // 设备不在线
      }
    }
  }

  // 剪贴板监控
  String? _lastClipboardContent;
  Timer? _clipboardMonitor;
  
  void _startClipboardMonitor() {
    _clipboardMonitor = Timer.periodic(const Duration(seconds: 2), (_) async {
      try {
        final data = await Clipboard.getData(Clipboard.kTextPlain);
        if (data?.text != null && data!.text != _lastClipboardContent && data.text!.isNotEmpty) {
          setState(() {
            _clipboardController.text = data.text!;
          });
        }
      } catch (e) {
        // 忽略
      }
    });
  }

  Future<void> _getLocalIP() async {
    try {
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
      for (var interface in interfaces) {
        for (var addr in interface.addresses) {
          if (addr.address.startsWith('192.168.') || addr.address.startsWith('10.')) {
            setState(() {
              localIP = addr.address;
            });
            break;
          }
        }
        if (localIP != null) break;
      }
    } catch (e) {
      print('获取IP失败: $e');
    }
  }

  Future<void> _startServer() async {
    try {
      _httpServer = await HttpServer.bind(InternetAddress.anyIPv4, 8765);
      
      await for (HttpRequest request in _httpServer!) {
        _handleRequest(request);
      }
      setState(() {});
    } catch (e) {
      print('启动服务器失败: $e');
    }
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final uri = request.uri.path;
    final ip = request.connectionInfo?.remoteAddress.address;
    
    try {
      if (uri == '/api/status') {
        request.response.statusCode = 200;
        request.response.headers.set('Content-Type', 'application/json; charset=utf-8');
        request.response.write(jsonEncode({'name': 'Ubuntu PC', 'type': 'desktop'}));
        await request.response.close();
      }
      else if (uri == '/api/connect') {
        // 手机连接
        final body = await utf8.decodeStream(request);
        final data = jsonDecode(body);
        
        setState(() {
          final existingIndex = devices.indexWhere((d) => d.ip == ip);
          if (existingIndex >= 0) {
            devices[existingIndex].name = data['name'] ?? '手机';
            devices[existingIndex].lastSeen = DateTime.now();
          } else {
            devices.add(ConnectedDevice(
              name: data['name'] ?? '手机',
              ip: ip ?? 'unknown',
              deviceType: data['deviceType'],
            ));
            
            // 保存到已连接设备列表
            final savedIndex = _savedDevices.indexWhere((d) => d.ip == ip);
            if (savedIndex >= 0) {
              _savedDevices[savedIndex].lastSeen = DateTime.now();
            } else {
              _savedDevices.add(ConnectedDevice(
                name: data['name'] ?? '手机',
                ip: ip ?? 'unknown',
                lastSeen: DateTime.now(),
                deviceType: data['deviceType'],
              ));
            }
            _saveDevices();
          }
          if (selectedDevice == null && devices.isNotEmpty) {
            selectedDevice = devices.first;
          }
        });
        
        request.response.statusCode = 200;
        request.response.headers.set('Content-Type', 'application/json');
        request.response.write(jsonEncode({'status': 'ok'}));
        await request.response.close();
      }
      else if (uri == '/api/send') {
        final body = await utf8.decodeStream(request);
        final data = jsonDecode(body);
        
        final type = data['type'];
        
        if (type == 'text') {
          setState(() {
            _messages.add({
              'from': selectedDevice?.name ?? '手机',
              'content': data['content'],
              'time': DateTime.now().toString().substring(11, 19),
              'isMine': false,
            });
          });
        }
        else if (type == 'clipboard') {
          // 收到剪贴板，同步到系统剪贴板
          await Clipboard.setData(ClipboardData(text: data['content']));
          _lastClipboardContent = data['content'];
          
          // 更新剪贴板面板
          setState(() {
            _clipboardController.text = data['content'];
          });
          
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('剪贴板已同步')),
            );
          }
        }
        else if (type == 'file') {
          _receiveFile(data);
        }
        
        request.response.statusCode = 200;
        request.response.headers.set('Content-Type', 'application/json');
        request.response.write(jsonEncode({'status': 'ok'}));
        await request.response.close();
      }
      else if (uri == '/api/messages') {
        request.response.statusCode = 200;
        request.response.headers.set('Content-Type', 'application/json');
        request.response.write(jsonEncode({'messages': _deviceMessages[ip] ?? []}));
        await request.response.close();
      }
      else if (uri == '/api/clipboard') {
        // 获取当前剪贴板
        final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
        request.response.statusCode = 200;
        request.response.headers.set('Content-Type', 'application/json');
        request.response.write(jsonEncode({'content': clipboardData?.text ?? ''}));
        await request.response.close();
      }
      else {
        request.response.statusCode = 404;
        await request.response.close();
      }
    } catch (e) {
      print('处理请求失败: $e');
      request.response.statusCode = 500;
      await request.response.close();
    }
  }

  Future<void> _receiveFile(Map<String, dynamic> msg) async {
    try {
      final fileName = msg['fileName'];
      final fileSize = msg['fileSize'];
      final base64Data = msg['data'];
      
      final downloadsDir = await getDownloadsDirectory();
      final filePath = p.join(downloadsDir!.path, fileName);
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

  // 发送剪贴板到手机
  Future<void> _sendClipboard() async {
    if (selectedDevice == null) return;
    
    final text = _clipboardController.text;
    if (text.isEmpty) return;
    
    try {
      await http.post(
        Uri.parse('http://${selectedDevice!.ip}:8765/api/send'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'type': 'clipboard', 'content': text}),
      );
      
      _lastClipboardContent = text;
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('剪贴板已发送')),
        );
      }
    } catch (e) {
      print('发送失败: $e');
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
  Future<void> _copyToSystemClipboard() async {
    try {
      await Clipboard.setData(ClipboardData(text: _clipboardController.text));
      _lastClipboardContent = _clipboardController.text;
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已复制到剪贴板')),
        );
      }
    } catch (e) {
      print('复制失败: $e');
    }
  }

  Future<void> _sendScreenshot() async {
    if (selectedDevice == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先选择设备')),
      );
      return;
    }
    
    try {
      final tempDir = await getTemporaryDirectory();
      final screenshotPath = '${tempDir.path}/screenshot.png';
      
      await Process.run('gnome-screenshot', ['-f', screenshotPath]);
      
      final file = File(screenshotPath);
      if (await file.exists()) {
        final bytes = await file.readAsBytes();
        final base64Data = base64Encode(bytes);
        
        await http.post(
          Uri.parse('http://${selectedDevice!.ip}:8765/api/send'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'type': 'screenshot', 'data': base64Data}),
        );
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('截图已发送')),
          );
        }
        
        await file.delete();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('截屏失败: $e')),
        );
      }
    }
  }

  Future<void> _sendText() async {
    if (_messageController.text.isEmpty || selectedDevice == null) return;
    
    try {
      await http.post(
        Uri.parse('http://${selectedDevice!.ip}:8765/api/send'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'type': 'text', 'content': _messageController.text}),
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
    if (selectedDevice == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先选择设备')),
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
        title: const Text('连接信息'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('我的 IP: ${localIP ?? "获取中..."}', 
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
            const SizedBox(height: 8),
            const Text('请在手机端手动输入此 IP 进行连接',
              style: TextStyle(color: Colors.grey, fontSize: 12)),
            const SizedBox(height: 16),
            const Divider(),
            const SizedBox(height: 8),
            const Text('已保存的设备:', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            SizedBox(
              height: 150,
              child: _savedDevices.isEmpty
                  ? const Center(child: Text('暂无保存的设备', style: TextStyle(color: Colors.grey)))
                  : ListView.builder(
                      itemCount: _savedDevices.length,
                      itemBuilder: (context, index) {
                        final device = _savedDevices[index];
                        return ListTile(
                          leading: const Icon(Icons.phone_android),
                          title: Text(device.name),
                          subtitle: Text(device.ip),
                          trailing: device.lastSeen != null
                              ? Text(_formatTime(device.lastSeen!))
                              : null,
                          onTap: () {
                            Navigator.pop(context);
                            // 尝试连接
                            _tryConnectToDevice(device.ip);
                          },
                        );
                      },
                    ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final diff = now.difference(time);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes}分钟前';
    if (diff.inDays < 1) return '${diff.inHours}小时前';
    return '${diff.inDays}天前';
  }

  Future<void> _tryConnectToDevice(String ip) async {
    try {
      final result = await http.get(
        Uri.parse('http://$ip:8765/api/status'),
      ).timeout(const Duration(seconds: 2));
      
      if (result.statusCode == 200) {
        final data = jsonDecode(result.body);
        setState(() {
          final existingIndex = devices.indexWhere((d) => d.ip == ip);
          if (existingIndex >= 0) {
            selectedDevice = devices[existingIndex];
          } else {
            final device = ConnectedDevice(
              name: data['name'] ?? '设备',
              ip: ip,
              lastSeen: DateTime.now(),
            );
            devices.add(device);
            selectedDevice = device;
          }
        });
        
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已连接到 $ip')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('连接失败: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isConnected = devices.isNotEmpty;
    
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Text('快传 - Ubuntu 端'),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: isConnected ? Colors.green : Colors.grey,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                isConnected ? '已连接' : '等待连接',
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          IconButton(
            icon: const Icon(Icons.info),
            onPressed: _showManualConnectDialog,
            tooltip: '查看本机IP',
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
                Text('我的 IP: ${localIP ?? "获取中..."}', 
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
                      '${_savedDevices.length}个已保存设备',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                const SizedBox(width: 8),
                TextButton.icon(
                  onPressed: _showManualConnectDialog,
                  icon: const Icon(Icons.info_outline, size: 16),
                  label: const Text('查看详情'),
                ),
              ],
            ),
          ),
          
          Row(
            children: [
              SizedBox(
                width: 250,
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(16),
                      color: Colors.grey[100],
                      child: Row(
                        children: [
                          const Icon(Icons.phone_android),
                          const SizedBox(width: 8),
                          const Text('已连接设备', style: TextStyle(fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ),
                    Expanded(
                      child: devices.isEmpty
                          ? Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(Icons.cloud_off, size: 48, color: Colors.grey),
                                  const SizedBox(height: 8),
                                  const Text('等待手机连接...\n让手机输入本机 IP 连接',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(color: Colors.grey),
                                  ),
                                  const SizedBox(height: 16),
                                  if (_savedDevices.isNotEmpty)
                                    TextButton(
                                      onPressed: _checkAutoConnect,
                                      child: const Text('点击尝试自动连接'),
                                    ),
                                ],
                              ),
                            )
                          : ListView.builder(
                              itemCount: devices.length,
                              itemBuilder: (context, index) {
                                final device = devices[index];
                                final isSelected = selectedDevice?.ip == device.ip;
                                return ListTile(
                                  leading: const Icon(Icons.phone_android),
                                  title: Text(device.name),
                                  subtitle: Text(device.ip),
                                  selected: isSelected,
                                  selectedTileColor: Colors.blue[50],
                                  onTap: () {
                                    setState(() {
                                      selectedDevice = device;
                                    });
                                  },
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
              const VerticalDivider(width: 1),
              
              Expanded(
                child: Column(
                  children: [
                    // 功能按钮
                    if (selectedDevice != null)
                      Container(
                        padding: const EdgeInsets.all(8),
                        color: Colors.grey[50],
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            _buildFeatureButton(Icons.chat, '消息', () => setState(() => _selectedTab = 0)),
                            _buildFeatureButton(Icons.content_paste, '剪贴板', () => setState(() => _selectedTab = 1)),
                            _buildFeatureButton(Icons.folder, '文件', () => setState(() => _selectedTab = 2)),
                            _buildFeatureButton(Icons.screenshot_monitor, '投屏', _sendScreenshot),
                            _buildFeatureButton(Icons.attach_file, '发文件', _sendFile),
                          ],
                        ),
                      ),
                    
                    // 内容区域
                    Expanded(
                      child: selectedDevice == null
                          ? Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  const Icon(Icons.link_off, size: 64, color: Colors.grey),
                                  const SizedBox(height: 16),
                                  const Text('请先连接设备',
                                    style: TextStyle(color: Colors.grey, fontSize: 18)),
                                ],
                              ),
                            )
                          : _buildContentPanel(),
                    ),
                    
                    // 消息输入框（始终显示）
                    if (selectedDevice != null)
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
              ),
              const VerticalDivider(width: 1),
              
              SizedBox(
                width: 250,
                child: Column(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(16),
                      color: Colors.grey[100],
                      child: const Row(
                        children: [
                          Icon(Icons.history),
                          SizedBox(width: 8),
                          Text('传输历史', style: TextStyle(fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ),
                    Expanded(
                      child: _transferHistory.isEmpty
                          ? const Center(
                              child: Text('暂无传输记录',
                                style: TextStyle(color: Colors.grey),
                              ),
                            )
                          : ListView.builder(
                              itemCount: _transferHistory.length,
                              itemBuilder: (context, index) {
                                final item = _transferHistory[index];
                                return ListTile(
                                  leading: Icon(
                                    item['direction'] == '发送' 
                                        ? Icons.upload 
                                        : Icons.download,
                                    color: Colors.blue,
                                  ),
                                  title: Text(item['name'], maxLines: 1, overflow: TextOverflow.ellipsis),
                                  subtitle: Text('${item['size']} • ${item['time']}'),
                                  trailing: Text(
                                    item['status'],
                                    style: TextStyle(
                                      color: item['status'] == '完成' ? Colors.green : Colors.orange,
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            ],
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
                onPressed: _copyToSystemClipboard,
                tooltip: '复制到系统剪贴板',
              ),
              ElevatedButton.icon(
                onPressed: _sendClipboard,
                icon: const Icon(Icons.send, size: 16),
                label: const Text('发送到手机'),
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
          const Text('💡 手机发送的剪贴板内容会自动显示在这里',
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
                        const Text('暂无文件',
                          style: TextStyle(color: Colors.grey)),
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
                          trailing: item['status'] == '完成' && item['path'] != null
                              ? IconButton(
                                  icon: const Icon(Icons.folder_open),
                                  onPressed: () {
                                    Process.run('xdg-open', [item['path']]);
                                  },
                                  tooltip: '打开位置',
                                )
                              : null,
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
      case 'tar':
      case 'gz':
        return Icons.folder_zip;
      default:
        return Icons.insert_drive_file;
    }
  }

  Widget _buildFeatureButton(IconData icon, String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: _selectedTab == 0 && label == '消息' || 
                               _selectedTab == 1 && label == '剪贴板' || 
                               _selectedTab == 2 && label == '文件'
                ? Colors.blue[700] : Colors.blue),
            const SizedBox(height: 4),
            Text(label, style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
