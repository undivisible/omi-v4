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
}
