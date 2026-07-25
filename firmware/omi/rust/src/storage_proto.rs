// Pure storage BLE sync wire-format logic ported from storage.c.

pub const CMD_STOP_SYNC: u8 = 0x03;
pub const CMD_RING_INFO: u8 = 0x10;
pub const CMD_RING_READ: u8 = 0x11;
pub const CMD_RING_ADVANCE: u8 = 0x12;
pub const CMD_RING_CLEAR: u8 = 0x13;

pub const STORAGE_DEFERRED: u8 = 0xFF;
pub const INVALID_COMMAND: u8 = 6;
pub const STORAGE_NOT_READY: u8 = 9;
pub const SEQ_OUT_OF_RANGE: u8 = 10;

pub const NOTIFY_ACK: u8 = 0x01;
pub const NOTIFY_INFO: u8 = 0x02;
pub const NOTIFY_DATA: u8 = 0x03;
pub const NOTIFY_DONE: u8 = 0x04;
pub const NOTIFY_READ_BEGIN: u8 = 0x05;

pub const ACK_PAYLOAD_LEN: usize = 2;
pub const DONE_PAYLOAD_LEN: usize = 14;
pub const RING_INFO_PAYLOAD_LEN: usize = 31;
pub const READ_BEGIN_PAYLOAD_LEN: usize = 13;

pub const RAW_AUDIO_TIMESTAMP_BYTES: u16 = 4;
pub const MAX_WRITE_SIZE: u16 = 440;
pub const RAW_AUDIO_PACKET_BYTES: u16 = RAW_AUDIO_TIMESTAMP_BYTES + MAX_WRITE_SIZE;

