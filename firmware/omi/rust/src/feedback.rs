// Error-indication color/blink tables ported from firmware/omi/src/feedback.c.
// Timing (`k_msleep`) and the LED driver calls stay in C.

#[derive(Copy, Clone, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum ErrorKind {
    Settings = 0,
    LedDriver = 1,
    BatteryInit = 2,
    BatteryCharge = 3,
    Button = 4,
    Haptic = 5,
    SdCard = 6,
    Storage = 7,
    Transport = 8,
    Codec = 9,
    Microphone = 10,
}

#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub struct ErrorPattern {
    pub red: bool,
    pub green: bool,
    pub blue: bool,
    pub blinks: u8,
}

const fn pattern(red: bool, green: bool, blue: bool, blinks: u8) -> ErrorPattern {
    ErrorPattern {
        red,
        green,
        blue,
        blinks,
    }
}

/// Color-coded component pattern after the shared RED alert blink.
pub fn error_pattern(kind: ErrorKind) -> ErrorPattern {
    match kind {
        ErrorKind::Settings => pattern(true, false, false, 1),
        ErrorKind::LedDriver => pattern(true, false, false, 2),
        ErrorKind::BatteryInit => pattern(true, true, false, 1),
        ErrorKind::BatteryCharge => pattern(true, true, false, 2),
        ErrorKind::Button => pattern(false, true, false, 1),
        ErrorKind::Haptic => pattern(true, false, true, 3),
        ErrorKind::SdCard => pattern(false, true, true, 1),
        ErrorKind::Storage => pattern(false, true, true, 2),
        ErrorKind::Transport => pattern(false, false, true, 1),
        ErrorKind::Codec => pattern(true, false, true, 1),
        ErrorKind::Microphone => pattern(true, false, true, 2),
    }
}

pub fn selftest() -> i32 {
    let mut failures = 0;
    let p = error_pattern(ErrorKind::Haptic);
    if !p.red || p.green || !p.blue || p.blinks != 3 {
        failures += 1;
    }
    let p = error_pattern(ErrorKind::Transport);
    if p.red || p.green || !p.blue || p.blinks != 1 {
        failures += 1;
    }
    failures
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn patterns_match_c_tables() {
        assert_eq!(
            error_pattern(ErrorKind::Settings),
            pattern(true, false, false, 1)
        );
        assert_eq!(
            error_pattern(ErrorKind::BatteryCharge),
            pattern(true, true, false, 2)
        );
        assert_eq!(
            error_pattern(ErrorKind::Microphone),
            pattern(true, false, true, 2)
        );
        assert_eq!(
            error_pattern(ErrorKind::SdCard),
            pattern(false, true, true, 1)
        );
    }
}
