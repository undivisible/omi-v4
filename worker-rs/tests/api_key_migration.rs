use std::fs;
use std::path::Path;

use omi_v4_api_rs::api_key_migration::{
    automatic_migration_request, eligible_migration, forwardable_firebase_bearer,
    legacy_metadata_endpoint, legacy_metadata_response, legacy_metadata_unavailable,
    migration_receipt, project_legacy_metadata, validate_migration_request, LegacyKeyKind,
    MigrationRequestError, LEGACY_KEY_KINDS, LEGACY_METADATA_FIELDS,
    LEGACY_METADATA_UNAVAILABLE_STATUS,
};
use omi_v4_api_rs::crypto_util::base64url;
use serde_json::json;

const FIREBASE_HEADER: &[u8] = br#"{"alg":"RS256","kid":"test-kid"}"#;
const WORKER_SESSION_HEADER: &[u8] = br#"{"alg":"HS256","typ":"JWT"}"#;
const NO_KID_HEADER: &[u8] = br#"{"alg":"RS256"}"#;
const EMPTY_KID_HEADER: &[u8] = br#"{"alg":"RS256","kid":""}"#;
const NONE_ALG_HEADER: &[u8] = br#"{"alg":"none"}"#;
const PAYLOAD: &[u8] = br#"{"sub":"uid-1"}"#;

/// Builds a syntactically-shaped, unsigned JWT for the forwardability checks.
/// The signature segment is a literal placeholder so no fixture in this file
/// resembles a usable credential.
fn unsigned_jwt(header: &[u8], payload: &[u8]) -> String {
    format!(
        "{}.{}.{}",
        base64url(header),
        base64url(payload),
        "signature-placeholder"
    )
}

#[test]
fn migration_accepts_only_a_named_legacy_kind_and_never_accepts_a_raw_key() {
    let request = validate_migration_request(
        &json!({
            "legacyKind": "mcp",
            "name": "  Claude Desktop replacement  ",
            "scopes": ["memory:read", "conversations:read"]
        }),
        1_000,
    )
    .expect("metadata-only migration request should validate");

    assert_eq!(request.legacy_kind, LegacyKeyKind::Mcp);
    assert_eq!(request.name, "Claude Desktop replacement");
    assert_eq!(request.scopes, vec!["memory:read", "conversations:read"]);
    assert!(validate_migration_request(
        &json!({
            "legacyKind": "mcp",
            "name": "client",
            "legacyKey": "omi_mcp_0123456789abcdef0123456789abcdef"
        }),
        1_000,
    )
    .is_err());
}

#[test]
fn migration_receipt_is_account_bound_and_has_no_credential_material() {
    let receipt = migration_receipt("migration-1", "uid-1", "key-1", LegacyKeyKind::Dev, 7_000);
    assert_eq!(receipt["id"], "migration-1");
    assert_eq!(receipt["legacyKind"], "dev");
    assert_eq!(receipt["replacementKeyId"], "key-1");
    assert_eq!(receipt["completedAt"], 7_000);
    assert!(receipt.get("key").is_none());
    assert!(receipt.get("legacyKey").is_none());
}

#[test]
fn migration_rejects_unknown_kind_empty_scopes_and_raw_key_like_names() {
    for body in [
        json!({"legacyKind": "other", "name": "client", "scopes": ["memory:read"]}),
        json!({"legacyKind": "mcp", "name": "client", "scopes": []}),
        json!({"legacyKind": "mcp", "name": "omi_mcp_0123456789abcdef0123456789abcdef", "scopes": ["memory:read"]}),
    ] {
        assert!(matches!(
            validate_migration_request(&body, 1_000),
            Err(MigrationRequestError::Invalid)
        ));
    }
}

#[test]
fn automatic_reconciliation_is_zero_click_and_uses_safe_defaults() {
    let request = automatic_migration_request(&json!({})).expect("empty reconciliation request");
    assert_eq!(request.name, "Migrated MCP integration");
    assert_eq!(request.scopes, vec!["memory:read", "conversations:read"]);

    // A reconciler accepts no caller-supplied material: it must discover account
    // metadata server-side, not turn UI/body fields into a migration request.
    assert!(automatic_migration_request(&json!({"legacyKey": "omi_mcp_secret"})).is_err());
}

#[test]
fn eligible_migration_is_metadata_only_and_reuses_defaults_and_receipts() {
    let without_receipt = eligible_migration(None);
    assert_eq!(without_receipt["legacyKind"], "mcp");
    assert_eq!(without_receipt["name"], "Migrated MCP integration");
    let expected_scopes = json!(["memory:read", "conversations:read"]);
    assert_eq!(
        without_receipt["scopes"].as_array().unwrap(),
        expected_scopes.as_array().unwrap()
    );
    assert_eq!(without_receipt["alreadyMigrated"], false);
    assert!(without_receipt["receiptId"].is_null());

    let with_receipt = eligible_migration(Some("migration-1"));
    assert_eq!(with_receipt["alreadyMigrated"], true);
    assert_eq!(with_receipt["receiptId"], "migration-1");

    // Discovery must never surface raw legacy or replacement secrets.
    assert!(without_receipt.get("key").is_none());
    assert!(without_receipt.get("legacyKey").is_none());
    assert!(without_receipt.get("replacementKeyId").is_none());
    assert!(without_receipt.get("secret").is_none());
}

