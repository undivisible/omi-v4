//! Pure billing logic ported from `worker/src/billing.ts`: Stripe checkout/
//! portal form-parameter assembly and response validation. The `fetch` to
//! `api.stripe.com` and the D1 `stripe_customer_id` lookup are glue.

use serde_json::Value;

/// Build the `checkout/sessions` form parameters (parity with the TS
/// `URLSearchParams`). `customer` (existing stripe_customer_id) takes
/// precedence over `customer_email`.
pub fn checkout_params(
    uid: &str,
    price_id: &str,
    app_url: &str,
    customer_id: Option<&str>,
    email: Option<&str>,
) -> Vec<(String, String)> {
    let mut params = vec![
        ("mode".into(), "subscription".into()),
        ("line_items[0][price]".into(), price_id.into()),
        ("line_items[0][quantity]".into(), "1".into()),
        ("client_reference_id".into(), uid.into()),
        ("metadata[firebase_uid]".into(), uid.into()),
        (
            "subscription_data[metadata][firebase_uid]".into(),
            uid.into(),
        ),
        (
            "success_url".into(),
            format!("{app_url}/billing/success?session_id={{CHECKOUT_SESSION_ID}}"),
        ),
        ("cancel_url".into(), format!("{app_url}/billing")),
    ];
    if let Some(customer) = customer_id {
        params.push(("customer".into(), customer.into()));
    } else if let Some(email) = email {
        params.push(("customer_email".into(), email.into()));
    }
    params
}

/// Build the `billing_portal/sessions` form parameters.
pub fn portal_params(customer_id: &str, app_url: &str) -> Vec<(String, String)> {
    vec![
        ("customer".into(), customer_id.into()),
        ("return_url".into(), format!("{app_url}/billing")),
    ]
}

/// x-www-form-urlencode a set of key/value pairs (application/x-www-form-
/// urlencoded, matching `URLSearchParams` serialization: space→`+`).
pub fn encode_form(params: &[(String, String)]) -> String {
    params
        .iter()
        .map(|(key, value)| format!("{}={}", form_encode(key), form_encode(value)))
        .collect::<Vec<_>>()
        .join("&")
}

fn form_encode(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for byte in value.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'*' => {
                out.push(byte as char)
            }
            b' ' => out.push('+'),
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

/// Validate a Stripe API response body: must be ok with string `id` and `url`.
/// Mirrors the `stripeRequest` null-guard. `ok` is the HTTP-status check.
pub fn parse_session(ok: bool, body: &Value) -> Option<(String, String)> {
    if !ok {
        return None;
    }
    let id = body.get("id").and_then(Value::as_str)?;
    let url = body.get("url").and_then(Value::as_str)?;
    Some((id.to_string(), url.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn checkout_params_prefers_customer_over_email() {
        let params = checkout_params(
            "uid-1",
            "price_pro",
            "https://app.test",
            Some("cus_9"),
            Some("u@x.com"),
        );
        assert!(params.contains(&("customer".into(), "cus_9".into())));
        assert!(!params.iter().any(|(k, _)| k == "customer_email"));
        assert!(params.contains(&("client_reference_id".into(), "uid-1".into())));
        assert!(params.contains(&(
            "success_url".into(),
            "https://app.test/billing/success?session_id={CHECKOUT_SESSION_ID}".into()
        )));
    }

    #[test]
    fn checkout_params_falls_back_to_email() {
        let params = checkout_params("uid-1", "price", "https://app.test", None, Some("u@x.com"));
        assert!(params.contains(&("customer_email".into(), "u@x.com".into())));
        assert!(!params.iter().any(|(k, _)| k == "customer"));
    }

    #[test]
    fn checkout_params_no_customer_no_email() {
        let params = checkout_params("uid-1", "price", "https://app.test", None, None);
        assert!(!params
            .iter()
            .any(|(k, _)| k == "customer" || k == "customer_email"));
    }

    #[test]
    fn portal_params_shape() {
        let params = portal_params("cus_9", "https://app.test");
        assert_eq!(
            params,
            vec![
                ("customer".into(), "cus_9".into()),
                ("return_url".into(), "https://app.test/billing".into()),
            ]
        );
    }

    #[test]
    fn form_encoding() {
        let encoded = encode_form(&[
            ("a".into(), "hello world".into()),
            ("b".into(), "x=y&z".into()),
        ]);
        assert_eq!(encoded, "a=hello+world&b=x%3Dy%26z");
    }

    #[test]
    fn session_parse_guards() {
        assert_eq!(
            parse_session(true, &json!({"id": "cs_1", "url": "https://checkout"})),
            Some(("cs_1".into(), "https://checkout".into()))
        );
        assert!(parse_session(false, &json!({"id": "cs_1", "url": "u"})).is_none());
        assert!(parse_session(true, &json!({"error": "bad"})).is_none());
        assert!(parse_session(true, &json!({"id": "cs_1"})).is_none());
    }
}
