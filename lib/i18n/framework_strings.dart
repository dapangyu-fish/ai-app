// 框架级 i18n 字符串表
// ──────────────────────────────────────────────────────────
// 所有"框架自身 UI"出现的文案在这里集中维护。
// JSON-APP 的 i18n 走 interpreter 的 global.i18n + {{ t('key') }}，
// 与本表完全隔离，互不影响。
//
// 用法：
//   T.of(context).loginTitle           // 跟随当前 locale
//   T.lookup(locale, 'loginTitle')     // 显式指定 locale
//
// 添加新字符串的规范：
//   1) 在 _Strings 类里加新字段（key 用 lowerCamelCase）
//   2) 在 _zhCN / _enUS 两个表里补对应翻译
//   3) 不要在业务代码里直接写硬字符串
//
// 不在这里维护的：
//   - JSON-APP 内的字符串（由 JSON-APP 自己的 global.i18n 管）
//   - 后端返回的错误信息（这类显示原文，不要硬编码到客户端 i18n 里）

import 'package:flutter/widgets.dart';

// 暴露给外部用作类型签名（避免 library_private_types_in_public_api 警告）
typedef FrameworkStrings = _Strings;

class _Strings {
  // ── 通用按钮 / 标签 ──
  final String ok;
  final String cancel;
  final String confirm;
  final String save;
  final String delete;
  final String retry;
  final String back;
  final String loading;
  final String empty;
  final String search;
  final String settings;
  final String language;
  final String done;
  final String yes;
  final String no;

  // ── 登录 / 注册 ──
  final String authLoginTitle;
  final String authLoginSubtitle;        // 登录页大标题下的副标题
  final String authRegisterTitle;
  final String authRegisterSubtitle;     // 注册页大标题下的副标题
  final String authVerifyTitle;          // AppBar title
  final String authVerifyPageHeading;    // OTP 页大标题（页内 H1）
  final String authVerifyCodeSentTo;     // "验证码已发送到 {email}" — 有 {email} 占位符
  final String authEmailHint;
  final String authPasswordHint;
  final String authPasswordConfirmHint;
  final String authUsernameHint;
  final String authUsernameOptionalHint; // 注册页可选用户名 hint
  final String authVerifyCodeHint;
  final String authLoginButton;
  final String authRegisterButton;
  final String authVerifyButton;
  final String authResendCodeButton;
  final String authResendCodePrompt;     // "没收到？重新发送验证码"
  final String authNoAccountPrompt;      // "还没有账户？"（前缀，跟独立按钮配合）
  final String authHasAccountPrompt;     // "已有账户？"
  final String authSwitchToRegister;
  final String authSwitchToLogin;
  final String authForgotPassword;
  final String authEmailRequired;
  final String authEmailInvalid;
  final String authPasswordRequired;
  final String authPasswordTooShort;
  final String authPasswordMismatch;
  final String authUsernameRequired;
  final String authVerifyCodeRequired;
  final String authVerifyCodeSent;
  final String authLoginFailed;
  final String authRegisterFailed;
  final String authVerifyFailed;
  final String authNetworkError;

  // ── 主页 ──
  final String homeAppTitle;
  final String homeWelcome;          // "Hi, {name}"
  final String homeSubtitle;         // 探索和运行你的应用
  final String homeMarket;           // 应用市场
  final String homeMarketSubtitle;   // 发现精彩应用
  final String homeMyApps;           // 我的 APP
  final String homeMyAppsSubtitle;   // 历史记录
  final String homeMessages;         // 消息
  final String homeMessagesSubtitle; // 查看会话与好友消息
  final String homeUnreadCount;      // "{n} 条未读"
  final String homePickFile;         // 选择本地文件
  final String homePickFileSubtitle; // 从设备导入 JSON 配置
  final String homeImLoginFailed;    // IM 连接失败，请稍后重试

  // ── 用户菜单 ──
  final String userMenuProfile;
  final String userMenuLogout;

  // ── 个人资料页 ──
  final String profileTitle;
  final String profileEditAvatar;
  final String profileSavedSuccess;
  final String profileSaveFailed;
  final String profileSaveFailedWith;   // "失败：{msg}" — 有 {msg} 占位

  // ── 用户角色徽章 ──
  final String roleUser;
  final String roleAdmin;
  final String roleProUser;

