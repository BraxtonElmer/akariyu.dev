import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'routing/router.dart';
import 'theme/theme.dart';

class AkariyuApp extends ConsumerWidget {
  const AkariyuApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: 'akariyu',
      debugShowCheckedModeBanner: false,
      theme: AkariyuTheme.dark,
      darkTheme: AkariyuTheme.dark,
      themeMode: ThemeMode.dark,
      routerConfig: router,
    );
  }
}
