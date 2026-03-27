/// Breaks the import cycle common.dart ↔ desktop_tab_page.dart (which pulls in
/// RemotePage → common.dart). The main window registers the real opener once
/// [DesktopTabPage] is alive.
typedef DesktopRemoteTabOpener = void Function(
  String id, {
  String? password,
  bool? isSharedPassword,
  bool? forceRelay,
});

DesktopRemoteTabOpener? _desktopRemoteTabOpener;

void registerDesktopRemoteTabOpener(DesktopRemoteTabOpener? opener) {
  _desktopRemoteTabOpener = opener;
}

void invokeDesktopRemoteTabOpener(
  String id, {
  String? password,
  bool? isSharedPassword,
  bool? forceRelay,
}) {
  _desktopRemoteTabOpener?.call(
    id,
    password: password,
    isSharedPassword: isSharedPassword,
    forceRelay: forceRelay,
  );
}
