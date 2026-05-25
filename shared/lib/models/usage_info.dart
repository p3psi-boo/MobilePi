class UsageCostInfo {
  final double input;
  final double output;
  final double cacheRead;
  final double cacheWrite;
  final double total;

  const UsageCostInfo({
    this.input = 0,
    this.output = 0,
    this.cacheRead = 0,
    this.cacheWrite = 0,
    this.total = 0,
  });

  factory UsageCostInfo.fromJson(Map<String, dynamic> json) {
    double d(Object? v) {
      if (v is num) return v.toDouble();
      return double.tryParse(v?.toString() ?? '') ?? 0;
    }

    return UsageCostInfo(
      input: d(json['input']),
      output: d(json['output']),
      cacheRead: d(json['cacheRead']),
      cacheWrite: d(json['cacheWrite']),
      total: d(json['total']),
    );
  }

  Map<String, dynamic> toJson() => {
    'input': input,
    'output': output,
    'cacheRead': cacheRead,
    'cacheWrite': cacheWrite,
    'total': total,
  };
}

class UsageInfo {
  final int input;
  final int output;
  final int cacheRead;
  final int cacheWrite;
  final int? totalTokens;
  final UsageCostInfo? cost;

  const UsageInfo({
    this.input = 0,
    this.output = 0,
    this.cacheRead = 0,
    this.cacheWrite = 0,
    this.totalTokens,
    this.cost,
  });

  static int _i(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v?.toString() ?? '') ?? 0;
  }

  static int? _in(Object? v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString());
  }

  factory UsageInfo.fromJson(Map<String, dynamic> json) {
    return UsageInfo(
      input: _i(json['input'] ?? json['input_tokens']),
      output: _i(json['output'] ?? json['output_tokens']),
      cacheRead: _i(json['cacheRead'] ?? json['cache_read_input_tokens']),
      cacheWrite: _i(json['cacheWrite'] ?? json['cache_write_input_tokens']),
      totalTokens: _in(json['totalTokens'] ?? json['total_tokens']),
      cost: json['cost'] is Map
          ? UsageCostInfo.fromJson(Map<String, dynamic>.from(json['cost'] as Map))
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'input': input,
    'output': output,
    'cacheRead': cacheRead,
    'cacheWrite': cacheWrite,
    if (totalTokens != null) 'totalTokens': totalTokens,
    if (cost != null) 'cost': cost!.toJson(),
  };
}
