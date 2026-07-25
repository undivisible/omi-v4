use core::sync::atomic::{AtomicU32, Ordering};

pub const COUNT: usize = 6;

pub struct Counters {
    values: [u32; COUNT],
}

impl Counters {
    pub fn increment(&mut self, metric: usize) {
        if let Some(value) = self.values.get_mut(metric) {
            *value = value.wrapping_add(1);
        }
    }

    pub fn reset(&mut self) {
        self.values = [0; COUNT];
    }

    pub fn values(&self) -> &[u32; COUNT] {
        &self.values
    }
}

static METRICS: [AtomicU32; COUNT] = [const { AtomicU32::new(0) }; COUNT];

pub fn increment(metric: u8) {
    if let Some(value) = METRICS.get(metric as usize) {
        value.fetch_add(1, Ordering::Relaxed);
    }
}

pub fn reset() {
    for value in &METRICS {
        value.store(0, Ordering::Relaxed);
    }
}

pub fn read(metric: u8) -> u32 {
    METRICS
        .get(metric as usize)
        .map(|value| value.load(Ordering::Relaxed))
        .unwrap_or(0)
}

pub fn selftest() -> i32 {
    let mut counters = Counters { values: [0; COUNT] };
    counters.increment(0);
    counters.increment(0);
    counters.increment(COUNT);
    if counters.values()[0] != 2 {
        return 1;
    }
    counters.reset();
    if counters.values() != &[0; COUNT] {
        return 1;
    }
    0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn increments_and_resets() {
        let mut counters = Counters { values: [0; COUNT] };
        counters.increment(3);
        counters.increment(3);
        counters.increment(COUNT);
        assert_eq!(counters.values()[3], 2);
        counters.reset();
        assert_eq!(counters.values(), &[0; COUNT]);
    }

    #[test]
    fn selftest_passes() {
        assert_eq!(selftest(), 0);
    }
}
