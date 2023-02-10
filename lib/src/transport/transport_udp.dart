part of 'transport.dart';

class TransportUdp extends TransportBase {
  static const defaultPort = 2022;

  RawDatagramSocket? _socket;

  TransportUdp({required super.bindAddress, super.onMessage, super.ttl});

  @override
  Future<void> start() async {
    if (_socket != null) return;
    _socket = await RawDatagramSocket.bind(
      bindAddress.address,
      bindAddress.port,
      ttl: ttl,
    );
    _socket!.listen(
      (event) async {
        if (event != RawSocketEvent.read) return;
        final datagram = _socket?.receive();
        if (datagram == null || datagram.data.length < PacketHeader.length) {
          return;
        }
        try {
          await onMessage!(Packet(
            srcFullAddress: FullAddress(
              address: datagram.address,
              isLocal: bindAddress.isLocal,
              port: datagram.port,
            ),
            header: PacketHeader.fromBytes(datagram.data),
            datagram: datagram.data,
          ));
        } on StopProcessing catch (_) {
        } catch (e) {
          logger?.call(e.toString());
        }
      },
    );
  }

  @override
  void stop() {
    _socket?.close();
    _socket = null;
  }

  @override
  void send(
    final Iterable<FullAddress> fullAddresses,
    final Uint8List datagram,
  ) {
    if (_socket == null) return;
    for (final peerFullAddress in fullAddresses) {
      if (peerFullAddress.type == bindAddress.type) {
        _socket!.send(datagram, peerFullAddress.address, peerFullAddress.port);
      }
    }
  }
}