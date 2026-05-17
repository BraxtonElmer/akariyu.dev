import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/providers.dart';
import '../features/home/home_screen.dart';
import '../features/onboarding/add_server_screen.dart';
import '../features/onboarding/lock_screen.dart';
import '../features/onboarding/welcome_screen.dart';

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
