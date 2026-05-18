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
import 'locale_controller.dart';

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

  // ── 新手引导（coachmark）──
  final String onboardingNext;          // 下一步
  final String onboardingDone;          // 完成
  final String onboardingSkip;          // 跳过
  final String onboardingReplayMenu;    // 用户菜单里"再看新手引导"
  final String onboardingStep1Title;    // 设计师悬浮球
  final String onboardingStep1Body;
  final String onboardingStep2Title;    // 用户菜单
  final String onboardingStep2Body;
  final String onboardingStep3Title;    // 应用市场
  final String onboardingStep3Body;
  final String onboardingStep4Title;    // 我的 APP
  final String onboardingStep4Body;
  final String onboardingStep5Title;    // 消息
  final String onboardingStep5Body;
  // ── 配置中心熔断（remote config pause_*）──
  final String errPauseLogin;        // 服务端压力过大，请稍后重试登录
  final String errPauseRegister;     // 服务端压力过大，请稍后重试注册
  final String errPauseRequest;      // 服务端压力过大，请稍后重试

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
  final String settingsLanguageDe;
  final String settingsLanguageEs;
  final String settingsLanguageSystem;
  final String settingsAiProvider;
  final String settingsAbout;
  final String settingsVersion;

  // ── 添加到 我的 APP 弹窗 ──
  final String addToMyAppsTitle;
  final String addToMyAppsContent;
  final String addToMyAppsAdded;
  final String saveFailedWith;          // "保存失败：{msg}"

  // ── 市场删除 / 上架 / 作者 ──
  final String marketDeleteConfirmTitle;
  final String marketDeleteConfirmContent; // 含 {package}
  final String marketDeleting;
  final String marketDeleteSuccess;
  final String marketDeleteFailed;
  final String marketDeleteFailedWith;     // 含 {msg}
  final String marketUnpublishTooltip;
  final String marketAuthor;               // 含 {author}

  // ── 我的 APP 收尾 ──
  final String myAppsEmptyHint;            // 空态副提示
  final String myAppsUploadTooltip;
  final String myAppsUploading;
  final String myAppsPublishSuccess;

  // ── 发布弹窗 ──
  final String publishDialogTitle;
  final String publishCreateNamespace;
  final String publishCreateNamespaceTitle;
  final String publishNamespaceName;
  final String publishNamespaceHint;
  final String publishCreateFailed;
  final String publishInviteMember;
  final String publishNamespaceField;
  final String publishOfficialNamespace;
  final String publishPkgNameField;
  final String publishRandomGenerate;
  final String publishDescField;
  final String publishVersionField;
  final String publishTypeField;
  final String publishButton;
  final String publishPkgNameRequired;
  final String publishAppidInvalid;
  final String publishVersionInvalid;
  final String publishNamespaceRequired;
  final String publishUuidConflictTitle;
  final String publishUuidConflictContent;  // 含 {pkg}
  final String publishFailedWithCode;        // 含 {code}

  // ── 通用提示 ──
  final String create;
  final String gotIt;
  final String copy;
  final String featureInDevelopment;
  final String featureStayTuned;

  // ── 崩溃页 / 渲染错误 ──
  final String crashTitle;
  final String crashSubtitle;          // "{file} 运行崩溃"
  final String crashCopied;
  final String crashAiFix;
  final String uiRenderCrash;
  final String pageConfigNotFound;
  final String errorPathUnavailable;

  // ── 错误 / 状态 ──
  final String errorGeneric;
  final String errorNoNetwork;
  final String errorNotLoggedIn;
  final String errorNetworkWith;        // "网络错误：{msg}"
  final String errorServerWithCode;     // "服务器错误 ({code})"

  // ── IM 消息预览 / 系统消息 fallback ──
  final String imPreviewImage;
  final String imPreviewVoice;
  final String imPreviewVideo;
  final String imPreviewFile;
  final String imPreviewFileWithName;     // "[文件] {name}"
  final String imPreviewLocation;
  final String imPreviewCard;
  final String imPreviewMerger;
  final String imPreviewQuoteFallback;
  final String imPreviewEmoji;
  final String imPreviewRichTextFallback;
  final String imPreviewCustom;
  final String imPreviewAtFallback;
  final String imPreviewOA;
  final String imPreviewSystem;
  final String imPreviewBurnAfterRead;
  final String imPreviewRevoked;
  final String imPreviewUnknown;          // "[未知消息: {type}]"

  // ── IM 好友系统消息 ──
  final String imSysFriendApplyAccepted;
  final String imSysFriendApplyRejected;
  final String imSysFriendApplyReceived;
  final String imSysFriendAdded;
  final String imSysFriendDeleted;
  final String imSysFriendRemarkChanged;
  final String imSysFriendBlacklisted;
  final String imSysFriendUnblacklisted;

  // ── IM 群聊系统消息 ──
  final String imSysGroupCreated;
  final String imSysGroupInfoChanged;
  final String imSysGroupNameChanged;
  final String imSysGroupNoticeUpdated;
  final String imSysGroupApplyReceived;
  final String imSysGroupMemberQuit;
  final String imSysGroupMemberKicked;
  final String imSysGroupMemberInvited;
  final String imSysGroupMemberJoined;
  final String imSysGroupDismissed;
  final String imSysGroupOwnerTransferred;
  final String imSysGroupApplyApproved;
  final String imSysGroupApplyRejected;
  final String imSysGroupMemberMuted;
  final String imSysGroupMemberUnmuted;
  final String imSysGroupMutedAll;
  final String imSysGroupUnmutedAll;
  final String imSysGroupMemberInfoChanged;
  final String imSysGroupMemberSetAdmin;
  final String imSysGroupAdminRevoked;

  // ── IM 其他系统消息 ──
  final String imSysUserInfoUpdated;
  final String imSysConversationChanged;

  // ── IM 会话列表 ──
  final String imConversationsTitle;
  final String imContacts;
  final String imEmptyMessages;
  final String imEmptyMessagesHint;
  final String imUnknownPeer;
  final String imConfirmDeleteTitle;
  final String imDeleteConversationContent;   // "删除与 {name} 的会话？"
  final String imPin;
  final String imUnpin;
  final String imMarkRead;
  final String imDeleteConversation;

  // ── IM 时间相对 ──
  final String imTimeJustNow;
  final String imTimeMinutesAgo;          // "{n}分钟前"
  final String imTimeYesterday;
  final String imTimeDaysAgo;             // "{n}天前"

  // ── IM 聊天页 ──
  final String imGroupChat;
  final String imChatInputHint;
  final String imActionCopy;
  final String imToastCopied;
  final String imActionRevoke;
  final String imToastRevokeExpired;
  final String imAttachImage;
  final String imAttachCamera;
  final String imAttachVideo;
  final String imAttachFile;
  final String imImageExpired;
  final String imSaveToAlbum;
  final String imSaveSuccess;
  final String imSaveFailed;
  final String imCacheManageTitle;
  final String imCacheTotal;
  final String imCacheSelectAll;
  final String imCacheDeselectAll;
  final String imCacheClearSelected;
  final String imCacheClearedToast;
  final String imCacheNoSelection;
  final String imCacheLoading;
  final String imCacheEntry;

  // ── 悬浮球双击快捷菜单 ──
  final String ballMenuTitle;
  final String ballMenuRestoreSession;
  final String ballMenuRestoreSessionEmpty;
  final String ballMenuGoHome;

  // ── 默认启动 App 设置 ──
  final String defaultStartupEntry;        // 设置页入口标题
  final String defaultStartupSubtitleNone; // subtitle 没选时的占位
  final String defaultStartupTitle;        // 选择页标题
  final String defaultStartupHint;         // 选择页顶部说明
  final String defaultStartupNoneOption;   // "无（用 MyApp 首页）"
  final String defaultStartupTabMarket;
  final String defaultStartupTabLocal;
  final String defaultStartupEmptyMarket;
  final String defaultStartupEmptyLocal;
  final String defaultStartupSavedToast;
  final String defaultStartupSetAsStartup;
  final String defaultStartupCurrent;
  final String defaultStartupResetToNone;

  // ── IM 好友页 ──
  final String imAdd;
  final String imAddFriend;
  final String imCreateGroup;
  final String imMyId;
  final String imCopiedId;
  final String imNewFriends;
  final String imEmptyFriends;
  final String imEmptyFriendsHint;
  final String imDeleteFriendTitle;
  final String imDeleteFriendContent;     // "确定删除 {name}？"
  final String imApplyAccepted;
  final String imApplyRejected;
  final String imApplyPending;
  final String imEmptyApplications;
  final String imApplyDefaultMessage;
  final String imAccept;
  final String imReject;

  // ── IM 加好友搜索 ──
  final String imAddFriendDialogTitle;
  final String imAddFriendDefaultGreeting;
  final String imAddFriendNote;
  final String imSendApplication;
  final String imApplicationSent;
  final String imApplicationFailed;
  final String imSearchTitle;
  final String imSearchHint;
  final String imSearchHelp;
  final String imSearchHelpMin;
  final String imSearchNoMatch;            // 'No users matching "{q}"'
  final String imSearchNoMatchHint;
  final String imYouSelfBadge;

  // ── IM 创建群聊 ──
  final String imCreateGroupFailed;
  final String imCreateGroupTitle;
  final String imCreate;
  final String imGroupNameLabel;
  final String imGroupNameHint;
  final String imSelectMembers;
  final String imSelectedCount;            // "已选 {n} 人"
  final String imEmptyFriendsForGroupHint;

  // ── IM 群聊管理 ──
  final String imGroupSettings;
  final String imMemberCount;              // "{n} 名成员"
  final String imGroupNotice;
  final String imGroupMembers;
  final String imGroupOwnerLabel;
  final String imGroupAdminLabel;
  final String imInviteMembers;
  final String imLeaveGroup;
  final String imUserIdLabel;
  final String imUserIdHint;
  final String imInviteSent;
  final String imInviteFailedWith;         // "邀请失败: {err}"
  final String imLeaveGroupConfirmContent; // "确定退出「{name}」？"
  final String imLeaveFailedWith;          // "退出失败: {err}"
  final String imConfirmLeave;

  // ── AI 对话浮层（多会话 / 状态消息）──
  final String chatSessionDefaultTitle;     // chip / sheet 显示用："新会话"
  final String chatSessionMenuNew;          // 下拉菜单顶部："新建会话"
  final String chatSessionMenuEmpty;        // 下拉空态："暂无会话"
  final String chatSessionRenameTitle;      // 重命名 dialog 标题
  final String chatSessionRenameHint;       // 重命名 textfield hint："新标题"
  final String chatSessionActionRename;     // action sheet item："重命名"
  final String chatSessionDeleteTitle;      // 删除 dialog 标题
  final String chatSessionDeleteContent;    // 删除确认正文，{title} 占位
  final String chatStatusGenerating;        // "正在生成代码..."
  final String chatStatusStartingAi;        // "正在启动 AI 引擎..."
  final String chatStatusResumingLast;      // "正在恢复上次对话..."
  final String chatActionUploadCurrentApp;  // "上传当前应用配置"
  final String chatActionRetryDownloadJson; // "重试下载 JSON"
  final String chatTimeJustNow;             // "刚刚"
  final String chatTimeMinutesAgo;          // "{n} 分钟前"
  final String chatTimeHoursAgo;            // "{n} 小时前"
  final String chatTimeDaysAgo;             // "{n} 天前"
  final String chatDownloadStateDownloading; // "下载中..."
  final String chatDownloadStateRun;         // "下载并运行"
  final String chatDownloadStateRetry;       // "重试下载并运行"

  // ── AI 对话错误 / 编辑消息 ──
  final String chatErrorWith;                // "出错了: {err}"
  final String chatJsonDownloadFailed;       // "下载 JSON 失败"
  final String chatNoActiveApp;              // "当前没有运行的应用配置"
  final String chatUploadingApp;             // "正在上传当前应用配置..."
  final String chatDownloadRetryFailedWith;  // "下载重试失败: {err}"
  final String chatAnalysisFailedWith;       // "分析失败: {err}"
  final String chatEditMessageTitle;         // "编辑消息"
  final String chatEditMessageHint;          // "编辑你的消息..."
  final String chatEditButton;               // "编辑"
  final String chatSendButton;               // "发送"

  // ── 语音识别（ASR）──
  final String asrErrBytedanceWith;          // "豆包ASR错误: {err}"
  final String asrErrNativeInitWithHint;     // 原生语音识别初始化失败 + 建议
  final String asrConnectingBytedance;       // "正在连接豆包ASR..."
  final String asrErrBytedanceTimeoutWithHint; // 豆包ASR连接超时 + 建议
  final String asrErrNativeStartWithHint;    // 原生 ASR 启动失败 + 建议
  final String asrErrMicPermissionDenied;
  final String asrErrStartFailWith;          // "语音识别启动失败: {err}"
  final String asrErrBytedanceNotConnected;
  final String asrErrBytedanceStartFailWith;

  // ── Auth：切换账号 + service 抛错 ──
  final String authSwitchAccountCancelled;        // "已取消切换账号"
  final String authClearLocalFailedWith;          // "清除本地数据失败：{err}"
  final String authSwitchAccountTitle;            // "切换账号"
  final String authSwitchAccountContent;          // 含 {newEmail}/{prevEmail} 插值
  final String authSwitchAccountConfirm;          // "确认清除并继续"
  final String authErrSignupFailed;               // "注册失败"
  final String authErrLoginFailed;                // "登录失败"
  final String authErrVerifyFailed;               // "验证失败"
  final String authErrSendFailed;                 // "发送失败"
  final String authErrNoRefreshToken;             // "无 refresh token"
  final String authErrRefreshFailed;              // "刷新失败"
  final String authErrGetUserInfoFailed;          // "获取用户信息失败"
  final String authErrServerWith;                 // "服务器错误 ({code})"
  final String authErrUpdateFailed;               // "更新失败"
  final String authErrAvatarUploadFailed;         // "头像上传失败"

  // ── 设置页 ──
  final String settingsSectionAsr;                 // "语音识别"
  final String settingsAsrOnline;                  // "在线识别"
  final String settingsAsrOnlineSubtitle;
  final String settingsAsrBytedance;               // "豆包 ASR"
  final String settingsAsrBytedanceSubtitle;
  final String settingsProvidersFailed;            // "无法获取供应商列表"
  final String settingsProvidersFallback;          // "使用默认供应商 DeepSeek"
  final String settingsModelWith;                  // "模型: {model}"

  // ── IM 剩余字符串（im_models / chat_page / im_service push 文案）──
  final String imUserUnknown;                      // "未知"
  final String imMessageRecalled;                  // "撤回了一条消息"
  final String imAttachmentFile;                   // "文件"
  final String imImageQualityNormal;
  final String imImageQualityNormalSubtitle;
  final String imImageQualityHd;
  final String imImageQualityHdSubtitle;
  final String imDownloadingMsg;                   // "正在下载..."
  final String imDownloadFailedWith;               // "下载失败 {code}"
  final String imOpenFailedWith;                   // "打开失败：{msg}"
  final String imOpenExceptionWith;                // "打开异常：{err}"
  final String imVideoLoadFailedWith;              // "视频加载失败: {err}"
  final String imPushNewMessage;                   // "新消息"
  final String imPushImagePreview;                 // "[图片]"
  final String imMsgPreviewVideo;                  // "[视频]"
  final String imMsgPreviewVoice;                  // "[语音]"
  final String imMsgPreviewFile;                   // "[文件]"
  final String imMsgPreviewLocation;               // "[位置]"
  final String imMsgPreviewGeneric;                // "[消息]"

  // ── main 杂项 + JSON-UI 控件默认值 / 内置错误 ──
  final String mainCantResolveAppConfigError;
  final String widgetImagePickerPlaceholder;
  final String widgetImagePickerReselect;
  final String widgetCameraNoCamera;
  final String widgetDatePickerPlaceholder;
  final String widgetTimePickerPlaceholder;
  final String widgetButtonDefaultLabel;
  final String widgetMissingItemTemplate;          // "缺少 item_template"
  final String widgetDropdownPlaceholder;          // "请选择"
  final String widgetPullToRefresh;                // "下拉刷新"
  final String widgetVideoNoUrl;                   // "未配置视频地址"
  final String widgetVideoUnsupportedSource;
  final String widgetVideoPlaybackFailedWith;      // "播放失败: {err}"
  final String widgetVideoLoadFailedWith;          // 多行 "视频加载失败\n{err}"
  final String widgetVideoLoading;
  final String widgetRefNotFoundWith;              // "未找到: {ref}"
  final String widgetRefMissingFromOrName;         // "ref 控件需要 from 和 widget 字段"
  final String widgetRefMissingRootWith;           // "{ref} 缺少 root 定义"
  final String widgetUnknownTypeWith;              // "未知控件类型: {type}"
  final String widgetHttpNetworkFailed;            // "网络请求失败"

  // ── Phase 7：ai_chat_service / asr_service / game_engine / interpreter 杂项 ──
  final String chatErrNoRetryMessage;              // "没有可重试的消息"
  final String chatErrConnectionUnstableWith;      // "连接持续不稳定（已重试 {n} 次）"
  final String chatErrPleaseLogin;                 // "请先登录"
  final String chatErrServerWithBody;              // "服务器错误 ({code}): {body}"
  final String chatErrDownloadGenJsonWith;         // "下载生成的 JSON 失败 (HTTP {code})"
  final String chatErrDownloadJsonExceptionWith;
  final String chatErrCancelled;                   // "已取消"
  final String chatErrQuotaExceeded;               // "配额已用完"
  final String chatErrConnectionTimeout;           // "连接超时"
  final String chatErrNetworkWith;                 // "网络错误: {err}"
  final String chatErrUploadFailedRetriesWith;     // "上传失败（已重试 {n} 次）：{err}"
  final String chatUploadSuccessIntro;             // 上传成功后给 AI 的前置介绍语
  final String asrBytedanceConnected;              // "已连接"
  final String asrBytedanceDisconnected;           // "连接断开"
  final String asrErrUnknown;                      // "未知错误"
  final String asrBytedanceConnectFailedWith;      // "连接失败: {err}"
  final String asrErrMicPermissionDeniedShort;     // "麦克风权限未授予"
  final String asrRecordErrorWith;                 // "录音错误: {err}"
  final String asrRecording;                       // "正在录音..."
  final String asrRecordStartFailWith;             // "录音启动失败: {err}"
  final String gameOver;                           // "游戏结束"
  final String gameRestartHint;                    // "点击重新开始"
  final String gameBestScoreWith;                  // "最佳 {score}"
  final String gameScoreWith;                      // "得分 {score}"
  final String builtinBiometricDefaultReason;      // "请验证身份"
  final String builtinInputDialogDefaultTitle;     // "输入"
  final String imSenderMe;                         // "我"
  final String relativeDateYesterday;              // "昨天"
  final String depErrConflictWith;                 // "已加载 {loaded}, 需要 {needed}"

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
    required this.onboardingNext,
    required this.onboardingDone,
    required this.onboardingSkip,
    required this.onboardingReplayMenu,
    required this.onboardingStep1Title,
    required this.onboardingStep1Body,
    required this.onboardingStep2Title,
    required this.onboardingStep2Body,
    required this.onboardingStep3Title,
    required this.onboardingStep3Body,
    required this.onboardingStep4Title,
    required this.onboardingStep4Body,
    required this.onboardingStep5Title,
    required this.onboardingStep5Body,
    required this.errPauseLogin,
    required this.errPauseRegister,
    required this.errPauseRequest,
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
    required this.settingsLanguageDe,
    required this.settingsLanguageEs,
    required this.settingsLanguageSystem,
    required this.settingsAiProvider,
    required this.settingsAbout,
    required this.settingsVersion,
    required this.addToMyAppsTitle,
    required this.addToMyAppsContent,
    required this.addToMyAppsAdded,
    required this.saveFailedWith,
    required this.marketDeleteConfirmTitle,
    required this.marketDeleteConfirmContent,
    required this.marketDeleting,
    required this.marketDeleteSuccess,
    required this.marketDeleteFailed,
    required this.marketDeleteFailedWith,
    required this.marketUnpublishTooltip,
    required this.marketAuthor,
    required this.myAppsEmptyHint,
    required this.myAppsUploadTooltip,
    required this.myAppsUploading,
    required this.myAppsPublishSuccess,
    required this.publishDialogTitle,
    required this.publishCreateNamespace,
    required this.publishCreateNamespaceTitle,
    required this.publishNamespaceName,
    required this.publishNamespaceHint,
    required this.publishCreateFailed,
    required this.publishInviteMember,
    required this.publishNamespaceField,
    required this.publishOfficialNamespace,
    required this.publishPkgNameField,
    required this.publishRandomGenerate,
    required this.publishDescField,
    required this.publishVersionField,
    required this.publishTypeField,
    required this.publishButton,
    required this.publishPkgNameRequired,
    required this.publishAppidInvalid,
    required this.publishVersionInvalid,
    required this.publishNamespaceRequired,
    required this.publishUuidConflictTitle,
    required this.publishUuidConflictContent,
    required this.publishFailedWithCode,
    required this.create,
    required this.gotIt,
    required this.copy,
    required this.featureInDevelopment,
    required this.featureStayTuned,
    required this.crashTitle,
    required this.crashSubtitle,
    required this.crashCopied,
    required this.crashAiFix,
    required this.uiRenderCrash,
    required this.pageConfigNotFound,
    required this.errorPathUnavailable,
    required this.errorGeneric,
    required this.errorNoNetwork,
    required this.errorNotLoggedIn,
    required this.errorNetworkWith,
    required this.errorServerWithCode,
    required this.imPreviewImage,
    required this.imPreviewVoice,
    required this.imPreviewVideo,
    required this.imPreviewFile,
    required this.imPreviewFileWithName,
    required this.imPreviewLocation,
    required this.imPreviewCard,
    required this.imPreviewMerger,
    required this.imPreviewQuoteFallback,
    required this.imPreviewEmoji,
    required this.imPreviewRichTextFallback,
    required this.imPreviewCustom,
    required this.imPreviewAtFallback,
    required this.imPreviewOA,
    required this.imPreviewSystem,
    required this.imPreviewBurnAfterRead,
    required this.imPreviewRevoked,
    required this.imPreviewUnknown,
    required this.imSysFriendApplyAccepted,
    required this.imSysFriendApplyRejected,
    required this.imSysFriendApplyReceived,
    required this.imSysFriendAdded,
    required this.imSysFriendDeleted,
    required this.imSysFriendRemarkChanged,
    required this.imSysFriendBlacklisted,
    required this.imSysFriendUnblacklisted,
    required this.imSysGroupCreated,
    required this.imSysGroupInfoChanged,
    required this.imSysGroupNameChanged,
    required this.imSysGroupNoticeUpdated,
    required this.imSysGroupApplyReceived,
    required this.imSysGroupMemberQuit,
    required this.imSysGroupMemberKicked,
    required this.imSysGroupMemberInvited,
    required this.imSysGroupMemberJoined,
    required this.imSysGroupDismissed,
    required this.imSysGroupOwnerTransferred,
    required this.imSysGroupApplyApproved,
    required this.imSysGroupApplyRejected,
    required this.imSysGroupMemberMuted,
    required this.imSysGroupMemberUnmuted,
    required this.imSysGroupMutedAll,
    required this.imSysGroupUnmutedAll,
    required this.imSysGroupMemberInfoChanged,
    required this.imSysGroupMemberSetAdmin,
    required this.imSysGroupAdminRevoked,
    required this.imSysUserInfoUpdated,
    required this.imSysConversationChanged,
    required this.imConversationsTitle,
    required this.imContacts,
    required this.imEmptyMessages,
    required this.imEmptyMessagesHint,
    required this.imUnknownPeer,
    required this.imConfirmDeleteTitle,
    required this.imDeleteConversationContent,
    required this.imPin,
    required this.imUnpin,
    required this.imMarkRead,
    required this.imDeleteConversation,
    required this.imTimeJustNow,
    required this.imTimeMinutesAgo,
    required this.imTimeYesterday,
    required this.imTimeDaysAgo,
    required this.imGroupChat,
    required this.imChatInputHint,
    required this.imActionCopy,
    required this.imToastCopied,
    required this.imActionRevoke,
    required this.imToastRevokeExpired,
    required this.imAttachImage,
    required this.imAttachCamera,
    required this.imAttachVideo,
    required this.imAttachFile,
    required this.imImageExpired,
    required this.imSaveToAlbum,
    required this.imSaveSuccess,
    required this.imSaveFailed,
    required this.imCacheManageTitle,
    required this.imCacheTotal,
    required this.imCacheSelectAll,
    required this.imCacheDeselectAll,
    required this.imCacheClearSelected,
    required this.imCacheClearedToast,
    required this.imCacheNoSelection,
    required this.imCacheLoading,
    required this.imCacheEntry,
    required this.ballMenuTitle,
    required this.ballMenuRestoreSession,
    required this.ballMenuRestoreSessionEmpty,
    required this.ballMenuGoHome,
    required this.defaultStartupEntry,
    required this.defaultStartupSubtitleNone,
    required this.defaultStartupTitle,
    required this.defaultStartupHint,
    required this.defaultStartupNoneOption,
    required this.defaultStartupTabMarket,
    required this.defaultStartupTabLocal,
    required this.defaultStartupEmptyMarket,
    required this.defaultStartupEmptyLocal,
    required this.defaultStartupSavedToast,
    required this.defaultStartupSetAsStartup,
    required this.defaultStartupCurrent,
    required this.defaultStartupResetToNone,
    required this.imAdd,
    required this.imAddFriend,
    required this.imCreateGroup,
    required this.imMyId,
    required this.imCopiedId,
    required this.imNewFriends,
    required this.imEmptyFriends,
    required this.imEmptyFriendsHint,
    required this.imDeleteFriendTitle,
    required this.imDeleteFriendContent,
    required this.imApplyAccepted,
    required this.imApplyRejected,
    required this.imApplyPending,
    required this.imEmptyApplications,
    required this.imApplyDefaultMessage,
    required this.imAccept,
    required this.imReject,
    required this.imAddFriendDialogTitle,
    required this.imAddFriendDefaultGreeting,
    required this.imAddFriendNote,
    required this.imSendApplication,
    required this.imApplicationSent,
    required this.imApplicationFailed,
    required this.imSearchTitle,
    required this.imSearchHint,
    required this.imSearchHelp,
    required this.imSearchHelpMin,
    required this.imSearchNoMatch,
    required this.imSearchNoMatchHint,
    required this.imYouSelfBadge,
    required this.imCreateGroupFailed,
    required this.imCreateGroupTitle,
    required this.imCreate,
    required this.imGroupNameLabel,
    required this.imGroupNameHint,
    required this.imSelectMembers,
    required this.imSelectedCount,
    required this.imEmptyFriendsForGroupHint,
    required this.imGroupSettings,
    required this.imMemberCount,
    required this.imGroupNotice,
    required this.imGroupMembers,
    required this.imGroupOwnerLabel,
    required this.imGroupAdminLabel,
    required this.imInviteMembers,
    required this.imLeaveGroup,
    required this.imUserIdLabel,
    required this.imUserIdHint,
    required this.imInviteSent,
    required this.imInviteFailedWith,
    required this.imLeaveGroupConfirmContent,
    required this.imLeaveFailedWith,
    required this.imConfirmLeave,
    required this.chatSessionDefaultTitle,
    required this.chatSessionMenuNew,
    required this.chatSessionMenuEmpty,
    required this.chatSessionRenameTitle,
    required this.chatSessionRenameHint,
    required this.chatSessionActionRename,
    required this.chatSessionDeleteTitle,
    required this.chatSessionDeleteContent,
    required this.chatStatusGenerating,
    required this.chatStatusStartingAi,
    required this.chatStatusResumingLast,
    required this.chatActionUploadCurrentApp,
    required this.chatActionRetryDownloadJson,
    required this.chatTimeJustNow,
    required this.chatTimeMinutesAgo,
    required this.chatTimeHoursAgo,
    required this.chatTimeDaysAgo,
    required this.chatDownloadStateDownloading,
    required this.chatDownloadStateRun,
    required this.chatDownloadStateRetry,
    required this.chatErrorWith,
    required this.chatJsonDownloadFailed,
    required this.chatNoActiveApp,
    required this.chatUploadingApp,
    required this.chatDownloadRetryFailedWith,
    required this.chatAnalysisFailedWith,
    required this.chatEditMessageTitle,
    required this.chatEditMessageHint,
    required this.chatEditButton,
    required this.chatSendButton,
    required this.asrErrBytedanceWith,
    required this.asrErrNativeInitWithHint,
    required this.asrConnectingBytedance,
    required this.asrErrBytedanceTimeoutWithHint,
    required this.asrErrNativeStartWithHint,
    required this.asrErrMicPermissionDenied,
    required this.asrErrStartFailWith,
    required this.asrErrBytedanceNotConnected,
    required this.asrErrBytedanceStartFailWith,
    required this.authSwitchAccountCancelled,
    required this.authClearLocalFailedWith,
    required this.authSwitchAccountTitle,
    required this.authSwitchAccountContent,
    required this.authSwitchAccountConfirm,
    required this.authErrSignupFailed,
    required this.authErrLoginFailed,
    required this.authErrVerifyFailed,
    required this.authErrSendFailed,
    required this.authErrNoRefreshToken,
    required this.authErrRefreshFailed,
    required this.authErrGetUserInfoFailed,
    required this.authErrServerWith,
    required this.authErrUpdateFailed,
    required this.authErrAvatarUploadFailed,
    required this.settingsSectionAsr,
    required this.settingsAsrOnline,
    required this.settingsAsrOnlineSubtitle,
    required this.settingsAsrBytedance,
    required this.settingsAsrBytedanceSubtitle,
    required this.settingsProvidersFailed,
    required this.settingsProvidersFallback,
    required this.settingsModelWith,
    required this.imUserUnknown,
    required this.imMessageRecalled,
    required this.imAttachmentFile,
    required this.imImageQualityNormal,
    required this.imImageQualityNormalSubtitle,
    required this.imImageQualityHd,
    required this.imImageQualityHdSubtitle,
    required this.imDownloadingMsg,
    required this.imDownloadFailedWith,
    required this.imOpenFailedWith,
    required this.imOpenExceptionWith,
    required this.imVideoLoadFailedWith,
    required this.imPushNewMessage,
    required this.imPushImagePreview,
    required this.imMsgPreviewVideo,
    required this.imMsgPreviewVoice,
    required this.imMsgPreviewFile,
    required this.imMsgPreviewLocation,
    required this.imMsgPreviewGeneric,
    required this.mainCantResolveAppConfigError,
    required this.widgetImagePickerPlaceholder,
    required this.widgetImagePickerReselect,
    required this.widgetCameraNoCamera,
    required this.widgetDatePickerPlaceholder,
    required this.widgetTimePickerPlaceholder,
    required this.widgetButtonDefaultLabel,
    required this.widgetMissingItemTemplate,
    required this.widgetDropdownPlaceholder,
    required this.widgetPullToRefresh,
    required this.widgetVideoNoUrl,
    required this.widgetVideoUnsupportedSource,
    required this.widgetVideoPlaybackFailedWith,
    required this.widgetVideoLoadFailedWith,
    required this.widgetVideoLoading,
    required this.widgetRefNotFoundWith,
    required this.widgetRefMissingFromOrName,
    required this.widgetRefMissingRootWith,
    required this.widgetUnknownTypeWith,
    required this.widgetHttpNetworkFailed,
    required this.chatErrNoRetryMessage,
    required this.chatErrConnectionUnstableWith,
    required this.chatErrPleaseLogin,
    required this.chatErrServerWithBody,
    required this.chatErrDownloadGenJsonWith,
    required this.chatErrDownloadJsonExceptionWith,
    required this.chatErrCancelled,
    required this.chatErrQuotaExceeded,
    required this.chatErrConnectionTimeout,
    required this.chatErrNetworkWith,
    required this.chatErrUploadFailedRetriesWith,
    required this.chatUploadSuccessIntro,
    required this.asrBytedanceConnected,
    required this.asrBytedanceDisconnected,
    required this.asrErrUnknown,
    required this.asrBytedanceConnectFailedWith,
    required this.asrErrMicPermissionDeniedShort,
    required this.asrRecordErrorWith,
    required this.asrRecording,
    required this.asrRecordStartFailWith,
    required this.gameOver,
    required this.gameRestartHint,
    required this.gameBestScoreWith,
    required this.gameScoreWith,
    required this.builtinBiometricDefaultReason,
    required this.builtinInputDialogDefaultTitle,
    required this.imSenderMe,
    required this.relativeDateYesterday,
    required this.depErrConflictWith,
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
  onboardingNext: '下一步',
  onboardingDone: '完成',
  onboardingSkip: '跳过',
  onboardingReplayMenu: '再看新手引导',
  onboardingStep1Title: '让 AI 帮你设计 APP',
  onboardingStep1Body: '长按 3 秒进入 AI 对话——跟它说"做一个 todo list"就能生成完整 APP，还能反复改。可拖动到屏幕任意位置；双击回到上次对话。',
  onboardingStep2Title: '账号与语言',
  onboardingStep2Body: '在这里查看个人资料、切换语言，或退出登录。新手引导也能从这里再看一遍。',
  onboardingStep3Title: '应用市场',
  onboardingStep3Body: '浏览社区分享的 JSON-APP，一键下载试用。',
  onboardingStep4Title: '我的 APP',
  onboardingStep4Body: '你保存或 AI 生成过的 APP 都在这里，离线也能用。',
  onboardingStep5Title: '私信',
  onboardingStep5Body: '和好友、客服、小组聊天，支持文字、图片、表情。',
  errPauseLogin: '服务端压力过大，请稍后重试登录',
  errPauseRegister: '服务端压力过大，请稍后重试注册',
  errPauseRequest: '服务端压力过大，请稍后重试',
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
  settingsLanguageDe: 'Deutsch',
  settingsLanguageEs: 'Español',
  settingsLanguageSystem: '跟随系统',
  settingsAiProvider: 'AI 服务商',
  settingsAbout: '关于',
  settingsVersion: '版本',
  addToMyAppsTitle: '添加到我的 APP',
  addToMyAppsContent: '是否将此应用添加到"我的 APP"列表？\n\n添加后可以方便地复用和发布到市场。',
  addToMyAppsAdded: '已添加到我的 APP',
  saveFailedWith: '保存失败：{msg}',
  marketDeleteConfirmTitle: '确认下架',
  marketDeleteConfirmContent: '确定要永久删除包 "{package}" 吗？\n\n此操作不可撤销，将删除所有版本。',
  marketDeleting: '正在删除…',
  marketDeleteSuccess: '删除成功',
  marketDeleteFailed: '删除失败',
  marketDeleteFailedWith: '删除失败：{msg}',
  marketUnpublishTooltip: '下架',
  marketAuthor: '作者：{author}',
  myAppsEmptyHint: '长按悬浮球，用语音让 AI 帮你生成',
  myAppsUploadTooltip: '上传到市场',
  myAppsUploading: '正在上传到市场…',
  myAppsPublishSuccess: '发布成功 🎉',
  publishDialogTitle: '发布到市场',
  publishCreateNamespace: '创建空间',
  publishCreateNamespaceTitle: '创建命名空间',
  publishNamespaceName: '空间名称',
  publishNamespaceHint: '小写字母、数字、- 和 _',
  publishCreateFailed: '创建失败',
  publishInviteMember: '邀请成员',
  publishNamespaceField: '项目空间',
  publishOfficialNamespace: '(官方/无空间)',
  publishPkgNameField: '包名',
  publishRandomGenerate: '随机生成',
  publishDescField: '描述',
  publishVersionField: '版本号',
  publishTypeField: '类型',
  publishButton: '发布',
  publishPkgNameRequired: '包名不能为空',
  publishAppidInvalid: 'AppID 必须是有效的 UUID 格式',
  publishVersionInvalid: '版本号必须是 x.y.z 格式',
  publishNamespaceRequired: '请选择命名空间或创建一个新空间',
  publishUuidConflictTitle: 'UUID 冲突',
  publishUuidConflictContent: '该 UUID 已被包 "{pkg}" 使用。\n请点击「随机生成 🎲」获取新的 UUID 后重试。',
  publishFailedWithCode: '发布失败 ({code})',
  create: '创建',
  gotIt: '知道了',
  copy: '复制',
  featureInDevelopment: '此功能正在开发中',
  featureStayTuned: '敬请期待！',
  crashTitle: '运行出错',
  crashSubtitle: '{file} 运行崩溃',
  crashCopied: '崩溃信息已复制',
  crashAiFix: 'AI 分析修复',
  uiRenderCrash: 'UI 渲染/布局崩溃',
  pageConfigNotFound: '未找到页面配置',
  errorPathUnavailable: '无法获取文件路径',
  errorGeneric: '出错了',
  errorNoNetwork: '无网络连接',
  errorNotLoggedIn: '未登录',
  errorNetworkWith: '网络错误：{msg}',
  errorServerWithCode: '服务器错误 ({code})',
  imPreviewImage: '[图片]',
  imPreviewVoice: '[语音]',
  imPreviewVideo: '[视频]',
  imPreviewFile: '[文件]',
  imPreviewFileWithName: '[文件] {name}',
  imPreviewLocation: '[位置]',
  imPreviewCard: '[名片]',
  imPreviewMerger: '[聊天记录]',
  imPreviewQuoteFallback: '[引用]',
  imPreviewEmoji: '[表情]',
  imPreviewRichTextFallback: '[富文本]',
  imPreviewCustom: '[自定义消息]',
  imPreviewAtFallback: '[@消息]',
  imPreviewOA: '[OA 通知]',
  imPreviewSystem: '[系统通知]',
  imPreviewBurnAfterRead: '[阅后即焚]',
  imPreviewRevoked: '撤回了一条消息',
  imPreviewUnknown: '[未知消息: {type}]',
  imSysFriendApplyAccepted: '对方同意了你的好友申请',
  imSysFriendApplyRejected: '对方拒绝了你的好友申请',
  imSysFriendApplyReceived: '收到一条好友申请',
  imSysFriendAdded: '你们已经是好友了，可以聊天了',
  imSysFriendDeleted: '你们的好友关系已解除',
  imSysFriendRemarkChanged: '好友备注已修改',
  imSysFriendBlacklisted: '已加入黑名单',
  imSysFriendUnblacklisted: '已移出黑名单',
  imSysGroupCreated: '群聊已创建',
  imSysGroupInfoChanged: '群信息已修改',
  imSysGroupNameChanged: '群名已修改',
  imSysGroupNoticeUpdated: '群公告已更新',
  imSysGroupApplyReceived: '收到一条入群申请',
  imSysGroupMemberQuit: '有成员退出群聊',
  imSysGroupMemberKicked: '有成员被移出群聊',
  imSysGroupMemberInvited: '有成员被邀请入群',
  imSysGroupMemberJoined: '有成员加入群聊',
  imSysGroupDismissed: '群聊已解散',
  imSysGroupOwnerTransferred: '群主已转让',
  imSysGroupApplyApproved: '入群申请已通过',
  imSysGroupApplyRejected: '入群申请已被拒绝',
  imSysGroupMemberMuted: '成员被禁言',
  imSysGroupMemberUnmuted: '成员禁言已解除',
  imSysGroupMutedAll: '全员禁言',
  imSysGroupUnmutedAll: '全员禁言已解除',
  imSysGroupMemberInfoChanged: '成员信息变更',
  imSysGroupMemberSetAdmin: '成员被设为管理员',
  imSysGroupAdminRevoked: '管理员已恢复为普通成员',
  imSysUserInfoUpdated: '用户资料已更新',
  imSysConversationChanged: '会话已变更',
  imConversationsTitle: '消息',
  imContacts: '通讯录',
  imEmptyMessages: '暂无消息',
  imEmptyMessagesHint: '开始一段对话吧',
  imUnknownPeer: '未知',
  imConfirmDeleteTitle: '确认删除',
  imDeleteConversationContent: '删除与 {name} 的会话？',
  imPin: '置顶',
  imUnpin: '取消置顶',
  imMarkRead: '标记已读',
  imDeleteConversation: '删除会话',
  imTimeJustNow: '刚刚',
  imTimeMinutesAgo: '{n}分钟前',
  imTimeYesterday: '昨天',
  imTimeDaysAgo: '{n}天前',
  imGroupChat: '群聊',
  imChatInputHint: '输入消息...',
  imActionCopy: '复制',
  imToastCopied: '已复制',
  imActionRevoke: '撤回',
  imToastRevokeExpired: '超过 2 分钟无法撤回',
  imAttachImage: '图片',
  imAttachCamera: '拍照',
  imAttachVideo: '视频',
  imAttachFile: '文件',
  imImageExpired: '图片已过期',
  imSaveToAlbum: '保存到相册',
  imSaveSuccess: '已保存',
  imSaveFailed: '保存失败',
  imCacheManageTitle: '聊天图片缓存管理',
  imCacheTotal: '总计 {size}',
  imCacheSelectAll: '全选',
  imCacheDeselectAll: '取消全选',
  imCacheClearSelected: '清理选中',
  imCacheClearedToast: '已清理 {size}',
  imCacheNoSelection: '请先选择会话',
  imCacheLoading: '正在统计…',
  imCacheEntry: '聊天图片缓存',
  ballMenuTitle: '快捷菜单',
  ballMenuRestoreSession: '恢复会话',
  ballMenuRestoreSessionEmpty: '没有历史会话',
  ballMenuGoHome: '回到主页',
  defaultStartupEntry: '默认启动 App',
  defaultStartupSubtitleNone: '未设置（启动到 MyApp 首页）',
  defaultStartupTitle: '默认启动 App',
  defaultStartupHint: '设置后，打开 App 会直接进入选中的应用；通过悬浮球菜单"回到主页"返回 MyApp 首页',
  defaultStartupNoneOption: '不设置（启动到 MyApp 首页）',
  defaultStartupTabMarket: '市场',
  defaultStartupTabLocal: '本地',
  defaultStartupEmptyMarket: '市场暂无 App',
  defaultStartupEmptyLocal: '本地还没有保存的 App',
  defaultStartupSavedToast: '已设置',
  defaultStartupSetAsStartup: '设为启动 App',
  defaultStartupCurrent: '当前启动 App',
  defaultStartupResetToNone: '取消设置',
  imAdd: '添加',
  imAddFriend: '加好友',
  imCreateGroup: '建群',
  imMyId: '我的 ID:',
  imCopiedId: '已复制 ID',
  imNewFriends: '新的朋友',
  imEmptyFriends: '还没有好友',
  imEmptyFriendsHint: '点右上角 + 加好友',
  imDeleteFriendTitle: '删除好友',
  imDeleteFriendContent: '确定删除 {name}？',
  imApplyAccepted: '已同意',
  imApplyRejected: '已拒绝',
  imApplyPending: '待处理',
  imEmptyApplications: '还没有人申请加你',
  imApplyDefaultMessage: '请求加你为好友',
  imAccept: '同意',
  imReject: '拒绝',
  imAddFriendDialogTitle: '发送好友申请',
  imAddFriendDefaultGreeting: '我想加你为好友',
  imAddFriendNote: '附言',
  imSendApplication: '发送申请',
  imApplicationSent: '申请已发送，等对方同意',
  imApplicationFailed: '申请发送失败',
  imSearchTitle: '加好友',
  imSearchHint: '邮箱 / 用户名 / ID 都可以搜',
  imSearchHelp: '输入邮箱、用户名或 ID 搜索',
  imSearchHelpMin: '至少输入 2 个字符',
  imSearchNoMatch: '没找到匹配 "{q}" 的用户',
  imSearchNoMatchHint: '对方需要先在 app 里注册',
  imYouSelfBadge: '（你自己）',
  imCreateGroupFailed: '创建群聊失败，请重试',
  imCreateGroupTitle: '创建群聊',
  imCreate: '创建',
  imGroupNameLabel: '群名称',
  imGroupNameHint: '给群聊起个名字',
  imSelectMembers: '选择成员',
  imSelectedCount: '已选 {n} 人',
  imEmptyFriendsForGroupHint: '要先加几个好友才能建群',
  imGroupSettings: '群聊设置',
  imMemberCount: '{n} 名成员',
  imGroupNotice: '群公告',
  imGroupMembers: '群成员',
  imGroupOwnerLabel: '群主',
  imGroupAdminLabel: '管理员',
  imInviteMembers: '邀请成员',
  imLeaveGroup: '退出群聊',
  imUserIdLabel: '用户 ID',
  imUserIdHint: '输入要邀请的用户 ID',
  imInviteSent: '邀请已发送',
  imInviteFailedWith: '邀请失败: {err}',
  imLeaveGroupConfirmContent: '确定退出「{name}」？',
  imLeaveFailedWith: '退出失败: {err}',
  imConfirmLeave: '确定退出',
  chatSessionDefaultTitle: '新会话',
  chatSessionMenuNew: '新建会话',
  chatSessionMenuEmpty: '暂无会话',
  chatSessionRenameTitle: '重命名会话',
  chatSessionRenameHint: '新标题',
  chatSessionActionRename: '重命名',
  chatSessionDeleteTitle: '删除会话',
  chatSessionDeleteContent: '删除「{title}」？后台正在跑的回答也会被中止。',
  chatStatusGenerating: '正在生成代码...',
  chatStatusStartingAi: '正在启动 AI 引擎...',
  chatStatusResumingLast: '正在恢复上次对话...',
  chatActionUploadCurrentApp: '上传当前应用配置',
  chatActionRetryDownloadJson: '重试下载 JSON',
  chatTimeJustNow: '刚刚',
  chatTimeMinutesAgo: '{n} 分钟前',
  chatTimeHoursAgo: '{n} 小时前',
  chatTimeDaysAgo: '{n} 天前',
  chatDownloadStateDownloading: '下载中...',
  chatDownloadStateRun: '下载并运行',
  chatDownloadStateRetry: '重试下载并运行',
  chatErrorWith: '出错了: {err}',
  chatJsonDownloadFailed: '下载 JSON 失败',
  chatNoActiveApp: '当前没有运行的应用配置',
  chatUploadingApp: '正在上传当前应用配置...',
  chatDownloadRetryFailedWith: '下载重试失败: {err}',
  chatAnalysisFailedWith: '分析失败: {err}',
  chatEditMessageTitle: '编辑消息',
  chatEditMessageHint: '编辑你的消息...',
  chatEditButton: '编辑',
  chatSendButton: '发送',
  asrErrBytedanceWith: '豆包ASR错误: {err}',
  asrErrNativeInitWithHint: '原生语音识别初始化失败，请在设置中切换到豆包ASR',
  asrConnectingBytedance: '正在连接豆包ASR...',
  asrErrBytedanceTimeoutWithHint: '豆包ASR连接超时，请检查网络或切换到其他识别方式',
  asrErrNativeStartWithHint: '原生语音识别启动失败，请在设置中切换到豆包ASR',
  asrErrMicPermissionDenied: '麦克风权限未授予，请在手机「设置 → 应用 → 权限」中开启麦克风权限后重试',
  asrErrStartFailWith: '语音识别启动失败: {err}',
  asrErrBytedanceNotConnected: '豆包ASR未连接，请检查网络',
  asrErrBytedanceStartFailWith: '豆包ASR启动失败: {err}',
  authSwitchAccountCancelled: '已取消切换账号',
  authClearLocalFailedWith: '清除本地数据失败：{err}',
  authSwitchAccountTitle: '切换账号',
  authSwitchAccountContent: '检测到本次登录的账号（{newEmail}）与上次（{prevEmail}）不一致。\n\n继续将清除本地所有聊天记录、通讯录与本地数据，是否继续？',
  authSwitchAccountConfirm: '确认清除并继续',
  authErrSignupFailed: '注册失败',
  authErrLoginFailed: '登录失败',
  authErrVerifyFailed: '验证失败',
  authErrSendFailed: '发送失败',
  authErrNoRefreshToken: '无 refresh token',
  authErrRefreshFailed: '刷新失败',
  authErrGetUserInfoFailed: '获取用户信息失败',
  authErrServerWith: '服务器错误 ({code})',
  authErrUpdateFailed: '更新失败',
  authErrAvatarUploadFailed: '头像上传失败',
  settingsSectionAsr: '语音识别',
  settingsAsrOnline: '在线识别',
  settingsAsrOnlineSubtitle: '使用 speech_to_text，需要网络连接',
  settingsAsrBytedance: '豆包 ASR',
  settingsAsrBytedanceSubtitle: '字节跳动语音识别，需要网络和配额',
  settingsProvidersFailed: '无法获取供应商列表',
  settingsProvidersFallback: '使用默认供应商 DeepSeek',
  settingsModelWith: '模型: {model}',
  imUserUnknown: '未知',
  imMessageRecalled: '撤回了一条消息',
  imAttachmentFile: '文件',
  imImageQualityNormal: '普通画质',
  imImageQualityNormalSubtitle: '自动压缩，长边 1920，发送更快',
  imImageQualityHd: '高清原图',
  imImageQualityHdSubtitle: '保留原尺寸和画质',
  imDownloadingMsg: '正在下载...',
  imDownloadFailedWith: '下载失败 {code}',
  imOpenFailedWith: '打开失败：{msg}',
  imOpenExceptionWith: '打开异常：{err}',
  imVideoLoadFailedWith: '视频加载失败: {err}',
  imPushNewMessage: '新消息',
  imPushImagePreview: '[图片]',
  imMsgPreviewVideo: '[视频]',
  imMsgPreviewVoice: '[语音]',
  imMsgPreviewFile: '[文件]',
  imMsgPreviewLocation: '[位置]',
  imMsgPreviewGeneric: '[消息]',
  mainCantResolveAppConfigError: '无法解析或下载该应用配置',
  widgetImagePickerPlaceholder: '点击选择图片',
  widgetImagePickerReselect: '点击重新选择',
  widgetCameraNoCamera: '无可用相机',
  widgetDatePickerPlaceholder: '请选择日期',
  widgetTimePickerPlaceholder: '请选择时间',
  widgetButtonDefaultLabel: '按钮',
  widgetMissingItemTemplate: '缺少 item_template',
  widgetDropdownPlaceholder: '请选择',
  widgetPullToRefresh: '下拉刷新',
  widgetVideoNoUrl: '未配置视频地址',
  widgetVideoUnsupportedSource: '不支持的视频来源',
  widgetVideoPlaybackFailedWith: '播放失败: {err}',
  widgetVideoLoadFailedWith: '视频加载失败\n{err}',
  widgetVideoLoading: '视频加载中...',
  widgetRefNotFoundWith: '未找到: {ref}',
  widgetRefMissingFromOrName: 'ref 控件需要 from 和 widget 字段',
  widgetRefMissingRootWith: '{ref} 缺少 root 定义',
  widgetUnknownTypeWith: '未知控件类型: {type}',
  widgetHttpNetworkFailed: '网络请求失败',
  chatErrNoRetryMessage: '没有可重试的消息',
  chatErrConnectionUnstableWith: '连接持续不稳定（已重试 {n} 次）',
  chatErrPleaseLogin: '请先登录',
  chatErrServerWithBody: '服务器错误 ({code}): {body}',
  chatErrDownloadGenJsonWith: '下载生成的 JSON 失败 (HTTP {code})',
  chatErrDownloadJsonExceptionWith: '下载 JSON 异常: {err}',
  chatErrCancelled: '已取消',
  chatErrQuotaExceeded: '配额已用完',
  chatErrConnectionTimeout: '连接超时',
  chatErrNetworkWith: '网络错误: {err}',
  chatErrUploadFailedRetriesWith: '上传失败（已重试 {n} 次）：{err}',
  chatUploadSuccessIntro: '以下是我当前正在运行的 JSON-APP 完整配置（已上传至临时存储），后续对话请基于这个配置进行修改或分析：\n\n',
  asrBytedanceConnected: '已连接',
  asrBytedanceDisconnected: '连接断开',
  asrErrUnknown: '未知错误',
  asrBytedanceConnectFailedWith: '连接失败: {err}',
  asrErrMicPermissionDeniedShort: '麦克风权限未授予',
  asrRecordErrorWith: '录音错误: {err}',
  asrRecording: '正在录音...',
  asrRecordStartFailWith: '录音启动失败: {err}',
  gameOver: '游戏结束',
  gameRestartHint: '点击重新开始',
  gameBestScoreWith: '最佳 {score}',
  gameScoreWith: '得分 {score}',
  builtinBiometricDefaultReason: '请验证身份',
  builtinInputDialogDefaultTitle: '输入',
  imSenderMe: '我',
  relativeDateYesterday: '昨天',
  depErrConflictWith: '已加载 {loaded}, 需要 {needed}',
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
  onboardingNext: 'Next',
  onboardingDone: 'Done',
  onboardingSkip: 'Skip',
  onboardingReplayMenu: 'Replay onboarding',
  onboardingStep1Title: 'Design apps with AI',
  onboardingStep1Body: 'Long-press for ~3s to open AI chat—say "make me a todo list" and get a working app you can keep iterating on. Drag anywhere to move; double-tap to resume the last conversation.',
  onboardingStep2Title: 'Account & language',
  onboardingStep2Body: 'View your profile, switch language, or sign out here. You can also replay this onboarding from this menu.',
  onboardingStep3Title: 'App marketplace',
  onboardingStep3Body: 'Browse community JSON apps and try them in one tap.',
  onboardingStep4Title: 'My apps',
  onboardingStep4Body: 'All your saved or AI-generated apps live here, also available offline.',
  onboardingStep5Title: 'Messages',
  onboardingStep5Body: 'Chat with friends, support, or groups. Supports text, images and emoji.',
  errPauseLogin: 'Server is busy, please try signing in again later',
  errPauseRegister: 'Server is busy, please try signing up again later',
  errPauseRequest: 'Server is busy, please try again later',
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
  settingsLanguageDe: 'Deutsch',
  settingsLanguageEs: 'Español',
  settingsLanguageSystem: 'System',
  settingsAiProvider: 'AI provider',
  settingsAbout: 'About',
  settingsVersion: 'Version',
  addToMyAppsTitle: 'Add to My Apps',
  addToMyAppsContent: 'Add this app to "My Apps"?\n\nYou can then reuse it and publish it to the marketplace.',
  addToMyAppsAdded: 'Added to My Apps',
  saveFailedWith: 'Save failed: {msg}',
  marketDeleteConfirmTitle: 'Confirm unpublish',
  marketDeleteConfirmContent: 'Permanently delete package "{package}"?\n\nThis cannot be undone — all versions will be removed.',
  marketDeleting: 'Deleting…',
  marketDeleteSuccess: 'Deleted',
  marketDeleteFailed: 'Delete failed',
  marketDeleteFailedWith: 'Delete failed: {msg}',
  marketUnpublishTooltip: 'Unpublish',
  marketAuthor: 'Author: {author}',
  myAppsEmptyHint: 'Long-press the floating button and speak — AI will generate one',
  myAppsUploadTooltip: 'Upload to marketplace',
  myAppsUploading: 'Uploading to marketplace…',
  myAppsPublishSuccess: 'Published 🎉',
  publishDialogTitle: 'Publish to marketplace',
  publishCreateNamespace: 'Create namespace',
  publishCreateNamespaceTitle: 'Create namespace',
  publishNamespaceName: 'Namespace',
  publishNamespaceHint: 'Lowercase letters, digits, - and _',
  publishCreateFailed: 'Create failed',
  publishInviteMember: 'Invite member',
  publishNamespaceField: 'Namespace',
  publishOfficialNamespace: '(Official / no namespace)',
  publishPkgNameField: 'Package name',
  publishRandomGenerate: 'Random',
  publishDescField: 'Description',
  publishVersionField: 'Version',
  publishTypeField: 'Type',
  publishButton: 'Publish',
  publishPkgNameRequired: 'Package name is required',
  publishAppidInvalid: 'AppID must be a valid UUID',
  publishVersionInvalid: 'Version must follow x.y.z',
  publishNamespaceRequired: 'Pick or create a namespace',
  publishUuidConflictTitle: 'UUID conflict',
  publishUuidConflictContent: 'This UUID is already used by package "{pkg}".\nClick "Random 🎲" to generate a new one and retry.',
  publishFailedWithCode: 'Publish failed ({code})',
  create: 'Create',
  gotIt: 'Got it',
  copy: 'Copy',
  featureInDevelopment: 'This feature is under development',
  featureStayTuned: 'Stay tuned!',
  crashTitle: 'Runtime error',
  crashSubtitle: '{file} crashed',
  crashCopied: 'Crash info copied',
  crashAiFix: 'AI fix',
  uiRenderCrash: 'UI render / layout crash',
  pageConfigNotFound: 'Page config not found',
  errorPathUnavailable: 'Could not resolve file path',
  errorGeneric: 'Something went wrong',
  errorNoNetwork: 'No network',
  errorNotLoggedIn: 'Not signed in',
  errorNetworkWith: 'Network error: {msg}',
  errorServerWithCode: 'Server error ({code})',
  imPreviewImage: '[Image]',
  imPreviewVoice: '[Voice]',
  imPreviewVideo: '[Video]',
  imPreviewFile: '[File]',
  imPreviewFileWithName: '[File] {name}',
  imPreviewLocation: '[Location]',
  imPreviewCard: '[Card]',
  imPreviewMerger: '[Forwarded chat]',
  imPreviewQuoteFallback: '[Quote]',
  imPreviewEmoji: '[Sticker]',
  imPreviewRichTextFallback: '[Rich text]',
  imPreviewCustom: '[Custom message]',
  imPreviewAtFallback: '[Mention]',
  imPreviewOA: '[OA notice]',
  imPreviewSystem: '[System notice]',
  imPreviewBurnAfterRead: '[Burn after read]',
  imPreviewRevoked: 'recalled a message',
  imPreviewUnknown: '[Unknown message: {type}]',
  imSysFriendApplyAccepted: 'Your friend request was accepted',
  imSysFriendApplyRejected: 'Your friend request was declined',
  imSysFriendApplyReceived: 'New friend request received',
  imSysFriendAdded: "You're now friends. Say hi!",
  imSysFriendDeleted: 'Your friendship has ended',
  imSysFriendRemarkChanged: 'Friend remark updated',
  imSysFriendBlacklisted: 'Added to blacklist',
  imSysFriendUnblacklisted: 'Removed from blacklist',
  imSysGroupCreated: 'Group created',
  imSysGroupInfoChanged: 'Group info updated',
  imSysGroupNameChanged: 'Group name changed',
  imSysGroupNoticeUpdated: 'Group notice updated',
  imSysGroupApplyReceived: 'New join request',
  imSysGroupMemberQuit: 'A member left the group',
  imSysGroupMemberKicked: 'A member was removed',
  imSysGroupMemberInvited: 'A member was invited',
  imSysGroupMemberJoined: 'A new member joined',
  imSysGroupDismissed: 'The group was dismissed',
  imSysGroupOwnerTransferred: 'Group ownership transferred',
  imSysGroupApplyApproved: 'Join request approved',
  imSysGroupApplyRejected: 'Join request rejected',
  imSysGroupMemberMuted: 'A member was muted',
  imSysGroupMemberUnmuted: 'A member was unmuted',
  imSysGroupMutedAll: 'All members muted',
  imSysGroupUnmutedAll: 'All members unmuted',
  imSysGroupMemberInfoChanged: "A member's info changed",
  imSysGroupMemberSetAdmin: 'A member was made admin',
  imSysGroupAdminRevoked: 'An admin was demoted',
  imSysUserInfoUpdated: 'Profile updated',
  imSysConversationChanged: 'Conversation changed',
  imConversationsTitle: 'Messages',
  imContacts: 'Contacts',
  imEmptyMessages: 'No messages yet',
  imEmptyMessagesHint: 'Start a conversation',
  imUnknownPeer: 'Unknown',
  imConfirmDeleteTitle: 'Confirm delete',
  imDeleteConversationContent: 'Delete conversation with {name}?',
  imPin: 'Pin',
  imUnpin: 'Unpin',
  imMarkRead: 'Mark as read',
  imDeleteConversation: 'Delete conversation',
  imTimeJustNow: 'Just now',
  imTimeMinutesAgo: '{n}m ago',
  imTimeYesterday: 'Yesterday',
  imTimeDaysAgo: '{n}d ago',
  imGroupChat: 'Group',
  imChatInputHint: 'Type a message...',
  imActionCopy: 'Copy',
  imToastCopied: 'Copied',
  imActionRevoke: 'Recall',
  imToastRevokeExpired: 'Cannot recall after 2 minutes',
  imAttachImage: 'Image',
  imAttachCamera: 'Camera',
  imAttachVideo: 'Video',
  imAttachFile: 'File',
  imImageExpired: 'Image expired',
  imSaveToAlbum: 'Save to album',
  imSaveSuccess: 'Saved',
  imSaveFailed: 'Save failed',
  imCacheManageTitle: 'Chat media cache',
  imCacheTotal: 'Total {size}',
  imCacheSelectAll: 'Select all',
  imCacheDeselectAll: 'Deselect all',
  imCacheClearSelected: 'Clear selected',
  imCacheClearedToast: 'Cleared {size}',
  imCacheNoSelection: 'Select at least one conversation',
  imCacheLoading: 'Calculating…',
  imCacheEntry: 'Chat media cache',
  ballMenuTitle: 'Quick menu',
  ballMenuRestoreSession: 'Restore session',
  ballMenuRestoreSessionEmpty: 'No previous session',
  ballMenuGoHome: 'Back to home',
  defaultStartupEntry: 'Default startup app',
  defaultStartupSubtitleNone: 'Not set (open to MyApp home)',
  defaultStartupTitle: 'Default startup app',
  defaultStartupHint: 'When set, the app launches directly into your chosen app. Use the floating ball menu "Back to home" to return to MyApp home.',
  defaultStartupNoneOption: 'Unset (open to MyApp home)',
  defaultStartupTabMarket: 'Market',
  defaultStartupTabLocal: 'Local',
  defaultStartupEmptyMarket: 'No apps in market yet',
  defaultStartupEmptyLocal: 'No saved local apps yet',
  defaultStartupSavedToast: 'Saved',
  defaultStartupSetAsStartup: 'Set as startup',
  defaultStartupCurrent: 'Current startup',
  defaultStartupResetToNone: 'Reset',
  imAdd: 'Add',
  imAddFriend: 'Add friend',
  imCreateGroup: 'New group',
  imMyId: 'My ID:',
  imCopiedId: 'ID copied',
  imNewFriends: 'New requests',
  imEmptyFriends: 'No friends yet',
  imEmptyFriendsHint: 'Tap + at the top to add friends',
  imDeleteFriendTitle: 'Delete friend',
  imDeleteFriendContent: 'Delete {name}?',
  imApplyAccepted: 'Accepted',
  imApplyRejected: 'Rejected',
  imApplyPending: 'Pending',
  imEmptyApplications: 'No incoming requests',
  imApplyDefaultMessage: 'Wants to be your friend',
  imAccept: 'Accept',
  imReject: 'Reject',
  imAddFriendDialogTitle: 'Send friend request',
  imAddFriendDefaultGreeting: "Hi, I'd like to add you",
  imAddFriendNote: 'Message',
  imSendApplication: 'Send',
  imApplicationSent: 'Request sent. Waiting for approval.',
  imApplicationFailed: 'Failed to send request',
  imSearchTitle: 'Add friend',
  imSearchHint: 'Search by email, username, or ID',
  imSearchHelp: 'Enter email, username, or ID to search',
  imSearchHelpMin: 'Type at least 2 characters',
  imSearchNoMatch: 'No users matching "{q}"',
  imSearchNoMatchHint: 'They need to sign up first',
  imYouSelfBadge: '(you)',
  imCreateGroupFailed: 'Failed to create group. Please retry.',
  imCreateGroupTitle: 'New group',
  imCreate: 'Create',
  imGroupNameLabel: 'Group name',
  imGroupNameHint: 'Give the group a name',
  imSelectMembers: 'Pick members',
  imSelectedCount: '{n} selected',
  imEmptyFriendsForGroupHint: 'Add some friends first',
  imGroupSettings: 'Group settings',
  imMemberCount: '{n} members',
  imGroupNotice: 'Group notice',
  imGroupMembers: 'Members',
  imGroupOwnerLabel: 'Owner',
  imGroupAdminLabel: 'Admin',
  imInviteMembers: 'Invite members',
  imLeaveGroup: 'Leave group',
  imUserIdLabel: 'User ID',
  imUserIdHint: 'User ID to invite',
  imInviteSent: 'Invitation sent',
  imInviteFailedWith: 'Invite failed: {err}',
  imLeaveGroupConfirmContent: 'Leave "{name}"?',
  imLeaveFailedWith: 'Leave failed: {err}',
  imConfirmLeave: 'Confirm leave',
  chatSessionDefaultTitle: 'New chat',
  chatSessionMenuNew: 'New chat',
  chatSessionMenuEmpty: 'No chats yet',
  chatSessionRenameTitle: 'Rename chat',
  chatSessionRenameHint: 'New title',
  chatSessionActionRename: 'Rename',
  chatSessionDeleteTitle: 'Delete chat',
  chatSessionDeleteContent: 'Delete "{title}"? The reply still running in the background will be aborted.',
  chatStatusGenerating: 'Generating code...',
  chatStatusStartingAi: 'Starting AI engine...',
  chatStatusResumingLast: 'Resuming last conversation...',
  chatActionUploadCurrentApp: 'Upload current app config',
  chatActionRetryDownloadJson: 'Retry downloading JSON',
  chatTimeJustNow: 'just now',
  chatTimeMinutesAgo: '{n} min ago',
  chatTimeHoursAgo: '{n} h ago',
  chatTimeDaysAgo: '{n} d ago',
  chatDownloadStateDownloading: 'Downloading...',
  chatDownloadStateRun: 'Download & run',
  chatDownloadStateRetry: 'Retry download & run',
  chatErrorWith: 'Error: {err}',
  chatJsonDownloadFailed: 'Failed to download JSON',
  chatNoActiveApp: 'No running app config right now',
  chatUploadingApp: 'Uploading current app config...',
  chatDownloadRetryFailedWith: 'Download retry failed: {err}',
  chatAnalysisFailedWith: 'Analysis failed: {err}',
  chatEditMessageTitle: 'Edit message',
  chatEditMessageHint: 'Edit your message...',
  chatEditButton: 'Edit',
  chatSendButton: 'Send',
  asrErrBytedanceWith: 'ByteDance ASR error: {err}',
  asrErrNativeInitWithHint: 'Native speech recognition failed to initialize. Try switching to ByteDance ASR in settings.',
  asrConnectingBytedance: 'Connecting to ByteDance ASR...',
  asrErrBytedanceTimeoutWithHint: 'ByteDance ASR connection timeout. Check the network or switch to another recognizer.',
  asrErrNativeStartWithHint: 'Native speech recognition failed to start. Try switching to ByteDance ASR in settings.',
  asrErrMicPermissionDenied: 'Microphone permission denied. Enable it in Settings → Apps → Permissions and try again.',
  asrErrStartFailWith: 'Speech recognition failed to start: {err}',
  asrErrBytedanceNotConnected: 'ByteDance ASR is not connected. Check the network.',
  asrErrBytedanceStartFailWith: 'ByteDance ASR failed to start: {err}',
  authSwitchAccountCancelled: 'Account switch cancelled',
  authClearLocalFailedWith: 'Failed to clear local data: {err}',
  authSwitchAccountTitle: 'Switch account',
  authSwitchAccountContent: 'The signed-in account ({newEmail}) differs from the previous one ({prevEmail}).\n\nContinuing will wipe all local chat history, contacts and local data. Continue?',
  authSwitchAccountConfirm: 'Wipe and continue',
  authErrSignupFailed: 'Sign-up failed',
  authErrLoginFailed: 'Login failed',
  authErrVerifyFailed: 'Verification failed',
  authErrSendFailed: 'Send failed',
  authErrNoRefreshToken: 'No refresh token',
  authErrRefreshFailed: 'Refresh failed',
  authErrGetUserInfoFailed: 'Failed to fetch user info',
  authErrServerWith: 'Server error ({code})',
  authErrUpdateFailed: 'Update failed',
  authErrAvatarUploadFailed: 'Avatar upload failed',
  settingsSectionAsr: 'Speech recognition',
  settingsAsrOnline: 'Online recognition',
  settingsAsrOnlineSubtitle: 'Uses speech_to_text, requires network',
  settingsAsrBytedance: 'ByteDance ASR',
  settingsAsrBytedanceSubtitle: 'ByteDance speech recognition, requires network and quota',
  settingsProvidersFailed: 'Failed to fetch providers',
  settingsProvidersFallback: 'Falling back to default provider DeepSeek',
  settingsModelWith: 'Model: {model}',
  imUserUnknown: 'Unknown',
  imMessageRecalled: 'recalled a message',
  imAttachmentFile: 'File',
  imImageQualityNormal: 'Standard quality',
  imImageQualityNormalSubtitle: 'Auto-compressed, long side 1920, faster to send',
  imImageQualityHd: 'Original',
  imImageQualityHdSubtitle: 'Keep the original size and quality',
  imDownloadingMsg: 'Downloading...',
  imDownloadFailedWith: 'Download failed {code}',
  imOpenFailedWith: 'Open failed: {msg}',
  imOpenExceptionWith: 'Open error: {err}',
  imVideoLoadFailedWith: 'Failed to load video: {err}',
  imPushNewMessage: 'New message',
  imPushImagePreview: '[Image]',
  imMsgPreviewVideo: '[Video]',
  imMsgPreviewVoice: '[Voice]',
  imMsgPreviewFile: '[File]',
  imMsgPreviewLocation: '[Location]',
  imMsgPreviewGeneric: '[Message]',
  mainCantResolveAppConfigError: 'Failed to resolve or download this app config',
  widgetImagePickerPlaceholder: 'Tap to pick an image',
  widgetImagePickerReselect: 'Tap to pick again',
  widgetCameraNoCamera: 'No camera available',
  widgetDatePickerPlaceholder: 'Pick a date',
  widgetTimePickerPlaceholder: 'Pick a time',
  widgetButtonDefaultLabel: 'Button',
  widgetMissingItemTemplate: 'Missing item_template',
  widgetDropdownPlaceholder: 'Select',
  widgetPullToRefresh: 'Pull to refresh',
  widgetVideoNoUrl: 'No video URL configured',
  widgetVideoUnsupportedSource: 'Unsupported video source',
  widgetVideoPlaybackFailedWith: 'Playback failed: {err}',
  widgetVideoLoadFailedWith: 'Failed to load video\n{err}',
  widgetVideoLoading: 'Loading video...',
  widgetRefNotFoundWith: 'Not found: {ref}',
  widgetRefMissingFromOrName: 'ref widget requires "from" and "widget" fields',
  widgetRefMissingRootWith: '{ref} is missing the root definition',
  widgetUnknownTypeWith: 'Unknown widget type: {type}',
  widgetHttpNetworkFailed: 'Network request failed',
  chatErrNoRetryMessage: 'No message to retry',
  chatErrConnectionUnstableWith: 'Connection keeps dropping (already retried {n} times)',
  chatErrPleaseLogin: 'Please sign in first',
  chatErrServerWithBody: 'Server error ({code}): {body}',
  chatErrDownloadGenJsonWith: 'Failed to download generated JSON (HTTP {code})',
  chatErrDownloadJsonExceptionWith: 'Download JSON error: {err}',
  chatErrCancelled: 'Cancelled',
  chatErrQuotaExceeded: 'Quota exceeded',
  chatErrConnectionTimeout: 'Connection timeout',
  chatErrNetworkWith: 'Network error: {err}',
  chatErrUploadFailedRetriesWith: 'Upload failed (retried {n} times): {err}',
  chatUploadSuccessIntro: 'Here is the full JSON-APP config currently running (already uploaded to temporary storage). Please base any further modifications or analysis on this config:\n\n',
  asrBytedanceConnected: 'Connected',
  asrBytedanceDisconnected: 'Disconnected',
  asrErrUnknown: 'Unknown error',
  asrBytedanceConnectFailedWith: 'Connection failed: {err}',
  asrErrMicPermissionDeniedShort: 'Microphone permission denied',
  asrRecordErrorWith: 'Recording error: {err}',
  asrRecording: 'Recording...',
  asrRecordStartFailWith: 'Recording failed to start: {err}',
  gameOver: 'Game Over',
  gameRestartHint: 'Tap to restart',
  gameBestScoreWith: 'Best {score}',
  gameScoreWith: 'Score {score}',
  builtinBiometricDefaultReason: 'Please verify your identity',
  builtinInputDialogDefaultTitle: 'Input',
  imSenderMe: 'Me',
  relativeDateYesterday: 'Yesterday',
  depErrConflictWith: 'Loaded {loaded}, but {needed} is required',
);

