// SD raw-ring validation and seq/sector math. Disk I/O and the worker stay in C.

use crate::storage_proto::RAW_AUDIO_PACKET_BYTES;

pub const RAW_META_SECTORS: u32 = 64;
pub const RAW_BATCH_SECTORS: u32 = 32;
pub const DISK_SECTOR_SIZE: u32 = 512;
pub const RAW_BATCH_BYTES: u32 = RAW_BATCH_SECTORS * DISK_SECTOR_SIZE;
pub const RAW_BATCH_HEADER_BYTES: u32 = 32;
pub const RAW_PACKETS_PER_BATCH: u32 =
    (RAW_BATCH_BYTES - RAW_BATCH_HEADER_BYTES) / RAW_AUDIO_PACKET_BYTES as u32;

pub const RAW_META_MAGIC: u32 = 0x4F4D_4952;
pub const RAW_BATCH_MAGIC: u32 = 0x4F4D_4942;
pub const RAW_LAYOUT_VERSION: u16 = 1;

pub fn ring_used_packets(
    write_seq: u64,
    read_seq: u64,
    current_batch_loaded: bool,
    current_batch_packets: u32,
    current_batch_base_seq: u64,
) -> u64 {
    let committed = write_seq.wrapping_sub(read_seq);

    if !current_batch_loaded || current_batch_packets == 0 {
        return committed;
    }

    let batch_end = current_batch_base_seq.wrapping_add(u64::from(current_batch_packets));
    if batch_end <= write_seq {
        return committed;
    }

    committed.wrapping_add(batch_end.wrapping_sub(write_seq))
}

pub fn ring_used_bytes(
    write_seq: u64,
    read_seq: u64,
    current_batch_loaded: bool,
    current_batch_packets: u32,
    current_batch_base_seq: u64,
) -> u64 {
    ring_used_packets(
        write_seq,
        read_seq,
        current_batch_loaded,
        current_batch_packets,
        current_batch_base_seq,
    ) * u64::from(RAW_AUDIO_PACKET_BYTES)
}

pub fn batch_sector_for_base_seq(base_seq: u64, data_batch_count: u32) -> u32 {
    if data_batch_count == 0 {
        return RAW_META_SECTORS;
    }
    let batch_index = base_seq / u64::from(RAW_PACKETS_PER_BATCH);
    let slot = (batch_index % u64::from(data_batch_count)) as u32;
    RAW_META_SECTORS + (slot * RAW_BATCH_SECTORS)
}

pub fn meta_record_valid(
    magic: u32,
    version: u16,
    write_seq: u64,
    read_seq: u64,
    capacity_packets: u32,
) -> bool {
    if magic != RAW_META_MAGIC || version != RAW_LAYOUT_VERSION {
        return false;
    }
    if write_seq < read_seq {
        return false;
    }
    if (write_seq - read_seq) > u64::from(capacity_packets) {
        return false;
    }
    true
}

pub fn batch_header_valid(magic: u32, version: u16, packet_count: u16, start_seq: u64) -> bool {
    if magic != RAW_BATCH_MAGIC || version != RAW_LAYOUT_VERSION {
        return false;
    }
    if u32::from(packet_count) > RAW_PACKETS_PER_BATCH {
        return false;
    }
    if !start_seq.is_multiple_of(u64::from(RAW_PACKETS_PER_BATCH)) {
        return false;
    }
    true
}

/// Write `"%08X.txt"` into `out`. Returns bytes written excluding NUL, or 0.
pub fn format_timestamp_name(timestamp: u32, out: &mut [u8]) -> usize {
    const SUFFIX: &[u8] = b".txt";
    if out.len() < 8 + SUFFIX.len() + 1 {
        if !out.is_empty() {
            out[0] = 0;
        }
        return 0;
    }
    const HEX: &[u8; 16] = b"0123456789ABCDEF";
    for (i, slot) in out.iter_mut().enumerate().take(8) {
        let nibble = ((timestamp >> (28 - 4 * i)) & 0xF) as usize;
        *slot = HEX[nibble];
    }
    out[8..12].copy_from_slice(SUFFIX);
    out[12] = 0;
    12
}

pub fn selftest() -> i32 {
    let mut failures = 0;
    if RAW_PACKETS_PER_BATCH != 36 {
        failures += 1;
    }
    if ring_used_packets(10, 2, false, 0, 0) != 8 {
        failures += 1;
    }
    if ring_used_packets(10, 2, true, 5, 10) != 8 + 5 {
        failures += 1;
    }
    if batch_sector_for_base_seq(0, 4) != RAW_META_SECTORS {
        failures += 1;
    }
    if batch_sector_for_base_seq(u64::from(RAW_PACKETS_PER_BATCH), 4)
        != RAW_META_SECTORS + RAW_BATCH_SECTORS
    {
        failures += 1;
    }
    if !meta_record_valid(RAW_META_MAGIC, RAW_LAYOUT_VERSION, 10, 2, 100) {
        failures += 1;
    }
    if meta_record_valid(RAW_META_MAGIC, RAW_LAYOUT_VERSION, 2, 10, 100) {
        failures += 1;
    }
    if !batch_header_valid(RAW_BATCH_MAGIC, RAW_LAYOUT_VERSION, 1, 0) {
        failures += 1;
    }
    if batch_header_valid(RAW_BATCH_MAGIC, RAW_LAYOUT_VERSION, 1, 1) {
        failures += 1;
    }
    let mut name = [0u8; 16];
    if format_timestamp_name(0x1A2B_3C4D, &mut name) != 12
        || &name[..12] != b"1A2B3C4D.txt"
    {
        failures += 1;
    }
    failures
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn packets_per_batch_matches_c() {
        assert_eq!(RAW_PACKETS_PER_BATCH, 36);
    }

    #[test]
    fn used_and_sector_math() {
        assert_eq!(ring_used_packets(100, 40, false, 0, 0), 60);
        assert_eq!(ring_used_bytes(100, 40, false, 0, 0), 60 * 444);
        assert_eq!(batch_sector_for_base_seq(72, 8), RAW_META_SECTORS + 2 * RAW_BATCH_SECTORS);
    }

    #[test]
    fn validation_gates() {
        assert!(meta_record_valid(RAW_META_MAGIC, 1, 5, 5, 10));
        assert!(!meta_record_valid(0, 1, 5, 5, 10));
        assert!(batch_header_valid(RAW_BATCH_MAGIC, 1, 36, 0));
        assert!(!batch_header_valid(RAW_BATCH_MAGIC, 1, 37, 0));
    }

    #[test]
    fn timestamp_name_hex() {
        let mut buf = [0u8; 20];
        assert_eq!(format_timestamp_name(0xDEAD_BEEF, &mut buf), 12);
        assert_eq!(&buf[..12], b"DEADBEEF.txt");
        assert_eq!(buf[12], 0);
    }
}
