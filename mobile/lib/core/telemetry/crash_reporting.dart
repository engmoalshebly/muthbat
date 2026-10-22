import 'package:sentry_flutter/sentry_flutter.dart';
import '../config/env.dart';

/// Crash reporting is opt-in per build: without --dart-define=SENTRY_DSN it is
/// fully disabled. Ledger data (phones, names, amounts) must never leave the
/// device through it, so everything user-derived is stripped before sending.
class CrashReporting {
  CrashReporting._();

  static const String dsn = String.fromEnvironment('SENTRY_DSN');
  static const String _release = String.fromEnvironment('APP_RELEASE');

  static bool get enabled => dsn.isNotEmpty;

  static final RegExp _digits = RegExp(r'\+?\d[\d\s\-]{6,}\d');

  static String scrub(String text) => text.replaceAll(_digits, '[number]');

  static void configure(SentryFlutterOptions options) {
    options
      ..dsn = dsn
      ..environment = EnvConfig.env.name
      ..release = _release.isEmpty ? null : _release
      ..sendDefaultPii = false
      ..attachScreenshot = false
      ..attachViewHierarchy = false
      ..tracesSampleRate = 0
      ..beforeBreadcrumb = _beforeBreadcrumb
      ..beforeSend = _beforeSend;
  }

  static Breadcrumb? _beforeBreadcrumb(Breadcrumb? crumb, Hint hint) {
    if (crumb == null) return null;
    const dropped = {
      'http',
      'xhr',
      'ui.click',
      'navigation',
      'user.interaction',
    };
    if (dropped.contains(crumb.category) || dropped.contains(crumb.type)) {
      return null;
    }
    return crumb.copyWith(
      message: crumb.message == null ? null : scrub(crumb.message!),
      data: null,
    );
  }

  static SentryEvent? _beforeSend(SentryEvent event, Hint hint) {
    return event.copyWith(
      user: null,
      request: null,
      serverName: null,
      message: event.message == null
          ? null
          : SentryMessage(scrub(event.message!.formatted)),
      exceptions: event.exceptions
          ?.map(
            (e) => e.copyWith(value: e.value == null ? null : scrub(e.value!)),
          )
          .toList(),
    );
  }
}
