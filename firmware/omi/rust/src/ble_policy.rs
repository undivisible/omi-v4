#[cfg(not(target_os = "none"))]
use std::sync::Mutex;

#[cfg(target_os = "none")]
use zephyr::sync::Mutex;

#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub struct BlePolicyState {
    conn_params_fast: bool,
    last_charging: Option<bool>,
    mtu_recheck_attempts: u8,
}

#[repr(C)]
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub struct MtuRecheckDecision {
    pub request_exchange: bool,
    pub reschedule: bool,
    pub negotiated: bool,
    pub attempt: u8,
}

pub const MTU_RECHECK_MAX_ATTEMPTS: u8 = 6;

impl BlePolicyState {
    pub const fn new() -> Self {
        Self {
            conn_params_fast: true,
            last_charging: None,
            mtu_recheck_attempts: 0,
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

    pub fn reset_mtu_recheck(&mut self) {
        self.mtu_recheck_attempts = 0;
    }

    pub fn mtu_recheck_can_schedule(&self) -> bool {
        self.mtu_recheck_attempts < MTU_RECHECK_MAX_ATTEMPTS
    }

    pub fn mtu_recheck_step(&mut self, connection_present: bool, mtu: u16) -> MtuRecheckDecision {
        if !connection_present || mtu > 23 {
            let negotiated = connection_present && mtu > 23;
            self.reset_mtu_recheck();
            return MtuRecheckDecision {
                request_exchange: false,
                reschedule: false,
                negotiated,
                attempt: 0,
            };
        }

        if !self.mtu_recheck_can_schedule() {
            return MtuRecheckDecision {
                request_exchange: false,
                reschedule: false,
                negotiated: false,
                attempt: self.mtu_recheck_attempts,
            };
        }

        self.mtu_recheck_attempts += 1;
        MtuRecheckDecision {
            request_exchange: true,
            reschedule: self.mtu_recheck_can_schedule(),
            negotiated: false,
            attempt: self.mtu_recheck_attempts,
        }
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

pub fn reset_mtu_recheck() {
    STATE.lock().unwrap().reset_mtu_recheck();
}

pub fn mtu_recheck_can_schedule() -> bool {
    STATE.lock().unwrap().mtu_recheck_can_schedule()
}

pub fn mtu_recheck_step(connection_present: bool, mtu: u16) -> MtuRecheckDecision {
    STATE
        .lock()
        .unwrap()
        .mtu_recheck_step(connection_present, mtu)
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
    if !state.mtu_recheck_can_schedule() {
        failures += 1;
    }
    for attempt in 1..=MTU_RECHECK_MAX_ATTEMPTS {
        let decision = state.mtu_recheck_step(true, 23);
        if !decision.request_exchange || decision.attempt != attempt {
            failures += 1;
        }
        if decision.reschedule != (attempt < MTU_RECHECK_MAX_ATTEMPTS) {
            failures += 1;
        }
    }
    if state.mtu_recheck_can_schedule() {
        failures += 1;
    }
    let negotiated = state.mtu_recheck_step(true, 24);
    if negotiated.request_exchange || !negotiated.negotiated || !state.mtu_recheck_can_schedule() {
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

    #[test]
    fn mtu_rechecks_stop_after_six_and_reset_on_negotiation() {
        let mut state = BlePolicyState::new();
        for attempt in 1..=MTU_RECHECK_MAX_ATTEMPTS {
            let decision = state.mtu_recheck_step(true, 23);
            assert!(decision.request_exchange);
            assert_eq!(decision.attempt, attempt);
            assert_eq!(decision.reschedule, attempt < MTU_RECHECK_MAX_ATTEMPTS);
        }
        assert!(!state.mtu_recheck_can_schedule());

        let decision = state.mtu_recheck_step(true, 24);
        assert!(!decision.request_exchange);
        assert!(decision.negotiated);
        assert!(state.mtu_recheck_can_schedule());

        let decision = state.mtu_recheck_step(false, 23);
        assert!(!decision.request_exchange);
        assert!(!decision.negotiated);
        assert_eq!(decision.attempt, 0);
    }
}
