pub const RING_BUFFER_HEADER_SIZE: usize = 2;
pub const NET_BUFFER_HEADER_SIZE: usize = 3;

pub fn encode_ring_header(len: u16) -> [u8; RING_BUFFER_HEADER_SIZE] {
    [(len & 0xFF) as u8, (len >> 8) as u8]
}

pub fn decode_ring_header(bytes: &[u8]) -> Option<u16> {
    if bytes.len() < RING_BUFFER_HEADER_SIZE {
        return None;
    }
    Some(u16::from(bytes[0]) | (u16::from(bytes[1]) << 8))
}

pub fn encode_packet_header(id: u16, index: u8) -> [u8; NET_BUFFER_HEADER_SIZE] {
    [(id & 0xFF) as u8, (id >> 8) as u8, index]
}

pub fn decode_packet_header(bytes: &[u8]) -> Option<(u16, u8)> {
    if bytes.len() < NET_BUFFER_HEADER_SIZE {
        return None;
    }
    Some((u16::from(bytes[0]) | (u16::from(bytes[1]) << 8), bytes[2]))
}

pub fn selftest() -> i32 {
    let mut failures = 0;

    for len in [0u16, 1, 0x00FF, 0x0100, 0xABCD, 0xFFFF] {
        let encoded = encode_ring_header(len);
        if decode_ring_header(&encoded) != Some(len) {
            failures += 1;
        }
    }

    for (id, index) in [(0u16, 0u8), (1, 2), (0x1234, 0xFF), (0xFFFF, 0)] {
        let encoded = encode_packet_header(id, index);
        if decode_packet_header(&encoded) != Some((id, index)) {
            failures += 1;
        }
    }

    if decode_ring_header(&[0]).is_some() {
        failures += 1;
    }
    if decode_packet_header(&[0, 0]).is_some() {
        failures += 1;
    }

    if encode_ring_header(0xABCD) != [0xCD, 0xAB] {
        failures += 1;
    }
    if encode_packet_header(0x1234, 7) != [0x34, 0x12, 7] {
        failures += 1;
    }

    failures
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ring_header_matches_the_c_wire_format() {
        assert_eq!(encode_ring_header(0xABCD), [0xCD, 0xAB]);
        assert_eq!(decode_ring_header(&[0xCD, 0xAB]), Some(0xABCD));
    }

    #[test]
    fn packet_header_matches_the_c_wire_format() {
        assert_eq!(encode_packet_header(0x1234, 7), [0x34, 0x12, 7]);
        assert_eq!(decode_packet_header(&[0x34, 0x12, 7]), Some((0x1234, 7)));
    }

    #[test]
    fn short_buffers_are_rejected() {
        assert_eq!(decode_ring_header(&[0]), None);
        assert_eq!(decode_packet_header(&[0, 0]), None);
    }

    #[test]
    fn selftest_passes() {
        assert_eq!(selftest(), 0);
    }
}