const _Strings _deDE = _Strings(
  ok: 'OK',
  cancel: 'Abbrechen',
  confirm: 'Bestätigen',
  save: 'Speichern',
  delete: 'Löschen',
  retry: 'Wiederholen',
  back: 'Zurück',
  loading: 'Wird geladen…',
  empty: 'Keine Daten',
  search: 'Suchen',
  settings: 'Einstellungen',
  language: 'Sprache',
  done: 'Fertig',
  yes: 'Ja',
  no: 'Nein',
  authLoginTitle: 'Anmelden',
  authLoginSubtitle: 'Melde dich bei deinem Konto an',
  authRegisterTitle: 'Registrieren',
  authRegisterSubtitle: 'Neues Konto erstellen',
  authVerifyTitle: 'E-Mail bestätigen',
  authVerifyPageHeading: 'Bestätige deine E-Mail',
  authVerifyCodeSentTo: 'Code gesendet an\n{email}',
  authEmailHint: 'E-Mail',
  authPasswordHint: 'Passwort',
  authPasswordConfirmHint: 'Passwort bestätigen',
  authUsernameHint: 'Benutzername',
  authUsernameOptionalHint: 'Benutzername (optional)',
  authVerifyCodeHint: 'Bestätigungscode',
  authLoginButton: 'Anmelden',
  authRegisterButton: 'Registrieren',
  authVerifyButton: 'Bestätigen',
  authResendCodeButton: 'Erneut senden',
  authResendCodePrompt: 'Nicht erhalten? Code erneut senden',
  authNoAccountPrompt: 'Noch kein Konto?',
  authHasAccountPrompt: 'Schon ein Konto?',
  authSwitchToRegister: 'Kein Konto? Registrieren',
  authSwitchToLogin: 'Schon registriert? Anmelden',
  authForgotPassword: 'Passwort vergessen?',
  authEmailRequired: 'E-Mail ist erforderlich',
  authEmailInvalid: 'Ungültige E-Mail',
  authPasswordRequired: 'Passwort ist erforderlich',
  authPasswordTooShort: 'Passwort muss mindestens 6 Zeichen lang sein',
  authPasswordMismatch: 'Passwörter stimmen nicht überein',
  authUsernameRequired: 'Benutzername ist erforderlich',
  authVerifyCodeRequired: 'Bestätigungscode ist erforderlich',
  authVerifyCodeSent: 'Code gesendet',
  authLoginFailed: 'Anmeldung fehlgeschlagen',
  authRegisterFailed: 'Registrierung fehlgeschlagen',
  authVerifyFailed: 'Bestätigung fehlgeschlagen',
  authNetworkError: 'Netzwerkfehler',
  homeAppTitle: 'MyApp',
  homeWelcome: 'Hallo, {name}',
  homeSubtitle: 'Entdecke und starte deine Apps',
  homeMarket: 'App-Store',
  homeMarketSubtitle: 'Apps entdecken',
  homeMyApps: 'Meine Apps',
  homeMyAppsSubtitle: 'Verlauf',
  homeMessages: 'Nachrichten',
  homeMessagesSubtitle: 'Chats und Freunde',
  homeUnreadCount: '{n} ungelesen',
  homePickFile: 'Lokale Datei wählen',
  homePickFileSubtitle: 'JSON-Konfiguration vom Gerät importieren',
  homeImLoginFailed: 'IM-Verbindung fehlgeschlagen, bitte später erneut versuchen',
  onboardingNext: 'Weiter',
  onboardingDone: 'Fertig',
  onboardingSkip: 'Überspringen',
  onboardingReplayMenu: 'Einführung erneut anzeigen',
  onboardingStep1Title: 'Apps mit KI gestalten',
  onboardingStep1Body: 'Halte ca. 3 s gedrückt, um den KI-Chat zu öffnen — sag z. B. „mach mir eine Todo-Liste" und du bekommst eine funktionierende App, die du weiter iterieren kannst. Verschiebe per Drag; doppeltippe, um das letzte Gespräch fortzusetzen.',
  onboardingStep2Title: 'Konto & Sprache',
  onboardingStep2Body: 'Hier siehst du dein Profil, wechselst die Sprache oder meldest dich ab. Die Einführung kannst du von hier auch erneut starten.',
  onboardingStep3Title: 'App-Marktplatz',
  onboardingStep3Body: 'Stöbere durch Community-JSON-Apps und teste sie mit einem Tipp.',
  onboardingStep4Title: 'Meine Apps',
  onboardingStep4Body: 'Alle deine gespeicherten oder per KI generierten Apps findest du hier, auch offline.',
  onboardingStep5Title: 'Nachrichten',
  onboardingStep5Body: 'Chatte mit Freunden, Support oder Gruppen. Unterstützt Text, Bilder und Emojis.',
  errPauseLogin: 'Server ist überlastet, bitte später erneut anmelden',
  errPauseRegister: 'Server ist überlastet, bitte später erneut registrieren',
  errPauseRequest: 'Server ist überlastet, bitte später erneut versuchen',
  userMenuProfile: 'Profil',
  userMenuLogout: 'Abmelden',
  profileTitle: 'Profil',
  profileEditAvatar: 'Avatar ändern',
  profileSavedSuccess: 'Gespeichert',
  profileSaveFailed: 'Speichern fehlgeschlagen',
  profileSaveFailedWith: 'Fehlgeschlagen: {msg}',
  roleUser: 'Nutzer',
  roleAdmin: 'Admin',
  roleProUser: 'Pro-Nutzer',
  marketTitle: 'App-Store',
  marketEmpty: 'Noch keine Apps',
  marketLoadFailed: 'Laden fehlgeschlagen',
  marketRunButton: 'Starten',
  myAppsTitle: 'Meine Apps',
  myAppsEmpty: 'Noch keine Apps',
  myAppsRun: 'Starten',
  myAppsDelete: 'Löschen',
  myAppsDeleteConfirmTitle: 'Diese App löschen?',
  myAppsDeleteConfirmMessage: 'Dies kann nicht rückgängig gemacht werden',
  settingsTitle: 'Einstellungen',
  settingsLanguage: 'Sprache',
  settingsLanguageZh: '中文',
  settingsLanguageEn: 'English',
  settingsLanguageDe: 'Deutsch',
  settingsLanguageEs: 'Español',
  settingsLanguageSystem: 'System',
  settingsAiProvider: 'KI-Anbieter',
  settingsAbout: 'Über',
  settingsVersion: 'Version',
  addToMyAppsTitle: 'Zu „Meine Apps" hinzufügen',
  addToMyAppsContent: 'Diese App zu „Meine Apps" hinzufügen?\n\nDu kannst sie dann wiederverwenden und im Marktplatz veröffentlichen.',
  addToMyAppsAdded: 'Zu „Meine Apps" hinzugefügt',
  saveFailedWith: 'Speichern fehlgeschlagen: {msg}',
  marketDeleteConfirmTitle: 'Veröffentlichung zurückziehen',
  marketDeleteConfirmContent: 'Paket „{package}" dauerhaft löschen?\n\nDies kann nicht rückgängig gemacht werden — alle Versionen werden entfernt.',
  marketDeleting: 'Wird gelöscht…',
  marketDeleteSuccess: 'Gelöscht',
  marketDeleteFailed: 'Löschen fehlgeschlagen',
  marketDeleteFailedWith: 'Löschen fehlgeschlagen: {msg}',
  marketUnpublishTooltip: 'Zurückziehen',
  marketAuthor: 'Autor: {author}',
  myAppsEmptyHint: 'Halte den Floating-Button gedrückt und sprich — die KI generiert eine für dich',
  myAppsUploadTooltip: 'In den Marktplatz hochladen',
  myAppsUploading: 'Wird in den Marktplatz hochgeladen…',
  myAppsPublishSuccess: 'Veröffentlicht 🎉',
  publishDialogTitle: 'Im Marktplatz veröffentlichen',
  publishCreateNamespace: 'Namespace erstellen',
  publishCreateNamespaceTitle: 'Namespace erstellen',
  publishNamespaceName: 'Namespace',
  publishNamespaceHint: 'Kleinbuchstaben, Ziffern, - und _',
  publishCreateFailed: 'Erstellen fehlgeschlagen',
  publishInviteMember: 'Mitglied einladen',
  publishNamespaceField: 'Namespace',
  publishOfficialNamespace: '(Offiziell / kein Namespace)',
  publishPkgNameField: 'Paketname',
  publishRandomGenerate: 'Zufällig',
  publishDescField: 'Beschreibung',
  publishVersionField: 'Version',
  publishTypeField: 'Typ',
  publishButton: 'Veröffentlichen',
  publishPkgNameRequired: 'Paketname ist erforderlich',
  publishAppidInvalid: 'AppID muss eine gültige UUID sein',
  publishVersionInvalid: 'Version muss dem Format x.y.z folgen',
  publishNamespaceRequired: 'Bitte Namespace wählen oder erstellen',
  publishUuidConflictTitle: 'UUID-Konflikt',
  publishUuidConflictContent: 'Diese UUID wird bereits vom Paket „{pkg}" verwendet.\nKlicke auf „Zufällig 🎲", um eine neue zu generieren, und versuche es erneut.',
  publishFailedWithCode: 'Veröffentlichen fehlgeschlagen ({code})',
  create: 'Erstellen',
  gotIt: 'Verstanden',
  copy: 'Kopieren',
  featureInDevelopment: 'Diese Funktion ist in Entwicklung',
  featureStayTuned: 'Bald verfügbar!',
  crashTitle: 'Laufzeitfehler',
  crashSubtitle: '{file} ist abgestürzt',
  crashCopied: 'Fehlerinfo kopiert',
  crashAiFix: 'KI-Fix',
  uiRenderCrash: 'UI-Render-/Layout-Absturz',
  pageConfigNotFound: 'Seitenkonfiguration nicht gefunden',
  errorPathUnavailable: 'Dateipfad konnte nicht aufgelöst werden',
  errorGeneric: 'Etwas ist schiefgelaufen',
  errorNoNetwork: 'Kein Netzwerk',
  errorNotLoggedIn: 'Nicht angemeldet',
  errorNetworkWith: 'Netzwerkfehler: {msg}',
  errorServerWithCode: 'Serverfehler ({code})',
  imPreviewImage: '[Bild]',
  imPreviewVoice: '[Sprache]',
  imPreviewVideo: '[Video]',
  imPreviewFile: '[Datei]',
  imPreviewFileWithName: '[Datei] {name}',
  imPreviewLocation: '[Standort]',
  imPreviewCard: '[Karte]',
  imPreviewMerger: '[Weitergeleiteter Chat]',
  imPreviewQuoteFallback: '[Zitat]',
  imPreviewEmoji: '[Sticker]',
  imPreviewRichTextFallback: '[Rich-Text]',
  imPreviewCustom: '[Benutzerdefinierte Nachricht]',
  imPreviewAtFallback: '[Erwähnung]',
  imPreviewOA: '[OA-Hinweis]',
  imPreviewSystem: '[Systemhinweis]',
  imPreviewBurnAfterRead: '[Nach Lesen löschen]',
  imPreviewRevoked: 'hat eine Nachricht zurückgenommen',
  imPreviewUnknown: '[Unbekannte Nachricht: {type}]',
  imSysFriendApplyAccepted: 'Deine Freundschaftsanfrage wurde angenommen',
  imSysFriendApplyRejected: 'Deine Freundschaftsanfrage wurde abgelehnt',
  imSysFriendApplyReceived: 'Neue Freundschaftsanfrage erhalten',
  imSysFriendAdded: 'Ihr seid jetzt Freunde. Sag hallo!',
  imSysFriendDeleted: 'Eure Freundschaft wurde beendet',
  imSysFriendRemarkChanged: 'Freundes-Notiz aktualisiert',
  imSysFriendBlacklisted: 'Zur Sperrliste hinzugefügt',
  imSysFriendUnblacklisted: 'Von der Sperrliste entfernt',
  imSysGroupCreated: 'Gruppe erstellt',
  imSysGroupInfoChanged: 'Gruppeninfo aktualisiert',
  imSysGroupNameChanged: 'Gruppenname geändert',
  imSysGroupNoticeUpdated: 'Gruppenmitteilung aktualisiert',
  imSysGroupApplyReceived: 'Neue Beitrittsanfrage',
  imSysGroupMemberQuit: 'Ein Mitglied hat die Gruppe verlassen',
  imSysGroupMemberKicked: 'Ein Mitglied wurde entfernt',
  imSysGroupMemberInvited: 'Ein Mitglied wurde eingeladen',
  imSysGroupMemberJoined: 'Ein neues Mitglied ist beigetreten',
  imSysGroupDismissed: 'Die Gruppe wurde aufgelöst',
  imSysGroupOwnerTransferred: 'Gruppeneigentümerschaft übertragen',
  imSysGroupApplyApproved: 'Beitrittsanfrage genehmigt',
  imSysGroupApplyRejected: 'Beitrittsanfrage abgelehnt',
  imSysGroupMemberMuted: 'Ein Mitglied wurde stummgeschaltet',
  imSysGroupMemberUnmuted: 'Stummschaltung eines Mitglieds aufgehoben',
  imSysGroupMutedAll: 'Alle Mitglieder stummgeschaltet',
  imSysGroupUnmutedAll: 'Stummschaltung aller Mitglieder aufgehoben',
  imSysGroupMemberInfoChanged: 'Mitgliedsinfo geändert',
  imSysGroupMemberSetAdmin: 'Ein Mitglied wurde zum Admin ernannt',
  imSysGroupAdminRevoked: 'Ein Admin wurde zurückgestuft',
  imSysUserInfoUpdated: 'Profil aktualisiert',
  imSysConversationChanged: 'Gespräch geändert',
  imConversationsTitle: 'Nachrichten',
  imContacts: 'Kontakte',
  imEmptyMessages: 'Noch keine Nachrichten',
  imEmptyMessagesHint: 'Starte ein Gespräch',
  imUnknownPeer: 'Unbekannt',
  imConfirmDeleteTitle: 'Löschen bestätigen',
  imDeleteConversationContent: 'Gespräch mit {name} löschen?',
  imPin: 'Anheften',
  imUnpin: 'Loslösen',
  imMarkRead: 'Als gelesen markieren',
  imDeleteConversation: 'Gespräch löschen',
  imTimeJustNow: 'Gerade eben',
  imTimeMinutesAgo: 'vor {n} Min.',
  imTimeYesterday: 'Gestern',
  imTimeDaysAgo: 'vor {n} T.',
  imGroupChat: 'Gruppe',
  imChatInputHint: 'Nachricht eingeben…',
  imActionCopy: 'Kopieren',
  imToastCopied: 'Kopiert',
  imActionRevoke: 'Zurücknehmen',
  imToastRevokeExpired: 'Nach 2 Minuten nicht mehr möglich',
  imAttachImage: 'Bild',
  imAttachCamera: 'Kamera',
  imAttachVideo: 'Video',
  imAttachFile: 'Datei',
  imImageExpired: 'Bild abgelaufen',
  imSaveToAlbum: 'In Album speichern',
  imSaveSuccess: 'Gespeichert',
  imSaveFailed: 'Speichern fehlgeschlagen',
  imCacheManageTitle: 'Chat-Medien-Cache',
  imCacheTotal: 'Insgesamt {size}',
  imCacheSelectAll: 'Alle auswählen',
  imCacheDeselectAll: 'Auswahl aufheben',
  imCacheClearSelected: 'Auswahl löschen',
  imCacheClearedToast: '{size} gelöscht',
  imCacheNoSelection: 'Mindestens ein Gespräch wählen',
  imCacheLoading: 'Wird berechnet…',
  imCacheEntry: 'Chat-Medien-Cache',
  ballMenuTitle: 'Schnellmenü',
  ballMenuRestoreSession: 'Sitzung wiederherstellen',
  ballMenuRestoreSessionEmpty: 'Keine vorherige Sitzung',
  ballMenuGoHome: 'Zur Startseite',
  defaultStartupEntry: 'Standard-Start-App',
  defaultStartupSubtitleNone: 'Nicht festgelegt (öffnet MyApp-Startseite)',
  defaultStartupTitle: 'Standard-Start-App',
  defaultStartupHint: 'Wenn festgelegt, startet die App direkt in der gewählten App. Nutze im Floating-Ball-Menü „Zur Startseite", um zur MyApp-Startseite zurückzukehren.',
  defaultStartupNoneOption: 'Nicht festgelegt (öffnet MyApp-Startseite)',
  defaultStartupTabMarket: 'Markt',
  defaultStartupTabLocal: 'Lokal',
  defaultStartupEmptyMarket: 'Noch keine Apps im Markt',
  defaultStartupEmptyLocal: 'Noch keine gespeicherten lokalen Apps',
  defaultStartupSavedToast: 'Gespeichert',
  defaultStartupSetAsStartup: 'Als Start-App festlegen',
  defaultStartupCurrent: 'Aktuelle Start-App',
  defaultStartupResetToNone: 'Zurücksetzen',
  imAdd: 'Hinzufügen',
  imAddFriend: 'Freund hinzufügen',
  imCreateGroup: 'Neue Gruppe',
  imMyId: 'Meine ID:',
  imCopiedId: 'ID kopiert',
  imNewFriends: 'Neue Anfragen',
  imEmptyFriends: 'Noch keine Freunde',
  imEmptyFriendsHint: 'Tippe oben rechts auf +, um Freunde hinzuzufügen',
  imDeleteFriendTitle: 'Freund löschen',
  imDeleteFriendContent: '{name} löschen?',
  imApplyAccepted: 'Angenommen',
  imApplyRejected: 'Abgelehnt',
  imApplyPending: 'Ausstehend',
  imEmptyApplications: 'Keine eingehenden Anfragen',
  imApplyDefaultMessage: 'Möchte dein Freund werden',
  imAccept: 'Annehmen',
  imReject: 'Ablehnen',
  imAddFriendDialogTitle: 'Freundschaftsanfrage senden',
  imAddFriendDefaultGreeting: 'Hallo, ich möchte dich hinzufügen',
  imAddFriendNote: 'Nachricht',
  imSendApplication: 'Senden',
  imApplicationSent: 'Anfrage gesendet. Warten auf Bestätigung.',
  imApplicationFailed: 'Anfrage konnte nicht gesendet werden',
  imSearchTitle: 'Freund hinzufügen',
  imSearchHint: 'Suche per E-Mail, Benutzername oder ID',
  imSearchHelp: 'Gib E-Mail, Benutzername oder ID ein',
  imSearchHelpMin: 'Mindestens 2 Zeichen eingeben',
  imSearchNoMatch: 'Keine Nutzer gefunden für „{q}"',
  imSearchNoMatchHint: 'Sie müssen sich zuerst registrieren',
  imYouSelfBadge: '(du)',
  imCreateGroupFailed: 'Gruppe konnte nicht erstellt werden. Bitte erneut versuchen.',
  imCreateGroupTitle: 'Neue Gruppe',
  imCreate: 'Erstellen',
  imGroupNameLabel: 'Gruppenname',
  imGroupNameHint: 'Gib der Gruppe einen Namen',
  imSelectMembers: 'Mitglieder auswählen',
  imSelectedCount: '{n} ausgewählt',
  imEmptyFriendsForGroupHint: 'Zuerst ein paar Freunde hinzufügen',
  imGroupSettings: 'Gruppeneinstellungen',
  imMemberCount: '{n} Mitglieder',
  imGroupNotice: 'Gruppenmitteilung',
  imGroupMembers: 'Mitglieder',
  imGroupOwnerLabel: 'Eigentümer',
  imGroupAdminLabel: 'Admin',
  imInviteMembers: 'Mitglieder einladen',
  imLeaveGroup: 'Gruppe verlassen',
  imUserIdLabel: 'Nutzer-ID',
  imUserIdHint: 'Nutzer-ID zum Einladen',
  imInviteSent: 'Einladung gesendet',
  imInviteFailedWith: 'Einladung fehlgeschlagen: {err}',
  imLeaveGroupConfirmContent: '„{name}" verlassen?',
  imLeaveFailedWith: 'Verlassen fehlgeschlagen: {err}',
  imConfirmLeave: 'Verlassen bestätigen',
  chatSessionDefaultTitle: 'Neuer Chat',
  chatSessionMenuNew: 'Neuer Chat',
  chatSessionMenuEmpty: 'Noch keine Chats',
  chatSessionRenameTitle: 'Chat umbenennen',
  chatSessionRenameHint: 'Neuer Titel',
  chatSessionActionRename: 'Umbenennen',
  chatSessionDeleteTitle: 'Chat löschen',
  chatSessionDeleteContent: '„{title}" löschen? Die im Hintergrund laufende Antwort wird abgebrochen.',
  chatStatusGenerating: 'Code wird generiert...',
  chatStatusStartingAi: 'KI-Modul wird gestartet...',
  chatStatusResumingLast: 'Letzte Unterhaltung wird wiederhergestellt...',
  chatActionUploadCurrentApp: 'Aktuelle App-Konfiguration hochladen',
  chatActionRetryDownloadJson: 'JSON-Download wiederholen',
  chatTimeJustNow: 'gerade eben',
  chatTimeMinutesAgo: 'vor {n} Min.',
  chatTimeHoursAgo: 'vor {n} Std.',
  chatTimeDaysAgo: 'vor {n} T.',
  chatDownloadStateDownloading: 'Wird geladen...',
  chatDownloadStateRun: 'Herunterladen & starten',
  chatDownloadStateRetry: 'Erneut herunterladen & starten',
  chatErrorWith: 'Fehler: {err}',
  chatJsonDownloadFailed: 'JSON konnte nicht heruntergeladen werden',
  chatNoActiveApp: 'Aktuell läuft keine App-Konfiguration',
  chatUploadingApp: 'Aktuelle App-Konfiguration wird hochgeladen...',
  chatDownloadRetryFailedWith: 'Download-Wiederholung fehlgeschlagen: {err}',
  chatAnalysisFailedWith: 'Analyse fehlgeschlagen: {err}',
  chatEditMessageTitle: 'Nachricht bearbeiten',
  chatEditMessageHint: 'Nachricht bearbeiten...',
  chatEditButton: 'Bearbeiten',
  chatSendButton: 'Senden',
  asrErrBytedanceWith: 'ByteDance-ASR-Fehler: {err}',
  asrErrNativeInitWithHint: 'Native Spracherkennung konnte nicht initialisiert werden. Wechseln Sie in den Einstellungen auf ByteDance ASR.',
  asrConnectingBytedance: 'Verbindung zu ByteDance ASR wird hergestellt...',
  asrErrBytedanceTimeoutWithHint: 'Zeitüberschreitung bei der Verbindung zu ByteDance ASR. Netzwerk prüfen oder eine andere Erkennung wählen.',
  asrErrNativeStartWithHint: 'Native Spracherkennung konnte nicht gestartet werden. Wechseln Sie in den Einstellungen auf ByteDance ASR.',
  asrErrMicPermissionDenied: 'Mikrofonberechtigung nicht erteilt. Aktivieren Sie sie unter Einstellungen → Apps → Berechtigungen und versuchen Sie es erneut.',
  asrErrStartFailWith: 'Spracherkennung konnte nicht gestartet werden: {err}',
  asrErrBytedanceNotConnected: 'ByteDance ASR ist nicht verbunden. Bitte Netzwerk prüfen.',
  asrErrBytedanceStartFailWith: 'ByteDance ASR konnte nicht gestartet werden: {err}',
  authSwitchAccountCancelled: 'Kontowechsel abgebrochen',
  authClearLocalFailedWith: 'Löschen der lokalen Daten fehlgeschlagen: {err}',
  authSwitchAccountTitle: 'Konto wechseln',
  authSwitchAccountContent: 'Das angemeldete Konto ({newEmail}) unterscheidet sich vom vorherigen ({prevEmail}).\n\nBeim Fortfahren werden alle lokalen Chats, Kontakte und Daten gelöscht. Fortfahren?',
  authSwitchAccountConfirm: 'Löschen und fortfahren',
  authErrSignupFailed: 'Registrierung fehlgeschlagen',
  authErrLoginFailed: 'Anmeldung fehlgeschlagen',
  authErrVerifyFailed: 'Verifizierung fehlgeschlagen',
  authErrSendFailed: 'Senden fehlgeschlagen',
  authErrNoRefreshToken: 'Kein Refresh-Token vorhanden',
  authErrRefreshFailed: 'Aktualisierung fehlgeschlagen',
  authErrGetUserInfoFailed: 'Abrufen der Benutzerinfo fehlgeschlagen',
  authErrServerWith: 'Serverfehler ({code})',
  authErrUpdateFailed: 'Aktualisierung fehlgeschlagen',
  authErrAvatarUploadFailed: 'Avatar-Upload fehlgeschlagen',
  settingsSectionAsr: 'Spracherkennung',
  settingsAsrOnline: 'Online-Erkennung',
  settingsAsrOnlineSubtitle: 'Nutzt speech_to_text, Netzwerk erforderlich',
  settingsAsrBytedance: 'ByteDance ASR',
  settingsAsrBytedanceSubtitle: 'ByteDance-Spracherkennung, benötigt Netzwerk und Kontingent',
  settingsProvidersFailed: 'Anbieterliste konnte nicht geladen werden',
  settingsProvidersFallback: 'Fallback auf Standardanbieter DeepSeek',
  settingsModelWith: 'Modell: {model}',
  imUserUnknown: 'Unbekannt',
  imMessageRecalled: 'hat eine Nachricht zurückgezogen',
  imAttachmentFile: 'Datei',
  imImageQualityNormal: 'Standardqualität',
  imImageQualityNormalSubtitle: 'Automatisch komprimiert, Langseite 1920, schneller versandt',
  imImageQualityHd: 'Originalqualität',
  imImageQualityHdSubtitle: 'Originalgröße und Qualität beibehalten',
  imDownloadingMsg: 'Wird heruntergeladen...',
  imDownloadFailedWith: 'Download fehlgeschlagen {code}',
  imOpenFailedWith: 'Öffnen fehlgeschlagen: {msg}',
  imOpenExceptionWith: 'Öffnen-Fehler: {err}',
  imVideoLoadFailedWith: 'Video konnte nicht geladen werden: {err}',
  imPushNewMessage: 'Neue Nachricht',
  imPushImagePreview: '[Bild]',
  imMsgPreviewVideo: '[Video]',
  imMsgPreviewVoice: '[Sprachnachricht]',
  imMsgPreviewFile: '[Datei]',
  imMsgPreviewLocation: '[Standort]',
  imMsgPreviewGeneric: '[Nachricht]',
  mainCantResolveAppConfigError: 'App-Konfiguration konnte nicht aufgelöst oder heruntergeladen werden',
  widgetImagePickerPlaceholder: 'Zum Auswählen tippen',
  widgetImagePickerReselect: 'Zum erneuten Auswählen tippen',
  widgetCameraNoCamera: 'Keine Kamera verfügbar',
  widgetDatePickerPlaceholder: 'Datum wählen',
  widgetTimePickerPlaceholder: 'Uhrzeit wählen',
  widgetButtonDefaultLabel: 'Schaltfläche',
  widgetMissingItemTemplate: 'item_template fehlt',
  widgetDropdownPlaceholder: 'Auswählen',
  widgetPullToRefresh: 'Zum Aktualisieren ziehen',
  widgetVideoNoUrl: 'Keine Video-URL konfiguriert',
  widgetVideoUnsupportedSource: 'Video-Quelle nicht unterstützt',
  widgetVideoPlaybackFailedWith: 'Wiedergabe fehlgeschlagen: {err}',
  widgetVideoLoadFailedWith: 'Video konnte nicht geladen werden\n{err}',
  widgetVideoLoading: 'Video wird geladen...',
  widgetRefNotFoundWith: 'Nicht gefunden: {ref}',
  widgetRefMissingFromOrName: 'ref-Widget benötigt „from" und „widget" Felder',
  widgetRefMissingRootWith: '{ref} fehlt die root-Definition',
  widgetUnknownTypeWith: 'Unbekannter Widget-Typ: {type}',
  widgetHttpNetworkFailed: 'Netzwerkanfrage fehlgeschlagen',
  chatErrNoRetryMessage: 'Keine Nachricht zum erneuten Versuchen',
  chatErrConnectionUnstableWith: 'Verbindung bricht ständig ab (bereits {n} Mal versucht)',
  chatErrPleaseLogin: 'Bitte zuerst anmelden',
  chatErrServerWithBody: 'Serverfehler ({code}): {body}',
  chatErrDownloadGenJsonWith: 'Generierte JSON konnte nicht heruntergeladen werden (HTTP {code})',
  chatErrDownloadJsonExceptionWith: 'Download-JSON-Fehler: {err}',
  chatErrCancelled: 'Abgebrochen',
  chatErrQuotaExceeded: 'Kontingent aufgebraucht',
  chatErrConnectionTimeout: 'Verbindungs-Zeitüberschreitung',
  chatErrNetworkWith: 'Netzwerkfehler: {err}',
  chatErrUploadFailedRetriesWith: 'Upload fehlgeschlagen (bereits {n} Versuche): {err}',
  chatUploadSuccessIntro: 'Hier ist die vollständige JSON-APP-Konfiguration, die gerade läuft (bereits in den temporären Speicher hochgeladen). Bitte basieren Sie weitere Änderungen oder Analysen auf dieser Konfiguration:\n\n',
  asrBytedanceConnected: 'Verbunden',
  asrBytedanceDisconnected: 'Verbindung getrennt',
  asrErrUnknown: 'Unbekannter Fehler',
  asrBytedanceConnectFailedWith: 'Verbindung fehlgeschlagen: {err}',
  asrErrMicPermissionDeniedShort: 'Mikrofonberechtigung verweigert',
  asrRecordErrorWith: 'Aufnahmefehler: {err}',
  asrRecording: 'Aufnahme läuft...',
  asrRecordStartFailWith: 'Aufnahme konnte nicht gestartet werden: {err}',
  gameOver: 'Spiel beendet',
  gameRestartHint: 'Tippen zum Neustart',
  gameBestScoreWith: 'Beste {score}',
  gameScoreWith: 'Punkte {score}',
  builtinBiometricDefaultReason: 'Bitte Identität bestätigen',
  builtinInputDialogDefaultTitle: 'Eingabe',
  imSenderMe: 'Ich',
  relativeDateYesterday: 'Gestern',
  depErrConflictWith: '{loaded} geladen, aber {needed} erforderlich',
);

