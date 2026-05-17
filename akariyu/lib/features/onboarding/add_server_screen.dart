import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/providers.dart';
import '../../core/ssh/ssh_models.dart';
import '../../core/ssh/ssh_service.dart';
import '../../dev_credentials.dart';
import '../../shared/widgets/akariyu_button.dart';
import '../../shared/widgets/akariyu_text_field.dart';
import '../../theme/colors.dart';
import '../../theme/typography.dart';

/// Add/edit server form. When [existingId] is non-null the form loads the
/// existing profile and its stored secrets, and `Save` updates in place
/// instead of creating a new profile.
class AddServerScreen extends ConsumerStatefulWidget {
  const AddServerScreen({super.key, this.existingId});

  final String? existingId;

  bool get isEditing => existingId != null;

  @override
  ConsumerState<AddServerScreen> createState() => _AddServerScreenState();
}

class _AddServerScreenState extends ConsumerState<AddServerScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _host = TextEditingController();
  final _port = TextEditingController(text: '22');
  final _user = TextEditingController();
  final _key = TextEditingController();
  final _passphrase = TextEditingController();
  final _password = TextEditingController();

  SshAuthMode _authMode = SshAuthMode.privateKey;
  bool _testing = false;
  bool _saving = false;
  bool _loading = false;
  String? _statusMessage;
  bool _statusOk = false;

  /// `true` once the user touches the key field while editing. Lets us
  /// distinguish "left untouched, keep existing key" from "intentionally
  /// blanked".
  bool _keyTouched = false;
  bool _passwordTouched = false;

  @override
  void initState() {
    super.initState();
    if (widget.isEditing) {
      _loading = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadExisting());
    } else if (DevCredentials.enabled) {
      _applyDevPrefill();
    } else {
      _name.text = 'dev-server';
    }
  }

  void _applyDevPrefill() {
    // Trim whitespace around the raw triple-quoted PEM so the leading /
    // trailing newlines in the source don't end up in the actual key.
    final key = DevCredentials.privateKey.trim();
    _name.text = DevCredentials.name;
    _host.text = DevCredentials.host;
    _port.text = DevCredentials.port.toString();
    _user.text = DevCredentials.username;
    _authMode = DevCredentials.authMode;
    _key.text = key;
    _passphrase.text = DevCredentials.passphrase;
    _password.text = DevCredentials.password;
    _keyTouched = key.isNotEmpty;
    _passwordTouched = DevCredentials.password.isNotEmpty;
  }

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _port.dispose();
    _user.dispose();
    _key.dispose();
    _passphrase.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _loadExisting() async {
    final repo = ref.read(serverRepositoryProvider);
    final profile = await repo.load(widget.existingId!);
    if (profile == null) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _statusOk = false;
        _statusMessage = 'Could not find that server.';
      });
      return;
    }
    final pk = await repo.loadPrivateKey(profile.id);
    final pw = await repo.loadPassword(profile.id);
    if (!mounted) return;
    setState(() {
      _name.text = profile.name;
      _host.text = profile.host;
      _port.text = profile.port.toString();
      _user.text = profile.username;
      _authMode = profile.authMode;
      _key.text = pk ?? '';
      _password.text = pw ?? '';
      _loading = false;
    });
  }

  Future<void> _onTest() async {
    if (!_formKey.currentState!.validate()) return;
    HapticFeedback.lightImpact();
    setState(() {
      _testing = true;
      _statusMessage = null;
    });
    final profile = _buildProfile(id: widget.existingId ?? 'test');
    SshConnection? conn;
    try {
      conn = await SshConnection.connect(
        profile: profile,
        privateKey:
            _authMode == SshAuthMode.privateKey ? _key.text.trim() : null,
        passphrase: _passphrase.text.isEmpty ? null : _passphrase.text,
        password: _authMode == SshAuthMode.password ? _password.text : null,
      );
      final result = await conn.probe();
      setState(() {
        _statusOk = result.ok;
        _statusMessage = result.ok
            ? 'Connected as ${result.whoami} • ${result.uname}'
            : 'Probe failed: ${result.error}';
      });
    } on SshAuthenticationException catch (e) {
      setState(() {
        _statusOk = false;
        _statusMessage = e.message;
      });
    } on SshConnectionException catch (e) {
      setState(() {
        _statusOk = false;
        _statusMessage = e.message;
      });
    } catch (e) {
      setState(() {
        _statusOk = false;
        _statusMessage = 'Unexpected error: $e';
      });
    } finally {
      await conn?.close();
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _onSave() async {
    if (!_formKey.currentState!.validate()) return;
    HapticFeedback.mediumImpact();
    setState(() => _saving = true);
    final repo = ref.read(serverRepositoryProvider);
    final id = widget.existingId ?? repo.generateId();
    final profile = _buildProfile(id: id);

    // Determine what secret to pass. When editing and the field was never
    // touched, we pass null so the repository keeps the previously stored
    // value untouched.
    final keyToWrite = _authMode == SshAuthMode.privateKey
        ? (widget.isEditing && !_keyTouched ? null : _key.text.trim())
        : null;
    final passwordToWrite = _authMode == SshAuthMode.password
        ? (widget.isEditing && !_passwordTouched ? null : _password.text)
        : null;

    try {
      // Disconnect any live connection — auth params may have changed.
      if (widget.isEditing) {
        await ref.read(connectionManagerProvider).disconnect(id);
      }
      await ref.read(serverListProvider.notifier).add(
            profile,
            privateKey: keyToWrite,
            password: passwordToWrite,
          );
      if (!mounted) return;
      context.go('/');
    } catch (e) {
      setState(() {
        _statusOk = false;
        _statusMessage = 'Could not save: $e';
      });
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  ServerProfile _buildProfile({required String id}) {
    return ServerProfile(
      id: id,
      name: _name.text.trim(),
      host: _host.text.trim(),
      port: int.tryParse(_port.text.trim()) ?? 22,
      username: _user.text.trim(),
      authMode: _authMode,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AkariyuColors.backgroundBase,
      appBar: AppBar(
        title: Text(widget.isEditing ? 'Edit server' : 'Add server'),
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : Form(
                key: _formKey,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
                  children: [
                    AkariyuTextField(
                      controller: _name,
                      label: 'Name',
                      hint: 'dev-server',
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: 16),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: 3,
                          child: AkariyuTextField(
                            controller: _host,
                            label: 'Host',
                            hint: 'example.com or 10.0.0.4',
                            keyboardType: TextInputType.url,
                            textInputAction: TextInputAction.next,
                            autocorrect: false,
                            enableSuggestions: false,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 1,
                          child: AkariyuTextField(
                            controller: _port,
                            label: 'Port',
                            hint: '22',
                            keyboardType: TextInputType.number,
                            textInputAction: TextInputAction.next,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    AkariyuTextField(
                      controller: _user,
                      label: 'Username',
                      hint: 'ubuntu',
                      textInputAction: TextInputAction.next,
                      autocorrect: false,
                      enableSuggestions: false,
                    ),
                    const SizedBox(height: 24),
                    Text('Authentication', style: AkariyuTypography.labelLarge),
                    const SizedBox(height: 8),
                    _AuthModeSelector(
                      value: _authMode,
                      onChanged: (m) => setState(() => _authMode = m),
                    ),
                    const SizedBox(height: 16),
                    if (_authMode == SshAuthMode.privateKey) ...[
                      AkariyuTextField(
                        controller: _key,
                        label: 'Private key (PEM)',
                        hint:
                            '-----BEGIN OPENSSH PRIVATE KEY-----\n...\n-----END OPENSSH PRIVATE KEY-----',
                        maxLines: 6,
                        minLines: 4,
                        monospace: true,
                        autocorrect: false,
                        enableSuggestions: false,
                        onChanged: (_) {
                          if (!_keyTouched) {
                            setState(() => _keyTouched = true);
                          }
                        },
                      ),
                      const SizedBox(height: 12),
                      AkariyuTextField(
                        controller: _passphrase,
                        label: 'Passphrase (optional)',
                        obscureText: true,
                        autocorrect: false,
                        enableSuggestions: false,
                      ),
                    ] else
                      AkariyuTextField(
                        controller: _password,
                        label: 'Password',
                        obscureText: true,
                        autocorrect: false,
                        enableSuggestions: false,
                        onChanged: (_) {
                          if (!_passwordTouched) {
                            setState(() => _passwordTouched = true);
                          }
                        },
                      ),
                    const SizedBox(height: 24),
                    if (_statusMessage != null)
                      _StatusBanner(ok: _statusOk, message: _statusMessage!),
                    const SizedBox(height: 16),
                    AkariyuButton(
                      label: 'Test connection',
                      variant: AkariyuButtonVariant.secondary,
                      fullWidth: true,
                      loading: _testing,
                      onPressed: _testing || _saving ? null : _onTest,
                    ),
                    const SizedBox(height: 12),
                    AkariyuButton(
                      label: widget.isEditing ? 'Save changes' : 'Save server',
                      fullWidth: true,
                      loading: _saving,
                      onPressed: _testing || _saving ? null : _onSave,
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}

class _AuthModeSelector extends StatelessWidget {
  const _AuthModeSelector({required this.value, required this.onChanged});

  final SshAuthMode value;
  final ValueChanged<SshAuthMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AkariyuColors.surfaceCard,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AkariyuColors.borderSubtle),
      ),
      padding: const EdgeInsets.all(4),
      child: Row(
        children: [
          for (final mode in SshAuthMode.values)
            Expanded(
              child: GestureDetector(
                onTap: () => onChanged(mode),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: mode == value
                        ? AkariyuColors.accent
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    mode == SshAuthMode.privateKey ? 'Private key' : 'Password',
                    style: AkariyuTypography.labelLarge.copyWith(
                      color: mode == value
                          ? AkariyuColors.textPrimary
                          : AkariyuColors.textSecondary,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.ok, required this.message});

  final bool ok;
  final String message;

  @override
  Widget build(BuildContext context) {
    final color = ok ? AkariyuColors.success : AkariyuColors.error;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            ok ? Icons.check_circle_outline : Icons.error_outline,
            color: color,
            size: 18,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: AkariyuTypography.bodyMedium.copyWith(
                color: AkariyuColors.textPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
