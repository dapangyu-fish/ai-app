import 'dart:convert';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../designer/app_storage.dart';
import '../designer/hidden_env_entry.dart';
import '../i18n/framework_strings.dart';
import '../i18n/language_switcher.dart';
import 'auth_service.dart';

/// 登录 / 注册页面
class AuthPage extends StatefulWidget {
  final VoidCallback onAuthSuccess;

  const AuthPage({super.key, required this.onAuthSuccess});

  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> {
  final _emailCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _usernameCtrl = TextEditingController();
  bool _isLogin = true;
  bool _loading = false;
  String? _error;
  String? _info;
  bool _obscure = true;

  @override
  void initState() {
    super.initState();
    _loadLastEmail();
  }

  Future<void> _loadLastEmail() async {
    final prefs = await SharedPreferences.getInstance();
    final lastEmail = prefs.getString('auth_last_email');
    if (lastEmail != null && mounted) {
      _emailCtrl.text = lastEmail;
    }
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passwordCtrl.dispose();
    _usernameCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _emailCtrl.text.trim();
    final password = _passwordCtrl.text.trim();
    final t = T.of(context);

    if (email.isEmpty) {
      setState(() => _error = t.authEmailRequired);
      return;
    }
    if (password.isEmpty) {
      setState(() => _error = t.authPasswordRequired);
      return;
    }
    if (!_isLogin && password.length < 6) {
      setState(() => _error = t.authPasswordTooShort);
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
      _info = null;
    });

    try {
      if (_isLogin) {
        await AuthService.signIn(email: email, password: password);
        // signIn 内部已经在同邮箱时把 _lastEmailKey 写好；切账号时则 token 还没落地
        if (!await _handlePendingAccountSwitch()) return;
        widget.onAuthSuccess();
      } else {
        final result = await AuthService.register(
          email: email,
          password: password,
          username: _usernameCtrl.text.trim().isEmpty
              ? null
              : _usernameCtrl.text.trim(),
        );
        if (result['needs_confirm'] == true) {
          if (!context.mounted) return;
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => OtpVerifyPage(
                email: email,
                onVerified: widget.onAuthSuccess,
              ),
            ),
          );
        } else {
          // 自动确认 register（已拿到 token） — 同样要处理切账号
          if (!await _handlePendingAccountSwitch()) return;
          widget.onAuthSuccess();
        }
      }
    } catch (e) {
      final msg = e.toString().replaceFirst('Exception: ', '');
      if (msg.contains('邮箱未验证') || msg.contains('not confirmed')) {
        if (context.mounted) {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => OtpVerifyPage(
                email: _emailCtrl.text.trim(),
                onVerified: widget.onAuthSuccess,
              ),
            ),
          );
        }
      } else {
        setState(() => _error = msg);
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 检查 AuthService 是否有 pending 切账号；有则弹框处理。
  /// 返回 true：可以继续走"登录成功"后续逻辑（onAuthSuccess）。
  /// 返回 false：用户取消 / 异常，留在登录页。
  Future<bool> _handlePendingAccountSwitch() async {
    final info = AuthService.pendingAccountSwitch;
    if (info == null) return true;

    if (!mounted) {
      AuthService.cancelPendingAccountSwitch();
      return false;
    }

    final confirmed = await showAccountSwitchDialog(context, info);
    if (confirmed != true) {
      AuthService.cancelPendingAccountSwitch();
      if (mounted) {
        setState(() {
          _error = T.current.authSwitchAccountCancelled;
        });
      }
      return false;
    }

    try {
      await AuthService.confirmAccountSwitchAndWipe();
      return true;
    } catch (e) {
      debugPrint('[AuthPage] confirmAccountSwitchAndWipe 失败: $e');
      if (mounted) {
        setState(() => _error = T.fmt(T.current.authClearLocalFailedWith, {'err': e}));
      }
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    CurrentPageState.instance.setFrameworkPage('auth');
    final cs = Theme.of(context).colorScheme;
    final t = T.of(context);

    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        actions: const [
          LanguageSwitcher(),
          SizedBox(width: 8),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const SizedBox(height: 60),

                // Brand icon
                Icon(Icons.auto_awesome, size: 48, color: cs.onSurface),
                const SizedBox(height: 20),

                // Brand name —— 隐藏入口：登录前连点 7 下进入服务环境页
                HiddenEnvEntry(
                  child: Text(
                    'MyApp',
                    style: GoogleFonts.inter(
                      fontSize: 32,
                      fontWeight: FontWeight.w700,
                      color: cs.onSurface,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  _isLogin ? t.authLoginSubtitle : t.authRegisterSubtitle,
                  style: TextStyle(
                    fontSize: 15,
                    color: cs.onSurfaceVariant,
                  ),
                ),

                const SizedBox(height: 48),

                // Username (register only)
                if (!_isLogin) ...[
                  TextField(
                    controller: _usernameCtrl,
                    style: TextStyle(color: cs.onSurface),
                    decoration: InputDecoration(
                      hintText: t.authUsernameOptionalHint,
                      hintStyle: TextStyle(color: cs.onSurfaceVariant),
                      prefixIcon: Icon(Icons.person_outline, color: cs.onSurfaceVariant),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],

                // Email
                TextField(
                  controller: _emailCtrl,
                  keyboardType: TextInputType.emailAddress,
                  style: TextStyle(color: cs.onSurface),
                  decoration: InputDecoration(
                    hintText: t.authEmailHint,
                    hintStyle: TextStyle(color: cs.onSurfaceVariant),
                    prefixIcon: Icon(Icons.email_outlined, color: cs.onSurfaceVariant),
                  ),
                  onSubmitted: (_) => _submit(),
                ),
                const SizedBox(height: 12),

                // Password
                TextField(
                  controller: _passwordCtrl,
                  obscureText: _obscure,
                  style: TextStyle(color: cs.onSurface),
                  decoration: InputDecoration(
                    hintText: t.authPasswordHint,
                    hintStyle: TextStyle(color: cs.onSurfaceVariant),
                    prefixIcon: Icon(Icons.lock_outlined, color: cs.onSurfaceVariant),
                    suffixIcon: IconButton(
                      icon: Icon(
                          _obscure ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                          color: cs.onSurfaceVariant),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                  onSubmitted: (_) => _submit(),
                ),

                const SizedBox(height: 28),

                // Submit button
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: FilledButton(
                    onPressed: _loading ? null : _submit,
                    child: _loading
                        ? SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: cs.onPrimary),
                          )
                        : Text(_isLogin ? t.authLoginButton : t.authRegisterButton),
                  ),
                ),

                // Success info
                if (_info != null) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.check_circle_outline,
                            color: cs.onSurface, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                            child: Text(_info!,
                                style: TextStyle(color: cs.onSurface, fontSize: 13))),
                      ],
                    ),
                  ),
                ],

                // Error
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: cs.errorContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.error_outline, color: cs.error, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                            child: Text(_error!,
                                style: TextStyle(color: cs.onErrorContainer, fontSize: 13))),
                      ],
                    ),
                  ),
                ],

                const SizedBox(height: 28),

                // Toggle login/register
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(_isLogin ? t.authNoAccountPrompt : t.authHasAccountPrompt,
                        style: TextStyle(color: cs.onSurfaceVariant, fontSize: 14)),
                    TextButton(
                      onPressed: () => setState(() {
                        _isLogin = !_isLogin;
                        _error = null;
                        _info = null;
                      }),
                      child: Text(
                        _isLogin ? t.authRegisterButton : t.authLoginButton,
                        style: TextStyle(
                          color: cs.onSurface,
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 40),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 切换账号确认弹窗。返回 true=确认清除并继续，false/null=取消。
Future<bool?> showAccountSwitchDialog(
    BuildContext context, AccountSwitchInfo info) {
  final cs = Theme.of(context).colorScheme;
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) {
      final t = T.of(ctx);
      return AlertDialog(
        title: Text(t.authSwitchAccountTitle),
        content: Text(T.fmt(t.authSwitchAccountContent, {
          'newEmail': info.newEmail,
          'prevEmail': info.prevEmail,
        })),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(t.cancel),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: cs.error),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(t.authSwitchAccountConfirm),
          ),
        ],
      );
    },
  );
}

