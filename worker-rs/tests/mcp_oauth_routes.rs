use omi_v4_api_rs::mcp_oauth_routes::{
    metadata_for_path, AUTHORIZATION_SERVER_METADATA_PATH, PROTECTED_RESOURCE_METADATA_PATH,
};

#[test]
fn serves_canonical_metadata_from_the_standard_discovery_routes() {
    let authorization = metadata_for_path(AUTHORIZATION_SERVER_METADATA_PATH)
        .expect("authorization-server discovery route should resolve");
    assert_eq!(authorization["issuer"], "https://api.omi.tsc.hk");
    assert_eq!(
        authorization["code_challenge_methods_supported"],
        serde_json::json!(["S256"])
    );

    let resource = metadata_for_path(PROTECTED_RESOURCE_METADATA_PATH)
        .expect("protected-resource discovery route should resolve");
    assert_eq!(resource["resource"], "https://api.omi.tsc.hk/mcp");
    assert_eq!(
        resource["authorization_servers"],
        serde_json::json!(["https://api.omi.tsc.hk"])
    );
}