#[test]
fn legacy_metadata_endpoints_are_pinned_to_two_allowlisted_paths_under_the_configured_base() {
    let expected_kinds = [LegacyKeyKind::Mcp, LegacyKeyKind::Dev];
    assert_eq!(LEGACY_KEY_KINDS, expected_kinds);

    let mcp = legacy_metadata_endpoint("https://api.omi.example", LegacyKeyKind::Mcp);
    let dev = legacy_metadata_endpoint("https://api.omi.example/", LegacyKeyKind::Dev);
    assert_eq!(mcp.unwrap(), "https://api.omi.example/v1/mcp/keys");
    assert_eq!(dev.unwrap(), "https://api.omi.example/v1/dev/keys");

    // A base that carries anything beyond an https origin could send the
    // forwarded bearer somewhere other than the two allowlisted endpoints.
    for base in [
        "",
        "not a url",
        "http://api.omi.example",
        "https://user@api.omi.example",
        "https://user:pass@api.omi.example",
        "https://api.omi.example/proxy",
        "https://api.omi.example/?next=1",
        "https://api.omi.example/#fragment",
    ] {
        let resolved = legacy_metadata_endpoint(base, LegacyKeyKind::Mcp);
        assert!(resolved.is_none(), "base must be refused: {base}");
    }
}

#[test]
fn forwarded_legacy_bearer_requests_reject_redirects() {
    let route_source =
        fs::read_to_string(Path::new(env!("CARGO_MANIFEST_DIR")).join("src/routes_keys.rs"))
            .expect("read legacy metadata route source");
    let fetch_helper = route_source
        .split("async fn read_legacy_metadata")
        .nth(1)
        .and_then(|tail| tail.split("async fn handle_legacy_key_metadata").next())
        .expect("legacy metadata fetch helper");

    assert!(
        fetch_helper.contains("init.with_redirect(RequestRedirect::Error)"),
        "a forwarded Firebase bearer must never follow an upstream redirect"
    );
}

#[test]
fn only_a_firebase_shaped_id_token_is_forwardable_upstream() {
    let firebase = unsigned_jwt(FIREBASE_HEADER, PAYLOAD);
    let header = format!("Bearer {firebase}");
    let forwarded = forwardable_firebase_bearer(&header);
    assert_eq!(forwarded, Some(firebase.clone()));

    // A worker-issued session is an HS256 token this worker signed itself. It
    // means nothing upstream, so it must stop here rather than be forwarded.
    let worker_session = unsigned_jwt(WORKER_SESSION_HEADER, PAYLOAD);
    let two_segments = format!("{}.{}", base64url(FIREBASE_HEADER), base64url(PAYLOAD));
    let refused = [
        String::new(),
        "Bearer ".to_owned(),
        "Basic dXNlcjpwYXNz".to_owned(),
        firebase.clone(),
        format!("Bearer {worker_session}"),
        format!("Bearer {two_segments}"),
        format!("Bearer {firebase}.extra-segment"),
        format!("Bearer omi_sk_0123abcd_{}", "a".repeat(43)),
        format!("Bearer {}", base64url(b"opaque-refresh-material")),
        format!("Bearer {}", unsigned_jwt(NONE_ALG_HEADER, PAYLOAD)),
        format!("Bearer {}", unsigned_jwt(NO_KID_HEADER, PAYLOAD)),
        format!("Bearer {}", unsigned_jwt(EMPTY_KID_HEADER, PAYLOAD)),
        format!("Bearer {}", unsigned_jwt(b"not-json", PAYLOAD)),
    ];
    for (index, authorization) in refused.iter().enumerate() {
        assert!(
            forwardable_firebase_bearer(authorization).is_none(),
            "authorization case {index} must not be forwardable"
        );
    }
}

