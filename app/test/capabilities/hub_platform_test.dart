import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omi/capabilities/hub_platform.dart';

void main() {
  test('hubIsWeb tracks kIsWeb', () {
    expect(hubIsWeb, kIsWeb);
    expect(nativeHubLinked, isNot(kIsWeb));
    if (kIsWeb) {
      expect(meetingAssistSupported, isFalse);
      expect(desktopVoiceSupported, isFalse);
    }
  });

  test('remote computer-use delegation stays available everywhere', () {
    expect(remoteComputerUseSupported, isTrue);
  });

  test('desktop chrome and pendant are mutually exclusive surfaces', () {
    if (kIsWeb) {
      expect(desktopChromeSupported, isFalse);
      expect(pendantSupported, isFalse);
      return;
    }
    final desktop = hubIsDesktop;
    final mobile = hubIsMobile;
    expect(desktop || mobile, isTrue);
    if (desktop) {
      expect(pendantSupported, isFalse);
    }
    if (mobile) {
      expect(desktopChromeSupported, isFalse);
      expect(desktopVoiceSupported, isFalse);
    }
  });
}
