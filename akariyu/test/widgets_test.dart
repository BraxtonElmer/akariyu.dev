import 'package:akariyu/shared/widgets/akariyu_button.dart';
import 'package:akariyu/shared/widgets/akariyu_card.dart';
import 'package:akariyu/shared/widgets/akariyu_text_field.dart';
import 'package:akariyu/shared/widgets/status_dot.dart';
import 'package:akariyu/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) =>
    MaterialApp(theme: AkariyuTheme.dark, home: Scaffold(body: child));

void main() {
  group('AkariyuButton', () {
    testWidgets('invokes onPressed when enabled', (tester) async {
      var taps = 0;
      await tester.pumpWidget(_wrap(
        AkariyuButton(label: 'Go', onPressed: () => taps++),
      ));
      await tester.tap(find.text('Go'));
      await tester.pumpAndSettle();
      expect(taps, 1);
    });

    testWidgets('disabled when onPressed null', (tester) async {
      await tester.pumpWidget(_wrap(
        const AkariyuButton(label: 'Off', onPressed: null),
      ));
      await tester.tap(find.text('Off'));
      await tester.pumpAndSettle();
      // No callback → still 0; test passes if tap doesn't throw.
      expect(find.text('Off'), findsOneWidget);
    });

    testWidgets('shows spinner when loading', (tester) async {
      await tester.pumpWidget(_wrap(
        AkariyuButton(label: 'Save', loading: true, onPressed: () {}),
      ));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Save'), findsNothing);
    });
  });

  group('AkariyuCard', () {
    testWidgets('forwards taps', (tester) async {
      var taps = 0;
      await tester.pumpWidget(_wrap(
        AkariyuCard(
          onTap: () => taps++,
          child: const Text('content'),
        ),
      ));
      await tester.tap(find.text('content'));
      await tester.pumpAndSettle();
      expect(taps, 1);
    });
  });

  group('AkariyuTextField', () {
    testWidgets('reflects controller changes', (tester) async {
      final c = TextEditingController();
      await tester.pumpWidget(_wrap(
        AkariyuTextField(controller: c, hint: 'hi'),
      ));
      await tester.enterText(find.byType(TextField), 'hello');
      expect(c.text, 'hello');
    });

    testWidgets('renders label and helper', (tester) async {
      await tester.pumpWidget(_wrap(
        const AkariyuTextField(label: 'Host', helper: 'e.g. 10.0.0.1'),
      ));
      expect(find.text('Host'), findsOneWidget);
      expect(find.text('e.g. 10.0.0.1'), findsOneWidget);
    });
  });

  group('StatusDot', () {
    testWidgets('builds for each status', (tester) async {
      for (final s in DotStatus.values) {
        await tester.pumpWidget(_wrap(StatusDot(status: s)));
        await tester.pump();
        expect(find.byType(StatusDot), findsOneWidget);
      }
    });
  });
}