/// 邮箱 OTP 验证码输入页面
class OtpVerifyPage extends StatefulWidget {
  final String email;
  final VoidCallback onVerified;

  const OtpVerifyPage({
    super.key,
    required this.email,
    required this.onVerified,
  });

  @override
  State<OtpVerifyPage> createState() => _OtpVerifyPageState();
}

class _OtpVerifyPageState extends State<OtpVerifyPage> {
  final _codeCtrl = TextEditingController();
  bool _loading = false;
  String? _error;
  String? _info;

  @override
  void dispose() {
    _codeCtrl.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    final code = _codeCtrl.text.trim();
    if (code.isEmpty) {
      setState(() => _error = T.of(context).authVerifyCodeRequired);
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      await AuthService.verifyOtp(email: widget.email, token: code);
      // 与 AuthPage._submit 同样的切账号检测
      final info = AuthService.pendingAccountSwitch;
      if (info != null) {
        if (!mounted) {
          AuthService.cancelPendingAccountSwitch();
          return;
        }
        final confirmed = await showAccountSwitchDialog(context, info);
        if (confirmed != true) {
          AuthService.cancelPendingAccountSwitch();
          if (mounted) {
            setState(() => _error = T.current.authSwitchAccountCancelled);
          }
          return;
        }
        try {
          await AuthService.confirmAccountSwitchAndWipe();
        } catch (e) {
          debugPrint('[OtpVerifyPage] wipe 失败: $e');
          if (mounted) {
            setState(() => _error = T.fmt(T.current.authClearLocalFailedWith, {'err': e}));
          }
          return;
        }
      }
      if (mounted) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
      widget.onVerified();
    } catch (e) {
      setState(
          () => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _resend() async {
    setState(() {
      _loading = true;
      _error = null;
      _info = null;
    });

    try {
      await AuthService.resendVerification(widget.email);
      setState(() => _info = T.of(context).authVerifyCodeSent);
    } catch (e) {
      setState(
          () => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    CurrentPageState.instance.setFrameworkPage('otp_verify');
    final cs = Theme.of(context).colorScheme;
    final t = T.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(t.authVerifyTitle, style: GoogleFonts.inter(fontWeight: FontWeight.w600)),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Column(
              children: [
                Icon(Icons.mark_email_read_outlined, size: 56, color: cs.onSurface),
                const SizedBox(height: 20),
                Text(
                  t.authVerifyPageHeading,
                  style: GoogleFonts.inter(
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    color: cs.onSurface,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  T.fmt(t.authVerifyCodeSentTo, {'email': widget.email}),
                  textAlign: TextAlign.center,
                  style: TextStyle(color: cs.onSurfaceVariant, fontSize: 14),
                ),
                const SizedBox(height: 36),

                // Code input
                TextField(
                  controller: _codeCtrl,
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                    fontSize: 24,
                    letterSpacing: 8,
                    fontWeight: FontWeight.bold,
                    color: cs.onSurface,
                  ),
                  decoration: InputDecoration(
                    hintText: t.authVerifyCodeHint,
                    hintStyle: TextStyle(
                      color: cs.onSurfaceVariant,
                      fontSize: 16,
                      letterSpacing: 0,
                    ),
                  ),
                  onSubmitted: (_) => _verify(),
                ),
                const SizedBox(height: 28),

                // Verify button
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: FilledButton(
                    onPressed: _loading ? null : _verify,
                    child: _loading
                        ? SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: cs.onPrimary),
                          )
                        : Text(t.authVerifyButton),
                  ),
                ),

                const SizedBox(height: 16),

                // Resend
                TextButton(
                  onPressed: _loading ? null : _resend,
                  child: Text(
                    t.authResendCodePrompt,
                    style: TextStyle(color: cs.onSurfaceVariant),
                  ),
                ),

                if (_info != null) ...[
                  const SizedBox(height: 12),
                  Text(_info!, style: TextStyle(color: cs.onSurface, fontSize: 13)),
                ],

                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: cs.errorContainer,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.error_outline, color: cs.error, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                            child: Text(_error!,
                                style: TextStyle(color: cs.onErrorContainer, fontSize: 13))),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 个人资料页面
class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final _usernameCtrl = TextEditingController();
  bool _loading = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _usernameCtrl.text = AuthService.currentUser?['username'] ?? '';
  }

  @override
  void dispose() {
    _usernameCtrl.dispose();
    super.dispose();
  }

  Future<void> _saveUsername() async {
    final name = _usernameCtrl.text.trim();
    if (name.isEmpty) return;

    setState(() {
      _loading = true;
      _message = null;
    });
    try {
      await AuthService.updateProfile(username: name);
      if (!mounted) return;
      setState(() => _message = T.of(context).profileSavedSuccess);
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = T.fmt(
            T.of(context).profileSaveFailedWith,
            {'msg': e.toString().replaceFirst('Exception: ', '')},
          ));
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _pickAvatar() async {
    try {
      final picker = ImagePicker();
      final file = await picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 256,
        maxHeight: 256,
        imageQuality: 80,
      );
      if (file == null) return;

      setState(() {
        _loading = true;
        _message = null;
      });

      final bytes = await file.readAsBytes();
      final b64 = base64Encode(bytes);
      await AuthService.uploadAvatar(b64);

      // 清除图片缓存，确保新头像立即显示
      imageCache.clear();
      imageCache.clearLiveImages();

      if (!mounted) return;
      setState(() => _message = T.of(context).profileSavedSuccess);
    } catch (e) {
      if (!mounted) return;
      setState(() => _message = T.fmt(
            T.of(context).profileSaveFailedWith,
            {'msg': e.toString().replaceFirst('Exception: ', '')},
          ));
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    CurrentPageState.instance.setFrameworkPage('profile');
    final user = AuthService.currentUser;
    String avatarUrl = user?['avatar_url'] as String? ?? '';
    if (avatarUrl.isNotEmpty && avatarUrl.startsWith('http')) {
      avatarUrl = avatarUrl.contains('?') 
          ? '$avatarUrl&_cb=${AuthService.avatarCacheBuster}'
          : '$avatarUrl?_cb=${AuthService.avatarCacheBuster}';
    }
    debugPrint('[ProfilePage] Final avatarUrl to render: $avatarUrl');
    final cs = Theme.of(context).colorScheme;
    final t = T.of(context);

    Widget avatar;
    if (avatarUrl.startsWith('http')) {
      avatar = CircleAvatar(
        radius: 48,
        backgroundImage: CachedNetworkImageProvider(avatarUrl),
        onBackgroundImageError: (e, stack) {
          debugPrint('[ProfilePage] CachedNetworkImage ERROR: $e');
        },
        child: const Icon(Icons.person, color: Colors.transparent),
      );
    } else if (avatarUrl.startsWith('data:')) {
      final parts = avatarUrl.split(',');
      if (parts.length == 2) {
        avatar = CircleAvatar(
          radius: 48,
          backgroundImage: MemoryImage(base64Decode(parts[1])),
        );
      } else {
        avatar = CircleAvatar(
            radius: 48, child: Icon(Icons.person_outline, size: 48, color: cs.onSurface));
      }
    } else {
      avatar = CircleAvatar(
          radius: 48, child: Icon(Icons.person_outline, size: 48, color: cs.onSurface));
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(t.profileTitle, style: GoogleFonts.inter(fontWeight: FontWeight.w600)),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const SizedBox(height: 16),

            // Avatar
            GestureDetector(
              onTap: _loading ? null : _pickAvatar,
              child: Stack(
                children: [
                  avatar,
                  Positioned(
                    bottom: 0,
                    right: 0,
                    child: Container(
                      padding: const EdgeInsets.all(4),
                      decoration: BoxDecoration(
                        color: cs.onSurface,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(Icons.camera_alt,
                          size: 16, color: cs.surface),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(user?['email'] ?? '',
                style: TextStyle(color: cs.onSurfaceVariant, fontSize: 14)),
            const SizedBox(height: 8),
            // User Role Badge
            Builder(builder: (context) {
              final role = user?['role']?.toString() ?? 'user';
              String roleText = t.roleUser;
              Color roleColor = cs.surfaceContainerHighest;
              Color roleTextColor = cs.onSurfaceVariant;

              if (role == 'admin') {
                roleText = t.roleAdmin;
                roleColor = cs.primaryContainer;
                roleTextColor = cs.onPrimaryContainer;
              } else if (role == 'pro') {
                roleText = t.roleProUser;
                roleColor = cs.tertiaryContainer;
                roleTextColor = cs.onTertiaryContainer;
              }

              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  color: roleColor,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  roleText,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: roleTextColor,
                  ),
                ),
              );
            }),
            const SizedBox(height: 36),

            // Username
            TextField(
              controller: _usernameCtrl,
              style: TextStyle(color: cs.onSurface),
              decoration: InputDecoration(
                hintText: t.authUsernameHint,
                hintStyle: TextStyle(color: cs.onSurfaceVariant),
                prefixIcon: Icon(Icons.person_outline, color: cs.onSurfaceVariant),
              ),
            ),
            const SizedBox(height: 20),

            SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton(
                onPressed: _loading ? null : _saveUsername,
                child: _loading
                    ? SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: cs.onPrimary),
                      )
                    : Text(t.save),
              ),
            ),

            if (_message != null) ...[
              const SizedBox(height: 16),
              Text(_message!, style: TextStyle(color: cs.onSurface, fontSize: 13)),
            ],

            const SizedBox(height: 36),
            Divider(color: cs.outline),
            const SizedBox(height: 20),

            // Logout
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: () async {
                  await AuthService.signOut();
                  if (context.mounted) Navigator.of(context).pop();
                },
                child: Text(
                  t.userMenuLogout,
                  style: TextStyle(color: cs.error, fontSize: 15),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
