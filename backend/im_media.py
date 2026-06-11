"""IM 富媒体上传 - 图片 / 视频 / 文件 / 视频首帧

设计：
  客户端 POST /api/im/media/upload-url
    body: { "purpose": "image"|"video"|"file"|"snapshot",
            "ext": "jpg",
            "content_type": "image/jpeg",
            "size": 850000 }
    resp: { "put_url": <presigned PUT, 15min>,
            "public_url": <https://oss/im-media/...>,
            "key":  "<purpose>/<yyyy>/<mm>/<userid>_<uuid>.<ext>" }

  客户端用 put_url 直传到 MinIO，然后用 public_url 调 OpenIM
  createXxxMessageByURL 建系统消息。

bucket = "im-media"。bucket policy 设为 public-read 后 public_url 直接可访问；
没设的话客户端要再调 /api/im/media/get-url 拿预签名 GET（生命周期 24h）。
默认走 public-read（和现有 json-component / models 一致），加密内容不走这条
通道。

为什么不让 OpenIM SDK 自己上传：
  OpenIM 自带 MinIO 桶，但跟我们现有 ops 栈是两套。统一到一个 MinIO 集群
  方便后续做 lifecycle / 统计 / CDN。SDK 提供了 createXxxMessageByURL，
  正好走这条路。

PR-1 范围：仅本文件 + app.py 注册。客户端 lib/im/im_media_uploader.dart
随后一同提交。
"""
import os
import uuid
from datetime import datetime, timedelta
from urllib.parse import urlparse

from flask import jsonify, request
from minio import Minio

from auth import require_auth
from config import (
    MINIO_ACCESS_KEY,
    MINIO_ENDPOINT,
    MINIO_PUBLIC_URL,
    MINIO_SECRET_KEY,
    MINIO_SECURE,
)

BUCKET = "im-media"

# 各 purpose 的大小上限（字节）。超过后端直接 413。
# 移动端原图照片就能轻松上 10MB 不裁剪，所以 image 给到 15MB；
# 视频 100MB 是 1080p / 60s 左右一个 mp4 的体量；其余文件按 30MB 兜底。
SIZE_LIMITS = {
    "image": 15 * 1024 * 1024,
    "snapshot": 2 * 1024 * 1024,  # 视频首帧缩略图，必然很小
    "video": 100 * 1024 * 1024,
    "file": 30 * 1024 * 1024,
}

# MIME 白名单。一刀切 image/* 和 video/* 是为了让相册随手发的 heic / mov
# 都能过；file 走具体白名单，杜绝随手 .exe / .apk。
ALLOWED_MIME_PATTERNS = {
    "image": [r"image/"],
    "snapshot": [r"image/jpeg", r"image/png"],
    "video": [r"video/"],
    "file": [
        # 文档
        "application/pdf",
        "application/msword",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "application/vnd.ms-excel",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "application/vnd.ms-powerpoint",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "text/plain",
        "text/csv",
        "application/json",
        # 压缩包
        "application/zip",
        "application/x-zip-compressed",
        "application/x-tar",
        "application/gzip",
        "application/x-7z-compressed",
        "application/x-rar-compressed",
    ],
}

# 后缀白名单：MIME 拿不到时（比如有些客户端不传 content_type）兜底
ALLOWED_EXT = {
    "image": {"jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp"},
    "snapshot": {"jpg", "jpeg", "png"},
    "video": {"mp4", "mov", "m4v", "webm", "mkv", "avi", "3gp"},
    "file": {
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx",
        "txt", "csv", "json", "md",
        "zip", "tar", "gz", "7z", "rar",
    },
}

# 预签名有效期。15 分钟够单文件上传；客户端排队多文件时每个文件单独申请。
PRESIGN_TTL = timedelta(minutes=15)


_minio_client = Minio(
    MINIO_ENDPOINT,
    access_key=MINIO_ACCESS_KEY,
    secret_key=MINIO_SECRET_KEY,
    secure=MINIO_SECURE,
)


