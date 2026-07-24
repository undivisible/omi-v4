// Pure tap/double/long/release classification ported from
// firmware/omi/src/lib/core/button.c `check_button_level`. GPIO sampling, GATT
// notify, turnoff_all, and the Zephyr work queue stay in C.

pub const BUTTON_CHECK_INTERVAL_MS: u32 = 40;
pub const TAP_THRESHOLD_MS: u32 = 300;
pub const DOUBLE_TAP_WINDOW_MS: u32 = 600;
pub const LONG_PRESS_TIME_MS: u32 = 3000;

/// Event codes match C's `ButtonEvent` / `omi_rust_button_event_t`.
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum ButtonEvent {
    None = 0,
    SingleTap = 1,
    DoubleTap = 2,
    LongPress = 3,
    Release = 4,
}

#[derive(Copy, Clone, Debug)]
pub struct ButtonFsm {
    current_time: u32,
    press_start_time: u32,
    release_time: u32,
    last_tap_time: u32,
    is_pressed: bool,
    last_event: ButtonEvent,
}

impl ButtonFsm {
    pub const fn new() -> Self {
        Self {
            current_time: 0,
            press_start_time: 0,
            release_time: 0,
            last_tap_time: 0,
            is_pressed: false,
            last_event: ButtonEvent::None,
        }
    }

    pub fn reset(&mut self) {
        *self = Self::new();
    }

    /// One 40 ms poll tick. `pressed` is the sampled GPIO level (true = down).
    pub fn step(&mut self, pressed: bool) -> ButtonEvent {
        self.current_time = self.current_time.wrapping_add(1);

        let mut event = ButtonEvent::None;

        if pressed && !self.is_pressed {
            self.is_pressed = true;
            self.press_start_time = self.current_time;
        } else if !pressed && self.is_pressed {
            self.is_pressed = false;
            self.release_time = self.current_time;

            let press_duration =
                (self.release_time - self.press_start_time) * BUTTON_CHECK_INTERVAL_MS;
            if press_duration < TAP_THRESHOLD_MS {
                if self.last_tap_time > 0
                    && (self.current_time - self.last_tap_time) * BUTTON_CHECK_INTERVAL_MS
                        < DOUBLE_TAP_WINDOW_MS
                {
                    event = ButtonEvent::DoubleTap;
                    self.last_tap_time = 0;
                } else {
                    self.last_tap_time = self.current_time;
                }
            }
        }

        if !pressed && !self.is_pressed {
            let press_duration =
                (self.release_time - self.press_start_time) * BUTTON_CHECK_INTERVAL_MS;
            if press_duration < TAP_THRESHOLD_MS
                && self.last_tap_time > 0
                && (self.current_time - self.press_start_time) * BUTTON_CHECK_INTERVAL_MS
                    > TAP_THRESHOLD_MS
            {
                event = ButtonEvent::SingleTap;
                self.last_tap_time = 0;
            } else if (self.current_time - self.press_start_time) * BUTTON_CHECK_INTERVAL_MS
                > TAP_THRESHOLD_MS
            {
                event = ButtonEvent::Release;
            }
        }

        if self.is_pressed
            && (self.current_time - self.press_start_time) * BUTTON_CHECK_INTERVAL_MS
                >= LONG_PRESS_TIME_MS
        {
            event = ButtonEvent::LongPress;
        }

        match event {
            ButtonEvent::SingleTap | ButtonEvent::DoubleTap => {
                self.last_event = event;
                event
            }
            ButtonEvent::LongPress => {
                if self.last_event != ButtonEvent::LongPress {
                    self.last_event = event;
                    event
                } else {
                    ButtonEvent::None
                }
            }
            ButtonEvent::Release => {
                if self.last_event != ButtonEvent::Release {
                    self.last_event = event;
                    self.current_time = 0;
                    self.press_start_time = 0;
                    self.release_time = 0;
                    self.last_tap_time = 0;
                    event
                } else {
                    ButtonEvent::None
                }
            }
            ButtonEvent::None => ButtonEvent::None,
        }
    }
}

