import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/providers.dart';
import '../features/claude/claude_chat_screen.dart';
import '../features/claude/claude_sessions_screen.dart';
import '../features/files/file_editor_screen.dart';
import '../features/home/home_screen.dart';
import '../features/onboarding/add_server_screen.dart';
import '../features/onboarding/lock_screen.dart';
import '../features/onboarding/welcome_screen.dart';
import '../features/server/server_shell.dart';

final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/lock',
    routes: [
      GoRoute(
        path: '/lock',
        builder: (_, _) => const LockScreen(),
      ),
      GoRoute(
        path: '/',
        builder: (_, _) => const HomeScreen(),
      ),
      GoRoute(
        path: '/welcome',
        builder: (_, _) => const WelcomeScreen(),
      ),
      GoRoute(
        path: '/onboarding/add',
        builder: (_, _) => const AddServerScreen(),
      ),
      GoRoute(
        path: '/server/:id/edit',
        builder: (_, state) =>
            AddServerScreen(existingId: state.pathParameters['id']),
      ),
      GoRoute(
        path: '/server/:id',
        builder: (_, state) =>
            ServerShell(serverId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/server/:id/files',
        builder: (_, state) => ServerShell(
          serverId: state.pathParameters['id']!,
          initialTab: ServerTab.files,
        ),
      ),
      GoRoute(
        path: '/server/:id/terminal',
        builder: (_, state) => ServerShell(
          serverId: state.pathParameters['id']!,
          initialTab: ServerTab.terminal,
        ),
      ),
      GoRoute(
        path: '/server/:id/claude',
        builder: (_, state) => ServerShell(
          serverId: state.pathParameters['id']!,
          initialTab: ServerTab.claude,
        ),
      ),
      GoRoute(
        path: '/server/:id/claude/:project',
        builder: (_, state) => ClaudeSessionsScreen(
          serverId: state.pathParameters['id']!,
          encodedDirName:
              Uri.decodeComponent(state.pathParameters['project']!),
        ),
      ),
      GoRoute(
        path: '/server/:id/claude/:project/sessions/:session',
        builder: (_, state) => ClaudeChatScreen(
          serverId: state.pathParameters['id']!,
          absolutePath:
              Uri.decodeQueryComponent(state.uri.queryParameters['path'] ?? ''),
        ),
      ),
      GoRoute(
        path: '/server/:id/files/edit',
        builder: (_, state) => FileEditorScreen(
          serverId: state.pathParameters['id']!,
          path: state.uri.queryParameters['path'] ?? '/',
        ),
      ),
    ],
    redirect: (context, state) {
      final servers = ref.read(serverListProvider).valueOrNull;
      final location = state.matchedLocation;
      if (location == '/lock' || location == '/onboarding/add') return null;
      if (servers != null && servers.isEmpty && location == '/') {
        return '/welcome';
      }
      return null;
    },
  );
});