const EAGAIN: i32 = 11;
const EBUSY: i32 = 16;
const ERANGE: i32 = 34;
const ETIMEDOUT: i32 = 116;
const ECANCELED: i32 = 125;

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StorageCommand {
    Invalid = 0,
    RingInfo = 1,
    RingRead = 2,
    RingAdvance = 3,
    RingClear = 4,
    StopSync = 5,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ParsedStorageCommand {
    pub command: StorageCommand,
    pub start_seq: u64,
    pub packet_count: u32,
    pub advance_seq: u64,
}

pub struct RingInfoFields {
    pub read_seq: u64,
    pub write_seq: u64,
    pub capacity_packets: u32,
    pub dropped_packets: u64,
    pub packet_bytes: u16,
}

fn put_be64(value: u64, out: &mut [u8]) {
    out.copy_from_slice(&value.to_be_bytes());
}

fn put_be32(value: u32, out: &mut [u8]) {
    out.copy_from_slice(&value.to_be_bytes());
}

fn put_be16(value: u16, out: &mut [u8]) {
    out.copy_from_slice(&value.to_be_bytes());
}

fn get_be64(bytes: &[u8]) -> u64 {
    let mut buf = [0u8; 8];
    buf.copy_from_slice(bytes);
    u64::from_be_bytes(buf)
}

fn get_be32(bytes: &[u8]) -> u32 {
    let mut buf = [0u8; 4];
    buf.copy_from_slice(bytes);
    u32::from_be_bytes(buf)
}

pub fn parse_command(buf: &[u8]) -> (u8, ParsedStorageCommand) {
    let mut parsed = ParsedStorageCommand {
        command: StorageCommand::Invalid,
        start_seq: 0,
        packet_count: 0,
        advance_seq: 0,
    };

    if buf.is_empty() {
        return (INVALID_COMMAND, parsed);
    }

    match buf[0] {
        CMD_RING_INFO => {
            parsed.command = StorageCommand::RingInfo;
            (STORAGE_DEFERRED, parsed)
        }
        CMD_RING_READ => {
            if buf.len() != 9 && buf.len() != 13 {
                return (INVALID_COMMAND, parsed);
            }
            parsed.command = StorageCommand::RingRead;
            parsed.start_seq = get_be64(&buf[1..9]);
            parsed.packet_count = if buf.len() == 13 {
                get_be32(&buf[9..13])
            } else {
                0
            };
            (STORAGE_DEFERRED, parsed)
        }
        CMD_RING_ADVANCE => {
            if buf.len() != 9 {
                return (INVALID_COMMAND, parsed);
            }
            parsed.command = StorageCommand::RingAdvance;
            parsed.advance_seq = get_be64(&buf[1..9]);
            (STORAGE_DEFERRED, parsed)
        }
        CMD_RING_CLEAR => {
            parsed.command = StorageCommand::RingClear;
            (STORAGE_DEFERRED, parsed)
        }
        CMD_STOP_SYNC => {
            parsed.command = StorageCommand::StopSync;
            (0, parsed)
        }
        _ => (INVALID_COMMAND, parsed),
    }
}

pub fn status_from_error(err: i32, fallback_status: u8) -> u8 {
    match err {
        e if e == -ERANGE => SEQ_OUT_OF_RANGE,
        e if e == -ETIMEDOUT || e == -EBUSY || e == -ECANCELED || e == -EAGAIN => STORAGE_NOT_READY,
        _ => fallback_status,
    }
}

pub fn ble_data_chunk_size(mtu: u16) -> u16 {
    let att_payload = if mtu > 3 { mtu - 3 } else { 20 };

    if att_payload <= 1 {
        20
    } else {
        att_payload - 1
    }
}

pub fn encode_ack(status: u8, out: &mut [u8]) -> usize {
    out[0] = NOTIFY_ACK;
    out[1] = status;
    ACK_PAYLOAD_LEN
}

pub fn crc32_update(mut crc: u32, data: &[u8]) -> u32 {
    crc = !crc;
    for byte in data {
        crc ^= u32::from(*byte);
        for _ in 0..8 {
            crc = (crc >> 1) ^ (0xEDB8_8320 & 0u32.wrapping_sub(crc & 1));
        }
    }
    !crc
}

pub fn encode_done(status: u8, next_seq: u64, crc: u32, out: &mut [u8]) -> usize {
    out[0] = NOTIFY_DONE;
    out[1] = status;
    put_be64(next_seq, &mut out[2..10]);
    put_be32(crc, &mut out[10..14]);
    DONE_PAYLOAD_LEN
}

pub fn encode_ring_info(info: &RingInfoFields, out: &mut [u8]) -> usize {
    out[0] = NOTIFY_INFO;
    put_be64(info.read_seq, &mut out[1..9]);
    put_be64(info.write_seq, &mut out[9..17]);
    put_be32(info.capacity_packets, &mut out[17..21]);
    put_be64(info.dropped_packets, &mut out[21..29]);
    put_be16(info.packet_bytes, &mut out[29..31]);
    RING_INFO_PAYLOAD_LEN
}

pub fn encode_read_begin(start_seq: u64, packet_count: u32, out: &mut [u8]) -> usize {
    out[0] = NOTIFY_READ_BEGIN;
    put_be64(start_seq, &mut out[1..9]);
    put_be32(packet_count, &mut out[9..13]);
    READ_BEGIN_PAYLOAD_LEN
}

pub fn encode_data(payload: &[u8], out: &mut [u8]) -> usize {
    out[0] = NOTIFY_DATA;
    let payload_len = payload.len();
    if payload_len > 0 {
        out[1..1 + payload_len].copy_from_slice(payload);
    }
    1 + payload_len
}

pub fn selftest() -> i32 {
    let mut failures = 0;

    let mut ack = [0u8; ACK_PAYLOAD_LEN];
    if encode_ack(0, &mut ack) != ACK_PAYLOAD_LEN || ack != [NOTIFY_ACK, 0] {
        failures += 1;
    }

    let mut done = [0u8; DONE_PAYLOAD_LEN];
    if encode_done(9, 0x0123_4567_89AB_CDEF, 0xCBF4_3926, &mut done) != DONE_PAYLOAD_LEN {
        failures += 1;
    }
    if done[0] != NOTIFY_DONE
        || done[1] != 9
        || done[2..10] != 0x0123_4567_89AB_CDEFu64.to_be_bytes()
        || done[10..14] != 0xCBF4_3926u32.to_be_bytes()
    {
        failures += 1;
    }

    let info = RingInfoFields {
        read_seq: 1,
        write_seq: 100,
        capacity_packets: 5000,
        dropped_packets: 3,
        packet_bytes: RAW_AUDIO_PACKET_BYTES,
    };
    let mut ring = [0u8; RING_INFO_PAYLOAD_LEN];
    if encode_ring_info(&info, &mut ring) != RING_INFO_PAYLOAD_LEN || ring[0] != NOTIFY_INFO {
        failures += 1;
    }

    let mut read_begin = [0u8; READ_BEGIN_PAYLOAD_LEN];
    if encode_read_begin(0x0123_4567_89AB_CDEF, 42, &mut read_begin) != READ_BEGIN_PAYLOAD_LEN {
        failures += 1;
    }
    if read_begin[0] != NOTIFY_READ_BEGIN
        || read_begin[1..9] != 0x0123_4567_89AB_CDEFu64.to_be_bytes()
        || read_begin[9..13] != 42u32.to_be_bytes()
    {
        failures += 1;
    }

    let payload = [0xAA, 0xBB, 0xCC];
    let mut data = [0u8; 4];
    if encode_data(&payload, &mut data) != 4 || data != [NOTIFY_DATA, 0xAA, 0xBB, 0xCC] {
        failures += 1;
    }

    if ble_data_chunk_size(0) != 19
        || ble_data_chunk_size(4) != 20
        || ble_data_chunk_size(517) != 513
    {
        failures += 1;
    }

    let (status, parsed) = parse_command(&[CMD_RING_INFO]);
    if status != STORAGE_DEFERRED || parsed.command != StorageCommand::RingInfo {
        failures += 1;
    }

    let read_cmd = [CMD_RING_READ, 0, 0, 0, 0, 0, 0, 0, 0x0A, 0, 0, 0, 5];
    let (status, parsed) = parse_command(&read_cmd);
    if status != STORAGE_DEFERRED
        || parsed.command != StorageCommand::RingRead
        || parsed.start_seq != 10
        || parsed.packet_count != 5
    {
        failures += 1;
    }

    if status_from_error(-ERANGE, STORAGE_NOT_READY) != SEQ_OUT_OF_RANGE {
        failures += 1;
    }
    if status_from_error(-EAGAIN, SEQ_OUT_OF_RANGE) != STORAGE_NOT_READY {
        failures += 1;
    }

    failures
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ack_wire_format() {
        let mut out = [0u8; ACK_PAYLOAD_LEN];
        assert_eq!(encode_ack(6, &mut out), 2);
        assert_eq!(out, [NOTIFY_ACK, 6]);
    }

    #[test]
    fn done_wire_format() {
        let mut out = [0u8; DONE_PAYLOAD_LEN];
        encode_done(0, 0xDEAD_BEEF_CAFE_BABEu64, 0xCBF4_3926, &mut out);
        assert_eq!(out[0], NOTIFY_DONE);
        assert_eq!(out[1], 0);
        assert_eq!(&out[2..10], &0xDEAD_BEEF_CAFE_BABEu64.to_be_bytes());
        assert_eq!(&out[10..], &0xCBF4_3926u32.to_be_bytes());
    }

    #[test]
    fn crc_matches_golden_vector() {
        assert_eq!(crc32_update(0, b"123456789"), 0xCBF4_3926);
        let first = crc32_update(0, b"1234");
        assert_eq!(crc32_update(first, b"56789"), 0xCBF4_3926);
    }

    #[test]
    fn read_begin_wire_format() {
        let mut out = [0u8; READ_BEGIN_PAYLOAD_LEN];
        assert_eq!(encode_read_begin(0x0123_4567_89AB_CDEF, 99, &mut out), 13);
        assert_eq!(out[0], NOTIFY_READ_BEGIN);
        assert_eq!(&out[1..9], &0x0123_4567_89AB_CDEFu64.to_be_bytes());
        assert_eq!(&out[9..13], &99u32.to_be_bytes());
    }

    #[test]
    fn data_wire_format() {
        let payload = [0xDE, 0xAD, 0xBE, 0xEF];
        let mut out = [0u8; 5];
        assert_eq!(encode_data(&payload, &mut out), 5);
        assert_eq!(out, [NOTIFY_DATA, 0xDE, 0xAD, 0xBE, 0xEF]);
    }

    #[test]
    fn data_empty_payload() {
        let mut out = [0xFF; 1];
        assert_eq!(encode_data(&[], &mut out), 1);
        assert_eq!(out, [NOTIFY_DATA]);
    }

    #[test]
    fn ring_info_wire_format() {
        let info = RingInfoFields {
            read_seq: 0x1111_1111_1111_1111,
            write_seq: 0x2222_2222_2222_2222,
            capacity_packets: 0x3333_3333,
            dropped_packets: 0x4444_4444_4444_4444,
            packet_bytes: RAW_AUDIO_PACKET_BYTES,
        };
        let mut out = [0u8; RING_INFO_PAYLOAD_LEN];
        encode_ring_info(&info, &mut out);
        assert_eq!(out[0], NOTIFY_INFO);
        assert_eq!(&out[1..9], &info.read_seq.to_be_bytes());
        assert_eq!(&out[9..17], &info.write_seq.to_be_bytes());
        assert_eq!(&out[17..21], &info.capacity_packets.to_be_bytes());
        assert_eq!(&out[21..29], &info.dropped_packets.to_be_bytes());
        assert_eq!(&out[29..31], &info.packet_bytes.to_be_bytes());
        assert_eq!(info.packet_bytes, 444);
    }

    #[test]
    fn ble_chunk_size_matches_c() {
        assert_eq!(ble_data_chunk_size(0), 19);
        assert_eq!(ble_data_chunk_size(3), 19);
        assert_eq!(ble_data_chunk_size(4), 20);
        assert_eq!(ble_data_chunk_size(5), 1);
        assert_eq!(ble_data_chunk_size(23), 19);
        assert_eq!(ble_data_chunk_size(517), 513);
    }

    #[test]
    fn parse_ring_read_without_count() {
        let cmd = [CMD_RING_READ, 0, 0, 0, 0, 0, 0, 0x01, 0x02];
        let (status, parsed) = parse_command(&cmd);
        assert_eq!(status, STORAGE_DEFERRED);
        assert_eq!(parsed.command, StorageCommand::RingRead);
        assert_eq!(parsed.start_seq, 0x102);
        assert_eq!(parsed.packet_count, 0);
    }

    #[test]
    fn parse_ring_advance() {
        let cmd = [CMD_RING_ADVANCE, 0, 0, 0, 0, 0, 0, 0x01, 0x03];
        let (status, parsed) = parse_command(&cmd);
        assert_eq!(status, STORAGE_DEFERRED);
        assert_eq!(parsed.command, StorageCommand::RingAdvance);
        assert_eq!(parsed.advance_seq, 0x103);
    }

    #[test]
    fn parse_invalid_commands() {
        let (status, parsed) = parse_command(&[]);
        assert_eq!(status, INVALID_COMMAND);
        assert_eq!(parsed.command, StorageCommand::Invalid);

        let (status, _) = parse_command(&[CMD_RING_READ, 0]);
        assert_eq!(status, INVALID_COMMAND);

        let (status, _) = parse_command(&[CMD_RING_ADVANCE, 0, 0]);
        assert_eq!(status, INVALID_COMMAND);

        let (status, parsed) = parse_command(&[0x99]);
        assert_eq!(status, INVALID_COMMAND);
        assert_eq!(parsed.command, StorageCommand::Invalid);
    }

    #[test]
    fn parse_stop_sync() {
        let (status, parsed) = parse_command(&[CMD_STOP_SYNC]);
        assert_eq!(status, 0);
        assert_eq!(parsed.command, StorageCommand::StopSync);
    }

    #[test]
    fn status_from_error_matches_c() {
        assert_eq!(status_from_error(-ERANGE, 0), SEQ_OUT_OF_RANGE);
        assert_eq!(status_from_error(-ETIMEDOUT, 0), STORAGE_NOT_READY);
        assert_eq!(status_from_error(-EBUSY, 0), STORAGE_NOT_READY);
        assert_eq!(status_from_error(-ECANCELED, 0), STORAGE_NOT_READY);
        assert_eq!(status_from_error(-EAGAIN, 0), STORAGE_NOT_READY);
        assert_eq!(status_from_error(-999, 7), 7);
    }

    #[test]
    fn selftest_passes() {
        assert_eq!(selftest(), 0);
    }
}
