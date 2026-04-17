import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
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
  String? _info; // 成功提示（如"请查收验证邮件"）
  bool _obscure = true;

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

    if (email.isEmpty || password.isEmpty) {
      setState(() => _error = '请填写邮箱和密码');
      return;
    }
    if (!_isLogin && password.length < 6) {
      setState(() => _error = '密码至少 6 位');
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
          // 跳转到 OTP 验证页
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => OtpVerifyPage(
                email: email,
                onVerified: widget.onAuthSuccess,
              ),
            ),
          );
        } else {
          widget.onAuthSuccess();
        }
      }
    } catch (e) {
      final msg = e.toString().replaceFirst('Exception: ', '');
      if (msg.contains('邮箱未验证') || msg.contains('not confirmed')) {
        // 未验证 → 跳转到验证码页面
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
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.code, size: 64, color: cs.primary),
                const SizedBox(height: 16),
                Text(
                  'JSON DSL v3.2',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold, color: cs.primary),
                ),
                const SizedBox(height: 8),
                Text(
                  _isLogin ? '登录你的账户' : '创建新账户',
                  style: Theme.of(context)
                      .textTheme
                      .bodyLarge
                      ?.copyWith(color: cs.onSurfaceVariant),
                ),
                const SizedBox(height: 40),

                // 用户名（仅注册）
                if (!_isLogin) ...[
                  TextField(
                    controller: _usernameCtrl,
                    decoration: InputDecoration(
                      labelText: '用户名（可选）',
                      prefixIcon: const Icon(Icons.person_outline),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],

                // 邮箱
                TextField(
                  controller: _emailCtrl,
                  keyboardType: TextInputType.emailAddress,
                  decoration: InputDecoration(
                    labelText: '邮箱',
                    prefixIcon: const Icon(Icons.email_outlined),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  onSubmitted: (_) => _submit(),
                ),
                const SizedBox(height: 16),

                // 密码
                TextField(
                  controller: _passwordCtrl,
                  obscureText: _obscure,
                  decoration: InputDecoration(
                    labelText: '密码',
                    prefixIcon: const Icon(Icons.lock_outlined),
                    suffixIcon: IconButton(
                      icon: Icon(
                          _obscure ? Icons.visibility_off : Icons.visibility),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  onSubmitted: (_) => _submit(),
                ),
                const SizedBox(height: 24),

                // 提交
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: FilledButton(
                    onPressed: _loading ? null : _submit,
                    child: _loading
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : Text(_isLogin ? '登录' : '注册',
                            style: const TextStyle(fontSize: 16)),
                  ),
                ),

                // 成功提示
                if (_info != null) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.green.shade50,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.check_circle_outline,
                            color: Colors.green.shade700, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                            child: Text(_info!,
                                style:
                                    TextStyle(color: Colors.green.shade700))),
                      ],
                    ),
                  ),
                ],

                // 错误提示
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: cs.errorContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.error_outline, color: cs.error, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                            child: Text(_error!,
                                style:
                                    TextStyle(color: cs.onErrorContainer))),
                      ],
                    ),
                  ),
                ],

                const SizedBox(height: 24),

                // 切换
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(_isLogin ? '还没有账户？' : '已有账户？',
                        style: TextStyle(color: cs.onSurfaceVariant)),
                    TextButton(
                      onPressed: () => setState(() {
                        _isLogin = !_isLogin;
                        _error = null;
                        _info = null;
                      }),
                      child: Text(_isLogin ? '注册' : '登录'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
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
      setState(() => _error = '请输入验证码');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      await AuthService.verifyOtp(email: widget.email, token: code);
      if (mounted) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
      widget.onVerified();
    } catch (e) {
      setState(
          () => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      setState(() => _loading = false);
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
      setState(() => _info = '验证邮件已重新发送');
    } catch (e) {
      setState(
          () => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('邮箱验证')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Column(
              children: [
                Icon(Icons.mark_email_read, size: 64, color: cs.primary),
                const SizedBox(height: 16),
                Text(
                  '验证你的邮箱',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text(
                  '验证码已发送到\n${widget.email}',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: cs.onSurfaceVariant),
                ),
                const SizedBox(height: 32),

                // 验证码输入
                TextField(
                  controller: _codeCtrl,
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 24, letterSpacing: 8, fontWeight: FontWeight.bold),
                  decoration: InputDecoration(
                    labelText: '6 位验证码',
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  onSubmitted: (_) => _verify(),
                ),
                const SizedBox(height: 24),

                // 验证按钮
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: FilledButton(
                    onPressed: _loading ? null : _verify,
                    child: _loading
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : const Text('验证', style: TextStyle(fontSize: 16)),
                  ),
                ),

                const SizedBox(height: 16),

                // 重新发送
                TextButton(
                  onPressed: _loading ? null : _resend,
                  child: const Text('没收到？重新发送验证码'),
                ),

                if (_info != null) ...[
                  const SizedBox(height: 12),
                  Text(_info!, style: TextStyle(color: Colors.green.shade700)),
                ],

                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: cs.errorContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.error_outline, color: cs.error, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                            child: Text(_error!,
                                style: TextStyle(color: cs.onErrorContainer))),
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

/// 个人资料页面 — 修改用户名、头像
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
      setState(() => _message = '用户名已更新');
    } catch (e) {
      setState(
          () => _message = '失败: ${e.toString().replaceFirst("Exception: ", "")}');
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

      final bytes = await File(file.path).readAsBytes();
      final b64 = base64Encode(bytes);
      await AuthService.uploadAvatar(b64);

      setState(() => _message = '头像已更新');
    } catch (e) {
      setState(
          () => _message = '失败: ${e.toString().replaceFirst("Exception: ", "")}');
    } finally {
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = AuthService.currentUser;
    final avatarUrl = user?['avatar_url'] as String? ?? '';
    final cs = Theme.of(context).colorScheme;

    Widget avatar;
    if (avatarUrl.startsWith('data:')) {
      final parts = avatarUrl.split(',');
      if (parts.length == 2) {
        avatar = CircleAvatar(
          radius: 48,
          backgroundImage: MemoryImage(base64Decode(parts[1])),
        );
      } else {
        avatar = CircleAvatar(
            radius: 48, child: Icon(Icons.person, size: 48, color: cs.primary));
      }
    } else {
      avatar = CircleAvatar(
          radius: 48, child: Icon(Icons.person, size: 48, color: cs.primary));
    }

    return Scaffold(
      appBar: AppBar(title: const Text('个人资料'), centerTitle: true),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            // 头像
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
                        color: cs.primary,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.camera_alt,
                          size: 16, color: Colors.white),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(user?['email'] ?? '',
                style: TextStyle(color: cs.onSurfaceVariant)),
            const SizedBox(height: 32),

            // 用户名
            TextField(
              controller: _usernameCtrl,
              decoration: InputDecoration(
                labelText: '用户名',
                prefixIcon: const Icon(Icons.person_outline),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
            ),
            const SizedBox(height: 16),

            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: _loading ? null : _saveUsername,
                child: _loading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Text('保存'),
              ),
            ),

            if (_message != null) ...[
              const SizedBox(height: 16),
              Text(_message!, style: TextStyle(color: cs.primary)),
            ],

            const SizedBox(height: 32),
            const Divider(),
            const SizedBox(height: 16),

            // 登出
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () async {
                  await AuthService.signOut();
                  if (context.mounted) Navigator.of(context).pop();
                },
                icon: const Icon(Icons.logout),
                label: const Text('退出登录'),
                style: OutlinedButton.styleFrom(foregroundColor: cs.error),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