def _minio_presign_client() -> Minio:
    """Sign client-facing URLs with the public OSS host.

    S3 v4 signatures include the Host header. The object operations still use
    the internal service endpoint, but presigned URLs sent to mobile clients
    must be signed for the public domain they will actually PUT to.
    """
    public_base = (MINIO_PUBLIC_URL or "").rstrip("/")
    if public_base:
        parsed = urlparse(public_base)
        if parsed.netloc:
            return Minio(
                parsed.netloc,
                access_key=MINIO_ACCESS_KEY,
                secret_key=MINIO_SECRET_KEY,
                secure=parsed.scheme == "https",
            )
    return _minio_client


def _ensure_bucket():
    """首次调用时建桶 + 设 public-read 策略。幂等。"""
    if _minio_client.bucket_exists(BUCKET):
        return
    _minio_client.make_bucket(BUCKET)
    # public-read：client 直接 GET 不用预签名，OpenIM 消息里塞的 URL 才能直读
    import json as _json
    policy = {
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow",
                "Principal": {"AWS": ["*"]},
                "Action": ["s3:GetObject"],
                "Resource": [f"arn:aws:s3:::{BUCKET}/*"],
            }
        ],
    }
    _minio_client.set_bucket_policy(BUCKET, _json.dumps(policy))


def _validate_mime(purpose: str, content_type: str) -> bool:
    pats = ALLOWED_MIME_PATTERNS.get(purpose, [])
    for p in pats:
        # 模式以 "/" 结尾视为 prefix（image/、video/）；否则全等
        if p.endswith("/"):
            if content_type.lower().startswith(p):
                return True
        else:
            if content_type.lower() == p:
                return True
    return False


def _validate_ext(purpose: str, ext: str) -> bool:
    return ext.lower() in ALLOWED_EXT.get(purpose, set())


def _build_key(purpose: str, user_id: str, ext: str) -> str:
    """key 格式: <purpose>/<yyyy>/<mm>/<userid>_<uuid>.<ext>
    分目录是为了后续做 lifecycle 时按 prefix 删旧。"""
    now = datetime.utcnow()
    safe_uid = (user_id or "anon").replace("-", "")[:16]
    name = f"{safe_uid}_{uuid.uuid4().hex}.{ext}"
    return f"{purpose}/{now:%Y/%m}/{name}"


@require_auth
def upload_url():
    """生成预签名 PUT。客户端拿到后直传到 MinIO，避免大文件经过 Flask。"""
    body = request.get_json(silent=True) or {}
    purpose = (body.get("purpose") or "").lower()
    ext = (body.get("ext") or "").lower().lstrip(".")
    content_type = (body.get("content_type") or "application/octet-stream").lower()
    size = body.get("size")

    if purpose not in SIZE_LIMITS:
        return jsonify({"error": f"purpose 必须是 {list(SIZE_LIMITS)}"}), 400

    if not ext:
        return jsonify({"error": "ext 必填"}), 400

    if not _validate_ext(purpose, ext):
        return jsonify({"error": f"{purpose} 不支持后缀 .{ext}"}), 400

    if not _validate_mime(purpose, content_type):
        return jsonify({"error": f"{purpose} 不支持 content_type={content_type}"}), 400

    if not isinstance(size, int) or size <= 0:
        return jsonify({"error": "size 必须是正整数"}), 400

    if size > SIZE_LIMITS[purpose]:
        max_mb = SIZE_LIMITS[purpose] // (1024 * 1024)
        return jsonify({"error": f"{purpose} 单文件最大 {max_mb}MB"}), 413

    user = request.supabase_user or {}
    user_id = str(user.get("id", "")) or ""

    try:
        _ensure_bucket()
        key = _build_key(purpose, user_id, ext)
        put_url = _minio_presign_client().presigned_put_object(BUCKET, key, expires=PRESIGN_TTL)
        public_url = f"{MINIO_PUBLIC_URL.rstrip('/')}/{BUCKET}/{key}"
        return jsonify({
            "put_url": put_url,
            "public_url": public_url,
            "key": key,
            "expires_in": int(PRESIGN_TTL.total_seconds()),
        })
    except Exception as e:
        return jsonify({"error": f"签名失败: {e}"}), 500
