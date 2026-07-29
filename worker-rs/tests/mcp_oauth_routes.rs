use omi_v4_api_rs::mcp_oauth_routes::{
    metadata_for_path, AUTHORIZATION_SERVER_METADATA_PATH, PROTECTED_RESOURCE_METADATA_PATH,
};

#[test]
fn does_not_advertise_an_unimplemented_oauth_authorization_server() {
    assert!(metadata_for_path(AUTHORIZATION_SERVER_METADATA_PATH).is_none());
    assert!(metadata_for_path(PROTECTED_RESOURCE_METADATA_PATH).is_none());
}
