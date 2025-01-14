import 'dart:io';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:sodium/sodium.dart';

import '/src/data/data.dart';

void cryptoWorker(final CryptoTask initialTask) async {
  final sodium = await SodiumInit.init(_loadSodium());
  final box = sodium.crypto.box;
  final sign = sodium.crypto.sign;
  final cryptoKeys = initialTask.extra == null
      ? CryptoKeys.empty()
      : initialTask.extra as CryptoKeys;

  if (cryptoKeys.seed.isEmpty) {
    cryptoKeys.seed = sodium.randombytes.buf(sodium.randombytes.seedBytes);
  }
  late final KeyPair encKeyPair, signKeyPair;

  // use given encryption key pair or create it from given or generated seed
  if (cryptoKeys.encPrivateKey.isEmpty || cryptoKeys.encPublicKey.isEmpty) {
    encKeyPair = box.seedKeyPair(
      SecureKey.fromList(sodium, cryptoKeys.seed),
    );
    cryptoKeys.encPublicKey = encKeyPair.publicKey;
    cryptoKeys.encPrivateKey = encKeyPair.secretKey.extractBytes();
  } else {
    encKeyPair = KeyPair(
      secretKey: SecureKey.fromList(sodium, cryptoKeys.encPrivateKey),
      publicKey: cryptoKeys.encPublicKey,
    );
  }
  // use given sign key pair or create it from given or generated seed
  if (cryptoKeys.signPrivateKey.isEmpty || cryptoKeys.signPublicKey.isEmpty) {
    signKeyPair = sign.seedKeyPair(
      SecureKey.fromList(sodium, cryptoKeys.seed),
    );
    cryptoKeys.signPublicKey = signKeyPair.publicKey;
    cryptoKeys.signPrivateKey = signKeyPair.secretKey.extractBytes();
  } else {
    signKeyPair = KeyPair(
      secretKey: SecureKey.fromList(sodium, cryptoKeys.signPrivateKey),
      publicKey: cryptoKeys.signPublicKey,
    );
  }

  // send back SendPort and keys
  final receivePort = ReceivePort();
  final mainIsolatePort = initialTask.payload as SendPort;
  initialTask.payload = receivePort.sendPort;
  initialTask.extra = cryptoKeys;
  mainIsolatePort.send(initialTask);

  receivePort.listen(
    (final task) {
      if (task is! CryptoTask) return;
      try {
        switch (task.type) {
          case CryptoTaskType.seal:
            final message = task.payload as Message;
            if (message.isNotEmpty) {
              message.payload = box.seal(
                publicKey: message.dstPeerId.encPublicKey,
                message: message.payload!,
              );
            }
            final datagram = message.toBytes();
            final signedDatagram = BytesBuilder(copy: false)
              ..add(datagram)
              ..add(sign.detached(
                message: datagram,
                secretKey: signKeyPair.secretKey,
              ));
            task.payload = signedDatagram.toBytes();
            break;

          case CryptoTaskType.unseal:
            final datagram = task.payload as Uint8List;
            if (!sign.verifyDetached(
              message: Message.getUnsignedDatagram(datagram),
              signature: Message.getSignature(datagram),
              publicKey: Message.getSrcPeerId(datagram).signPiblicKey,
            )) {
              task.payload = const ExceptionInvalidSignature();
              break;
            }
            if (Message.hasEmptyPayload(datagram)) {
              task.payload = emptyUint8List;
            } else {
              task.payload = box.sealOpen(
                cipherText: Message.getPayload(datagram),
                publicKey: encKeyPair.publicKey,
                secretKey: encKeyPair.secretKey,
              );
            }
            break;

          case CryptoTaskType.sign:
            task.payload = sign.detached(
              message: task.payload as Uint8List,
              secretKey: signKeyPair.secretKey,
            );
            break;

          case CryptoTaskType.verifySigned:
            final data = task.payload as Uint8List;
            final messageLength = data.length - signatureLength;
            task.payload = sign.verifyDetached(
              message: data.sublist(0, messageLength),
              signature: data.sublist(messageLength),
              publicKey: task.extra as Uint8List,
            );
            break;
        }
      } catch (e) {
        task.payload = e;
      } finally {
        mainIsolatePort.send(task);
      }
    },
    onDone: () {
      encKeyPair.secretKey.dispose();
      signKeyPair.secretKey.dispose();
    },
  );
}

DynamicLibrary _loadSodium() {
  if (Platform.isIOS) return DynamicLibrary.process();
  if (Platform.isAndroid) return DynamicLibrary.open('libsodium.so');
  if (Platform.isLinux) return DynamicLibrary.open('libsodium.so.23');
  if (Platform.isMacOS) {
    return DynamicLibrary.open('/usr/local/lib/libsodium.dylib');
  }
  if (Platform.isWindows) {
    return DynamicLibrary.open('C:\\Windows\\System32\\libsodium.dll');
  }
  throw OSError('[Crypto] Platform not supported');
}