  // ── 应用市场 ──
  final String marketTitle;
  final String marketEmpty;
  final String marketLoadFailed;
  final String marketRunButton;

  // ── 我的 APP ──
  final String myAppsTitle;
  final String myAppsEmpty;
  final String myAppsRun;
  final String myAppsDelete;
  final String myAppsDeleteConfirmTitle;
  final String myAppsDeleteConfirmMessage;

  // ── 设置页 ──
  final String settingsTitle;
  final String settingsLanguage;
  final String settingsLanguageZh;
  final String settingsLanguageEn;
  final String settingsLanguageSystem;
  final String settingsAiProvider;
  final String settingsAbout;
  final String settingsVersion;

  // ── 错误 / 状态 ──
  final String errorGeneric;
  final String errorNoNetwork;

  const _Strings({
    required this.ok,
    required this.cancel,
    required this.confirm,
    required this.save,
    required this.delete,
    required this.retry,
    required this.back,
    required this.loading,
    required this.empty,
    required this.search,
    required this.settings,
    required this.language,
    required this.done,
    required this.yes,
    required this.no,
    required this.authLoginTitle,
    required this.authLoginSubtitle,
    required this.authRegisterTitle,
    required this.authRegisterSubtitle,
    required this.authVerifyTitle,
    required this.authVerifyPageHeading,
    required this.authVerifyCodeSentTo,
    required this.authEmailHint,
    required this.authPasswordHint,
    required this.authPasswordConfirmHint,
    required this.authUsernameHint,
    required this.authUsernameOptionalHint,
    required this.authVerifyCodeHint,
    required this.authLoginButton,
    required this.authRegisterButton,
    required this.authVerifyButton,
    required this.authResendCodeButton,
    required this.authResendCodePrompt,
    required this.authNoAccountPrompt,
    required this.authHasAccountPrompt,
    required this.authSwitchToRegister,
    required this.authSwitchToLogin,
    required this.authForgotPassword,
    required this.authEmailRequired,
    required this.authEmailInvalid,
    required this.authPasswordRequired,
    required this.authPasswordTooShort,
    required this.authPasswordMismatch,
    required this.authUsernameRequired,
    required this.authVerifyCodeRequired,
    required this.authVerifyCodeSent,
    required this.authLoginFailed,
    required this.authRegisterFailed,
    required this.authVerifyFailed,
    required this.authNetworkError,
    required this.homeAppTitle,
    required this.homeWelcome,
    required this.homeSubtitle,
    required this.homeMarket,
    required this.homeMarketSubtitle,
    required this.homeMyApps,
    required this.homeMyAppsSubtitle,
    required this.homeMessages,
    required this.homeMessagesSubtitle,
    required this.homeUnreadCount,
    required this.homePickFile,
    required this.homePickFileSubtitle,
    required this.homeImLoginFailed,
    required this.userMenuProfile,
    required this.userMenuLogout,
    required this.profileTitle,
    required this.profileEditAvatar,
    required this.profileSavedSuccess,
    required this.profileSaveFailed,
    required this.profileSaveFailedWith,
    required this.roleUser,
    required this.roleAdmin,
    required this.roleProUser,
    required this.marketTitle,
    required this.marketEmpty,
    required this.marketLoadFailed,
    required this.marketRunButton,
    required this.myAppsTitle,
    required this.myAppsEmpty,
    required this.myAppsRun,
    required this.myAppsDelete,
    required this.myAppsDeleteConfirmTitle,
    required this.myAppsDeleteConfirmMessage,
    required this.settingsTitle,
    required this.settingsLanguage,
    required this.settingsLanguageZh,
    required this.settingsLanguageEn,
    required this.settingsLanguageSystem,
    required this.settingsAiProvider,
    required this.settingsAbout,
    required this.settingsVersion,
    required this.errorGeneric,
    required this.errorNoNetwork,
  });
}

