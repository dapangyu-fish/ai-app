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
