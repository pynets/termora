import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:termora/features/remote/data/host_store.dart';
import 'package:termora/features/remote/domain/ssh_host.dart';

// ----------------------------------------------------------------------
// 已保存的 SSH 主机列表
// ----------------------------------------------------------------------

class SshHostsController extends Notifier<List<SshHost>> {
  @override
  List<SshHost> build() {
    _load();
    return const [];
  }

  Future<void> _load() async {
    state = await SshHostStore.load();
  }

  /// 新增或更新(按 id 匹配)
  Future<void> upsert(SshHost host) async {
    final index = state.indexWhere((h) => h.id == host.id);
    if (index < 0) {
      state = [...state, host];
    } else {
      state = [
        for (final h in state)
          if (h.id == host.id) host else h,
      ];
    }
    await SshHostStore.save(state);
  }

  Future<void> remove(String id) async {
    state = [
      for (final h in state)
        if (h.id != id) h,
    ];
    await SshHostStore.save(state);
  }
}

final sshHostsProvider = NotifierProvider<SshHostsController, List<SshHost>>(
  SshHostsController.new,
);

// 连接主机不再走全局总线:远程页自带终端工作区,
// 直接通过 TerminalWorkspaceController 在页内开 SSH 会话。
