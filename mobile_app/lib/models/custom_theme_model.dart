import 'package:flutter/material.dart';

/// Decorative rounded/square rectangle drawn on 240x240 theme canvas.
class CustomThemeBox {
  final double x;
  final double y;
  final double w;
  final double h;
  final double r;
  final String? fill;
  final String? border;

  const CustomThemeBox({
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    this.r = 8,
    this.fill,
    this.border,
  });

  factory CustomThemeBox.fromJson(Map<String, dynamic> json) {
    return CustomThemeBox(
      x: (json['x'] as num?)?.toDouble() ?? 0,
      y: (json['y'] as num?)?.toDouble() ?? 0,
      w: (json['w'] as num?)?.toDouble() ?? 0,
      h: (json['h'] as num?)?.toDouble() ?? 0,
      r: (json['r'] as num?)?.toDouble() ?? 0,
      fill: json['fill']?.toString(),
      border: json['border']?.toString(),
    );
  }

  Map<String, dynamic> toJson() => {
        'x': x.round(),
        'y': y.round(),
        'w': w.round(),
        'h': h.round(),
        'r': r.round(),
        if (fill != null && fill!.isNotEmpty) 'fill': fill,
        if (border != null && border!.isNotEmpty) 'border': border,
      };

  Map<String, dynamic> toEsp32Json() => {
        'x': x.round(),
        'y': y.round(),
        'w': w.round(),
        'h': h.round(),
        'r': r.round(),
        if (fill != null && fill!.isNotEmpty)
          'fill': CustomThemeSpec.toHex6(fill, fallback: '#0B111A'),
        if (border != null && border!.isNotEmpty)
          'border': CustomThemeSpec.toHex6(border, fallback: '#FFFFFF'),
      };
}

/// Static text label placed on 240x240 theme canvas.
class CustomThemeLabel {
  final String text;
  final double x;
  final double y;
  final double maxW;
  final double fontSize;
  final String color;
  final bool center;
  final bool visible;

  const CustomThemeLabel({
    required this.text,
    this.x = 0,
    this.y = 0,
    this.maxW = 140,
    this.fontSize = 11,
    this.color = '#FFFFFF',
    this.center = false,
    this.visible = true,
  });

  factory CustomThemeLabel.fromJson(Map<String, dynamic> json) {
    return CustomThemeLabel(
      text: json['text']?.toString() ?? '',
      x: (json['x'] as num?)?.toDouble() ?? 0,
      y: (json['y'] as num?)?.toDouble() ?? 0,
      maxW: (json['maxW'] as num?)?.toDouble() ?? 140,
      fontSize: (json['fontSize'] as num?)?.toDouble() ?? 11,
      color: json['color']?.toString() ?? '#FFFFFF',
      center: json['center'] == true,
      visible: json['visible'] != false,
    );
  }

  Map<String, dynamic> toJson() => {
        'text': text,
        'x': x.round(),
        'y': y.round(),
        'maxW': maxW.round(),
        'fontSize': fontSize.round(),
        'color': color,
        'center': center,
        'visible': visible,
      };

  Map<String, dynamic> toEsp32Json() => {
        'text': text,
        'x': x.round(),
        'y': y.round(),
        'maxW': maxW.round(),
        'color': CustomThemeSpec.toHex6(color, fallback: '#FFFFFF'),
        'center': center,
        'visible': visible,
      };
}

class CustomThemeClockSpec {
  final bool visible;
  final double x;
  final double y;
  final double fontSize;
  final String font;
  final String color;
  final bool center;

  const CustomThemeClockSpec({
    this.visible = true,
    this.x = 20,
    this.y = 24,
    this.fontSize = 42,
    this.font = 'sans',
    this.color = '#FACC15',
    this.center = false,
  });