impl Default for ButtonFsm {
    fn default() -> Self {
        Self::new()
    }
}

pub fn selftest() -> i32 {
    let mut failures = 0;
    let mut fsm = ButtonFsm::new();

    // Short press then wait past tap threshold -> single tap.
    // 2 ticks pressed (~80 ms), then released; wait until
    // (current - press_start) * 40 > 300 => more than 7.5 ticks after press start.
    fsm.step(true);
    fsm.step(true);
    fsm.step(false);
    let mut saw_single = ButtonEvent::None;
    for _ in 0..12 {
        let e = fsm.step(false);
        if e == ButtonEvent::SingleTap {
            saw_single = e;
            break;
        }
    }
    if saw_single != ButtonEvent::SingleTap {
        failures += 1;
    }

    fsm.reset();
    // Two short presses within the double-tap window.
    fsm.step(true);
    fsm.step(false);
    fsm.step(true);
    let mut saw_double = ButtonEvent::None;
    for _ in 0..4 {
        let e = fsm.step(false);
        if e == ButtonEvent::DoubleTap {
            saw_double = e;
            break;
        }
    }
    if saw_double != ButtonEvent::DoubleTap {
        failures += 1;
    }

    fsm.reset();
    // Hold long enough for long press: 3000/40 = 75 ticks.
    let mut saw_long = ButtonEvent::None;
    for _ in 0..80 {
        let e = fsm.step(true);
        if e == ButtonEvent::LongPress {
            saw_long = e;
            break;
        }
    }
    if saw_long != ButtonEvent::LongPress {
        failures += 1;
    }
    // Second long-press tick is suppressed.
    if fsm.step(true) != ButtonEvent::None {
        failures += 1;
    }

    failures
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn single_tap_after_short_press() {
        let mut fsm = ButtonFsm::new();
        assert_eq!(fsm.step(true), ButtonEvent::None);
        assert_eq!(fsm.step(true), ButtonEvent::None);
        assert_eq!(fsm.step(false), ButtonEvent::None);
        let mut event = ButtonEvent::None;
        for _ in 0..20 {
            event = fsm.step(false);
            if event == ButtonEvent::SingleTap {
                break;
            }
        }
        assert_eq!(event, ButtonEvent::SingleTap);
    }

    #[test]
    fn double_tap_within_window() {
        let mut fsm = ButtonFsm::new();
        fsm.step(true);
        fsm.step(false);
        fsm.step(true);
        let mut event = ButtonEvent::None;
        for _ in 0..6 {
            event = fsm.step(false);
            if event == ButtonEvent::DoubleTap {
                break;
            }
        }
        assert_eq!(event, ButtonEvent::DoubleTap);
    }

    #[test]
    fn long_press_fires_once() {
        let mut fsm = ButtonFsm::new();
        let mut saw = ButtonEvent::None;
        for _ in 0..80 {
            let e = fsm.step(true);
            if e == ButtonEvent::LongPress {
                saw = e;
                break;
            }
        }
        assert_eq!(saw, ButtonEvent::LongPress);
        assert_eq!(fsm.step(true), ButtonEvent::None);
    }

    #[test]
    fn release_after_long_hold_resets_timers() {
        let mut fsm = ButtonFsm::new();
        for _ in 0..20 {
            fsm.step(true);
        }
        // Press held > TAP_THRESHOLD: the release edge itself yields Release.
        assert_eq!(fsm.step(false), ButtonEvent::Release);
        // After reset, a fresh short press can produce SingleTap.
        assert_eq!(fsm.step(true), ButtonEvent::None);
        assert_eq!(fsm.step(false), ButtonEvent::None);
        let mut event = ButtonEvent::None;
        for _ in 0..20 {
            event = fsm.step(false);
            if event == ButtonEvent::SingleTap {
                break;
            }
        }
        assert_eq!(event, ButtonEvent::SingleTap);
    }
}
