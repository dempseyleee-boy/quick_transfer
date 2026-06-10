class TransferQueue {
  final Map<String, List<Map<String, dynamic>>> _messagesByDevice = {};

  void enqueue(String deviceIp, Map<String, dynamic> message) {
    _messagesByDevice.putIfAbsent(deviceIp, () => []).add(message);
  }

  List<Map<String, dynamic>> drain(String deviceIp) {
    final messages = _messagesByDevice.remove(deviceIp);
    if (messages == null) return [];
    return List<Map<String, dynamic>>.from(messages);
  }
}
