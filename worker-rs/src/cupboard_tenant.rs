use serde_json::{json, Value};

pub const CUPBOARD_TENANT_LOOKUP_SQL: &str =
    "SELECT tenant_id FROM cupboard_tenants WHERE uid = ?1";
pub const CUPBOARD_TENANT_INSERT_SQL: &str =
    "INSERT INTO cupboard_tenants (uid, tenant_id, created_at) VALUES (?1, ?2, ?3) ON CONFLICT(uid) DO NOTHING";
pub const CUPBOARD_TENANT_DELETE_SQL: &str = "DELETE FROM cupboard_tenants WHERE uid = ?1";

pub enum MappingOperation {
    Read,
    Minted,
    Existing,
}

pub struct MappingResponse {
    pub status: u16,
    pub body: Value,
}

pub fn mapping_response(tenant_id: Option<&str>, operation: MappingOperation) -> MappingResponse {
    match tenant_id {
        Some(tenant_id) => MappingResponse {
            status: match operation {
                MappingOperation::Minted => 201,
                MappingOperation::Read | MappingOperation::Existing => 200,
            },
            body: json!({ "configured": true, "tenantId": tenant_id }),
        },
        None => MappingResponse {
            status: 404,
            body: json!({ "configured": false }),
        },
    }
}
