//! Desktop proactive keyboard binds: both-Shift chord semantics shared by
//! macOS/Windows runners and the Flutter shell. Swift/C++ emit physical
//! left/right Shift transitions; this module turns them into intents the UI
//! consumes (overlay summon, voice toggle, dismiss).

#![allow(dead_code)]

const DEFAULT_DOUBLE_CHORD_WINDOW_MS: u64 = 400;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PhysicalShift {
    Left,
    Right,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ProactiveBindAction {
    ToggleVoice,
    OpenOverlay,
    Escape,
    StartVoice,
    StopVoice,
    Cancel,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ProactiveBindInput {
    Shift { key: PhysicalShift, pressed: bool },
    SummonOverlay,
    Escape,
    SecureInput { enabled: bool },
    ChordTimeout,
}

pub struct ProactiveBindMachine {
    double_chord_window_ms: u64,
    secure_input: bool,
    left_down: bool,
    right_down: bool,
    chord_consumed: bool,
    pending_chord_at_ms: Option<u64>,
    now_ms: u64,
}

impl ProactiveBindMachine {
    pub fn new(now_ms: u64) -> Self {
        Self {
            double_chord_window_ms: DEFAULT_DOUBLE_CHORD_WINDOW_MS,
            secure_input: false,
            left_down: false,
            right_down: false,
            chord_consumed: false,
            pending_chord_at_ms: None,
            now_ms,
        }
    }

    pub fn with_double_chord_window_ms(mut self, window_ms: u64) -> Self {
        self.double_chord_window_ms = window_ms;
        self
    }

    pub fn set_now_ms(&mut self, now_ms: u64) {
        self.now_ms = now_ms;
    }

    pub fn has_pending_chord(&self) -> bool {
        self.pending_chord_at_ms.is_some()
    }

    pub fn double_chord_window_ms(&self) -> u64 {
        self.double_chord_window_ms
    }

    pub fn handle(&mut self, input: ProactiveBindInput) -> Vec<ProactiveBindAction> {
        match input {
            ProactiveBindInput::Shift { key, pressed } => self.shift(key, pressed),
            ProactiveBindInput::SummonOverlay => self.summon_overlay(),
            ProactiveBindInput::Escape => self.escape(),
            ProactiveBindInput::SecureInput { enabled } => self.set_secure_input(enabled),
            ProactiveBindInput::ChordTimeout => self.chord_timeout(),
        }
    }

    fn shift(&mut self, key: PhysicalShift, pressed: bool) -> Vec<ProactiveBindAction> {
        match key {
            PhysicalShift::Left => self.left_down = pressed,
            PhysicalShift::Right => self.right_down = pressed,
        }
        if self.secure_input {
            self.clear_chord_when_released();
            return Vec::new();
        }
        let both_down = self.left_down && self.right_down;
        if both_down && !self.chord_consumed {
            self.chord_consumed = true;
            if let Some(pending_at) = self.pending_chord_at_ms
                && self.now_ms.saturating_sub(pending_at) <= self.double_chord_window_ms
            {
                self.pending_chord_at_ms = None;
                return vec![ProactiveBindAction::ToggleVoice];
            }
            self.pending_chord_at_ms = Some(self.now_ms);
            return Vec::new();
        }
        self.clear_chord_when_released();
        Vec::new()
    }

    fn chord_timeout(&mut self) -> Vec<ProactiveBindAction> {
        if self.pending_chord_at_ms.is_none() {
            return Vec::new();
        }
        self.pending_chord_at_ms = None;
        vec![ProactiveBindAction::OpenOverlay]
    }

    fn summon_overlay(&mut self) -> Vec<ProactiveBindAction> {
        self.pending_chord_at_ms = None;
        if self.secure_input {
            Vec::new()
        } else {
            vec![ProactiveBindAction::OpenOverlay]
        }
    }

    fn escape(&mut self) -> Vec<ProactiveBindAction> {
        self.pending_chord_at_ms = None;
        vec![ProactiveBindAction::Escape]
    }

    fn set_secure_input(&mut self, enabled: bool) -> Vec<ProactiveBindAction> {
        self.secure_input = enabled;
        self.reset();
        if enabled {
            vec![ProactiveBindAction::Cancel]
        } else {
            Vec::new()
        }
    }

    fn clear_chord_when_released(&mut self) {
        if !self.left_down && !self.right_down {
            self.chord_consumed = false;
        }
    }

    fn reset(&mut self) {
        self.left_down = false;
        self.right_down = false;
        self.chord_consumed = false;
        self.pending_chord_at_ms = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn chord(machine: &mut ProactiveBindMachine) -> Vec<ProactiveBindAction> {
        let mut actions = Vec::new();
        actions.extend(machine.handle(ProactiveBindInput::Shift {
            key: PhysicalShift::Left,
            pressed: true,
        }));
        actions.extend(machine.handle(ProactiveBindInput::Shift {
            key: PhysicalShift::Right,
            pressed: true,
        }));
        actions.extend(machine.handle(ProactiveBindInput::Shift {
            key: PhysicalShift::Left,
            pressed: false,
        }));
        actions.extend(machine.handle(ProactiveBindInput::Shift {
            key: PhysicalShift::Right,
            pressed: false,
        }));
        actions
    }

    #[test]
    fn single_chord_resolves_to_overlay_after_timeout() {
        let mut machine = ProactiveBindMachine::new(0);
        assert!(chord(&mut machine).is_empty());
        assert!(machine.has_pending_chord());
        machine.set_now_ms(400);
        assert_eq!(
            machine.handle(ProactiveBindInput::ChordTimeout),
            vec![ProactiveBindAction::OpenOverlay]
        );
    }

    #[test]
    fn double_chord_inside_window_toggles_voice() {
        let mut machine = ProactiveBindMachine::new(0);
        assert!(chord(&mut machine).is_empty());
        machine.set_now_ms(250);
        assert_eq!(chord(&mut machine), vec![ProactiveBindAction::ToggleVoice]);
    }

    #[test]
    fn secure_input_cancels_and_suppresses_chords() {
        let mut machine = ProactiveBindMachine::new(0);
        machine.handle(ProactiveBindInput::Shift {
            key: PhysicalShift::Left,
            pressed: true,
        });
        assert_eq!(
            machine.handle(ProactiveBindInput::SecureInput { enabled: true }),
            vec![ProactiveBindAction::Cancel]
        );
        assert!(
            machine
                .handle(ProactiveBindInput::Shift {
                    key: PhysicalShift::Right,
                    pressed: true,
                })
                .is_empty()
        );
    }
}