const _Strings _zhCN = _Strings(
  ok: '确定',
  cancel: '取消',
  confirm: '确认',
  save: '保存',
  delete: '删除',
  retry: '重试',
  back: '返回',
  loading: '加载中…',
  empty: '暂无数据',
  search: '搜索',
  settings: '设置',
  language: '语言',
  done: '完成',
  yes: '是',
  no: '否',
  authLoginTitle: '登录',
  authLoginSubtitle: '登录你的账户',
  authRegisterTitle: '注册',
  authRegisterSubtitle: '创建新账户',
  authVerifyTitle: '验证邮箱',
  authVerifyPageHeading: '验证你的邮箱',
  authVerifyCodeSentTo: '验证码已发送到\n{email}',
  authEmailHint: '邮箱',
  authPasswordHint: '密码',
  authPasswordConfirmHint: '确认密码',
  authUsernameHint: '用户名',
  authUsernameOptionalHint: '用户名（可选）',
  authVerifyCodeHint: '验证码',
  authLoginButton: '登录',
  authRegisterButton: '注册',
  authVerifyButton: '验证',
  authResendCodeButton: '重新发送',
  authResendCodePrompt: '没收到？重新发送验证码',
  authNoAccountPrompt: '还没有账户？',
  authHasAccountPrompt: '已有账户？',
  authSwitchToRegister: '没有账号？去注册',
  authSwitchToLogin: '已有账号？去登录',
  authForgotPassword: '忘记密码？',
  authEmailRequired: '请输入邮箱',
  authEmailInvalid: '邮箱格式不正确',
  authPasswordRequired: '请输入密码',
  authPasswordTooShort: '密码至少 6 位',
  authPasswordMismatch: '两次密码不一致',
  authUsernameRequired: '请输入用户名',
  authVerifyCodeRequired: '请输入验证码',
  authVerifyCodeSent: '验证码已发送',
  authLoginFailed: '登录失败',
  authRegisterFailed: '注册失败',
  authVerifyFailed: '验证失败',
  authNetworkError: '网络错误，请检查连接',
  homeAppTitle: 'MyApp',
  homeWelcome: '你好，{name}',
  homeSubtitle: '探索和运行你的应用',
  homeMarket: '应用市场',
  homeMarketSubtitle: '发现精彩应用',
  homeMyApps: '我的 APP',
  homeMyAppsSubtitle: '历史记录',
  homeMessages: '消息',
  homeMessagesSubtitle: '查看会话与好友消息',
  homeUnreadCount: '{n} 条未读',
  homePickFile: '选择本地文件',
  homePickFileSubtitle: '从设备导入 JSON 配置',
  homeImLoginFailed: 'IM 连接失败，请稍后重试',
  userMenuProfile: '个人资料',
  userMenuLogout: '退出登录',
  profileTitle: '个人资料',
  profileEditAvatar: '更换头像',
  profileSavedSuccess: '保存成功',
  profileSaveFailed: '保存失败',
  profileSaveFailedWith: '失败：{msg}',
  roleUser: '普通用户',
  roleAdmin: '管理员',
  roleProUser: '高级用户',
  marketTitle: '应用市场',
  marketEmpty: '暂无应用',
  marketLoadFailed: '加载失败',
  marketRunButton: '运行',
  myAppsTitle: '我的 APP',
  myAppsEmpty: '还没有应用',
  myAppsRun: '运行',
  myAppsDelete: '删除',
  myAppsDeleteConfirmTitle: '删除该应用？',
  myAppsDeleteConfirmMessage: '此操作不可撤销',
  settingsTitle: '设置',
  settingsLanguage: '语言',
  settingsLanguageZh: '中文',
  settingsLanguageEn: 'English',
  settingsLanguageSystem: '跟随系统',
  settingsAiProvider: 'AI 服务商',
  settingsAbout: '关于',
  settingsVersion: '版本',
  errorGeneric: '出错了',
  errorNoNetwork: '无网络连接',
);

