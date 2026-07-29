use std::fs;
use std::path::Path;

use omi_v4_api_rs::cupboard_tenant::{
    mapping_response, MappingOperation, CUPBOARD_TENANT_DELETE_SQL, CUPBOARD_TENANT_INSERT_SQL,
    CUPBOARD_TENANT_LOOKUP_SQL,
};
use rusqlite::{Connection, OptionalExtension};

#[test]
fn sqlite_mapping_contract() {
    let db = Connection::open_in_memory().expect("open in-memory SQLite");
    db.execute_batch("CREATE TABLE users (uid TEXT PRIMARY KEY);")
        .expect("create users table");
    db.execute_batch(include_str!(
        "../../cloud/migrations/0042_cupboard_tenants.sql"
    ))
    .expect("apply cupboard tenant migration");
    for uid in ["uid-a", "uid-b", "uid-c"] {
        db.execute("INSERT INTO users (uid) VALUES (?1)", [uid])
            .expect("insert user");
    }

    assert_eq!(
        db.execute(CUPBOARD_TENANT_INSERT_SQL, ("uid-a", "opaque-a", 1)),
        Ok(1)
    );
    assert_eq!(
        db.execute(CUPBOARD_TENANT_INSERT_SQL, ("uid-b", "opaque-b", 2)),
        Ok(1)
    );
    assert_eq!(
        db.execute(
            CUPBOARD_TENANT_INSERT_SQL,
            ("uid-a", "opaque-a-replacement", 3)
        ),
        Ok(0)
    );
    assert_eq!(
        db.query_row(CUPBOARD_TENANT_LOOKUP_SQL, ["uid-a"], |row| row
            .get::<_, String>(0))
            .optional(),
        Ok(Some("opaque-a".to_string()))
    );

    assert_eq!(db.execute(CUPBOARD_TENANT_DELETE_SQL, ["uid-a"]), Ok(1));
    assert_eq!(
        db.query_row(CUPBOARD_TENANT_LOOKUP_SQL, ["uid-a"], |row| row
            .get::<_, String>(0))
            .optional(),
        Ok(None)
    );
    assert_eq!(
        db.query_row(CUPBOARD_TENANT_LOOKUP_SQL, ["uid-b"], |row| row
            .get::<_, String>(0))
            .optional(),
        Ok(Some("opaque-b".to_string()))
    );
    assert_eq!(
        db.execute(CUPBOARD_TENANT_INSERT_SQL, ("uid-a", "opaque-a-new", 4)),
        Ok(1)
    );
    assert!(db
        .execute(CUPBOARD_TENANT_INSERT_SQL, ("uid-c", "opaque-b", 5))
        .is_err());
}

#[test]
fn mapping_responses_are_minimal_and_do_not_expose_identity_material() {
    let missing = mapping_response(None, MappingOperation::Read);
    assert_eq!(missing.status, 404);
    assert_eq!(missing.body, serde_json::json!({ "configured": false }));

    let existing = mapping_response(Some("tenant-opaque"), MappingOperation::Read);
    assert_eq!(existing.status, 200);
    assert_eq!(
        existing.body,
        serde_json::json!({ "configured": true, "tenantId": "tenant-opaque" })
    );

    for response in [
        mapping_response(Some("tenant-opaque"), MappingOperation::Read),
        mapping_response(Some("tenant-opaque"), MappingOperation::Minted),
    ] {
        assert!(response.body.get("uid").is_none());
        assert!(response.body.get("email").is_none());
        assert!(response.body.get("claims").is_none());
        assert!(response.body.get("credential").is_none());
    }
}

#[test]
fn minting_is_explicit_and_idempotent_in_the_response_contract() {
    assert_eq!(
        mapping_response(Some("tenant-opaque"), MappingOperation::Minted).status,
        201
    );
    assert_eq!(
        mapping_response(Some("tenant-opaque"), MappingOperation::Existing).status,
        200
    );
}

#[test]
fn route_registration_and_auth_tripwires() {
    let source = fs::read_to_string(
        Path::new(env!("CARGO_MANIFEST_DIR")).join("src/routes_memory/wasm_glue.rs"),
    )
    .expect("read memory route source");

    for registration in [
        ".get_async(\"/v1/memory/cupboard/tenant\", handle_cupboard_tenant_get)",
        ".post_async(\"/v1/memory/cupboard/tenant\", handle_cupboard_tenant_post)",
        ".delete_async(\"/v1/memory/cupboard/tenant\", handle_cupboard_tenant_delete)",
    ] {
        assert!(source.contains(registration));
    }
    for handler in [
        "handle_cupboard_tenant_get",
        "handle_cupboard_tenant_post",
        "handle_cupboard_tenant_delete",
    ] {
        assert!(source
            .split(&format!("async fn {handler}"))
            .nth(1)
            .is_some_and(|body| body.contains("authed!(req, ctx)")));
    }
}
