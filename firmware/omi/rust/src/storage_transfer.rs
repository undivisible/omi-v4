#[cfg(not(target_os = "none"))]
use std::sync::Mutex;

#[cfg(target_os = "none")]
use zephyr::sync::Mutex;

use crate::storage_proto;

#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub struct StorageTransfer {
    active: bool,
    read_begin_sent: bool,
    done_pending: bool,
    start_seq: u64,
    current_seq: u64,
    remaining_packets: u32,
    end_status: u8,
    data_crc: u32,
}

impl StorageTransfer {
    pub const fn new() -> Self {
        Self {
            active: false,
            read_begin_sent: false,
            done_pending: false,
            start_seq: 0,
            current_seq: 0,
            remaining_packets: 0,
            end_status: 0,
            data_crc: 0,
        }
    }

    pub fn reset(&mut self) {
        *self = Self::new();
    }

    pub fn start(&mut self, start_seq: u64, packet_count: u32) {
        self.active = true;
        self.read_begin_sent = false;
        self.done_pending = false;
        self.start_seq = start_seq;
        self.current_seq = start_seq;
        self.remaining_packets = packet_count;
        self.end_status = 0;
        self.data_crc = 0;
    }

    pub fn active(&self) -> bool {
        self.active
    }

    pub fn read_begin_sent(&self) -> bool {
        self.read_begin_sent
    }

    pub fn mark_read_begin_sent(&mut self) {
        self.read_begin_sent = true;
    }

    pub fn done_pending(&self) -> bool {
        self.done_pending
    }

    pub fn complete(&mut self, status: u8) {
        self.end_status = status;
        self.done_pending = true;
        self.remaining_packets = 0;
    }

    pub fn start_seq(&self) -> u64 {
        self.start_seq
    }

    pub fn current_seq(&self) -> u64 {
        self.current_seq
    }

    pub fn remaining_packets(&self) -> u32 {
        self.remaining_packets
    }

    pub fn end_status(&self) -> u8 {
        self.end_status
    }

    pub fn data_crc(&self) -> u32 {
        self.data_crc
    }

    pub fn note_packets_read(&mut self, packets_read: u32) {
        let packets_read = packets_read.min(self.remaining_packets);
        self.current_seq = self.current_seq.wrapping_add(u64::from(packets_read));
        self.remaining_packets -= packets_read;
        if self.remaining_packets == 0 {
            self.done_pending = true;
        }
    }

    pub fn update_crc_byte(&mut self, byte: u8) {
        self.data_crc = storage_proto::crc32_update(self.data_crc, &[byte]);
    }
}

impl Default for StorageTransfer {
    fn default() -> Self {
        Self::new()
    }
}

static TRANSFER: Mutex<StorageTransfer> = Mutex::new(StorageTransfer::new());

pub fn reset() {
    TRANSFER.lock().unwrap().reset();
}

pub fn start(start_seq: u64, packet_count: u32) {
    TRANSFER.lock().unwrap().start(start_seq, packet_count);
}

pub fn active() -> bool {
    TRANSFER.lock().unwrap().active()
}

pub fn read_begin_sent() -> bool {
    TRANSFER.lock().unwrap().read_begin_sent()
}

pub fn mark_read_begin_sent() {
    TRANSFER.lock().unwrap().mark_read_begin_sent();
}

pub fn done_pending() -> bool {
    TRANSFER.lock().unwrap().done_pending()
}

pub fn complete(status: u8) {
    TRANSFER.lock().unwrap().complete(status);
}

pub fn start_seq() -> u64 {
    TRANSFER.lock().unwrap().start_seq()
}

pub fn current_seq() -> u64 {
    TRANSFER.lock().unwrap().current_seq()
}

pub fn remaining_packets() -> u32 {
    TRANSFER.lock().unwrap().remaining_packets()
}

pub fn end_status() -> u8 {
    TRANSFER.lock().unwrap().end_status()
}

pub fn data_crc() -> u32 {
    TRANSFER.lock().unwrap().data_crc()
}

pub fn note_packets_read(packets_read: u32) {
    TRANSFER.lock().unwrap().note_packets_read(packets_read);
}

pub fn update_crc_byte(byte: u8) {
    TRANSFER.lock().unwrap().update_crc_byte(byte);
}

pub fn selftest() -> i32 {
    let mut failures = 0;
    let mut transfer = StorageTransfer::new();
    transfer.start(10, 3);
    if !transfer.active() || transfer.read_begin_sent() || transfer.done_pending() {
        failures += 1;
    }
    transfer.mark_read_begin_sent();
    transfer.note_packets_read(2);
    if transfer.current_seq() != 12 || transfer.remaining_packets() != 1 || transfer.done_pending()
    {
        failures += 1;
    }
    for byte in b"123456789" {
        transfer.update_crc_byte(*byte);
    }
    if transfer.data_crc() != 0xCBF4_3926 {
        failures += 1;
    }
    transfer.note_packets_read(1);
    if !transfer.done_pending() {
        failures += 1;
    }
    transfer.reset();
    if transfer.active() || transfer.current_seq() != 0 || transfer.data_crc() != 0 {
        failures += 1;
    }
    failures
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn transfer_tracks_read_progress_and_crc() {
        let mut transfer = StorageTransfer::new();
        transfer.start(100, 2);
        transfer.mark_read_begin_sent();
        transfer.update_crc_byte(b'a');
        transfer.note_packets_read(1);
        assert!(transfer.active());
        assert!(transfer.read_begin_sent());
        assert!(!transfer.done_pending());
        assert_eq!(transfer.current_seq(), 101);
        assert_eq!(transfer.remaining_packets(), 1);
        transfer.note_packets_read(1);
        assert!(transfer.done_pending());
        assert_eq!(transfer.current_seq(), 102);
        assert_eq!(transfer.data_crc(), storage_proto::crc32_update(0, b"a"));
    }

    #[test]
    fn completion_clears_remaining_packets_and_reset_clears_state() {
        let mut transfer = StorageTransfer::new();
        transfer.start(7, 4);
        transfer.complete(9);
        assert!(transfer.done_pending());
        assert_eq!(transfer.remaining_packets(), 0);
        assert_eq!(transfer.end_status(), 9);
        transfer.reset();
        assert_eq!(transfer, StorageTransfer::new());
    }
}