const _Strings _esES = _Strings(
  ok: 'OK',
  cancel: 'Cancelar',
  confirm: 'Confirmar',
  save: 'Guardar',
  delete: 'Eliminar',
  retry: 'Reintentar',
  back: 'Atrás',
  loading: 'Cargando…',
  empty: 'Sin datos',
  search: 'Buscar',
  settings: 'Ajustes',
  language: 'Idioma',
  done: 'Listo',
  yes: 'Sí',
  no: 'No',
  authLoginTitle: 'Iniciar sesión',
  authLoginSubtitle: 'Inicia sesión en tu cuenta',
  authRegisterTitle: 'Registrarse',
  authRegisterSubtitle: 'Crear una cuenta nueva',
  authVerifyTitle: 'Verificar correo',
  authVerifyPageHeading: 'Verifica tu correo',
  authVerifyCodeSentTo: 'Código enviado a\n{email}',
  authEmailHint: 'Correo',
  authPasswordHint: 'Contraseña',
  authPasswordConfirmHint: 'Confirmar contraseña',
  authUsernameHint: 'Nombre de usuario',
  authUsernameOptionalHint: 'Nombre de usuario (opcional)',
  authVerifyCodeHint: 'Código de verificación',
  authLoginButton: 'Iniciar sesión',
  authRegisterButton: 'Registrarse',
  authVerifyButton: 'Verificar',
  authResendCodeButton: 'Reenviar',
  authResendCodePrompt: '¿No lo recibiste? Reenviar código',
  authNoAccountPrompt: '¿No tienes cuenta?',
  authHasAccountPrompt: '¿Ya tienes cuenta?',
  authSwitchToRegister: '¿Sin cuenta? Regístrate',
  authSwitchToLogin: '¿Ya tienes cuenta? Inicia sesión',
  authForgotPassword: '¿Olvidaste tu contraseña?',
  authEmailRequired: 'El correo es obligatorio',
  authEmailInvalid: 'Correo no válido',
  authPasswordRequired: 'La contraseña es obligatoria',
  authPasswordTooShort: 'La contraseña debe tener al menos 6 caracteres',
  authPasswordMismatch: 'Las contraseñas no coinciden',
  authUsernameRequired: 'El nombre de usuario es obligatorio',
  authVerifyCodeRequired: 'El código de verificación es obligatorio',
  authVerifyCodeSent: 'Código enviado',
  authLoginFailed: 'Error al iniciar sesión',
  authRegisterFailed: 'Error al registrarse',
  authVerifyFailed: 'Error al verificar',
  authNetworkError: 'Error de red',
  homeAppTitle: 'MyApp',
  homeWelcome: 'Hola, {name}',
  homeSubtitle: 'Explora y ejecuta tus apps',
  homeMarket: 'Tienda de apps',
  homeMarketSubtitle: 'Descubre apps',
  homeMyApps: 'Mis apps',
  homeMyAppsSubtitle: 'Historial',
  homeMessages: 'Mensajes',
  homeMessagesSubtitle: 'Conversaciones y amigos',
  homeUnreadCount: '{n} sin leer',
  homePickFile: 'Elegir archivo local',
  homePickFileSubtitle: 'Importar configuración JSON desde el dispositivo',
  homeImLoginFailed: 'Conexión IM fallida, inténtalo más tarde',
  onboardingNext: 'Siguiente',
  onboardingDone: 'Listo',
  onboardingSkip: 'Omitir',
  onboardingReplayMenu: 'Repetir tutorial',
  onboardingStep1Title: 'Diseña apps con IA',
  onboardingStep1Body: 'Mantén pulsado ~3s para abrir el chat de IA — dile «hazme una lista de tareas» y obtendrás una app funcional que puedes seguir iterando. Arrastra para moverlo; toca dos veces para retomar la última conversación.',
  onboardingStep2Title: 'Cuenta e idioma',
  onboardingStep2Body: 'Aquí puedes ver tu perfil, cambiar idioma o cerrar sesión. También puedes repetir el tutorial desde este menú.',
  onboardingStep3Title: 'Tienda de apps',
  onboardingStep3Body: 'Explora las apps JSON de la comunidad y pruébalas con un toque.',
  onboardingStep4Title: 'Mis apps',
  onboardingStep4Body: 'Todas tus apps guardadas o generadas por IA están aquí, disponibles también sin conexión.',
  onboardingStep5Title: 'Mensajes',
  onboardingStep5Body: 'Chatea con amigos, soporte o grupos. Admite texto, imágenes y emojis.',
  errPauseLogin: 'El servidor está ocupado, prueba a iniciar sesión más tarde',
  errPauseRegister: 'El servidor está ocupado, prueba a registrarte más tarde',
  errPauseRequest: 'El servidor está ocupado, inténtalo más tarde',
  userMenuProfile: 'Perfil',
  userMenuLogout: 'Cerrar sesión',
  profileTitle: 'Perfil',
  profileEditAvatar: 'Cambiar avatar',
  profileSavedSuccess: 'Guardado',
  profileSaveFailed: 'Error al guardar',
  profileSaveFailedWith: 'Error: {msg}',
  roleUser: 'Usuario',
  roleAdmin: 'Admin',
  roleProUser: 'Usuario Pro',
  marketTitle: 'Tienda de apps',
  marketEmpty: 'Aún no hay apps',
  marketLoadFailed: 'Error al cargar',
  marketRunButton: 'Ejecutar',
  myAppsTitle: 'Mis apps',
  myAppsEmpty: 'Aún no hay apps',
  myAppsRun: 'Ejecutar',
  myAppsDelete: 'Eliminar',
  myAppsDeleteConfirmTitle: '¿Eliminar esta app?',
  myAppsDeleteConfirmMessage: 'Esta acción no se puede deshacer',
  settingsTitle: 'Ajustes',
  settingsLanguage: 'Idioma',
  settingsLanguageZh: '中文',
  settingsLanguageEn: 'English',
  settingsLanguageDe: 'Deutsch',
  settingsLanguageEs: 'Español',
  settingsLanguageSystem: 'Sistema',
  settingsAiProvider: 'Proveedor de IA',
  settingsAbout: 'Acerca de',
  settingsVersion: 'Versión',
  addToMyAppsTitle: 'Añadir a Mis Apps',
  addToMyAppsContent: '¿Añadir esta app a «Mis Apps»?\n\nPodrás reutilizarla y publicarla en la tienda.',
  addToMyAppsAdded: 'Añadida a Mis Apps',
  saveFailedWith: 'Error al guardar: {msg}',
  marketDeleteConfirmTitle: 'Confirmar retirada',
  marketDeleteConfirmContent: '¿Eliminar permanentemente el paquete «{package}»?\n\nEsta acción no se puede deshacer — se eliminarán todas las versiones.',
  marketDeleting: 'Eliminando…',
  marketDeleteSuccess: 'Eliminado',
  marketDeleteFailed: 'Error al eliminar',
  marketDeleteFailedWith: 'Error al eliminar: {msg}',
  marketUnpublishTooltip: 'Retirar',
  marketAuthor: 'Autor: {author}',
  myAppsEmptyHint: 'Mantén pulsado el botón flotante y habla — la IA generará una',
  myAppsUploadTooltip: 'Subir a la tienda',
  myAppsUploading: 'Subiendo a la tienda…',
  myAppsPublishSuccess: 'Publicada 🎉',
  publishDialogTitle: 'Publicar en la tienda',
  publishCreateNamespace: 'Crear espacio',
  publishCreateNamespaceTitle: 'Crear espacio',
  publishNamespaceName: 'Espacio de nombres',
  publishNamespaceHint: 'Minúsculas, dígitos, - y _',
  publishCreateFailed: 'Error al crear',
  publishInviteMember: 'Invitar miembro',
  publishNamespaceField: 'Espacio de nombres',
  publishOfficialNamespace: '(Oficial / sin espacio)',
  publishPkgNameField: 'Nombre del paquete',
  publishRandomGenerate: 'Aleatorio',
  publishDescField: 'Descripción',
  publishVersionField: 'Versión',
  publishTypeField: 'Tipo',
  publishButton: 'Publicar',
  publishPkgNameRequired: 'El nombre del paquete es obligatorio',
  publishAppidInvalid: 'AppID debe ser un UUID válido',
  publishVersionInvalid: 'La versión debe seguir el formato x.y.z',
  publishNamespaceRequired: 'Selecciona o crea un espacio',
  publishUuidConflictTitle: 'Conflicto de UUID',
  publishUuidConflictContent: 'Este UUID ya lo usa el paquete «{pkg}».\nPulsa «Aleatorio 🎲» para generar uno nuevo e inténtalo de nuevo.',
  publishFailedWithCode: 'Error al publicar ({code})',
  create: 'Crear',
  gotIt: 'Entendido',
  copy: 'Copiar',
  featureInDevelopment: 'Esta función está en desarrollo',
  featureStayTuned: '¡Próximamente!',
  crashTitle: 'Error en ejecución',
  crashSubtitle: '{file} se bloqueó',
  crashCopied: 'Información del error copiada',
  crashAiFix: 'Reparar con IA',
  uiRenderCrash: 'Error de renderizado / diseño',
  pageConfigNotFound: 'Configuración de página no encontrada',
  errorPathUnavailable: 'No se pudo resolver la ruta del archivo',
  errorGeneric: 'Algo salió mal',
  errorNoNetwork: 'Sin red',
  errorNotLoggedIn: 'No has iniciado sesión',
  errorNetworkWith: 'Error de red: {msg}',
  errorServerWithCode: 'Error del servidor ({code})',
  imPreviewImage: '[Imagen]',
  imPreviewVoice: '[Voz]',
  imPreviewVideo: '[Vídeo]',
  imPreviewFile: '[Archivo]',
  imPreviewFileWithName: '[Archivo] {name}',
  imPreviewLocation: '[Ubicación]',
  imPreviewCard: '[Tarjeta]',
  imPreviewMerger: '[Chat reenviado]',
  imPreviewQuoteFallback: '[Cita]',
  imPreviewEmoji: '[Sticker]',
  imPreviewRichTextFallback: '[Texto enriquecido]',
  imPreviewCustom: '[Mensaje personalizado]',
  imPreviewAtFallback: '[Mención]',
  imPreviewOA: '[Aviso OA]',
  imPreviewSystem: '[Aviso del sistema]',
  imPreviewBurnAfterRead: '[Borrar al leer]',
  imPreviewRevoked: 'recuperó un mensaje',
  imPreviewUnknown: '[Mensaje desconocido: {type}]',
  imSysFriendApplyAccepted: 'Tu solicitud de amistad fue aceptada',
  imSysFriendApplyRejected: 'Tu solicitud de amistad fue rechazada',
  imSysFriendApplyReceived: 'Nueva solicitud de amistad',
  imSysFriendAdded: 'Ya sois amigos. ¡Saluda!',
  imSysFriendDeleted: 'La amistad ha terminado',
  imSysFriendRemarkChanged: 'Nota de amigo actualizada',
  imSysFriendBlacklisted: 'Añadido a la lista negra',
  imSysFriendUnblacklisted: 'Eliminado de la lista negra',
  imSysGroupCreated: 'Grupo creado',
  imSysGroupInfoChanged: 'Información del grupo actualizada',
  imSysGroupNameChanged: 'Nombre del grupo cambiado',
  imSysGroupNoticeUpdated: 'Aviso del grupo actualizado',
  imSysGroupApplyReceived: 'Nueva solicitud de unión',
  imSysGroupMemberQuit: 'Un miembro salió del grupo',
  imSysGroupMemberKicked: 'Un miembro fue eliminado',
  imSysGroupMemberInvited: 'Un miembro fue invitado',
  imSysGroupMemberJoined: 'Un nuevo miembro se unió',
  imSysGroupDismissed: 'El grupo se disolvió',
  imSysGroupOwnerTransferred: 'Propiedad del grupo transferida',
  imSysGroupApplyApproved: 'Solicitud de unión aprobada',
  imSysGroupApplyRejected: 'Solicitud de unión rechazada',
  imSysGroupMemberMuted: 'Un miembro fue silenciado',
  imSysGroupMemberUnmuted: 'Silencio de un miembro retirado',
  imSysGroupMutedAll: 'Todos los miembros silenciados',
  imSysGroupUnmutedAll: 'Silencio retirado para todos',
  imSysGroupMemberInfoChanged: 'Información de un miembro cambió',
  imSysGroupMemberSetAdmin: 'Un miembro fue nombrado admin',
  imSysGroupAdminRevoked: 'Un admin fue degradado',
  imSysUserInfoUpdated: 'Perfil actualizado',
  imSysConversationChanged: 'Conversación cambiada',
  imConversationsTitle: 'Mensajes',
  imContacts: 'Contactos',
  imEmptyMessages: 'Aún no hay mensajes',
  imEmptyMessagesHint: 'Inicia una conversación',
  imUnknownPeer: 'Desconocido',
  imConfirmDeleteTitle: 'Confirmar eliminación',
  imDeleteConversationContent: '¿Eliminar la conversación con {name}?',
  imPin: 'Fijar',
  imUnpin: 'Desfijar',
  imMarkRead: 'Marcar como leído',
  imDeleteConversation: 'Eliminar conversación',
  imTimeJustNow: 'Ahora',
  imTimeMinutesAgo: 'hace {n} min',
  imTimeYesterday: 'Ayer',
  imTimeDaysAgo: 'hace {n} d',
  imGroupChat: 'Grupo',
  imChatInputHint: 'Escribe un mensaje…',
  imActionCopy: 'Copiar',
  imToastCopied: 'Copiado',
  imActionRevoke: 'Retirar',
  imToastRevokeExpired: 'No se puede retirar tras 2 minutos',
  imAttachImage: 'Imagen',
  imAttachCamera: 'Cámara',
  imAttachVideo: 'Vídeo',
  imAttachFile: 'Archivo',
  imImageExpired: 'Imagen caducada',
  imSaveToAlbum: 'Guardar en álbum',
  imSaveSuccess: 'Guardado',
  imSaveFailed: 'Error al guardar',
  imCacheManageTitle: 'Caché de medios del chat',
  imCacheTotal: 'Total {size}',
  imCacheSelectAll: 'Seleccionar todo',
  imCacheDeselectAll: 'Quitar selección',
  imCacheClearSelected: 'Borrar seleccionado',
  imCacheClearedToast: '{size} borrado',
  imCacheNoSelection: 'Selecciona al menos una conversación',
  imCacheLoading: 'Calculando…',
  imCacheEntry: 'Caché de medios del chat',
  ballMenuTitle: 'Menú rápido',
  ballMenuRestoreSession: 'Restaurar sesión',
  ballMenuRestoreSessionEmpty: 'Sin sesión anterior',
  ballMenuGoHome: 'Volver al inicio',
  defaultStartupEntry: 'App de inicio predeterminada',
  defaultStartupSubtitleNone: 'Sin definir (abre la página de MyApp)',
  defaultStartupTitle: 'App de inicio predeterminada',
  defaultStartupHint: 'Cuando se define, la app abre directamente la elegida. Usa «Volver al inicio» en el menú del botón flotante para volver a la página de MyApp.',
  defaultStartupNoneOption: 'Sin definir (abre la página de MyApp)',
  defaultStartupTabMarket: 'Mercado',
  defaultStartupTabLocal: 'Local',
  defaultStartupEmptyMarket: 'Aún no hay apps en el mercado',
  defaultStartupEmptyLocal: 'Aún no hay apps locales guardadas',
  defaultStartupSavedToast: 'Guardado',
  defaultStartupSetAsStartup: 'Establecer como inicio',
  defaultStartupCurrent: 'App de inicio actual',
  defaultStartupResetToNone: 'Restablecer',
  imAdd: 'Añadir',
  imAddFriend: 'Añadir amigo',
  imCreateGroup: 'Nuevo grupo',
  imMyId: 'Mi ID:',
  imCopiedId: 'ID copiado',
  imNewFriends: 'Nuevas solicitudes',
  imEmptyFriends: 'Aún no tienes amigos',
  imEmptyFriendsHint: 'Toca + arriba para añadir amigos',
  imDeleteFriendTitle: 'Eliminar amigo',
  imDeleteFriendContent: '¿Eliminar a {name}?',
  imApplyAccepted: 'Aceptado',
  imApplyRejected: 'Rechazado',
  imApplyPending: 'Pendiente',
  imEmptyApplications: 'Sin solicitudes entrantes',
  imApplyDefaultMessage: 'Quiere ser tu amigo',
  imAccept: 'Aceptar',
  imReject: 'Rechazar',
  imAddFriendDialogTitle: 'Enviar solicitud de amistad',
  imAddFriendDefaultGreeting: 'Hola, me gustaría añadirte',
  imAddFriendNote: 'Mensaje',
  imSendApplication: 'Enviar',
  imApplicationSent: 'Solicitud enviada. Esperando aprobación.',
  imApplicationFailed: 'No se pudo enviar la solicitud',
  imSearchTitle: 'Añadir amigo',
  imSearchHint: 'Busca por correo, usuario o ID',
  imSearchHelp: 'Introduce correo, usuario o ID',
  imSearchHelpMin: 'Escribe al menos 2 caracteres',
  imSearchNoMatch: 'Ningún usuario coincide con «{q}»',
  imSearchNoMatchHint: 'Deben registrarse primero',
  imYouSelfBadge: '(tú)',
  imCreateGroupFailed: 'No se pudo crear el grupo. Inténtalo de nuevo.',
  imCreateGroupTitle: 'Nuevo grupo',
  imCreate: 'Crear',
  imGroupNameLabel: 'Nombre del grupo',
  imGroupNameHint: 'Pon un nombre al grupo',
  imSelectMembers: 'Elegir miembros',
  imSelectedCount: '{n} seleccionados',
  imEmptyFriendsForGroupHint: 'Añade algunos amigos primero',
  imGroupSettings: 'Ajustes del grupo',
  imMemberCount: '{n} miembros',
  imGroupNotice: 'Aviso del grupo',
  imGroupMembers: 'Miembros',
  imGroupOwnerLabel: 'Propietario',
  imGroupAdminLabel: 'Admin',
  imInviteMembers: 'Invitar miembros',
  imLeaveGroup: 'Salir del grupo',
  imUserIdLabel: 'ID de usuario',
  imUserIdHint: 'ID del usuario a invitar',
  imInviteSent: 'Invitación enviada',
  imInviteFailedWith: 'Error de invitación: {err}',
  imLeaveGroupConfirmContent: '¿Salir de «{name}»?',
  imLeaveFailedWith: 'Error al salir: {err}',
  imConfirmLeave: 'Confirmar salida',
  chatSessionDefaultTitle: 'Chat nuevo',
  chatSessionMenuNew: 'Chat nuevo',
  chatSessionMenuEmpty: 'Aún no hay chats',
  chatSessionRenameTitle: 'Renombrar chat',
  chatSessionRenameHint: 'Nuevo título',
  chatSessionActionRename: 'Renombrar',
  chatSessionDeleteTitle: 'Eliminar chat',
  chatSessionDeleteContent: '¿Eliminar «{title}»? La respuesta que se está ejecutando en segundo plano se cancelará.',
  chatStatusGenerating: 'Generando código...',
  chatStatusStartingAi: 'Iniciando motor de IA...',
  chatStatusResumingLast: 'Restaurando conversación anterior...',
  chatActionUploadCurrentApp: 'Subir configuración actual',
  chatActionRetryDownloadJson: 'Reintentar descarga del JSON',
  chatTimeJustNow: 'ahora mismo',
  chatTimeMinutesAgo: 'hace {n} min',
  chatTimeHoursAgo: 'hace {n} h',
  chatTimeDaysAgo: 'hace {n} d',
  chatDownloadStateDownloading: 'Descargando...',
  chatDownloadStateRun: 'Descargar y ejecutar',
  chatDownloadStateRetry: 'Reintentar descarga y ejecución',
  chatErrorWith: 'Error: {err}',
  chatJsonDownloadFailed: 'Error al descargar el JSON',
  chatNoActiveApp: 'No hay configuración de app activa',
  chatUploadingApp: 'Subiendo configuración actual...',
  chatDownloadRetryFailedWith: 'El reintento de descarga falló: {err}',
  chatAnalysisFailedWith: 'Análisis fallido: {err}',
  chatEditMessageTitle: 'Editar mensaje',
  chatEditMessageHint: 'Edita tu mensaje...',
  chatEditButton: 'Editar',
  chatSendButton: 'Enviar',
  asrErrBytedanceWith: 'Error de ASR ByteDance: {err}',
  asrErrNativeInitWithHint: 'No se pudo inicializar el reconocimiento nativo. Cambia a ASR ByteDance en Ajustes.',
  asrConnectingBytedance: 'Conectando con ASR ByteDance...',
  asrErrBytedanceTimeoutWithHint: 'Tiempo agotado al conectar con ASR ByteDance. Revisa la red o cambia de reconocedor.',
  asrErrNativeStartWithHint: 'El reconocimiento nativo no pudo iniciar. Cambia a ASR ByteDance en Ajustes.',
  asrErrMicPermissionDenied: 'Permiso de micrófono denegado. Actívalo en Ajustes → Apps → Permisos e inténtalo de nuevo.',
  asrErrStartFailWith: 'El reconocimiento de voz no pudo iniciar: {err}',
  asrErrBytedanceNotConnected: 'ASR ByteDance no está conectado. Revisa la red.',
  asrErrBytedanceStartFailWith: 'ASR ByteDance no pudo iniciar: {err}',
  authSwitchAccountCancelled: 'Cambio de cuenta cancelado',
  authClearLocalFailedWith: 'Error al borrar los datos locales: {err}',
  authSwitchAccountTitle: 'Cambiar de cuenta',
  authSwitchAccountContent: 'La cuenta actual ({newEmail}) es distinta de la anterior ({prevEmail}).\n\nContinuar borrará todo el historial de chats, contactos y datos locales. ¿Continuar?',
  authSwitchAccountConfirm: 'Borrar y continuar',
  authErrSignupFailed: 'Error al registrarse',
  authErrLoginFailed: 'Error al iniciar sesión',
  authErrVerifyFailed: 'Verificación fallida',
  authErrSendFailed: 'Envío fallido',
  authErrNoRefreshToken: 'Sin refresh token',
  authErrRefreshFailed: 'Actualización fallida',
  authErrGetUserInfoFailed: 'Error al obtener la info del usuario',
  authErrServerWith: 'Error del servidor ({code})',
  authErrUpdateFailed: 'Actualización fallida',
  authErrAvatarUploadFailed: 'Error al subir el avatar',
  settingsSectionAsr: 'Reconocimiento de voz',
  settingsAsrOnline: 'Reconocimiento online',
  settingsAsrOnlineSubtitle: 'Usa speech_to_text, requiere red',
  settingsAsrBytedance: 'ASR ByteDance',
  settingsAsrBytedanceSubtitle: 'Reconocimiento de voz de ByteDance, requiere red y cuota',
  settingsProvidersFailed: 'No se pudo obtener la lista de proveedores',
  settingsProvidersFallback: 'Usando proveedor predeterminado DeepSeek',
  settingsModelWith: 'Modelo: {model}',
  imUserUnknown: 'Desconocido',
  imMessageRecalled: 'retiró un mensaje',
  imAttachmentFile: 'Archivo',
  imImageQualityNormal: 'Calidad normal',
  imImageQualityNormalSubtitle: 'Compresión automática, lado largo 1920, envío más rápido',
  imImageQualityHd: 'Original',
  imImageQualityHdSubtitle: 'Mantener tamaño y calidad originales',
  imDownloadingMsg: 'Descargando...',
  imDownloadFailedWith: 'Descarga fallida {code}',
  imOpenFailedWith: 'Error al abrir: {msg}',
  imOpenExceptionWith: 'Error de apertura: {err}',
  imVideoLoadFailedWith: 'Error al cargar el video: {err}',
  imPushNewMessage: 'Nuevo mensaje',
  imPushImagePreview: '[Imagen]',
  imMsgPreviewVideo: '[Video]',
  imMsgPreviewVoice: '[Voz]',
  imMsgPreviewFile: '[Archivo]',
  imMsgPreviewLocation: '[Ubicación]',
  imMsgPreviewGeneric: '[Mensaje]',
  mainCantResolveAppConfigError: 'No se pudo resolver o descargar la configuración de la app',
  widgetImagePickerPlaceholder: 'Toca para elegir imagen',
  widgetImagePickerReselect: 'Toca para volver a elegir',
  widgetCameraNoCamera: 'No hay cámara disponible',
  widgetDatePickerPlaceholder: 'Elige una fecha',
  widgetTimePickerPlaceholder: 'Elige una hora',
  widgetButtonDefaultLabel: 'Botón',
  widgetMissingItemTemplate: 'Falta item_template',
  widgetDropdownPlaceholder: 'Seleccionar',
  widgetPullToRefresh: 'Desliza para actualizar',
  widgetVideoNoUrl: 'No hay URL de video configurada',
  widgetVideoUnsupportedSource: 'Fuente de video no compatible',
  widgetVideoPlaybackFailedWith: 'Reproducción fallida: {err}',
  widgetVideoLoadFailedWith: 'Error al cargar el video\n{err}',
  widgetVideoLoading: 'Cargando video...',
  widgetRefNotFoundWith: 'No encontrado: {ref}',
  widgetRefMissingFromOrName: 'El widget ref requiere los campos «from» y «widget»',
  widgetRefMissingRootWith: 'A {ref} le falta la definición de root',
  widgetUnknownTypeWith: 'Tipo de widget desconocido: {type}',
  widgetHttpNetworkFailed: 'Solicitud de red fallida',
  chatErrNoRetryMessage: 'No hay mensaje para reintentar',
  chatErrConnectionUnstableWith: 'La conexión sigue cayendo (ya se reintentó {n} veces)',
  chatErrPleaseLogin: 'Por favor inicia sesión primero',
  chatErrServerWithBody: 'Error del servidor ({code}): {body}',
  chatErrDownloadGenJsonWith: 'Error al descargar el JSON generado (HTTP {code})',
  chatErrDownloadJsonExceptionWith: 'Error al descargar JSON: {err}',
  chatErrCancelled: 'Cancelado',
  chatErrQuotaExceeded: 'Cuota agotada',
  chatErrConnectionTimeout: 'Tiempo de conexión agotado',
  chatErrNetworkWith: 'Error de red: {err}',
  chatErrUploadFailedRetriesWith: 'Subida fallida (ya reintentó {n} veces): {err}',
  chatUploadSuccessIntro: 'Esta es la configuración completa de la JSON-APP actualmente en ejecución (ya subida al almacenamiento temporal). Por favor basa las modificaciones o el análisis en esta configuración:\n\n',
  asrBytedanceConnected: 'Conectado',
  asrBytedanceDisconnected: 'Desconectado',
  asrErrUnknown: 'Error desconocido',
  asrBytedanceConnectFailedWith: 'Conexión fallida: {err}',
  asrErrMicPermissionDeniedShort: 'Permiso de micrófono denegado',
  asrRecordErrorWith: 'Error de grabación: {err}',
  asrRecording: 'Grabando...',
  asrRecordStartFailWith: 'La grabación no pudo iniciar: {err}',
  gameOver: 'Fin del juego',
  gameRestartHint: 'Toca para reiniciar',
  gameBestScoreWith: 'Mejor {score}',
  gameScoreWith: 'Puntuación {score}',
  builtinBiometricDefaultReason: 'Por favor verifica tu identidad',
  builtinInputDialogDefaultTitle: 'Entrada',
  imSenderMe: 'Yo',
  relativeDateYesterday: 'Ayer',
  depErrConflictWith: 'Cargado {loaded}, pero se requiere {needed}',
);

