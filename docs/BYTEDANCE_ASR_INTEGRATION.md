# 豆包ASR集成说明

## 概述

已成功将字节跳动豆包ASR（语音识别）集成到主应用中，作为第三种语音识别方式。

## 三种语音识别方式

1. **在线识别** - speech_to_text（原有）
2. **离线识别** - sherpa_onnx（原有）
3. **豆包ASR** - 字节跳动语音识别（新增）

## 配额控制

复用现有的 `chat_quotas` 表来控制使用次数：

- **管理员（admin）**: 999999 次/天（无限制）
- **专业用户（pro）**: 60 次/天
- **普通用户（user）**: 30 次/天

## 后端文件结构

```
backend/
├── app.py                          # 主应用（已修改，集成SocketIO）
├── auth.py                         # 认证模块（已修改，添加SocketIO认证装饰器）
├── bytedance_asr_service.py        # 豆包ASR核心服务（新增）
├── bytedance_asr_routes.py         # 豆包ASR WebSocket路由（新增）
├── requirements.txt                # 依赖（已更新）
└── database.py                     # 数据库（复用现有配额表）
```

## 客户端文件结构

```
lib/designer/
├── bytedance_asr_service.dart      # 豆包ASR服务（新增）
└── bytedance_asr_test_page.dart    # 测试页面示例（新增）
```

## 后端启动

```bash
# 1. 安装依赖
cd backend
pip install -r requirements.txt

# 2. 启动服务器
python app.py
```

服务器将在 `http://0.0.0.0:5566` 启动，WebSocket 端点为 `/socket.io`

## 客户端使用

### 1. 基本使用

```dart
import 'package:your_app/designer/bytedance_asr_service.dart';

final asrService = ByteDanceAsrService.instance;

// 设置回调
asrService.onStatusChange = (status) {
  print('状态: $status');
};

asrService.onResult = (text) {
  print('识别结果: $text');
};

asrService.onError = (error) {
  print('错误: $error');
};

asrService.onQuotaUpdate = (quota) {
  print('配额: ${quota['used']}/${quota['limit']}');
};

// 连接到服务器
final token = 'your_access_token'; // 从登录获取
await asrService.connect('http://your-server:5566', token);

// 开始录音识别
await asrService.startListening();

// 停止录音识别
await asrService.stopListening();

// 断开连接
asrService.disconnect();
```

### 2. 完整示例

参考 `lib/designer/bytedance_asr_test_page.dart`

## API 说明

### WebSocket 事件

#### 客户端 → 服务器

- `asr_connect` - 连接（需要认证）
- `asr_start` - 开始识别（需要认证，会检查配额）
- `asr_audio` - 发送音频数据
  ```json
  {
    "type": "audio",
    "data": "base64编码的PCM音频",
    "is_last": false
  }
  ```
- `asr_disconnect` - 断开连接

#### 服务器 → 客户端

- `asr_connected` - 连接成功
  ```json
  {"status": "ok"}
  ```
- `asr_started` - 识别开始
  ```json
  {
    "status": "ok",
    "quota": {
      "used": 1,
      "limit": 30,
      "remaining": 29
    }
  }
  ```
- `asr_result` - 识别结果
  ```json
  {
    "type": "result",
    "text": "识别的文字",
    "is_final": false
  }
  ```
- `asr_error` - 错误
  ```json
  {
    "type": "error",
    "message": "错误信息",
    "quota": {...}  // 可选
  }
  ```

## 音频参数

- **格式**: PCM 16-bit
- **采样率**: 16000 Hz
- **声道**: 单声道
- **分包大小**: 400ms
- **编码**: Base64

## 配额检查流程

1. 客户端发送 `asr_start` 事件
2. 服务器检查用户配额（通过 token 识别用户）
3. 如果配额充足：
   - 扣除 1 次配额
   - 连接到字节跳动ASR服务
   - 返回 `asr_started` 事件（包含配额信息）
4. 如果配额不足：
   - 返回 `asr_error` 事件（包含配额信息）

## 测试

### 后端测试

```bash
cd backend
python -m py_compile app.py bytedance_asr_service.py bytedance_asr_routes.py
```

### 客户端测试

```bash
flutter analyze lib/designer/bytedance_asr_service.dart lib/designer/bytedance_asr_test_page.dart
```

### 运行测试页面

```bash
flutter run -d <device-id> -t lib/designer/bytedance_asr_test_page.dart
```

## 注意事项

1. **认证**: 客户端必须通过 `token` 参数传递有效的访问令牌
2. **配额**: 每次开始识别会扣除 1 次配额，无论识别时长
3. **网络**: 需要稳定的网络连接，建议使用 WiFi
4. **权限**: 需要麦克风权限
5. **并发**: 目前支持多个客户端同时连接

## 故障排查

### 连接失败

- 检查服务器地址是否正确
- 检查 token 是否有效
- 检查网络连接

### 配额不足

- 检查用户角色和配额限制
- 等待第二天配额重置

### 识别无结果

- 检查麦克风权限
- 检查音频格式是否正确
- 查看服务器日志

## 依赖版本

### 后端

- Flask >= 3.1.0
- flask-socketio >= 5.3.0
- python-socketio >= 5.11.0
- websocket-client >= 1.8.0

### 客户端

- socket_io_client: ^2.0.3+1
- record: ^6.2.0
- shared_preferences: ^2.5.5

## 更新日志

### 2026-04-27

- ✅ 集成字节跳动豆包ASR
- ✅ 添加配额控制（复用 chat_quotas 表）
- ✅ 添加 SocketIO 认证装饰器
- ✅ 创建核心服务和路由
- ✅ 创建客户端服务和测试页面
- ✅ 所有代码编译通过