#[test]
fn legacy_metadata_projection_exposes_exactly_the_metadata_contract() {
    let upstream = json!({
        "keys": [{
            "id": "legacy-1",
            "name": "Claude Desktop",
            "prefix": "omi_mcp_ab12",
            "scopes": ["memory:read", 7, "conversations:read"],
            "createdAt": 1_000,
            "lastUsedAt": 2_000,
            "hash": "unused-upstream-field",
            "uid": "uid-1",
            "revoked": false
        }]
    });
    let projected = project_legacy_metadata(LegacyKeyKind::Mcp, &upstream);
    assert_eq!(projected.len(), 1);
    let entry = &projected[0];
    let fields: Vec<&str> = entry
        .as_object()
        .expect("projected entry is an object")
        .keys()
        .map(String::as_str)
        .collect();
    assert_eq!(fields, LEGACY_METADATA_FIELDS);
    assert_eq!(entry["legacyKind"], "mcp");
    assert_eq!(entry["id"], "legacy-1");
    assert_eq!(entry["name"], "Claude Desktop");
    assert_eq!(entry["prefix"], "omi_mcp_ab12");
    let expected_scopes = json!(["memory:read", "conversations:read"]);
    assert_eq!(entry["scopes"], expected_scopes);
    assert_eq!(entry["createdAt"], 1_000);
    assert_eq!(entry["lastUsedAt"], 2_000);

    // A bare array is accepted too, non-object members are skipped, absent
    // members become null rather than inventing a value, and a non-numeric
    // timestamp is refused rather than surfaced as an opaque string.
    let sparse = project_legacy_metadata(
        LegacyKeyKind::Dev,
        &json!(["not-an-object", {"createdAt": "2026-07-28T00:00:00Z"}]),
    );
    assert_eq!(sparse.len(), 1);
    assert_eq!(sparse[0]["legacyKind"], "dev");
    assert!(sparse[0]["id"].is_null());
    assert!(sparse[0]["name"].is_null());
    assert!(sparse[0]["prefix"].is_null());
    assert_eq!(sparse[0]["scopes"], json!([]));
    assert!(sparse[0]["createdAt"].is_null());
    assert!(sparse[0]["lastUsedAt"].is_null());

    let unusable = project_legacy_metadata(LegacyKeyKind::Mcp, &json!({"error": "nope"}));
    assert!(unusable.is_empty());
}

#[test]
fn legacy_metadata_projection_redacts_raw_token_like_values() {
    let secret_run = "0123456789abcdef".repeat(2);
    let upstream = json!([{
        "id": format!("omi_mcp_{secret_run}"),
        "name": format!("Claude Desktop ({secret_run}) key"),
        "prefix": "omi_mcp_ab12",
        "scopes": ["memory:read", secret_run.clone()],
        "createdAt": 1_000
    }]);
    let projected = project_legacy_metadata(LegacyKeyKind::Mcp, &upstream);
    assert_eq!(projected[0]["id"], "[redacted]");
    assert_eq!(projected[0]["name"], "Claude Desktop ([redacted]) key");
    let expected_scopes = json!(["memory:read", "[redacted]"]);
    assert_eq!(projected[0]["scopes"], expected_scopes);
    // A short public display prefix is not credential material, so it survives
    // intact — redaction that eats the whole contract helps nobody.
    assert_eq!(projected[0]["prefix"], "omi_mcp_ab12");
    let serialized = serde_json::to_string(&projected).expect("serialize");
    assert!(!serialized.contains(secret_run.as_str()));

    // A bearer that leaked into an upstream display field must not ride out
    // through this response either.
    let bearer_shaped = unsigned_jwt(FIREBASE_HEADER, PAYLOAD);
    let leaked = project_legacy_metadata(
        LegacyKeyKind::Dev,
        &json!([{"name": bearer_shaped.clone(), "id": "legacy-2"}]),
    );
    assert_eq!(leaked[0]["name"], "[redacted]");
    assert_eq!(leaked[0]["id"], "legacy-2");
    let serialized = serde_json::to_string(&leaked).expect("serialize");
    assert!(!serialized.contains(bearer_shaped.as_str()));
}

#[test]
fn legacy_metadata_unavailable_is_one_opaque_answer_for_every_cause() {
    let unavailable = legacy_metadata_unavailable();
    assert_eq!(LEGACY_METADATA_UNAVAILABLE_STATUS, 503);
    let expected = json!({ "error": "Legacy metadata unavailable" });
    assert_eq!(unavailable, expected);

    // Exactly one field: a worker-issued session, an unconfigured base and an
    // upstream refusal are indistinguishable, so the response is no oracle for
    // which credential a caller holds.
    let fields: Vec<&str> = unavailable
        .as_object()
        .expect("unavailable is an object")
        .keys()
        .map(String::as_str)
        .collect();
    assert_eq!(fields, ["error"]);

    let serialized = serde_json::to_string(&unavailable).expect("serialize");
    for leak in ["bearer", "authorization", "firebase", "session", "omi_"] {
        assert!(
            !serialized.to_ascii_lowercase().contains(leak),
            "opaque body must not mention {leak}"
        );
    }

    // The success envelope is a bare list of projected metadata and nothing else.
    assert_eq!(
        legacy_metadata_response(Vec::new()),
        json!({ "legacyKeys": [] })
    );
    let entries = project_legacy_metadata(LegacyKeyKind::Mcp, &json!([{"id": "legacy-1"}]));
    let response = legacy_metadata_response(entries);
    let fields: Vec<&str> = response
        .as_object()
        .expect("response is an object")
        .keys()
        .map(String::as_str)
        .collect();
    assert_eq!(fields, ["legacyKeys"]);
    assert_eq!(response["legacyKeys"][0]["id"], "legacy-1");
}
