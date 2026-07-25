// Stereo-to-mono mix and mean absolute amplitude. PDM / DMIC I/O stays in C.

pub fn interleaved_stereo_to_mono(interleaved: &[i16], mono_out: &mut [i16]) {
    let frames = mono_out.len().min(interleaved.len() / 2);
    for (i, sample) in mono_out.iter_mut().enumerate().take(frames) {
        let j = i * 2;
        let left = i32::from(interleaved[j]);
        let right = i32::from(interleaved[j + 1]);
        let sum = (left + right) >> 1;
        *sample = sum.clamp(i32::from(i16::MIN), i32::from(i16::MAX)) as i16;
    }
}

pub fn avg_abs_amplitude(buf: &[i16]) -> u32 {
    if buf.is_empty() {
        return 0;
    }
    let sum: u64 = buf
        .iter()
        .map(|&s| {
            let v = i32::from(s);
            u32::try_from(if v < 0 { -v } else { v }).unwrap_or(u32::MAX) as u64
        })
        .sum();
    (sum / buf.len() as u64) as u32
}

#[derive(Default)]
pub struct AadSilencePolicy {
    last_voice_ms: i64,
    woke: bool,
}

impl AadSilencePolicy {
    pub fn reset(&mut self, now_ms: i64) {
        self.last_voice_ms = now_ms;
        self.woke = false;
    }

    pub fn mark_woke(&mut self) {
        self.woke = true;
    }

    pub fn should_sleep(
        &mut self,
        samples: &[i16],
        now_ms: i64,
        threshold: u32,
        hold_ms: i64,
        storage_transfer_active: bool,
    ) -> bool {
        if self.woke || avg_abs_amplitude(samples) >= threshold {
            self.last_voice_ms = now_ms;
            self.woke = false;
        }
        !storage_transfer_active && now_ms.saturating_sub(self.last_voice_ms) >= hold_ms.max(0)
    }
}

#[cfg(target_os = "none")]
pub mod aad_state {
    use zephyr::sync::Mutex;

    use super::AadSilencePolicy;

    static POLICY: Mutex<AadSilencePolicy> = Mutex::new(AadSilencePolicy {
        last_voice_ms: 0,
        woke: false,
    });

    pub fn reset(now_ms: i64) {
        POLICY.lock().unwrap().reset(now_ms);
    }

    pub fn mark_woke() {
        POLICY.lock().unwrap().mark_woke();
    }

    pub fn should_sleep(
        samples: &[i16],
        now_ms: i64,
        threshold: u32,
        hold_ms: i64,
        storage_transfer_active: bool,
    ) -> bool {
        POLICY.lock().unwrap().should_sleep(
            samples,
            now_ms,
            threshold,
            hold_ms,
            storage_transfer_active,
        )
    }
}

pub fn selftest() -> i32 {
    let mut failures = 0;

    let inter = [1000i16, -1000, 20000, 20000];
    let mut mono = [0i16; 2];
    interleaved_stereo_to_mono(&inter, &mut mono);
    if mono[0] != 0 || mono[1] != 20000 {
        failures += 1;
    }

    let clip = [32767i16, 32767];
    let mut out = [0i16; 1];
    interleaved_stereo_to_mono(&clip, &mut out);
    if out[0] != 32767 {
        failures += 1;
    }

    if avg_abs_amplitude(&[]) != 0 {
        failures += 1;
    }
    if avg_abs_amplitude(&[-10, 20, -30]) != 20 {
        failures += 1;
    }

    let mut aad = AadSilencePolicy::default();
    aad.reset(100);
    if aad.should_sleep(&[0], 1_099, 10, 1_000, false)
        || !aad.should_sleep(&[0], 1_100, 10, 1_000, false)
    {
        failures += 1;
    }

    failures
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stereo_mix_averages_and_clips() {
        let inter = [1000i16, -1000, 20000, 20000, -30000, 0];
        let mut mono = [0i16; 3];
        interleaved_stereo_to_mono(&inter, &mut mono);
        assert_eq!(mono, [0, 20000, -15000]);
    }

    #[test]
    fn avg_abs_handles_signs_and_empty() {
        assert_eq!(avg_abs_amplitude(&[]), 0);
        assert_eq!(avg_abs_amplitude(&[-10, 20, -30]), 20);
    }

    #[test]
    fn aad_silence_waits_for_hold_and_defers_during_transfer() {
        let mut policy = AadSilencePolicy::default();
        policy.reset(1_000);
        assert!(!policy.should_sleep(&[0], 1_999, 10, 1_000, false));
        assert!(policy.should_sleep(&[0], 2_000, 10, 1_000, false));
        policy.mark_woke();
        assert!(!policy.should_sleep(&[0], 2_001, 10, 1_000, false));
        assert!(!policy.should_sleep(&[0], 3_001, 10, 1_000, true));
        assert!(policy.should_sleep(&[0], 3_001, 10, 1_000, false));
        assert!(!policy.should_sleep(&[20], 3_002, 10, 1_000, false));
    }
}