/// 公开访问点。
class T {
  /// 当前 BuildContext 的本地化字符串（推荐用法）
  static FrameworkStrings of(BuildContext context) {
    final localeStr = Localizations.localeOf(context).toLanguageTag();
    return _pick(localeStr);
  }

  /// 不在 widget 树里时（纯函数 / service 层）用这个，跟随用户当前选择的 locale。
  /// 走 LocaleController.currentLocaleTag()：appLocale 有值用值，否则回退到系统 locale。
  /// 注意启动早期 loadFromPrefs() 还没跑时也是回退到系统 locale，行为可预期。
  static FrameworkStrings get current {
    return _pick(LocaleController.currentLocaleTag());
  }

  /// 显式指定 locale 的查找（用于初始化前 / 不在 widget 树里的代码）
  static FrameworkStrings lookup(Locale locale) {
    return _pick(locale.toLanguageTag());
  }

  static FrameworkStrings _pick(String tag) {
    if (tag.startsWith('en')) return _enUS;
    if (tag.startsWith('de')) return _deDE;
    if (tag.startsWith('es')) return _esES;
    return _zhCN; // 默认中文
  }

  /// 框架支持的所有 locale，main.dart 的 supportedLocales 用
  static const List<Locale> supportedLocales = [
    Locale('zh', 'CN'),
    Locale('en', 'US'),
    Locale('de', 'DE'),
    Locale('es', 'ES'),
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
