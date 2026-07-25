#[cfg(not(target_os = "none"))]
use std::sync::Mutex;

#[cfg(target_os = "none")]
use zephyr::sync::Mutex;

#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub struct BlePolicyState {
    conn_params_fast: bool,
    last_charging: Option<bool>,
}

impl BlePolicyState {
    pub const fn new() -> Self {
        Self {
            conn_params_fast: true,
            last_charging: None,
        }
    }

    pub fn reevaluate_connection(
        &mut self,
        audio_subscribed: bool,
        storage_transfer_active: bool,
    ) -> Option<bool> {
        let want_fast = audio_subscribed || storage_transfer_active;
        if want_fast == self.conn_params_fast {
            None
        } else {
            self.conn_params_fast = want_fast;
            Some(want_fast)
        }
    }

    pub fn reset_connection(&mut self) {
        self.conn_params_fast = true;
    }

    pub fn should_notify_charging(&self, charging: bool, force: bool) -> bool {
        force || self.last_charging != Some(charging)
    }

    pub fn mark_charging_notified(&mut self, charging: bool) {
        self.last_charging = Some(charging);
    }

    pub fn reset_charging(&mut self) {
        self.last_charging = None;
    }
}

impl Default for BlePolicyState {
    fn default() -> Self {
        Self::new()
    }
}

static STATE: Mutex<BlePolicyState> = Mutex::new(BlePolicyState::new());

pub fn reevaluate_connection(
    audio_subscribed: bool,
    storage_transfer_active: bool,
) -> Option<bool> {
    STATE
        .lock()
        .unwrap()
        .reevaluate_connection(audio_subscribed, storage_transfer_active)
}

pub fn should_notify_charging(charging: bool, force: bool) -> bool {
    STATE
        .lock()
        .unwrap()
        .should_notify_charging(charging, force)
}

pub fn reset_connection() {
    STATE.lock().unwrap().reset_connection();
}

pub fn mark_charging_notified(charging: bool) {
    STATE.lock().unwrap().mark_charging_notified(charging);
}

pub fn reset_charging() {
    STATE.lock().unwrap().reset_charging();
}

pub fn selftest() -> i32 {
    let mut failures = 0;
    let mut state = BlePolicyState::new();
    if state.reevaluate_connection(false, false) != Some(false) {
        failures += 1;
    }
    if state.reevaluate_connection(false, false).is_some() {
        failures += 1;
    }
    if state.reevaluate_connection(true, false) != Some(true) {
        failures += 1;
    }
    state.reset_connection();
    if state.reevaluate_connection(true, false).is_some() {
        failures += 1;
    }
    if !state.should_notify_charging(false, false) {
        failures += 1;
    }
    state.mark_charging_notified(false);
    if state.should_notify_charging(false, false) || !state.should_notify_charging(false, true) {
        failures += 1;
    }
    state.reset_charging();
    if !state.should_notify_charging(false, false) {
        failures += 1;
    }
    failures
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn adaptive_connection_only_changes_on_mode_transition() {
        let mut state = BlePolicyState::new();
        assert_eq!(state.reevaluate_connection(false, false), Some(false));
        assert_eq!(state.reevaluate_connection(false, false), None);
        assert_eq!(state.reevaluate_connection(false, true), Some(true));
        assert_eq!(state.reevaluate_connection(true, true), None);
        state.reset_connection();
        assert_eq!(state.reevaluate_connection(true, false), None);
    }

    #[test]
    fn charging_notification_deduplicates_after_success() {
        let mut state = BlePolicyState::new();
        assert!(state.should_notify_charging(true, false));
        state.mark_charging_notified(true);
        assert!(!state.should_notify_charging(true, false));
        assert!(state.should_notify_charging(false, false));
        assert!(state.should_notify_charging(true, true));
        state.reset_charging();
        assert!(state.should_notify_charging(true, false));
    }
}
