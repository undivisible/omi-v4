use crate::model_tier::{
    ASYNC_AUDIO_TIER_PREFERENCE, Capability, CapabilityMismatch, ModelTier, select_model_for,
};

/// Where every online turn starts.
///
/// Nothing about the shape of a prompt says what answering it costs. This used
/// to be decided by counting characters and matching keyword lists, and that is
/// wrong in both directions: "is this clause enforceable?" is short and hard,
/// and "have a look at the thing I mentioned and tell me what you reckon" is
/// long and trivial. So the prompt is no longer read from the outside at all.
/// Mercury takes the turn first and hands it to a stronger model from inside it
/// — see `escalate_tool` — which is a judgement made with the question in hand
/// rather than a guess made from its length.
pub(crate) const FIRST_TIER: ModelTier = ModelTier::Speed;

/// What a turn has to be able to read is not a guess and never was, so it is
/// the one thing still decided before the model sees anything. The prompt says
/// what a turn is worth paying for; the attachment says what the model has to
/// be able to carry, and a configuration where no preferred tier can read it is
/// an error rather than a silent downgrade to a model that would answer about
/// audio it never received.
#[allow(dead_code)]
pub(crate) fn model_for_input(
    required: &[Capability],
    value: impl Fn(&str) -> Option<String> + Copy,
) -> Result<String, CapabilityMismatch> {
    // Audio in is the asynchronous voice-note case: cheapest capable tier
    // first, which is the balanced model.
    if required.contains(&Capability::AudioIn) {
        return select_model_for(required, ASYNC_AUDIO_TIER_PREFERENCE, value)
            .map(|(_, model)| model);
    }
    // Otherwise the turn starts where every turn starts, and falls through to a
    // tier that can read the input when the first one cannot — which is what
    // sends a picture to a model declaring `imageIn` instead of to Mercury.
    let preference = [FIRST_TIER, ModelTier::Multimodal, ModelTier::Balanced];
    select_model_for(required, &preference, value).map(|(_, model)| model)
}

#[cfg(test)]
mod tests {
    use super::*;

    use crate::model_tier::{
        DEFAULT_BALANCED_MODEL, DEFAULT_MULTIMODAL_MODEL, DEFAULT_SPEED_MODEL, capabilities_of,
        model_for_tier,
    };

    #[test]
    fn every_turn_starts_on_a_model_that_can_hold_a_text_conversation() {
        assert_eq!(FIRST_TIER, ModelTier::Speed);
        assert!(
            capabilities_of(&model_for_tier(FIRST_TIER, |_| None), |_| None)
                .contains(&Capability::Text)
        );
    }

    // The hard requirement the keyword lists never actually enforced: a turn
    // carrying a picture has to reach a model that declares it can see one.
    // Mercury cannot, so an image never lands there whatever the turn says.
    #[test]
    fn an_image_reaches_a_model_that_declares_it_can_see_one() {
        let model = model_for_input(&[Capability::Text, Capability::ImageIn], |_| None)
            .unwrap_or_else(|error_value| panic!("an image has a tier: {error_value}"));
        assert_eq!(model, DEFAULT_MULTIMODAL_MODEL);
        assert_ne!(model, DEFAULT_SPEED_MODEL);
        assert!(capabilities_of(&model, |_| None).contains(&Capability::ImageIn));
    }

    #[test]
    fn a_text_turn_stays_on_the_first_tier() {
        assert_eq!(
            model_for_input(&[Capability::Text], |_| None),
            Ok(DEFAULT_SPEED_MODEL.to_owned())
        );
    }

    #[test]
    fn audio_input_routes_to_the_balanced_model() {
        assert_eq!(
            model_for_input(&[Capability::AudioIn], |_| None),
            Ok(DEFAULT_BALANCED_MODEL.to_owned())
        );
    }

    #[test]
    fn an_input_no_configured_model_can_read_is_refused() {
        let text_only = |name: &str| match name {
            "OMI_MODEL_MULTIMODAL" => Some(DEFAULT_SPEED_MODEL.to_owned()),
            "OMI_MODEL_BALANCED" => Some(DEFAULT_SPEED_MODEL.to_owned()),
            _ => None,
        };
        assert!(model_for_input(&[Capability::ImageIn], text_only).is_err());
    }
}
