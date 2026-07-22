use serde_json::{json, Value};

// Ported from the GET /v1/setup-health handler in worker/src/routes.ts. The env
// reads live in the glue; this builds the identical JSON body from the resolved
// values so the shape is unit-testable.

/// True when a var is present and non-empty after trimming (TS `configured`).
pub fn configured(value: Option<&str>) -> bool {
    matches!(value, Some(v) if !v.trim().is_empty())
}

/// The resolved presence flags needed to build the setup-health payload.
pub struct SetupHealthInputs<'a> {
    pub firebase_project_id: Option<&'a str>,
    pub telegram_webhook_secret: Option<&'a str>,
    pub telegram_bot_token: Option<&'a str>,
    pub blooio_webhook_signing_secret: Option<&'a str>,
    pub blooio_api_key: Option<&'a str>,
    pub stripe_secret_key: Option<&'a str>,
    pub stripe_pro_price_id: Option<&'a str>,
    pub stripe_webhook_secret: Option<&'a str>,
    pub app_url: Option<&'a str>,
    pub mimo_api_key: Option<&'a str>,
    pub deepgram_api_key: Option<&'a str>,
    pub gemini_api_key: Option<&'a str>,
    pub gemini_live_model: Option<&'a str>,
    pub mimo_chat_completions_url: Option<&'a str>,
    pub firebase_service_account_email: Option<&'a str>,
    pub firebase_service_account_private_key: Option<&'a str>,
}

pub fn setup_health_body(input: &SetupHealthInputs<'_>) -> Value {
    json!({
        "worker": true,
        "firebase": configured(input.firebase_project_id),
        "memory": true,
        "channels": {
            "telegram": configured(input.telegram_webhook_secret)
                && configured(input.telegram_bot_token),
            "blooio": configured(input.blooio_webhook_signing_secret)
                && configured(input.blooio_api_key),
        },
        "billing": configured(input.stripe_secret_key)
            && configured(input.stripe_pro_price_id)
            && configured(input.stripe_webhook_secret)
            && configured(input.app_url),
        "models": {
            "managedChat": configured(input.mimo_api_key),
            "managedStt": configured(input.deepgram_api_key),
            "managedLiveVoice": configured(input.gemini_api_key)
                && configured(input.gemini_live_model),
            "managedAsr": configured(input.mimo_api_key)
                && configured(input.mimo_chat_completions_url),
        },
        "desktopAuth": configured(input.firebase_service_account_email)
            && configured(input.firebase_service_account_private_key)
            && configured(input.app_url),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn empty() -> SetupHealthInputs<'static> {
        SetupHealthInputs {
            firebase_project_id: None,
            telegram_webhook_secret: None,
            telegram_bot_token: None,
            blooio_webhook_signing_secret: None,
            blooio_api_key: None,
            stripe_secret_key: None,
            stripe_pro_price_id: None,
            stripe_webhook_secret: None,
            app_url: None,
            mimo_api_key: None,
            deepgram_api_key: None,
            gemini_api_key: None,
            gemini_live_model: None,
            mimo_chat_completions_url: None,
            firebase_service_account_email: None,
            firebase_service_account_private_key: None,
        }
    }

    #[test]
    fn configured_trims() {
        assert!(configured(Some("x")));
        assert!(!configured(Some("   ")));
        assert!(!configured(Some("")));
        assert!(!configured(None));
    }

    #[test]
    fn all_unconfigured() {
        let body = setup_health_body(&empty());
        assert_eq!(body["worker"], json!(true));
        assert_eq!(body["memory"], json!(true));
        assert_eq!(body["firebase"], json!(false));
        assert_eq!(body["channels"]["telegram"], json!(false));
        assert_eq!(body["billing"], json!(false));
        assert_eq!(body["models"]["managedChat"], json!(false));
        assert_eq!(body["desktopAuth"], json!(false));
    }

    #[test]
    fn telegram_needs_both_secret_and_token() {
        let mut input = empty();
        input.telegram_webhook_secret = Some("s");
        assert_eq!(setup_health_body(&input)["channels"]["telegram"], json!(false));
        input.telegram_bot_token = Some("t");
        assert_eq!(setup_health_body(&input)["channels"]["telegram"], json!(true));
    }

    #[test]
    fn managed_asr_needs_key_and_url() {
        let mut input = empty();
        input.mimo_api_key = Some("k");
        assert_eq!(setup_health_body(&input)["models"]["managedChat"], json!(true));
        assert_eq!(setup_health_body(&input)["models"]["managedAsr"], json!(false));
        input.mimo_chat_completions_url = Some("https://x");
        assert_eq!(setup_health_body(&input)["models"]["managedAsr"], json!(true));
    }
}
