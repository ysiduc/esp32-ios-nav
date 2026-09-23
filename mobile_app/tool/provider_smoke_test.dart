import 'dart:io';

Future<void> main(List<String> args) async {
  final flutterBin = Platform.environment['FLUTTER_ROOT'] != null
      ? '${Platform.environment['FLUTTER_ROOT']}/bin/flutter'
      : 'flutter';

  final process = await Process.start(
    flutterBin,
    ['test', 'tool/live_provider_smoke_test.dart'],
    mode: ProcessStartMode.inheritStdio,
  );

  final exitCode = await process.exitCode;
  exit(exitCode);
}
