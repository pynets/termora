import 'package:flutter_test/flutter_test.dart';
import 'package:termora/core/services/update_service.dart';

void main() {
  group('UpdateService.compareVersions', () {
    test('基本大小比较', () {
      expect(UpdateService.compareVersions('0.0.3', '0.0.2'), greaterThan(0));
      expect(UpdateService.compareVersions('0.0.2', '0.0.3'), lessThan(0));
      expect(UpdateService.compareVersions('0.0.2', '0.0.2'), 0);
    });

    test('位数不同按 0 补齐', () {
      expect(UpdateService.compareVersions('1.0', '0.9.9'), greaterThan(0));
      expect(UpdateService.compareVersions('1.0.0', '1.0'), 0);
      expect(UpdateService.compareVersions('1.0.1', '1.0'), greaterThan(0));
    });

    test('跨位进位与非数字后缀', () {
      expect(UpdateService.compareVersions('0.10.0', '0.9.9'), greaterThan(0));
      expect(
        UpdateService.compareVersions('1.0.0-beta', '1.0.0'),
        0, // 预发布后缀按数字段处理,不参与比较
      );
    });
  });
}