  factory CustomThemeClockSpec.fromJson(Map<String, dynamic> json) {
    return CustomThemeClockSpec(
      visible: json['visible'] != false,
      x: (json['x'] as num?)?.toDouble() ?? 20,
      y: (json['y'] as num?)?.toDouble() ?? 24,
      fontSize: (json['fontSize'] as num?)?.toDouble() ?? 42,
      font: json['font']?.toString() ?? 'sans',
      color: json['color']?.toString() ?? '#FACC15',
      center: json['center'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
        'visible': visible,
        'x': x.round(),
        'y': y.round(),
        'fontSize': fontSize.round(),
        'font': font,
        'color': color,
        'center': center,
      };

  Map<String, dynamic> toEsp32Json() => {
        'visible': visible,
        'x': x.round(),
        'y': y.round(),
        'fontSize': fontSize.round(),
        'font': font,
        'color': CustomThemeSpec.toHex6(color, fallback: '#FACC15'),
        'center': center,
      };
}

class CustomThemeDateSpec {
  final bool visible;
  final double x;
  final double y;
  final double fontSize;
  final String color;
  final String format; // vn_short | en_upper | dmy_dot | dmy_slash
  final bool center;

  const CustomThemeDateSpec({
    this.visible = true,
    this.x = 22,
    this.y = 74,
    this.fontSize = 11,
    this.color = '#FFFFFF',
    this.format = 'vn_short',
    this.center = false,
  });

  factory CustomThemeDateSpec.fromJson(Map<String, dynamic> json) {
    return CustomThemeDateSpec(
      visible: json['visible'] != false,
      x: (json['x'] as num?)?.toDouble() ?? 22,
      y: (json['y'] as num?)?.toDouble() ?? 74,
      fontSize: (json['fontSize'] as num?)?.toDouble() ?? 11,
      color: json['color']?.toString() ?? '#FFFFFF',
      format: json['format']?.toString() ?? 'vn_short',
      center: json['center'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
        'visible': visible,
        'x': x.round(),
        'y': y.round(),
        'fontSize': fontSize.round(),
        'color': color,
        'format': format,
        'center': center,
      };

  Map<String, dynamic> toEsp32Json() => {
        'visible': visible,
        'x': x.round(),
        'y': y.round(),
        'color': CustomThemeSpec.toHex6(color, fallback: '#FFFFFF'),
        'format': format,
        'center': center,
      };
}

class CustomThemeSongSpec {
  final bool visible;
  final double x;
  final double y;
  final double w;
  final double fontSize;
  final String color;
  final String bgColor;
  final double? boxX;
  final double? boxY;
  final double? boxW;
  final double? boxH;
  final String? border;
  final String? durColor;

  const CustomThemeSongSpec({
    this.visible = true,
    this.x = 20,
    this.y = 198,
    this.w = 196,
    this.fontSize = 11,
    this.color = '#FEF08A',
    this.bgColor = '#0B111A',
    this.boxX,
    this.boxY,
    this.boxW,
    this.boxH,
    this.border,
    this.durColor,
  });

  factory CustomThemeSongSpec.fromJson(Map<String, dynamic> json) {
    return CustomThemeSongSpec(
      visible: json['visible'] != false,
      x: (json['x'] as num?)?.toDouble() ?? 20,
      y: (json['y'] as num?)?.toDouble() ?? 198,
      w: (json['w'] as num?)?.toDouble() ?? 196,
      fontSize: (json['fontSize'] as num?)?.toDouble() ?? 11,
      color: json['color']?.toString() ?? '#FEF08A',
      bgColor: json['bgColor']?.toString() ?? '#0B111A',
      boxX: (json['boxX'] as num?)?.toDouble(),
      boxY: (json['boxY'] as num?)?.toDouble(),
      boxW: (json['boxW'] as num?)?.toDouble(),
      boxH: (json['boxH'] as num?)?.toDouble(),
      border: json['border']?.toString(),
      durColor: json['durColor']?.toString(),
    );
  }

  CustomThemeSongSpec copyWith({String? bgColor}) {
    return CustomThemeSongSpec(
      visible: visible,
      x: x,
      y: y,
      w: w,
      fontSize: fontSize,
      color: color,
      bgColor: bgColor ?? this.bgColor,
      boxX: boxX,
      boxY: boxY,
      boxW: boxW,
      boxH: boxH,
      border: border,
      durColor: durColor,
    );
  }

  Map<String, dynamic> toJson() => {
        'visible': visible,
        'x': x.round(),
        'y': y.round(),
        'w': w.round(),
        'fontSize': fontSize.round(),
        'color': color,
        'bgColor': bgColor,
        if (boxX != null) 'boxX': boxX!.round(),
        if (boxY != null) 'boxY': boxY!.round(),
        if (boxW != null) 'boxW': boxW!.round(),
        if (boxH != null) 'boxH': boxH!.round(),
        if (border != null && border!.isNotEmpty) 'border': border,
        if (durColor != null && durColor!.isNotEmpty) 'durColor': durColor,
      };

  Map<String, dynamic> toEsp32Json() => {
        'visible': visible,
        'x': x.round(),
        'y': y.round(),
        'w': w.round(),
        'color': CustomThemeSpec.toHex6(color, fallback: '#FEF08A'),
        'bgColor': CustomThemeSpec.toHex6(bgColor, fallback: '#0B111A'),
      };

  /// Compact Màn 2 song box specification uploaded inside /custom_man2.json.
  Map<String, dynamic> toEsp32Man2Json({double fallbackCardX = 122, double fallbackCardW = 114}) {
    final effX = (boxX ?? fallbackCardX).round();
    final effY = (boxY ?? 184).round();
    final effW = (boxW ?? fallbackCardW).round();
    final effH = (boxH ?? 50).round();
    return {
      'visible': visible,
      'boxX': effX,
      'boxY': effY,
      'boxW': effW,
      'boxH': effH,
      'bgColor': CustomThemeSpec.toHex6(bgColor, fallback: '#0B111A'),
      'border': CustomThemeSpec.toHex6(border, fallback: '#1E293B'),
      'color': CustomThemeSpec.toHex6(color, fallback: '#FACC15'),
      'durColor': CustomThemeSpec.toHex6(durColor, fallback: '#38BDF8'),
    };
  }
}

class CustomThemeDurationSpec {
  final bool visible;
  final String mode; // split | ratio | elapsed
  final double x;
  final double y;
  final double fontSize;
  final String color;
  final String secondaryColor;

  const CustomThemeDurationSpec({
    this.visible = true,
    this.mode = 'ratio',
    this.x = 228,
    this.y = 198,
    this.fontSize = 10,
    this.color = '#FB923C',
    this.secondaryColor = '#FFFFFF',
  });

  factory CustomThemeDurationSpec.fromJson(Map<String, dynamic> json) {
    return CustomThemeDurationSpec(
      visible: json['visible'] != false,
      mode: json['mode']?.toString() ?? 'ratio',
      x: (json['x'] as num?)?.toDouble() ?? 228,
      y: (json['y'] as num?)?.toDouble() ?? 198,
      fontSize: (json['fontSize'] as num?)?.toDouble() ?? 10,
      color: json['color']?.toString() ?? '#FB923C',
      secondaryColor: json['secondaryColor']?.toString() ?? '#FFFFFF',
    );
  }

  Map<String, dynamic> toJson() => {
        'visible': visible,
        'mode': mode,
        'x': x.round(),
        'y': y.round(),
        'fontSize': fontSize.round(),
        'color': color,
        'secondaryColor': secondaryColor,
      };

  Map<String, dynamic> toEsp32Json() => {
        'visible': visible,
        'mode': mode,
        'x': x.round(),
        'y': y.round(),
        'color': CustomThemeSpec.toHex6(color, fallback: '#FB923C'),
        'secondaryColor':
            CustomThemeSpec.toHex6(secondaryColor, fallback: '#FFFFFF'),
      };
}

class CustomThemeNotifTitleSpec {
  final bool visible;
  final double x;
  final double y;
  final double maxW;
  final double fontSize;
  final String color;

  const CustomThemeNotifTitleSpec({
    this.visible = true,
    this.x = 180,
    this.y = 44,
    this.maxW = 120,
    this.fontSize = 11,
    this.color = '#FACC15',
  });

  factory CustomThemeNotifTitleSpec.fromJson(Map<String, dynamic> json) {
    return CustomThemeNotifTitleSpec(
      visible: json['visible'] != false,
      x: (json['x'] as num?)?.toDouble() ?? 180,
      y: (json['y'] as num?)?.toDouble() ?? 44,
      maxW: (json['maxW'] as num?)?.toDouble() ?? 120,
      fontSize: (json['fontSize'] as num?)?.toDouble() ?? 11,
      color: json['color']?.toString() ?? '#FACC15',
    );
  }

  Map<String, dynamic> toJson() => {
        'visible': visible,
        'x': x.round(),
        'y': y.round(),
        'maxW': maxW.round(),
        'fontSize': fontSize.round(),
        'color': color,
      };

  Map<String, dynamic> toEsp32Json() => {
        'visible': visible,
        'x': x.round(),
        'y': y.round(),
        'maxW': maxW.round(),
        'color': CustomThemeSpec.toHex6(color, fallback: '#FACC15'),
      };
}

class CustomThemeNotifMsgSpec {
  final bool visible;
  final double x;
  final double y;
  final double maxW;
  final int maxLines;
  final double lineHeight;
  final double fontSize;
  final String color;

  const CustomThemeNotifMsgSpec({
    this.visible = true,
    this.x = 180,
    this.y = 64,
    this.maxW = 120,
    this.maxLines = 4,
    this.lineHeight = 15,
    this.fontSize = 10,
    this.color = '#FFFFFF',
  });

  factory CustomThemeNotifMsgSpec.fromJson(Map<String, dynamic> json) {
    return CustomThemeNotifMsgSpec(
      visible: json['visible'] != false,
      x: (json['x'] as num?)?.toDouble() ?? 180,
      y: (json['y'] as num?)?.toDouble() ?? 64,
      maxW: (json['maxW'] as num?)?.toDouble() ?? 120,
      maxLines: (json['maxLines'] as num?)?.toInt() ?? 4,
      lineHeight: (json['lineHeight'] as num?)?.toDouble() ?? 15,
      fontSize: (json['fontSize'] as num?)?.toDouble() ?? 10,
      color: json['color']?.toString() ?? '#FFFFFF',
    );
  }

  Map<String, dynamic> toJson() => {
        'visible': visible,
        'x': x.round(),
        'y': y.round(),
        'maxW': maxW.round(),
        'maxLines': maxLines,
        'lineHeight': lineHeight.round(),
        'fontSize': fontSize.round(),
        'color': color,
      };

  Map<String, dynamic> toEsp32Json() => {
        'visible': visible,
        'x': x.round(),
        'y': y.round(),
        'maxW': maxW.round(),
        'maxLines': maxLines.clamp(1, 8),
        'lineHeight': lineHeight.round().clamp(12, 24),
        'color': CustomThemeSpec.toHex6(color, fallback: '#FFFFFF'),
      };
}

/// Minimap placement & frame specification for Màn 2 (240x240 canvas).
class CustomMan2MinimapSpec {
  final double x;
  final double y;
  final double w;
  final double h;
  final double r;
  final String border;

  const CustomMan2MinimapSpec({
    this.x = 4,
    this.y = 8,
    this.w = 112,
    this.h = 224,
    this.r = 10,
    this.border = '#38BDF8',
  });

  factory CustomMan2MinimapSpec.fromJson(Map<String, dynamic> json) {
    return CustomMan2MinimapSpec(
      x: (json['x'] as num?)?.toDouble() ?? 4,
      y: (json['y'] as num?)?.toDouble() ?? 8,
      w: ((json['w'] as num?)?.toDouble() ?? 112).clamp(60.0, 112.0),
      h: ((json['h'] as num?)?.toDouble() ?? 224).clamp(60.0, 224.0),
      r: (json['r'] as num?)?.toDouble() ?? 10,
      border: json['border']?.toString() ?? '#38BDF8',
    );
  }

  Map<String, dynamic> toJson() => {
        'x': x.round(),
        'y': y.round(),
        'w': w.round(),
        'h': h.round(),
        'r': r.round(),
        'border': border,
      };

  Map<String, dynamic> toEsp32Json() => {
        'x': x.round(),
        'y': y.round(),
        'w': w.round().clamp(60, 112),
        'h': h.round().clamp(60, 224),
        'r': r.round(),
        'border': CustomThemeSpec.toHex6(border, fallback: '#38BDF8'),
      };
}

/// Notification card placement & colors for Màn 2 (240x240 canvas).
class CustomMan2NotifSpec {
  final bool visible;
  final double x;
  final double y;
  final double w;
  final double h;
  final double r;
  final String fill;
  final String border;
  final String titleColor;
  final String msgColor;

  const CustomMan2NotifSpec({
    this.visible = true,
    this.x = 122,
    this.y = 88,
    this.w = 114,
    this.h = 90,
    this.r = 10,
    this.fill = '#0B111A',
    this.border = '#1E293B',
    this.titleColor = '#FACC15',
    this.msgColor = '#FFFFFF',
  });

  factory CustomMan2NotifSpec.fromJson(Map<String, dynamic> json) {
    return CustomMan2NotifSpec(
      visible: json['visible'] != false,
      x: (json['x'] as num?)?.toDouble() ?? 122,
      y: (json['y'] as num?)?.toDouble() ?? 88,
      w: ((json['w'] as num?)?.toDouble() ?? 114).clamp(80.0, 120.0),
      h: ((json['h'] as num?)?.toDouble() ?? 90).clamp(60.0, 120.0),
      r: (json['r'] as num?)?.toDouble() ?? 10,
      fill: json['fill']?.toString() ?? '#0B111A',
      border: json['border']?.toString() ?? '#1E293B',
      titleColor: json['titleColor']?.toString() ?? '#FACC15',
      msgColor: json['msgColor']?.toString() ?? '#FFFFFF',
    );
  }

  Map<String, dynamic> toJson() => {
        'visible': visible,
        'x': x.round(),
        'y': y.round(),
        'w': w.round(),
        'h': h.round(),
        'r': r.round(),
        'fill': fill,
        'border': border,
        'titleColor': titleColor,
        'msgColor': msgColor,
      };

  Map<String, dynamic> toEsp32Json() => {
        'visible': visible,
        'x': x.round(),
        'y': y.round(),
        'w': w.round().clamp(80, 120),
        'h': h.round().clamp(60, 120),
        'fill': CustomThemeSpec.toHex6(fill, fallback: '#0B111A'),
        'border': CustomThemeSpec.toHex6(border, fallback: '#1E293B'),
        'titleColor': CustomThemeSpec.toHex6(titleColor, fallback: '#FACC15'),
        'msgColor': CustomThemeSpec.toHex6(msgColor, fallback: '#FFFFFF'),
      };
}

/// Complete declarative theme layout (240x240) rendered identically on Flutter & ESP32.
class CustomThemeSpec {
  final int targetScreen; // 1 = Màn chờ (theme 250), 2 = Màn bản đồ chờ (style 250)
  final String name;
  final String subtitle;
  final String accentColor;
  final String bgColor;
  final bool showWaybar;
  final bool showPanel;
  final CustomThemeBox? panel;
  final CustomMan2MinimapSpec minimap;
  final CustomMan2NotifSpec notif;
  final List<CustomThemeBox> boxes;
  final List<CustomThemeLabel> labels;
  final CustomThemeClockSpec clock;
  final CustomThemeDateSpec date;
  final CustomThemeSongSpec song;
  final CustomThemeDurationSpec duration;
  final CustomThemeNotifTitleSpec notifTitle;
  final CustomThemeNotifMsgSpec notifMsg;

  const CustomThemeSpec({
    this.targetScreen = 1,
    required this.name,
    this.subtitle = 'Theme ZIP tùy chỉnh',
    this.accentColor = '#00E5FF',
    this.bgColor = '#0B111A',
    this.showWaybar = false,
    this.showPanel = true,
    this.panel,
    this.minimap = const CustomMan2MinimapSpec(),
    this.notif = const CustomMan2NotifSpec(),
    this.boxes = const [],
    this.labels = const [],
    this.clock = const CustomThemeClockSpec(),
    this.date = const CustomThemeDateSpec(),
    this.song = const CustomThemeSongSpec(),
    this.duration = const CustomThemeDurationSpec(),
    this.notifTitle = const CustomThemeNotifTitleSpec(),
    this.notifMsg = const CustomThemeNotifMsgSpec(),
  });

  factory CustomThemeSpec.fromJson(
    Map<String, dynamic> json, {
    String fallbackName = 'Theme tùy chỉnh',
    int defaultTargetScreen = 1,
  }) {
    final rawBoxes = (json['boxes'] as List?) ?? const [];
    final rawLabels = (json['labels'] as List?) ?? const [];
    final explicitScreen = (json['screen'] as num?)?.toInt();
    final inferredScreen = explicitScreen == 2 || explicitScreen == 1
        ? explicitScreen!
        : (json['minimap'] is Map ? 2 : defaultTargetScreen);

    return CustomThemeSpec(
      targetScreen: inferredScreen,
      name: (json['name']?.toString().trim().isNotEmpty == true)
          ? json['name'].toString().trim()
          : fallbackName,
      subtitle: (json['subtitle']?.toString().trim().isNotEmpty == true)
          ? json['subtitle'].toString().trim()
          : 'Ảnh nền + mã theme ZIP',
      accentColor: json['accentColor']?.toString() ?? '#00E5FF',
      bgColor: json['bgColor']?.toString() ?? '#0B111A',
      showWaybar: json['showWaybar'] == true,
      showPanel: json['showPanel'] != false,
      panel: json['panel'] is Map
          ? CustomThemeBox.fromJson(Map<String, dynamic>.from(json['panel']))
          : null,
      minimap: json['minimap'] is Map
          ? CustomMan2MinimapSpec.fromJson(
              Map<String, dynamic>.from(json['minimap']))
          : const CustomMan2MinimapSpec(),
      notif: json['notif'] is Map
          ? CustomMan2NotifSpec.fromJson(
              Map<String, dynamic>.from(json['notif']))
          : const CustomMan2NotifSpec(),
      boxes: rawBoxes
          .whereType<Map>()
          .map((m) => CustomThemeBox.fromJson(Map<String, dynamic>.from(m)))
          .toList(),
      labels: rawLabels
          .whereType<Map>()
          .map((m) => CustomThemeLabel.fromJson(Map<String, dynamic>.from(m)))
          .toList(),
      clock: json['clock'] is Map
          ? CustomThemeClockSpec.fromJson(
              Map<String, dynamic>.from(json['clock']))
          : const CustomThemeClockSpec(),
      date: json['date'] is Map
          ? CustomThemeDateSpec.fromJson(
              Map<String, dynamic>.from(json['date']))
          : const CustomThemeDateSpec(),
      song: json['song'] is Map
          ? CustomThemeSongSpec.fromJson(
              Map<String, dynamic>.from(json['song']))
          : const CustomThemeSongSpec(),
      duration: json['duration'] is Map
          ? CustomThemeDurationSpec.fromJson(
              Map<String, dynamic>.from(json['duration']))
          : const CustomThemeDurationSpec(),
      notifTitle: json['notifTitle'] is Map
          ? CustomThemeNotifTitleSpec.fromJson(
              Map<String, dynamic>.from(json['notifTitle']))
          : const CustomThemeNotifTitleSpec(),
      notifMsg: json['notifMsg'] is Map
          ? CustomThemeNotifMsgSpec.fromJson(
              Map<String, dynamic>.from(json['notifMsg']))
          : const CustomThemeNotifMsgSpec(),
    );
  }

  CustomThemeSpec copyWith({
    int? targetScreen,
    CustomThemeSongSpec? song,
  }) {
    return CustomThemeSpec(
      targetScreen: targetScreen ?? this.targetScreen,
      name: name,
      subtitle: subtitle,
      accentColor: accentColor,
      bgColor: bgColor,
      showWaybar: showWaybar,
      showPanel: showPanel,
      panel: panel,
      minimap: minimap,
      notif: notif,
      boxes: boxes,
      labels: labels,
      clock: clock,
      date: date,
      song: song ?? this.song,
      duration: duration,
      notifTitle: notifTitle,
      notifMsg: notifMsg,
    );
  }

  Map<String, dynamic> toJson() => {
        'screen': targetScreen,
        'name': name,
        'subtitle': subtitle,
        'accentColor': accentColor,
        'bgColor': bgColor,
        'showWaybar': showWaybar,
        'showPanel': showPanel,
        if (panel != null) 'panel': panel!.toJson(),
        if (targetScreen == 2) 'minimap': minimap.toJson(),
        if (targetScreen == 2) 'notif': notif.toJson(),
        'boxes': boxes.map((b) => b.toJson()).toList(),
        'labels': labels.map((l) => l.toJson()).toList(),
        'clock': clock.toJson(),
        'date': date.toJson(),
        'song': song.toJson(),
        'duration': duration.toJson(),
        'notifTitle': notifTitle.toJson(),
        'notifMsg': notifMsg.toJson(),
      };

  /// Compact 240x240 layout payload uploaded to ESP32 SPIFFS (/custom_theme.json) for Màn 1.
  Map<String, dynamic> toEsp32CompactJson() => {
        'bgColor': toHex6(bgColor, fallback: '#0B111A'),
        'showWaybar': showWaybar,
        'boxes': boxes.take(6).map((b) => b.toEsp32Json()).toList(),
        'labels': labels.take(6).map((l) => l.toEsp32Json()).toList(),
        'clock': clock.toEsp32Json(),
        'date': date.toEsp32Json(),
        'song': song.toEsp32Json(),
        'duration': duration.toEsp32Json(),
        'notifTitle': notifTitle.toEsp32Json(),
        'notifMsg': notifMsg.toEsp32Json(),
      };

  /// Compact 240x240 layout payload uploaded to ESP32 SPIFFS (/custom_man2.json) for Màn 2.
  Map<String, dynamic> toEsp32Man2CompactJson() {
    final effectivePanel = panel ??
        const CustomThemeBox(
          x: 122,
          y: 6,
          w: 114,
          h: 228,
          r: 12,
          fill: '#131B26',
          border: '#202D3D',
        );
    return {
      'bgColor': toHex6(bgColor, fallback: '#0B111A'),
      'showPanel': showPanel,
      'panel': effectivePanel.toEsp32Json(),
      'minimap': minimap.toEsp32Json(),
      'clock': clock.toEsp32Json(),
      'date': date.toEsp32Json(),
      'song': song.toEsp32Man2Json(
        fallbackCardX: effectivePanel.x,
        fallbackCardW: effectivePanel.w,
      ),
      'notif': notif.toEsp32Json(),
    };
  }

  static Color parseColor(String? raw, Color fallback) {
    if (raw == null || raw.isEmpty) return fallback;
    var s = raw.trim();
    if (s.startsWith('#')) {
      s = s.substring(1);
    } else if (s.toLowerCase().startsWith('0x')) {
      s = s.substring(2);
    }
    if (s.length == 6) {
      s = 'FF$s';
    }
    if (s.length != 8) return fallback;
    final val = int.tryParse(s, radix: 16);
    if (val == null) return fallback;
    return Color(val);
  }

  static String toHex6(String? raw, {String fallback = '#FFFFFF'}) {
    final c = parseColor(raw, parseColor(fallback, Colors.white));
    final rgb = c.toARGB32() & 0x00FFFFFF;
    return '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
  }
}

/// Persisted custom theme imported from a user's ZIP archive.
class ImportedCustomTheme {
  final String id;
  final String name;
  final String subtitle;
  final String accentHex;
  final String bgImagePath;
  final String espBgImagePath;
  final String sourceSummary;
  final DateTime createdAt;
  final CustomThemeSpec spec;

  const ImportedCustomTheme({
    required this.id,
    required this.name,
    required this.subtitle,
    required this.accentHex,
    required this.bgImagePath,
    required this.espBgImagePath,
    required this.sourceSummary,
    required this.createdAt,
    required this.spec,
  });

  int get targetScreen => spec.targetScreen;

  Color get accentColor =>
      CustomThemeSpec.parseColor(accentHex, const Color(0xFF00E5FF));

  factory ImportedCustomTheme.fromJson(Map<String, dynamic> json) {
    final name = json['name']?.toString() ?? 'Theme tùy chỉnh';
    return ImportedCustomTheme(
      id: json['id']?.toString() ?? '',
      name: name,
      subtitle: json['subtitle']?.toString() ?? 'Theme ZIP',
      accentHex: json['accentHex']?.toString() ?? '#00E5FF',
      bgImagePath: json['bgImagePath']?.toString() ?? '',
      espBgImagePath: json['espBgImagePath']?.toString() ?? '',
      sourceSummary: json['sourceSummary']?.toString() ?? 'theme.json + bg.jpg',
      createdAt: DateTime.tryParse(json['createdAt']?.toString() ?? '') ??
          DateTime.now(),
      spec: json['spec'] is Map
          ? CustomThemeSpec.fromJson(
              Map<String, dynamic>.from(json['spec']),
              fallbackName: name,
            )
          : CustomThemeSpec(name: name),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'subtitle': subtitle,
        'accentHex': accentHex,
        'bgImagePath': bgImagePath,
        'espBgImagePath': espBgImagePath,
        'sourceSummary': sourceSummary,
        'createdAt': createdAt.toIso8601String(),
        'spec': spec.toJson(),
      };
}

