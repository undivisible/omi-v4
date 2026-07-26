pub const MAX_DOCUMENT_BYTES: usize = 4 * 1024 * 1024;
pub const MAX_IMAGE_BYTES: usize = 8 * 1024 * 1024;
pub const MAX_QUERY_CHARS: usize = 2_000;

pub fn document_name(value: &str) -> Option<String> {
    let value = value.trim();
    if value.is_empty()
        || value.chars().count() > 255
        || value.contains('/')
        || value.contains('\\')
        || value.chars().any(char::is_control)
        || !value.contains('.')
    {
        return None;
    }
    Some(value.to_string())
}

pub fn search_query(value: &str) -> Option<String> {
    let value = value.trim();
    (!value.is_empty() && value.chars().count() <= MAX_QUERY_CHARS).then(|| value.to_string())
}

pub fn tenant_folder(uid_hash: &str) -> String {
    format!("{uid_hash}/")
}

pub fn image_mime(value: Option<&str>) -> Option<&'static str> {
    match value?
        .split(';')
        .next()?
        .trim()
        .to_ascii_lowercase()
        .as_str()
    {
        "image/png" => Some("image/png"),
        "image/jpeg" => Some("image/jpeg"),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validates_document_names_queries_and_tenant_prefixes() {
        assert_eq!(
            document_name(" handbook.pdf ").as_deref(),
            Some("handbook.pdf")
        );
        assert!(document_name("../secret.pdf").is_none());
        assert!(document_name("folder/file.txt").is_none());
        assert!(document_name("README").is_none());
        assert_eq!(
            search_query("  vacation policy ").as_deref(),
            Some("vacation policy")
        );
        assert!(search_query("").is_none());
        assert_eq!(tenant_folder("abc123"), "abc123/");
        assert_eq!(image_mime(Some("image/png")), Some("image/png"));
        assert_eq!(
            image_mime(Some("image/jpeg; charset=binary")),
            Some("image/jpeg")
        );
        assert!(image_mime(Some("image/svg+xml")).is_none());
    }
}
