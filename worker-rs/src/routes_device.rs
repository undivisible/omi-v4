//! workers-rs I/O layer for pendant home-STA device cloud sync.
//! Compiled only for wasm32. Behaviour parity with `worker/src/device-sync.ts`.
//!
//! Routes:
//! - `POST /api/v1/devices/register` — Firebase auth; mints `omi_dev_` token
//! - `POST /api/v1/devices/:deviceId/audio` — device-token auth; metadata stub
//!   (`persisted: false`)

use serde_json::{json, Value};
use worker::{Headers, Request, Response, Result, RouteContext, Router};

use crate::device_sync::{
    self, DeviceTokenCandidate, MAXIMUM_REGISTERS_PER_HOUR, MAXIMUM_UPLOADS_PER_MINUTE,
    MAXIMUM_UPLOAD_BYTES, REGISTER_RATE_WINDOW_MS,
};
use crate::glue::{authenticate, error_json, AuthOutcome};
use crate::routes_ai::consume_rate_limit;
use crate::routes_memory::wasm_glue::{d1_all, d1_first, d1_run, n, nullable_s, s, str_field};
use crate::worker_util::{now_ms, secret_or_var as env_get, uuid_v4};

/// Register device-sync routes on the shared glue router.
pub fn register(router: Router<'static, ()>) -> Router<'static, ()> {
    router
        .post_async("/api/v1/devices/register", handle_register)
        .post_async("/api/v1/devices/:deviceId/audio", handle_audio_upload)
}

async fn json_object(req: &mut Request) -> Option<Value> {
    req.json::<Value>().await.ok().filter(Value::is_object)
}

fn json_status(body: &Value, status: u16) -> Result<Response> {
    Ok(Response::from_json(body)?.with_status(status))
}

/// Verified device token context (`requireDeviceToken`).
struct DeviceAuth {
    uid: String,
    device_id: String,
}

enum DeviceAuthOutcome {
    Ok(DeviceAuth),
    Reject(Response),
}

/// Port of `verifyDeviceToken` + `requireDeviceToken`.
/// Revoked tokens **or** revoked devices are rejected (SQL join filter).
async fn require_device_token(req: &Request, ctx: &RouteContext<()>) -> DeviceAuthOutcome {
    let authorization = req
        .headers()
        .get("authorization")
        .ok()
        .flatten()
        .unwrap_or_default();
    let bearer = authorization
        .strip_prefix("Bearer ")
        .map(str::trim)
        .unwrap_or("")
        .to_string();
    let header_token = req
        .headers()
        .get("x-device-token")
        .ok()
        .flatten()
        .unwrap_or_default();
    let token = if bearer.is_empty() {
        header_token.trim().to_string()
    } else {
        bearer
    };
    if !token.starts_with(device_sync::DEVICE_TOKEN_PREFIX) {
        return reject_device("Device token required", 401);
    }
    let Some(prefix) = device_sync::parse_device_token(&token) else {
        return reject_device("Authentication failed", 401);
    };
    let db = match ctx.env.d1("DB") {
        Ok(db) => db,
        Err(_) => return reject_device("Authentication unavailable", 503),
    };
    let now = now_ms();
    let rows = match d1_all(
        &db,
        "SELECT t.id, t.device_id, t.uid, t.token_hash FROM device_tokens t\n       INNER JOIN devices d ON d.id = t.device_id\n       WHERE t.prefix = ?1 AND t.revoked_at IS NULL AND d.revoked_at IS NULL",
        &[s(prefix)],
    )
    .await
    {
        Ok(rows) => rows,
        Err(_) => return reject_device("Authentication unavailable", 503),
    };
    let candidates: Vec<DeviceTokenCandidate> = rows
        .iter()
        .map(|row| DeviceTokenCandidate {
            id: str_field(row, "id"),
            device_id: str_field(row, "device_id"),
            uid: str_field(row, "uid"),
            token_hash: str_field(row, "token_hash"),
        })
        .collect();
    let presented = device_sync::digest_token(&token);
    let Some(matched) = device_sync::select_device_match(&presented, &candidates) else {
        return reject_device("Authentication failed", 401);
    };
    let _ = d1_run(
        &db,
        "UPDATE device_tokens SET last_used_at = ?1 WHERE id = ?2",
        &[n(now), s(&matched.id)],
    )
    .await;
    let _ = d1_run(
        &db,
        "UPDATE devices SET last_seen_at = ?1 WHERE id = ?2",
        &[n(now), s(&matched.device_id)],
    )
    .await;
    DeviceAuthOutcome::Ok(DeviceAuth {
        uid: matched.uid.clone(),
        device_id: matched.device_id.clone(),
    })
}

fn reject_device(message: &str, status: u16) -> DeviceAuthOutcome {
    let response = error_json(message, status).unwrap_or_else(|_| {
        Response::error(message.to_string(), status).unwrap_or_else(|_| {
            Response::empty()
                .map(|r| r.with_status(status))
                .expect("empty response")
        })
    });
    DeviceAuthOutcome::Reject(response)
}

fn request_origin(req: &Request) -> String {
    match req.url() {
        Ok(url) => {
            let host = url.host_str().unwrap_or("");
            if host.is_empty() {
                String::new()
            } else {
                format!("{}://{}", url.scheme(), host)
            }
        }
        Err(_) => String::new(),
    }
}

async fn handle_register(mut req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let auth = match authenticate(&req, &ctx).await {
        AuthOutcome::Ok(auth) => auth,
        AuthOutcome::Reject(response) => return Ok(response),
    };
    let body = json_object(&mut req).await;
    let request = match device_sync::validate_register(body.as_ref()) {
        Ok(request) => request,
        Err(message) => return error_json(message, 400),
    };
    let (allowed, retry_after) = consume_rate_limit(
        &ctx.env,
        &format!("device-register:{}", auth.uid),
        MAXIMUM_REGISTERS_PER_HOUR,
        REGISTER_RATE_WINDOW_MS,
    )
    .await;
    if !allowed {
        let headers = Headers::new();
        headers.set("retry-after", &retry_after.to_string())?;
        return Ok(
            Response::from_json(&json!({ "error": "Too many requests" }))?
                .with_status(429)
                .with_headers(headers),
        );
    }
    let db = ctx.env.d1("DB")?;
    let now = now_ms();
    let existing = d1_first(
        &db,
        "SELECT id FROM devices WHERE uid = ?1 AND device_uid = ?2 AND revoked_at IS NULL",
        &[s(&auth.uid), s(&request.device_uid)],
    )
    .await?;
    let device_id = match existing.as_ref().map(|row| str_field(row, "id")) {
        Some(id) if !id.is_empty() => id,
        _ => uuid_v4(),
    };
    if existing.is_none() {
        d1_run(
            &db,
            "INSERT INTO devices (id, uid, device_uid, name, created_at, last_seen_at)\n       VALUES (?1, ?2, ?3, ?4, ?5, ?5)",
            &[
                s(&device_id),
                s(&auth.uid),
                s(&request.device_uid),
                nullable_s(request.name.as_deref()),
                n(now),
            ],
        )
        .await?;
    } else if let Some(name) = request.name.as_deref() {
        d1_run(
            &db,
            "UPDATE devices SET name = ?1, last_seen_at = ?2 WHERE id = ?3",
            &[s(name), n(now), s(&device_id)],
        )
        .await?;
    }

    // Rotate: revoke any live tokens for this device, then mint a fresh one.
    d1_run(
        &db,
        "UPDATE device_tokens SET revoked_at = ?1\n     WHERE device_id = ?2 AND revoked_at IS NULL",
        &[n(now), s(&device_id)],
    )
    .await?;

    let mut prefix_bytes = [0u8; 4];
    let mut secret_bytes = [0u8; 32];
    getrandom::getrandom(&mut prefix_bytes).expect("getrandom");
    getrandom::getrandom(&mut secret_bytes).expect("getrandom");
    let minted = device_sync::mint_device_token(prefix_bytes, secret_bytes);
    let token_id = uuid_v4();
    d1_run(
        &db,
        "INSERT INTO device_tokens (id, device_id, uid, prefix, token_hash, created_at)\n     VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        &[
            s(&token_id),
            s(&device_id),
            s(&auth.uid),
            s(&minted.prefix),
            s(&minted.hash),
            n(now),
        ],
    )
    .await?;

    let host = env_get(&ctx.env, "APP_URL")
        .map(|value| value.trim_end_matches('/').to_string())
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| request_origin(&req));

    Response::from_json(&json!({
        "deviceId": device_id,
        "deviceUid": request.device_uid,
        "token": minted.token,
        "uploadHost": host,
        "uploadPath": format!("/api/v1/devices/{device_id}/audio"),
    }))
}

