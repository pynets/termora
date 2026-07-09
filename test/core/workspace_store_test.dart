import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:termora/core/services/workspace_store.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('DbWorkspaceSnapshot 序列化往返', () {
    const snap = DbWorkspaceSnapshot(
      openTables: [
        OpenTableSnapshot(schema: 'public', table: 'users'),
        OpenTableSnapshot(schema: 'hub', table: 'v_report', isView: true),
      ],
      activeTableKey: 'hub.v_report',
    );
    final restored = DbWorkspaceSnapshot.fromJson(snap.toJson());
    expect(restored.openTables.length, 2);
    expect(restored.openTables[0].schema, 'public');
    expect(restored.openTables[1].isView, true);
    expect(restored.openTables[1].key, 'hub.v_report');
    expect(restored.activeTableKey, 'hub.v_report');
  });

  test('顶层选中页存取', () async {
    expect(await WorkspaceStore.loadActiveFeature(), 0); // 默认终端
    await WorkspaceStore.saveActiveFeature(1);
    expect(await WorkspaceStore.loadActiveFeature(), 1);
  });

  test('SQL 文本存取', () async {
    expect(await WorkspaceStore.loadSqlText(), '');
    await WorkspaceStore.saveSqlText('select 1');
    expect(await WorkspaceStore.loadSqlText(), 'select 1');
  });

  test('每连接工作区独立存取 + 清除', () async {
    await WorkspaceStore.saveWorkspace(
      'conn-a',
      const DbWorkspaceSnapshot(
        openTables: [OpenTableSnapshot(schema: 'public', table: 't1')],
        activeTableKey: 'public.t1',
      ),
    );
    final a = await WorkspaceStore.loadWorkspace('conn-a');
    expect(a.openTables.single.table, 't1');
    // 另一个连接不受影响
    final b = await WorkspaceStore.loadWorkspace('conn-b');
    expect(b.openTables, isEmpty);

    await WorkspaceStore.clearWorkspace('conn-a');
    expect((await WorkspaceStore.loadWorkspace('conn-a')).openTables, isEmpty);
  });

  test('上次活动连接存取/清除(自动重连用)', () async {
    expect(await WorkspaceStore.loadLastConnection(), isNull);
    await WorkspaceStore.saveLastConnection('conn-x');
    expect(await WorkspaceStore.loadLastConnection(), 'conn-x');
    await WorkspaceStore.clearLastConnection();
    expect(await WorkspaceStore.loadLastConnection(), isNull);
  });

  test('损坏 JSON 回退为空快照', () async {
    SharedPreferences.setMockInitialValues({
      'database.workspace.bad': 'not json',
    });
    final snap = await WorkspaceStore.loadWorkspace('bad');
    expect(snap.openTables, isEmpty);
    expect(snap.activeTableKey, isNull);
  });
}