const _Strings _enUS = _Strings(
  ok: 'OK',
  cancel: 'Cancel',
  confirm: 'Confirm',
  save: 'Save',
  delete: 'Delete',
  retry: 'Retry',
  back: 'Back',
  loading: 'Loading…',
  empty: 'No data',
  search: 'Search',
  settings: 'Settings',
  language: 'Language',
  done: 'Done',
  yes: 'Yes',
  no: 'No',
  authLoginTitle: 'Sign in',
  authLoginSubtitle: 'Sign in to your account',
  authRegisterTitle: 'Sign up',
  authRegisterSubtitle: 'Create a new account',
  authVerifyTitle: 'Verify email',
  authVerifyPageHeading: 'Verify your email',
  authVerifyCodeSentTo: 'Code sent to\n{email}',
  authEmailHint: 'Email',
  authPasswordHint: 'Password',
  authPasswordConfirmHint: 'Confirm password',
  authUsernameHint: 'Username',
  authUsernameOptionalHint: 'Username (optional)',
  authVerifyCodeHint: 'Verification code',
  authLoginButton: 'Sign in',
  authRegisterButton: 'Sign up',
  authVerifyButton: 'Verify',
  authResendCodeButton: 'Resend',
  authResendCodePrompt: "Didn't get it? Resend code",
  authNoAccountPrompt: "Don't have an account?",
  authHasAccountPrompt: 'Already have an account?',
  authSwitchToRegister: "No account? Sign up",
  authSwitchToLogin: 'Have an account? Sign in',
  authForgotPassword: 'Forgot password?',
  authEmailRequired: 'Email is required',
  authEmailInvalid: 'Invalid email',
  authPasswordRequired: 'Password is required',
  authPasswordTooShort: 'Password must be at least 6 characters',
  authPasswordMismatch: 'Passwords do not match',
  authUsernameRequired: 'Username is required',
  authVerifyCodeRequired: 'Verification code is required',
  authVerifyCodeSent: 'Code sent',
  authLoginFailed: 'Sign-in failed',
  authRegisterFailed: 'Sign-up failed',
  authVerifyFailed: 'Verification failed',
  authNetworkError: 'Network error',
  homeAppTitle: 'MyApp',
  homeWelcome: 'Hi, {name}',
  homeSubtitle: 'Explore and run your apps',
  homeMarket: 'App store',
  homeMarketSubtitle: 'Discover apps',
  homeMyApps: 'My apps',
  homeMyAppsSubtitle: 'History',
  homeMessages: 'Messages',
  homeMessagesSubtitle: 'Conversations and friends',
  homeUnreadCount: '{n} unread',
  homePickFile: 'Choose local file',
  homePickFileSubtitle: 'Import a JSON config from device',
  homeImLoginFailed: 'IM connection failed, please retry later',
  userMenuProfile: 'Profile',
  userMenuLogout: 'Sign out',
  profileTitle: 'Profile',
  profileEditAvatar: 'Change avatar',
  profileSavedSuccess: 'Saved',
  profileSaveFailed: 'Save failed',
  profileSaveFailedWith: 'Failed: {msg}',
  roleUser: 'User',
  roleAdmin: 'Admin',
  roleProUser: 'Pro user',
  marketTitle: 'App store',
  marketEmpty: 'No apps yet',
  marketLoadFailed: 'Load failed',
  marketRunButton: 'Run',
  myAppsTitle: 'My apps',
  myAppsEmpty: 'No apps yet',
  myAppsRun: 'Run',
  myAppsDelete: 'Delete',
  myAppsDeleteConfirmTitle: 'Delete this app?',
  myAppsDeleteConfirmMessage: 'This cannot be undone',
  settingsTitle: 'Settings',
  settingsLanguage: 'Language',
  settingsLanguageZh: '中文',
  settingsLanguageEn: 'English',
  settingsLanguageSystem: 'System',
  settingsAiProvider: 'AI provider',
  settingsAbout: 'About',
  settingsVersion: 'Version',
  errorGeneric: 'Something went wrong',
  errorNoNetwork: 'No network',
);

/// 公开访问点。
class T {
  /// 当前 BuildContext 的本地化字符串（推荐用法）
  static FrameworkStrings of(BuildContext context) {
    final localeStr = Localizations.localeOf(context).toLanguageTag();
    return _pick(localeStr);
  }

  /// 显式指定 locale 的查找（用于初始化前 / 不在 widget 树里的代码）
  static FrameworkStrings lookup(Locale locale) {
    return _pick(locale.toLanguageTag());
  }

  static FrameworkStrings _pick(String tag) {
    if (tag.startsWith('en')) return _enUS;
    return _zhCN; // 默认中文
  }

  /// 框架支持的所有 locale，main.dart 的 supportedLocales 用
  static const List<Locale> supportedLocales = [
    Locale('zh', 'CN'),
    Locale('en', 'US'),
  ];

  /// 简单插值：把 {key} 替换成 args[key]
  static String fmt(String template, Map<String, Object?> args) {
    var out = template;
    args.forEach((k, v) {
      out = out.replaceAll('{$k}', v?.toString() ?? '');
    });
    return out;
  }
}
