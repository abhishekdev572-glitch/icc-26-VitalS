/// Data model representing a single VitalSense Protocol v1 JSON packet.
class VitalSenseData {
  final int protocol;
  final String deviceId;
  final int bed;
  final String position;
  final int positionDuration;
  final PlatesData plates;
  final List<int> fsr;
  final bool riskValid;
  final RiskData risk;
  final HighestRisk highestRisk;
  final AvoidReturnData avoidReturn;
  final int uptime;

  const VitalSenseData({
    required this.protocol,
    required this.deviceId,
    required this.bed,
    required this.position,
    required this.positionDuration,
    required this.plates,
    required this.fsr,
    required this.riskValid,
    required this.risk,
    required this.highestRisk,
    required this.avoidReturn,
    required this.uptime,
  });

  factory VitalSenseData.fromJson(Map<String, dynamic> json) {
    return VitalSenseData(
      protocol: _toInt(json['protocol']),
      deviceId: (json['deviceId'] as String?) ?? '',
      bed: _toInt(json['bed']),
      position: (json['position'] as String?) ?? 'CENTER',
      positionDuration: _toInt(json['positionDuration']),
      plates: PlatesData.fromJson(json['plates'] as Map<String, dynamic>),
      fsr: (json['fsr'] as List<dynamic>).map((e) => _toInt(e)).toList(),
      riskValid: (json['riskValid'] as bool?) ?? false,
      risk: RiskData.fromJson(json['risk'] as Map<String, dynamic>),
      highestRisk: HighestRisk.fromJson(
          json['highestRisk'] as Map<String, dynamic>),
      avoidReturn: AvoidReturnData.fromJson(
          json['avoidReturn'] as Map<String, dynamic>),
      uptime: _toInt(json['uptime']),
    );
  }

  /// Safely converts a JSON number (int or double) to int.
  static int _toInt(dynamic value) {
    if (value is int) return value;
    if (value is double) return value.toInt();
    return 0;
  }

  /// Validates that a parsed JSON map contains all required Protocol v1 fields.
  static bool isValid(Map<String, dynamic> json) {
    try {
      if (json['protocol'] != 1) {
        return false;
      }
      if (json['deviceId'] == null) {
        return false;
      }
      final pos = json['position'];
      if (!['CENTER', 'LEFT', 'RIGHT'].contains(pos)) {
        return false;
      }
      if (json['positionDuration'] is! num ||
          (json['positionDuration'] as num) < 0) {
        return false;
      }
      if (json['plates'] == null) {
        return false;
      }
      final fsrList = json['fsr'] as List?;
      if (fsrList == null || fsrList.length != 8) {
        return false;
      }
      if (json['riskValid'] is! bool) {
        return false;
      }
      if (json['risk'] == null) {
        return false;
      }
      if (json['highestRisk'] == null) {
        return false;
      }
      if (json['avoidReturn'] == null) {
        return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  String get positionLabel {
    switch (position) {
      case 'LEFT':
        return 'Left Side';
      case 'RIGHT':
        return 'Right Side';
      case 'CENTER':
      default:
        return 'Center / Back';
    }
  }

  String get formattedDuration {
    final h = positionDuration ~/ 3600;
    final m = (positionDuration % 3600) ~/ 60;
    final s = positionDuration % 60;
    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  String get bedLabel => 'Bed ${bed.toString().padLeft(2, '0')}';
}

class PlatesData {
  final int head;
  final int shoulders;
  final int hips;
  final int heels;

  const PlatesData({
    required this.head,
    required this.shoulders,
    required this.hips,
    required this.heels,
  });

  factory PlatesData.fromJson(Map<String, dynamic> json) {
    return PlatesData(
      head: VitalSenseData._toInt(json['head']),
      shoulders: VitalSenseData._toInt(json['shoulders']),
      hips: VitalSenseData._toInt(json['hips']),
      heels: VitalSenseData._toInt(json['heels']),
    );
  }
}

class RiskData {
  final int head;
  final int shoulders;
  final int hips;
  final int heels;

  const RiskData({
    required this.head,
    required this.shoulders,
    required this.hips,
    required this.heels,
  });

  factory RiskData.fromJson(Map<String, dynamic> json) {
    return RiskData(
      head: VitalSenseData._toInt(json['head']),
      shoulders: VitalSenseData._toInt(json['shoulders']),
      hips: VitalSenseData._toInt(json['hips']),
      heels: VitalSenseData._toInt(json['heels']),
    );
  }
}

class HighestRisk {
  final String zone;
  final int score;
  final String level;

  const HighestRisk({
    required this.zone,
    required this.score,
    required this.level,
  });

  factory HighestRisk.fromJson(Map<String, dynamic> json) {
    return HighestRisk(
      zone: (json['zone'] as String?) ?? 'NONE',
      score: VitalSenseData._toInt(json['score']),
      level: (json['level'] as String?) ?? 'NONE',
    );
  }

  String get zoneLabel {
    switch (zone) {
      case 'HEAD':
        return 'Head';
      case 'SHOULDERS':
        return 'Shoulders';
      case 'HIPS':
        return 'Hips';
      case 'HEELS':
        return 'Heels';
      default:
        return 'None';
    }
  }

  String get levelLabel {
    switch (level) {
      case 'LOW':
        return 'Low Risk';
      case 'MEDIUM':
        return 'Medium Risk';
      case 'HIGH':
        return 'High Risk';
      default:
        return 'Waiting...';
    }
  }
}

class AvoidReturnData {
  final int head;
  final int shoulders;
  final int hips;
  final int heels;

  const AvoidReturnData({
    required this.head,
    required this.shoulders,
    required this.hips,
    required this.heels,
  });

  factory AvoidReturnData.fromJson(Map<String, dynamic> json) {
    return AvoidReturnData(
      head: VitalSenseData._toInt(json['head']),
      shoulders: VitalSenseData._toInt(json['shoulders']),
      hips: VitalSenseData._toInt(json['hips']),
      heels: VitalSenseData._toInt(json['heels']),
    );
  }

  bool get hasAnyAlert =>
      head == 1 || shoulders == 1 || hips == 1 || heels == 1;
}
