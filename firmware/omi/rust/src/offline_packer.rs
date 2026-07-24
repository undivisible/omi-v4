// Pure offline SD batching logic ported from transport.c `write_to_storage`.
// C still owns `storage_temp_data` and calls `write_to_file`.

use crate::storage_proto;

pub const OPUS_PREFIX_LENGTH: u16 = 1;
pub const MAX_WRITE_SIZE: u16 = storage_proto::MAX_WRITE_SIZE;

/// Matches `omi_rust_packer_action_t` in omi_rust.h.
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum PackerActionKind {
    Append = 0,
    FlushExact = 1,
    FlushOverflow = 2,
}

/// One step of the offline batching state machine.
#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub struct PackerStep {
    pub action: PackerActionKind,
    pub prefix_offset: u16,
    pub data_offset: u16,
    pub trailing_prefix_offset: u16,
    pub flush_size: u16,
    pub new_buffer_offset: u16,
}

#[derive(Copy, Clone, Debug, Default, PartialEq, Eq)]
pub struct OfflinePacker {
    buffer_offset: u16,
}

impl OfflinePacker {
    pub const fn new() -> Self {
        Self { buffer_offset: 0 }
    }

    pub fn reset(&mut self) {
        self.buffer_offset = 0;
    }

    pub fn buffer_offset(&self) -> u16 {
        self.buffer_offset
    }

    /// Decide how C should place one Opus frame into `storage_temp_data`.
    pub fn step(&mut self, tx_buffer_size: u8) -> PackerStep {
        let packet_size = u16::from(tx_buffer_size) + OPUS_PREFIX_LENGTH;
        let capacity_limit = MAX_WRITE_SIZE - 1;
        let buffer_offset = self.buffer_offset;

        let step = if buffer_offset + packet_size > capacity_limit {
            PackerStep {
                action: PackerActionKind::FlushOverflow,
                trailing_prefix_offset: buffer_offset,
                prefix_offset: 0,
                data_offset: 1,
                flush_size: MAX_WRITE_SIZE,
                new_buffer_offset: packet_size,
            }
        } else if buffer_offset + packet_size == capacity_limit {
            PackerStep {
                action: PackerActionKind::FlushExact,
                prefix_offset: buffer_offset,
                data_offset: buffer_offset + 1,
                trailing_prefix_offset: 0,
                flush_size: MAX_WRITE_SIZE,
                new_buffer_offset: 0,
            }
        } else {
            PackerStep {
                action: PackerActionKind::Append,
                prefix_offset: buffer_offset,
                data_offset: buffer_offset + 1,
                trailing_prefix_offset: 0,
                flush_size: 0,
                new_buffer_offset: buffer_offset + packet_size,
            }
        };

        self.buffer_offset = step.new_buffer_offset;
        step
    }
}

pub fn selftest() -> i32 {
    let mut failures = 0;

    let mut packer = OfflinePacker::new();

    // Small frames append without flush.
    for size in [10u8, 20, 30] {
        let step = packer.step(size);
        if step.action != PackerActionKind::Append || step.flush_size != 0 {
            failures += 1;
        }
    }

    // Several smaller frames append, then one more triggers exact fill.
    packer.reset();
    for _ in 0..5 {
        let step = packer.step(80);
        if step.action != PackerActionKind::Append {
            failures += 1;
        }
    }
    let step = packer.step(33);
    if step.action != PackerActionKind::FlushExact || packer.buffer_offset() != 0 {
        failures += 1;
    }

    // Overflow leaves a trailing prefix and restarts at zero.
    packer.reset();
    packer.buffer_offset = 435;
    let step = packer.step(10);
    if step.action != PackerActionKind::FlushOverflow
        || step.trailing_prefix_offset != 435
        || step.prefix_offset != 0
        || step.data_offset != 1
        || step.new_buffer_offset != 11
    {
        failures += 1;
    }

    failures
}

#[cfg(test)]
mod tests {
    use super::*;

    fn simulate_c_buffer(packer: &mut OfflinePacker, sizes: &[u8]) -> (Vec<Vec<u8>>, Vec<u8>) {
        let mut flushes = Vec::new();
        let mut buf = vec![0u8; MAX_WRITE_SIZE as usize];

        for &size in sizes {
            let step = packer.step(size);
            match step.action {
                PackerActionKind::Append => {
                    buf[step.prefix_offset as usize] = size;
                    buf[step.data_offset as usize..step.data_offset as usize + size as usize]
                        .fill(size);
                }
                PackerActionKind::FlushExact => {
                    buf[step.prefix_offset as usize] = size;
                    buf[step.data_offset as usize..step.data_offset as usize + size as usize]
                        .fill(size);
                    flushes.push(buf.clone());
                    buf.fill(0);
                }
                PackerActionKind::FlushOverflow => {
                    buf[step.trailing_prefix_offset as usize] = size;
                    flushes.push(buf.clone());
                    buf.fill(0);
                    buf[step.prefix_offset as usize] = size;
                    buf[step.data_offset as usize..step.data_offset as usize + size as usize]
                        .fill(size);
                }
            }
        }

        (flushes, buf)
    }

    #[test]
    fn append_advances_offset() {
        let mut packer = OfflinePacker::new();
        let step = packer.step(50);
        assert_eq!(step.action, PackerActionKind::Append);
        assert_eq!(step.prefix_offset, 0);
        assert_eq!(step.data_offset, 1);
        assert_eq!(packer.buffer_offset(), 51);
    }

    #[test]
    fn exact_fill_flushes_and_resets_offset() {
        let mut packer = OfflinePacker::new();
        packer.buffer_offset = 388;
        let step = packer.step(50);
        assert_eq!(step.action, PackerActionKind::FlushExact);
        assert_eq!(step.flush_size, MAX_WRITE_SIZE);
        assert_eq!(packer.buffer_offset(), 0);
    }

    #[test]
    fn overflow_flushes_with_trailing_prefix() {
        let mut packer = OfflinePacker::new();
        packer.buffer_offset = 435;
        let step = packer.step(10);
        assert_eq!(step.action, PackerActionKind::FlushOverflow);
        assert_eq!(step.trailing_prefix_offset, 435);
        assert_eq!(packer.buffer_offset(), 11);
    }

    #[test]
    fn sequential_packets_match_c_layout() {
        let mut packer = OfflinePacker::new();
        // Five 80-byte frames (405 bytes), then 33-byte frame fills 439 exactly.
        let (flushes, tail) = simulate_c_buffer(&mut packer, &[80, 80, 80, 80, 80, 33]);
        assert_eq!(flushes.len(), 1);
        assert_eq!(tail[0], 0);
        assert_eq!(packer.buffer_offset(), 0);
    }

    #[test]
    fn selftest_passes() {
        assert_eq!(selftest(), 0);
    }
}
