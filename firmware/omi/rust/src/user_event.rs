// User-event wire format and drop-oldest queue. GATT notify and mutex stay in C.

pub const PAYLOAD_LEN: usize = 8;
pub const DEFAULT_QUEUE_LEN: usize = 16;

#[derive(Copy, Clone, Debug, PartialEq, Eq)]
pub struct Record {
    pub code: u8,
    pub source: u8,
    pub seq: u16,
    pub epoch_s: u32,
}

pub fn encode(rec: &Record) -> [u8; PAYLOAD_LEN] {
    let mut out = [0u8; PAYLOAD_LEN];
    out[0] = rec.code;
    out[1] = rec.source;
    out[2] = (rec.seq & 0xFF) as u8;
    out[3] = (rec.seq >> 8) as u8;
    out[4] = (rec.epoch_s & 0xFF) as u8;
    out[5] = ((rec.epoch_s >> 8) & 0xFF) as u8;
    out[6] = ((rec.epoch_s >> 16) & 0xFF) as u8;
    out[7] = ((rec.epoch_s >> 24) & 0xFF) as u8;
    out
}

pub fn decode(bytes: &[u8]) -> Option<Record> {
    if bytes.len() < PAYLOAD_LEN {
        return None;
    }
    Some(Record {
        code: bytes[0],
        source: bytes[1],
        seq: u16::from(bytes[2]) | (u16::from(bytes[3]) << 8),
        epoch_s: u32::from(bytes[4])
            | (u32::from(bytes[5]) << 8)
            | (u32::from(bytes[6]) << 16)
            | (u32::from(bytes[7]) << 24),
    })
}

/// Fixed-capacity drop-oldest ring matching `CONFIG_OMI_USER_EVENT_QUEUE_LEN`.
pub struct Queue<const N: usize> {
    slots: [Record; N],
    head: usize,
    count: usize,
    next_seq: u16,
}

impl<const N: usize> Queue<N> {
    pub const fn new() -> Self {
        Self {
            slots: [Record {
                code: 0,
                source: 0,
                seq: 0,
                epoch_s: 0,
            }; N],
            head: 0,
            count: 0,
            next_seq: 0,
        }
    }

    pub fn len(&self) -> usize {
        self.count
    }

    pub fn is_empty(&self) -> bool {
        self.count == 0
    }

    pub fn alloc_seq(&mut self) -> u16 {
        let seq = self.next_seq;
        self.next_seq = self.next_seq.wrapping_add(1);
        seq
    }

    pub fn push(&mut self, rec: Record) {
        if N == 0 {
            return;
        }
        if self.count == N {
            self.head = (self.head + 1) % N;
            self.count -= 1;
        }
        let tail = (self.head + self.count) % N;
        self.slots[tail] = rec;
        self.count += 1;
    }

    pub fn peek(&self) -> Option<&Record> {
        if self.count == 0 {
            None
        } else {
            Some(&self.slots[self.head])
        }
    }

    pub fn pop(&mut self) -> Option<Record> {
        if self.count == 0 {
            return None;
        }
        let rec = self.slots[self.head];
        self.head = (self.head + 1) % N;
        self.count -= 1;
        Some(rec)
    }
}

impl<const N: usize> Default for Queue<N> {
    fn default() -> Self {
        Self::new()
    }
}

pub fn selftest() -> i32 {
    let mut failures = 0;
    let rec = Record {
        code: 0x01,
        source: 0x02,
        seq: 0xABCD,
        epoch_s: 0x01020304,
    };
    let enc = encode(&rec);
    if decode(&enc) != Some(rec) {
        failures += 1;
    }
    if enc != [0x01, 0x02, 0xCD, 0xAB, 0x04, 0x03, 0x02, 0x01] {
        failures += 1;
    }

    let mut q = Queue::<2>::new();
    let mut a = rec;
    a.seq = q.alloc_seq();
    q.push(a);
    let mut b = rec;
    b.seq = q.alloc_seq();
    b.code = 0x21;
    q.push(b);
    let mut c = rec;
    c.seq = q.alloc_seq();
    c.code = 0x22;
    q.push(c); // drops oldest
    if q.len() != 2 || q.peek().map(|r| r.code) != Some(0x21) {
        failures += 1;
    }
    failures
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_le_payload() {
        let rec = Record {
            code: 0x20,
            source: 0x03,
            seq: 7,
            epoch_s: 1_700_000_000,
        };
        assert_eq!(decode(&encode(&rec)), Some(rec));
    }

    #[test]
    fn queue_drops_oldest() {
        let mut q = Queue::<2>::new();
        q.push(Record {
            code: 1,
            source: 1,
            seq: 0,
            epoch_s: 0,
        });
        q.push(Record {
            code: 2,
            source: 1,
            seq: 1,
            epoch_s: 0,
        });
        q.push(Record {
            code: 3,
            source: 1,
            seq: 2,
            epoch_s: 0,
        });
        assert_eq!(q.pop().unwrap().code, 2);
        assert_eq!(q.pop().unwrap().code, 3);
        assert!(q.pop().is_none());
    }
}
