part of 'signals.dart';

final assignRustSignal = <String, void Function(Uint8List, Uint8List)>{
  'NativeEvent': (Uint8List messageBytes, Uint8List binary) {
    final message = NativeEvent.bincodeDeserialize(messageBytes);
    final rustSignal = RustSignalPack(message, binary);
    _nativeEventStreamController.add(rustSignal);
    NativeEvent.latestRustSignal = rustSignal;
  },
};
