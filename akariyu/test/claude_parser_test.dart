import 'package:akariyu/core/claude/claude_models.dart';
import 'package:akariyu/core/claude/claude_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseLine', () {
    test('returns null for malformed JSON', () {
      expect(ClaudeJsonlParser.parseLine('{not json'), isNull);
    });

    test('parses a plain user message', () {
      const line =
          '{"type":"user","uuid":"u1","timestamp":"2026-05-17T10:00:00Z",'
          '"message":{"role":"user","content":"hello there"}}';
      final m = ClaudeJsonlParser.parseLine(line)!;
      expect(m.type, 'user');
      expect(m.role, 'user');
      expect(m.uuid, 'u1');
      expect(m.timestamp, isNotNull);
      expect(m.blocks, hasLength(1));
      expect((m.blocks.first as ClaudeTextBlock).text, 'hello there');
    });

    test('parses assistant block array with text and tool_use', () {
      const line =
          '{"type":"assistant","uuid":"a1","timestamp":"2026-05-17T10:01:00Z",'
          '"message":{"role":"assistant","model":"claude-opus-4-7",'
          '"content":[{"type":"text","text":"sure"},'
          '{"type":"tool_use","id":"t1","name":"Bash",'
          '"input":{"command":"ls -la"}}]}}';
      final m = ClaudeJsonlParser.parseLine(line)!;
      expect(m.type, 'assistant');
      expect(m.model, 'claude-opus-4-7');
      expect(m.blocks, hasLength(2));
      expect(m.blocks[0], isA<ClaudeTextBlock>());
      expect(m.blocks[1], isA<ClaudeToolUseBlock>());
      final tool = m.blocks[1] as ClaudeToolUseBlock;
      expect(tool.name, 'Bash');
      expect(tool.input['command'], 'ls -la');
    });

    test('parses tool_result inside a user content array', () {
      const line =
          '{"type":"user","uuid":"u2","timestamp":"2026-05-17T10:02:00Z",'
          '"message":{"role":"user","content":'
          '[{"type":"tool_result","tool_use_id":"t1","content":"OK","is_error":false}]}}';
      final m = ClaudeJsonlParser.parseLine(line)!;
      final tr = m.blocks.single as ClaudeToolResultBlock;
      expect(tr.toolUseId, 't1');
      expect(tr.content, 'OK');
      expect(tr.isError, isFalse);
    });

    test('flattens list-shaped tool_result content', () {
      const line =
          '{"type":"user","uuid":"u3","timestamp":"2026-05-17T10:03:00Z",'
          '"message":{"role":"user","content":'
          '[{"type":"tool_result","tool_use_id":"t1","content":'
          '[{"type":"text","text":"line1"},{"type":"text","text":"line2"}]}]}}';
      final m = ClaudeJsonlParser.parseLine(line)!;
      final tr = m.blocks.single as ClaudeToolResultBlock;
      expect(tr.content, 'line1\nline2');
    });

    test('parses a summary line', () {
      const line = '{"type":"summary","uuid":"s1","summary":"all good"}';
      final m = ClaudeJsonlParser.parseLine(line)!;
      expect(m.isSummary, isTrue);
      expect(m.summary, 'all good');
    });
  });

  group('parseAll', () {
    test('skips empty lines and bad json, keeps the good ones', () {
      const body = '''
{"type":"user","uuid":"u1","message":{"role":"user","content":"hi"}}

oops
{"type":"assistant","uuid":"a1","message":{"role":"assistant","content":[{"type":"text","text":"hey"}]}}
''';
      final msgs = ClaudeJsonlParser.parseAll(body);
      expect(msgs.map((m) => m.type), ['user', 'assistant']);
    });
  });

  group('ClaudeSessionMeta.extract', () {
    test('first user message + last preview + count', () {
      const body = '''
{"type":"user","uuid":"u1","timestamp":"2026-05-17T10:00:00Z","message":{"role":"user","content":"first prompt"}}
{"type":"assistant","uuid":"a1","timestamp":"2026-05-17T10:00:30Z","message":{"role":"assistant","content":[{"type":"text","text":"working on it"}]}}
{"type":"user","uuid":"u2","timestamp":"2026-05-17T10:01:00Z","message":{"role":"user","content":"thanks"}}
''';
      final meta = ClaudeSessionMeta.extract(body);
      expect(meta.firstUserMessage, 'first prompt');
      expect(meta.lastMessagePreview, 'thanks');
      expect(meta.messageCount, 3);
      expect(meta.lastMessageAt, isNotNull);
      expect(meta.summary, isNull);
    });

    test('picks up summary line as session title', () {
      const body = '''
{"type":"summary","uuid":"s1","summary":"Refactor auth flow"}
{"type":"user","uuid":"u1","timestamp":"2026-05-17T10:00:00Z","message":{"role":"user","content":"hi"}}
''';
      final meta = ClaudeSessionMeta.extract(body);
      expect(meta.summary, 'Refactor auth flow');
      // Summary rows don't count toward message tally.
      expect(meta.messageCount, 1);
    });

    test('uses most recent summary when multiple exist', () {
      const body = '''
{"type":"summary","uuid":"s1","summary":"Old title"}
{"type":"user","uuid":"u1","message":{"role":"user","content":"hi"}}
{"type":"summary","uuid":"s2","summary":"New title"}
''';
      final meta = ClaudeSessionMeta.extract(body);
      expect(meta.summary, 'New title');
    });
  });

  group('ClaudeProject decoding', () {
    test('decodes encoded directory back to path', () {
      final p = ClaudeProject(
        encodedDirName: '-home-elmer-projects-akariyu.dev',
        absoluteDir: '/x',
        sessionCount: 0,
        lastModified: null,
      );
      expect(p.displayPath, '/home/elmer/projects/akariyu.dev');
      expect(p.displayName, 'akariyu.dev');
    });

    test('handles dir without leading dash', () {
      final p = ClaudeProject(
        encodedDirName: 'tmp-foo',
        absoluteDir: '/x',
        sessionCount: 0,
        lastModified: null,
      );
      expect(p.displayPath, '/tmp/foo');
    });
  });

  group('ClaudeSession title', () {
    ClaudeSession make({String? first, String? summary}) => ClaudeSession(
          id: 'id',
          projectDir: 'p',
          fileName: 'id.jsonl',
          absolutePath: '/x',
          firstUserMessage: first,
          lastMessagePreview: null,
          lastMessageAt: null,
          messageCount: 0,
          summary: summary,
        );

    test('falls back to "Untitled session"', () {
      expect(make().title, 'Untitled session');
      expect(make(first: '').title, 'Untitled session');
    });

    test('takes first line, truncates over 60 chars', () {
      expect(make(first: 'hello\nworld').title, 'hello');
      final long = 'x' * 80;
      final t = make(first: long).title;
      expect(t.length, 61); // 60 chars + ellipsis
      expect(t.endsWith('…'), isTrue);
    });

    test('prefers summary over first user message', () {
      expect(
        make(first: 'long prompt text', summary: 'Refactor auth').title,
        'Refactor auth',
      );
    });
  });
}
