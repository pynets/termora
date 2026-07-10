import 'package:flutter_test/flutter_test.dart';
import 'package:termora/core/l10n/app_l10n.dart';

void main() {
  tearDown(() {
    // 恢复默认中文,避免影响其它断言中文 UI 的测试
    AppL10n.current = AppL10n.resolve(AppLocale.zh);
  });

  test('tr 中文直出,英文查表,缺失回落中文', () {
    AppL10n.current = AppL10n.resolve(AppLocale.zh);
    expect(tr('删除'), '删除');

    AppL10n.current = AppL10n.resolve(AppLocale.en);
    expect(tr('删除'), 'Delete');
    expect(tr('全选'), 'Select all');
    expect(tr('这条不存在的字符串'), '这条不存在的字符串');
  });

  test('tr2 模板占位替换(中英两路)', () {
    AppL10n.current = AppL10n.resolve(AppLocale.en);
    expect(tr2('删除 {0} 项', [3]), 'Delete 3 items');
    expect(tr2('{0} 列 × {1} 行', [4, 9]), '4 columns × 9 rows');

    AppL10n.current = AppL10n.resolve(AppLocale.zh);
    expect(tr2('删除 {0} 项', [3]), '删除 3 项');
  });
}
