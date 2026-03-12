import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

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

  ConnectedDevice({required this.name, required this.ip});
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
  final List<Map<String, dynamic>> _messages = [];
  final List<Map<String, dynamic>> _transferHistory = [];
  HttpServer? _httpServer;
  final Map<String, List<Map<String, dynamic>>> _deviceMessages = {};

  @override
  void initState() {
    super.initState();
    _getLocalIP();
    _startServer();
  }

  @override
  void dispose() {
    _httpServer?.close();
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _getLocalIP() async {
    try {
      final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
      for (var interface in interfaces) {
        for (var addr in interface.addresses) {
          if (addr.address.startsWith('192.168.')) {
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
          // 更新或添加设备
          final existingIndex = devices.indexWhere((d) => d.ip == ip);
          if (existingIndex >= 0) {
            devices[existingIndex].name = data['name'] ?? '手机';
            devices[existingIndex].lastSeen = DateTime.now();
          } else {
            devices.add(ConnectedDevice(
              name: data['name'] ?? '手机',
              ip: ip ?? 'unknown',
            ));
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
        // 接收消息
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
          await Clipboard.setData(ClipboardData(text: data['content']));
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
        // 拉取消息
        request.response.statusCode = 200;
        request.response.headers.set('Content-Type', 'application/json');
        request.response.write(jsonEncode({'messages': []}));
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

  Future<void> _sendClipboard() async {
    if (selectedDevice == null) return;
    
    final text = _messageController.text;
    if (text.isEmpty) return;
    
    try {
      await http.post(
        Uri.parse('http://${selectedDevice!.ip}:8765/api/send'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'type': 'clipboard', 'content': text}),
      );
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('剪贴板已发送')),
        );
      }
    } catch (e) {
      print('发送失败: $e');
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
                                  subtitle: const Text('已连接'),
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
                    if (selectedDevice != null)
                      Container(
                        padding: const EdgeInsets.all(8),
                        color: Colors.grey[50],
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            _buildFeatureButton(Icons.content_paste, '剪贴板', _sendClipboard),
                            _buildFeatureButton(Icons.screenshot_monitor, '投屏', _sendScreenshot),
                            _buildFeatureButton(Icons.attach_file, '发文件', _sendFile),
                          ],
                        ),
                      ),
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

  Widget _buildFeatureButton(IconData icon, String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.blue),
            const SizedBox(height: 4),
            Text(label, style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
