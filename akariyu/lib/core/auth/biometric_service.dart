import 'dart:io';

import 'package:flutter/services.dart' show PlatformException;
import 'package:local_auth/local_auth.dart';

/// Wraps [LocalAuthentication] for biometric/device-PIN unlock. Used to gate
/// app launch and (later) sensitive actions like exporting a key.
class BiometricService {
  BiometricService({LocalAuthentication? auth})
      : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  /// `true` if the device exposes any biometric or device-PIN authenticator.
  /// Falls back to `false` if the platform throws (e.g. desktop test runner).
  Future<bool> isAvailable() async {
    try {
      final supported = await _auth.isDeviceSupported();
      if (!supported) return false;
      final canCheck = await _auth.canCheckBiometrics;
      return canCheck || supported;
    } catch (_) {
      return false;
    }
  }

  /// Prompt the user to authenticate. Returns `true` on success.
  ///
  /// On unsupported platforms (no biometric / no device PIN), returns `true`
  /// so we don't lock the user out of their own app.
  Future<bool> authenticate({
    String reason = 'Unlock akariyu',
  }) async {
    if (!await isAvailable()) return true;
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        options: const AuthenticationOptions(
          biometricOnly: false,
          stickyAuth: true,
          useErrorDialogs: true,
        ),
      );
    } on PlatformException {
      return false;
    } catch (_) {
      return false;
    }
  }
}

/// True on platforms where biometric APIs are meaningfully available.
bool get biometricCapablePlatform => Platform.isIOS || Platform.isAndroid;
