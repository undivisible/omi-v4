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
    pub sendblue_api_key_id: Option<&'a str>,
    pub sendblue_api_key_secret: Option<&'a str>,
    pub sendblue_number: Option<&'a str>,
    pub sendblue_webhook_signing_secret: Option<&'a str>,
    pub sendblue_webhook_path_token: Option<&'a str>,
    pub stripe_secret_key: Option<&'a str>,
    pub stripe_pro_price_id: Option<&'a str>,
    pub stripe_webhook_secret: Option<&'a str>,
    pub app_url: Option<&'a str>,
    pub mimo_api_key: Option<&'a str>,
    pub openrouter_api_key: Option<&'a str>,
    pub gemini_api_key: Option<&'a str>,
    pub gemini_live_model: Option<&'a str>,
    pub firebase_service_account_email: Option<&'a str>,
    pub firebase_service_account_private_key: Option<&'a str>,
}

pub fn setup_health_body(input: &SetupHealthInputs<'_>) -> Value {
    let sendblue_inbound = configured(input.sendblue_api_key_id)
        && configured(input.sendblue_api_key_secret)
        && configured(input.sendblue_number)
        && configured(input.sendblue_webhook_signing_secret)
        && configured(input.sendblue_webhook_path_token);
    json!({
        "worker": true,
        "firebase": configured(input.firebase_project_id),
        "memory": true,
        "channels": {
            "telegram": configured(input.telegram_webhook_secret)
                && configured(input.telegram_bot_token),
            "imessage": sendblue_inbound,
        },
        "billing": configured(input.stripe_secret_key)
            && configured(input.stripe_pro_price_id)
            && configured(input.stripe_webhook_secret)
            && configured(input.app_url),
        "models": {
            "managedChat": configured(input.mimo_api_key),
            "managedStt": configured(input.openrouter_api_key),
            "managedLiveVoice": configured(input.gemini_api_key)
                && configured(input.gemini_live_model),
            "managedAsr": configured(input.openrouter_api_key),
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
            sendblue_api_key_id: None,
            sendblue_api_key_secret: None,
            sendblue_number: None,
            sendblue_webhook_signing_secret: None,
            sendblue_webhook_path_token: None,
            stripe_secret_key: None,
            stripe_pro_price_id: None,
            stripe_webhook_secret: None,
            app_url: None,
            mimo_api_key: None,
            openrouter_api_key: None,
            gemini_api_key: None,
            gemini_live_model: None,
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
        assert_eq!(body["channels"]["imessage"], json!(false));
        assert_eq!(body["billing"], json!(false));
        assert_eq!(body["models"]["managedChat"], json!(false));
        assert_eq!(body["desktopAuth"], json!(false));
    }

    #[test]
    fn telegram_needs_both_secret_and_token() {
        let mut input = empty();
        input.telegram_webhook_secret = Some("s");
        assert_eq!(
            setup_health_body(&input)["channels"]["telegram"],
            json!(false)
        );
        input.telegram_bot_token = Some("t");
        assert_eq!(
            setup_health_body(&input)["channels"]["telegram"],
            json!(true)
        );
    }

    #[test]
    fn managed_asr_needs_key_and_url() {
        let mut input = empty();
        input.mimo_api_key = Some("k");
        assert_eq!(
            setup_health_body(&input)["models"]["managedChat"],
            json!(true)
        );
        assert_eq!(
            setup_health_body(&input)["models"]["managedAsr"],
            json!(false)
        );
        input.openrouter_api_key = Some("k");
        assert_eq!(
            setup_health_body(&input)["models"]["managedAsr"],
            json!(true)
        );
    }

    #[test]
    fn managed_live_voice_needs_both_key_and_model() {
        let mut input = empty();
        input.gemini_api_key = Some("k");
        assert_eq!(
            setup_health_body(&input)["models"]["managedLiveVoice"],
            json!(false)
        );
        input.gemini_live_model = Some("gemini-live-2.5");
        assert_eq!(
            setup_health_body(&input)["models"]["managedLiveVoice"],
            json!(true)
        );
        input.gemini_api_key = Some("  ");
        assert_eq!(
            setup_health_body(&input)["models"]["managedLiveVoice"],
            json!(false)
        );
        input.gemini_api_key = None;
        assert_eq!(
            setup_health_body(&input)["models"]["managedLiveVoice"],
            json!(false)
        );
    }

    #[test]
    fn billing_needs_every_stripe_key_and_the_app_url() {
        let mut input = empty();
        input.stripe_secret_key = Some("sk");
        assert_eq!(setup_health_body(&input)["billing"], json!(false));
        input.stripe_pro_price_id = Some("price_pro");
        assert_eq!(setup_health_body(&input)["billing"], json!(false));
        input.stripe_webhook_secret = Some("whsec");
        assert_eq!(setup_health_body(&input)["billing"], json!(false));
        input.app_url = Some("https://app.test");
        assert_eq!(setup_health_body(&input)["billing"], json!(true));
        // Every conjunct is load-bearing: blanking any one flips it back.
        input.stripe_secret_key = Some(" ");
        assert_eq!(setup_health_body(&input)["billing"], json!(false));
        input.stripe_secret_key = Some("sk");
        input.stripe_pro_price_id = None;
        assert_eq!(setup_health_body(&input)["billing"], json!(false));
        input.stripe_pro_price_id = Some("price_pro");
        input.stripe_webhook_secret = None;
        assert_eq!(setup_health_body(&input)["billing"], json!(false));
        input.stripe_webhook_secret = Some("whsec");
        input.app_url = None;
        assert_eq!(setup_health_body(&input)["billing"], json!(false));
    }

    #[test]
    fn desktop_auth_needs_the_service_account_and_the_app_url() {
        let mut input = empty();
        input.firebase_service_account_email = Some("svc@project.iam");
        assert_eq!(setup_health_body(&input)["desktopAuth"], json!(false));
        input.firebase_service_account_private_key = Some("-----BEGIN");
        assert_eq!(setup_health_body(&input)["desktopAuth"], json!(false));
        input.app_url = Some("https://app.test");
        assert_eq!(setup_health_body(&input)["desktopAuth"], json!(true));
    }

    #[test]
    fn the_body_reports_presence_without_echoing_any_credential() {
        let secrets = [
            "leak-firebase-project",
            "leak-telegram-webhook-secret",
            "leak-telegram-bot-token",
            "leak-sendblue-key-id",
            "leak-sendblue-key-secret",
            "leak-sendblue-number",
            "leak-sendblue-signing-secret",
            "leak-sendblue-path-token",
            "leak-stripe-secret-key",
            "leak-stripe-price-id",
            "leak-stripe-webhook-secret",
            "leak-app-url",
            "leak-mimo-api-key",
            "leak-openrouter-api-key",
            "leak-gemini-api-key",
            "leak-gemini-live-model",
            "leak-mimo-completions-url",
            "leak-service-account-email",
            "leak-service-account-private-key",
        ];
        let input = SetupHealthInputs {
            firebase_project_id: Some(secrets[0]),
            telegram_webhook_secret: Some(secrets[1]),
            telegram_bot_token: Some(secrets[2]),
            sendblue_api_key_id: Some(secrets[3]),
            sendblue_api_key_secret: Some(secrets[4]),
            sendblue_number: Some(secrets[5]),
            sendblue_webhook_signing_secret: Some(secrets[6]),
            sendblue_webhook_path_token: Some(secrets[7]),
            stripe_secret_key: Some(secrets[8]),
            stripe_pro_price_id: Some(secrets[9]),
            stripe_webhook_secret: Some(secrets[10]),
            app_url: Some(secrets[11]),
            mimo_api_key: Some(secrets[12]),
            openrouter_api_key: Some(secrets[13]),
            gemini_api_key: Some(secrets[14]),
            gemini_live_model: Some(secrets[15]),
            firebase_service_account_email: Some(secrets[17]),
            firebase_service_account_private_key: Some(secrets[18]),
        };
        let body = setup_health_body(&input);
        // Fully configured: every flag is true.
        assert_eq!(body["firebase"], json!(true));
        assert_eq!(body["channels"]["telegram"], json!(true));
        assert_eq!(body["channels"]["imessage"], json!(true));
        assert_eq!(body["billing"], json!(true));
        assert_eq!(body["models"]["managedChat"], json!(true));
        assert_eq!(body["models"]["managedStt"], json!(true));
        assert_eq!(body["models"]["managedLiveVoice"], json!(true));
        assert_eq!(body["models"]["managedAsr"], json!(true));
        assert_eq!(body["desktopAuth"], json!(true));
        let serialized = body.to_string();
        for secret in secrets {
            assert!(!serialized.contains(secret), "{secret} leaked");
        }
        assert!(!serialized.contains("leak-"));
    }
}
