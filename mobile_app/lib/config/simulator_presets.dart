class SimulatorMockData {
  final String sender;
  final String message;
  final String songTitle;
  final String songArtist;
  final int elapsedSec;
  final int durationSec;
  final int batteryLevel;
  final bool isCharging;
  final bool isWifiConnected;
  final bool isBleConnected;

  const SimulatorMockData({
    this.sender = 'Vợ',
    this.message = 'Mua đồ ăn tối chưa anh ơi?',
    this.songTitle = 'Nơi Này Có Anh',
    this.songArtist = 'Sơn Tùng M-TP',
    this.elapsedSec = 84, // 01:24
    this.durationSec = 232, // 03:52
    this.batteryLevel = 85,
    this.isCharging = false,
    this.isWifiConnected = true,
    this.isBleConnected = true,
  });

  String get fullSongTitle => '$songTitle - $songArtist';

  String get elapsedStr {
    final m = (elapsedSec ~/ 60).toString().padLeft(2, '0');
    final s = (elapsedSec % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  String get durationStr {
    final m = (durationSec ~/ 60).toString().padLeft(2, '0');
    final s = (durationSec % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  String get timeRatioStr => '$elapsedStr / $durationStr';

  double get songProgress {
    if (durationSec <= 0) return 0.0;
    return (elapsedSec / durationSec).clamp(0.0, 1.0);
  }

  SimulatorMockData copyWith({
    String? sender,
    String? message,
    String? songTitle,
    String? songArtist,
    int? elapsedSec,
    int? durationSec,
    int? batteryLevel,
    bool? isCharging,
    bool? isWifiConnected,
    bool? isBleConnected,
  }) {
    return SimulatorMockData(
      sender: sender ?? this.sender,
      message: message ?? this.message,
      songTitle: songTitle ?? this.songTitle,
      songArtist: songArtist ?? this.songArtist,
      elapsedSec: elapsedSec ?? this.elapsedSec,
      durationSec: durationSec ?? this.durationSec,
      batteryLevel: batteryLevel ?? this.batteryLevel,
      isCharging: isCharging ?? this.isCharging,
      isWifiConnected: isWifiConnected ?? this.isWifiConnected,
      isBleConnected: isBleConnected ?? this.isBleConnected,
    );
  }

  static const SimulatorMockData defaultPreset = SimulatorMockData();
}