async fn handle_audio_upload(mut req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let device = match require_device_token(&req, &ctx).await {
        DeviceAuthOutcome::Ok(device) => device,
        DeviceAuthOutcome::Reject(response) => return Ok(response),
    };
    let path_device_id = ctx.param("deviceId").cloned().unwrap_or_default();
    if path_device_id.is_empty() || path_device_id != device.device_id {
        return error_json("Device mismatch", 403);
    }

    if let Some(declared) = req
        .headers()
        .get("content-length")
        .ok()
        .flatten()
        .and_then(|value| value.parse::<f64>().ok())
        .filter(|value| value.is_finite())
    {
        if declared > MAXIMUM_UPLOAD_BYTES as f64 {
            return error_json("Audio too large", 413);
        }
    }

    let body = json_object(&mut req).await;
    let upload = match device_sync::validate_upload(body.as_ref()) {
        Ok(upload) => upload,
        Err("Audio too large") => return error_json("Audio too large", 413),
        Err(message) => return error_json(message, 400),
    };

    let db = ctx.env.d1("DB")?;
    let now = now_ms();
    let recent = d1_first(
        &db,
        "SELECT COUNT(*) AS n FROM device_audio_uploads\n     WHERE device_id = ?1 AND created_at >= ?2",
        &[s(&device.device_id), n(now - 60_000)],
    )
    .await?;
    let recent_n = recent
        .as_ref()
        .and_then(|row| row.get("n"))
        .and_then(|value| value.as_i64().or_else(|| value.as_f64().map(|n| n as i64)))
        .unwrap_or(0);
    if recent_n >= MAXIMUM_UPLOADS_PER_MINUTE {
        return error_json("Rate limited", 429);
    }

    // Metadata receipt only — audio bytes are not persisted yet (home STA stub).
    let upload_id = uuid_v4();
    d1_run(
        &db,
        "INSERT INTO device_audio_uploads\n       (id, device_id, uid, start_seq, packet_count, byte_count, created_at)\n     VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
        &[
            s(&upload_id),
            s(&device.device_id),
            s(&device.uid),
            s(&upload.start_seq),
            n(upload.packet_count),
            n(upload.byte_count),
            n(now),
        ],
    )
    .await?;

    json_status(
        &json!({
            "uploadId": upload_id,
            "accepted": true,
            "persisted": false,
            "startSeq": upload.start_seq,
            "packetCount": upload.packet_count,
            "byteCount": upload.byte_count,
        }),
        200,
    )
}
