use serde_json::{json, Value};
use worker::{Headers, Request, Response, Result, RouteContext, Router};

use crate::glue::{error_json, AuthOutcome};
use crate::oauth;
use crate::routes_memory::wasm_glue::{d1_first, d1_run, n, s};
use crate::worker_util::now_ms;

pub fn register(router: Router<'static, ()>) -> Router<'static, ()> {
    router
        .get_async(
            "/.well-known/oauth-authorization-server",
            authorization_server_metadata,
        )
        .get_async(
            "/.well-known/oauth-protected-resource",
            protected_resource_metadata,
        )
        .get_async(
            "/mcp/.well-known/oauth-protected-resource",
            protected_resource_metadata,
        )
        .get_async("/oauth/authorize", authorize)
        .post_async("/oauth/token", token)
        .post_async("/oauth/revoke", revoke)
}

fn metadata_response(body: Value) -> Result<Response> {
    let headers = Headers::new();
    headers.set("cache-control", "public, max-age=3600")?;
    Ok(Response::from_json(&body)?.with_headers(headers))
}

async fn authorization_server_metadata(_req: Request, _ctx: RouteContext<()>) -> Result<Response> {
    metadata_response(json!({
        "issuer": oauth::ISSUER,
        "authorization_endpoint": format!("{}/oauth/authorize", oauth::ISSUER),
        "token_endpoint": format!("{}/oauth/token", oauth::ISSUER),
        "revocation_endpoint": format!("{}/oauth/revoke", oauth::ISSUER),
        "response_types_supported": ["code"],
        "grant_types_supported": ["authorization_code"],
        "token_endpoint_auth_methods_supported": ["none"],
        "code_challenge_methods_supported": ["S256"],
        "scopes_supported": oauth::ALLOWED_SCOPES,
    }))
}

async fn protected_resource_metadata(_req: Request, _ctx: RouteContext<()>) -> Result<Response> {
    metadata_response(json!({
        "resource": oauth::MCP_RESOURCE,
        "authorization_servers": [oauth::ISSUER],
        "scopes_supported": oauth::ALLOWED_SCOPES,
    }))
}

fn query(req: &Request, key: &str) -> Option<String> {
    req.url()
        .ok()?
        .query_pairs()
        .find_map(|(name, value)| (name == key).then(|| value.into_owned()))
}

fn redirect_uri(redirect_uri: &str, code: &str, state: &str) -> Option<url::Url> {
    let mut url = url::Url::parse(redirect_uri).ok()?;
    url.query_pairs_mut()
        .append_pair("code", code)
        .append_pair("state", state);
    Some(url)
}

async fn authorize(req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let response_type = query(&req, "response_type").unwrap_or_default();
    let client_id = query(&req, "client_id").unwrap_or_default();
    let redirect = query(&req, "redirect_uri").unwrap_or_default();
    let scope = query(&req, "scope").unwrap_or_default();
    let state = query(&req, "state").unwrap_or_default();
    let challenge = query(&req, "code_challenge").unwrap_or_default();
    let method = query(&req, "code_challenge_method").unwrap_or_default();
    if response_type != "code"
        || !oauth::registered_client(&client_id, &redirect)
        || state.is_empty()
        || state.len() > 1024
        || !oauth::valid_code_challenge(&challenge)
    {
        return error_json("Invalid authorization request", 400);
    }
    let Some(scopes) = oauth::normalize_scopes(&scope) else {
        return error_json("Invalid authorization request", 400);
    };
    if method != "S256" {
        return error_json("Invalid authorization request", 400);
    }
    let authorization = req
        .headers()
        .get("authorization")
        .ok()
        .flatten()
        .unwrap_or_default();
    let Some(firebase_token) = crate::auth::bearer_token(&authorization) else {
        return error_json("Authentication failed", 401);
    };
    let auth = match crate::glue::authenticate_firebase_bearer(&firebase_token, &ctx).await {
        AuthOutcome::Ok(auth) => auth,
        AuthOutcome::Reject(response) => return Ok(response),
    };
    let mut entropy = [0u8; 32];
    if getrandom::getrandom(&mut entropy).is_err() {
        return error_json("Authorization unavailable", 503);
    }
    let code = crate::crypto_util::base64url(&entropy);
    let now = now_ms();
    let db = ctx.env.d1("DB")?;
    d1_run(
        &db,
        "INSERT INTO oauth_authorization_codes (code_hash, uid, client_id, redirect_uri, scopes, code_challenge, expires_at, created_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
        &[
            s(&oauth::authorization_code_hash(&code)),
            s(&auth.uid),
            s(&client_id),
            s(&redirect),
            s(&scopes),
            s(&challenge),
            n(now.saturating_add(oauth::AUTHORIZATION_CODE_TTL_MS)),
            n(now),
        ],
    )
    .await?;
    let Some(location) = redirect_uri(&redirect, &code, &state) else {
        return error_json("Invalid authorization request", 400);
    };
    Response::redirect(location)
}

fn form_value(body: &str, name: &str) -> Option<String> {
    let mut values = url::form_urlencoded::parse(body.as_bytes()).filter(|(key, _)| key == name);
    let value = values.next()?.1.into_owned();
    values.next().is_none().then_some(value)
}

async fn token(mut req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let body = req.text().await.unwrap_or_default();
    let grant_type = form_value(&body, "grant_type").unwrap_or_default();
    let code = form_value(&body, "code").unwrap_or_default();
    let client_id = form_value(&body, "client_id").unwrap_or_default();
    let redirect = form_value(&body, "redirect_uri").unwrap_or_default();
    let verifier = form_value(&body, "code_verifier").unwrap_or_default();
    if grant_type != "authorization_code"
        || !oauth::registered_client(&client_id, &redirect)
        || verifier.is_empty()
    {
        return oauth_error("invalid_grant", 400);
    }
    let now = now_ms();
    let db = ctx.env.d1("DB")?;
    let code_hash = oauth::authorization_code_hash(&code);
    let Some(row) = d1_first(
        &db,
        "SELECT uid, scopes, code_challenge FROM oauth_authorization_codes WHERE code_hash = ?1 AND client_id = ?2 AND redirect_uri = ?3 AND consumed_at IS NULL AND expires_at > ?4",
        &[s(&code_hash), s(&client_id), s(&redirect), n(now)],
    )
    .await?
    else {
        return oauth_error("invalid_grant", 400);
    };
    let uid = row.get("uid").and_then(Value::as_str).unwrap_or_default();
    let scopes = row
        .get("scopes")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let challenge = row
        .get("code_challenge")
        .and_then(Value::as_str)
        .unwrap_or_default();
    if uid.is_empty() || scopes.is_empty() || !oauth::validate_pkce("S256", challenge, &verifier) {
        return oauth_error("invalid_grant", 400);
    }
    let mut entropy = [0u8; 32];
    if getrandom::getrandom(&mut entropy).is_err() {
        return oauth_error("temporarily_unavailable", 503);
    }
    let access_token = crate::crypto_util::base64url(&entropy);
    let expires_at = now.saturating_add(oauth::ACCESS_TOKEN_TTL_MS);
    let result = db.batch(vec![
        db.prepare("UPDATE oauth_authorization_codes SET consumed_at = ?2 WHERE code_hash = ?1 AND client_id = ?3 AND redirect_uri = ?4 AND consumed_at IS NULL AND expires_at > ?2")
            .bind(&[s(&code_hash), n(now), s(&client_id), s(&redirect)])?,
        db.prepare("INSERT INTO oauth_access_tokens (token_hash, uid, client_id, scopes, expires_at, created_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6)")
            .bind(&[s(&oauth::access_token_hash(&access_token)), s(uid), s(&client_id), s(scopes), n(expires_at), n(now)])?,
    ]).await?;
    if result.len() != 2
        || crate::worker_util::changes(&result[0]) != 1
        || crate::worker_util::changes(&result[1]) != 1
    {
        return oauth_error("invalid_grant", 400);
    }
    Response::from_json(&json!({
        "access_token": access_token,
        "token_type": "Bearer",
        "expires_in": oauth::ACCESS_TOKEN_TTL_MS / 1000,
        "scope": scopes,
    }))
}

fn oauth_error(error: &str, status: u16) -> Result<Response> {
    Ok(Response::from_json(&json!({ "error": error }))?.with_status(status))
}

/// RFC 7009-compatible idempotent access-token revocation for the registered
/// public client. The bearer is hashed before D1 lookup/update and the same
/// empty success shape covers unknown, expired, or already-revoked values.
async fn revoke(mut req: Request, ctx: RouteContext<()>) -> Result<Response> {
    let body = req.text().await.unwrap_or_default();
    let token = form_value(&body, "token").unwrap_or_default();
    let client_id = form_value(&body, "client_id").unwrap_or_default();
    if !oauth::valid_bearer_token(&token)
        || !oauth::registered_client(&client_id, "https://claude.ai/api/mcp/auth_callback")
    {
        return Ok(Response::empty()?.with_status(200));
    }
    let _ = d1_run(
        &ctx.env.d1("DB")?,
        "UPDATE oauth_access_tokens SET revoked_at = ?3 WHERE token_hash = ?1 AND client_id = ?2 AND revoked_at IS NULL",
        &[s(&oauth::access_token_hash(&token)), s(&client_id), n(now_ms())],
    )
    .await;
    Ok(Response::empty()?.with_status(200))
}

pub(crate) async fn verify_access_token(
    ctx: &RouteContext<()>,
    authorization: &str,
) -> Result<Option<(String, Vec<String>)>> {
    let Some(token) = crate::auth::bearer_token(authorization) else {
        return Ok(None);
    };
    if !oauth::valid_bearer_token(&token) {
        return Ok(None);
    }
    let row = d1_first(
        &ctx.env.d1("DB")?,
        "SELECT uid, scopes FROM oauth_access_tokens WHERE token_hash = ?1 AND revoked_at IS NULL AND expires_at > ?2",
        &[s(&oauth::access_token_hash(&token)), n(now_ms())],
    )
    .await?;
    let Some(row) = row else {
        return Ok(None);
    };
    let uid = row.get("uid").and_then(Value::as_str).unwrap_or_default();
    let scopes = row
        .get("scopes")
        .and_then(Value::as_str)
        .and_then(oauth::normalize_scopes);
    let Some(scopes) = scopes else {
        return Ok(None);
    };
    Ok((!uid.is_empty()).then(|| {
        (
            uid.to_owned(),
            scopes.split(' ').map(str::to_owned).collect(),
        )
    }))
}
