import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _CreateNative = Pointer<Void> Function();
typedef _CreateDart = Pointer<Void> Function();
typedef _SendNative = Int32 Function(Pointer<Void>, Pointer<Utf8>);
typedef _SendDart = int Function(Pointer<Void>, Pointer<Utf8>);
typedef _NextNative = Pointer<Utf8> Function(Pointer<Void>);
typedef _NextDart = Pointer<Utf8> Function(Pointer<Void>);
typedef _FreeNative = Void Function(Pointer<Utf8>);
typedef _FreeDart = void Function(Pointer<Utf8>);
typedef _DestroyNative = Void Function(Pointer<Void>);
typedef _DestroyDart = void Function(Pointer<Void>);

abstract interface class CoreTransport {
  void send(String request);
  String? nextEvent();
  void dispose();
}

/// Thin transport for the shared Rust core. The core owns the serial worker;
/// calls here only enqueue requests or drain the non-blocking event queue.
class CoreApi implements CoreTransport {
  CoreApi._(DynamicLibrary library)
    : _send = library.lookupFunction<_SendNative, _SendDart>('lightbar_send'),
      _next = library.lookupFunction<_NextNative, _NextDart>(
        'lightbar_next_event',
      ),
      _free = library.lookupFunction<_FreeNative, _FreeDart>(
        'lightbar_free_string',
      ),
      _destroy = library.lookupFunction<_DestroyNative, _DestroyDart>(
        'lightbar_destroy',
      ),
      _handle = library.lookupFunction<_CreateNative, _CreateDart>(
        'lightbar_create',
      )();

  factory CoreApi.open() {
    final override = Platform.environment['LIGHTBAR_CORE_LIBRARY'];
    final executableDir = File(Platform.resolvedExecutable).parent;
    final String libraryPath;
    if (override != null && override.isNotEmpty) {
      libraryPath = override;
    } else if (Platform.isMacOS) {
      libraryPath =
          '${executableDir.parent.path}/Frameworks/liblightbar_core.dylib';
    } else if (Platform.isWindows) {
      libraryPath =
          '${executableDir.path}${Platform.pathSeparator}lightbar_core.dll';
    } else if (Platform.isLinux) {
      libraryPath = '${executableDir.path}/lib/liblightbar_core.so';
    } else {
      throw UnsupportedError('不支持当前操作系统');
    }
    final api = CoreApi._(DynamicLibrary.open(libraryPath));
    if (api._handle == nullptr) throw StateError('无法启动设备控制内核');
    return api;
  }

  final _SendDart _send;
  final _NextDart _next;
  final _FreeDart _free;
  final _DestroyDart _destroy;
  Pointer<Void> _handle;

  @override
  void send(String request) {
    if (_handle == nullptr) throw StateError('设备控制内核已关闭');
    final bytes = request.toNativeUtf8();
    try {
      final result = _send(_handle, bytes);
      if (result != 0) throw StateError('设备请求失败：$result');
    } finally {
      calloc.free(bytes);
    }
  }

  @override
  String? nextEvent() {
    if (_handle == nullptr) return null;
    final value = _next(_handle);
    if (value == nullptr) return null;
    try {
      return value.toDartString();
    } finally {
      _free(value);
    }
  }

  @override
  void dispose() {
    if (_handle != nullptr) {
      _destroy(_handle);
      _handle = nullptr;
    }
  }
}
