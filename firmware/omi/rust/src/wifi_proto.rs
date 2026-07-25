// SoftAP + home-STA WiFi sync wire protocol (host-testable).
// SoftAP BLE commands match upstream BasedHardware/omi; feature bit diverges
// (upstream used bit 9 for WIFI; omi-v4 uses bit 16 — see FEATURE_WIFI).

pub const WIFI_CMD_SETUP: u8 = 0x01;
pub const WIFI_CMD_START: u8 = 0x02;
pub const WIFI_CMD_SHUTDOWN: u8 = 0x03;
pub const WIFI_CMD_DELETE_ALL: u8 = 0x04;
pub const WIFI_CMD_HOME_SETUP: u8 = 0x10;
pub const WIFI_CMD_HOME_CLEAR: u8 = 0x11;
pub const WIFI_CMD_CLOUD_TOKEN: u8 = 0x12;

pub const WIFI_ERR_OK: u8 = 0x00;
pub const WIFI_ERR_INVALID_LEN: u8 = 0x01;
pub const WIFI_ERR_INVALID_SETUP: u8 = 0x02;
pub const WIFI_ERR_INVALID_SSID: u8 = 0x03;
pub const WIFI_ERR_INVALID_PWD_LEN: u8 = 0x04;
pub const WIFI_ERR_ALREADY_ON: u8 = 0x05;
pub const WIFI_ERR_DELETE_FAILED: u8 = 0x10;
pub const WIFI_ERR_HW_UNAVAILABLE: u8 = 0xFE;
pub const WIFI_ERR_UNKNOWN_CMD: u8 = 0xFF;
pub const WIFI_ERR_HOME_DISABLED: u8 = 0x20;
pub const WIFI_ERR_TOKEN_INVALID: u8 = 0x21;

pub const WIFI_SSID_MAX: usize = 32;
pub const WIFI_PASSWORD_MIN: usize = 8;
pub const WIFI_PASSWORD_MAX: usize = 64;
pub const WIFI_TOKEN_MAX: usize = 96;
pub const WIFI_CLOUD_HOST_MAX: usize = 128;
pub const WIFI_DEVICE_ID_MAX: usize = 64;

pub const SOFTAP_STREAM_MAGIC: u8 = 0xA5;
pub const SOFTAP_STREAM_VERSION: u8 = 1;
pub const SOFTAP_HEADER_LEN: usize = 24;
pub const SOFTAP_DONE_MAGIC: u8 = 0x5A;

pub const HOME_UPLOAD_MAGIC: u8 = 0xC1;
pub const HOME_UPLOAD_VERSION: u8 = 1;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WifiBleCommand {
    Setup,
    Start,
    Shutdown,
    DeleteAll,
    HomeSetup,
    HomeClear,
    CloudToken,
    Unknown(u8),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WifiCredentials<'a> {
    pub ssid: &'a [u8],
    pub password: &'a [u8],
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ParsedWifiCommand<'a> {
    Setup(WifiCredentials<'a>),
    Start,
    Shutdown,
    DeleteAll,
    HomeSetup(WifiCredentials<'a>),
    HomeClear,
    CloudToken {
        host: &'a [u8],
        device_id: &'a [u8],
        token: &'a [u8],
    },
    Error(u8),
}

pub fn classify_command(cmd: u8) -> WifiBleCommand {
    match cmd {
        WIFI_CMD_SETUP => WifiBleCommand::Setup,
        WIFI_CMD_START => WifiBleCommand::Start,
        WIFI_CMD_SHUTDOWN => WifiBleCommand::Shutdown,
        WIFI_CMD_DELETE_ALL => WifiBleCommand::DeleteAll,
        WIFI_CMD_HOME_SETUP => WifiBleCommand::HomeSetup,
        WIFI_CMD_HOME_CLEAR => WifiBleCommand::HomeClear,
        WIFI_CMD_CLOUD_TOKEN => WifiBleCommand::CloudToken,
        other => WifiBleCommand::Unknown(other),
    }
}

fn parse_credentials(buf: &[u8]) -> Result<WifiCredentials<'_>, u8> {
    if buf.is_empty() {
        return Err(WIFI_ERR_INVALID_SETUP);
    }
    let ssid_len = buf[0] as usize;
    if ssid_len == 0 || ssid_len > WIFI_SSID_MAX || 1 + ssid_len > buf.len() {
        return Err(WIFI_ERR_INVALID_SSID);
    }
    let ssid = &buf[1..1 + ssid_len];
    let pwd_len_idx = 1 + ssid_len;
    if pwd_len_idx >= buf.len() {
        return Err(WIFI_ERR_INVALID_PWD_LEN);
    }
    let pwd_len = buf[pwd_len_idx] as usize;
    let pwd_start = pwd_len_idx + 1;
    if !(WIFI_PASSWORD_MIN..=WIFI_PASSWORD_MAX).contains(&pwd_len)
        || pwd_start + pwd_len > buf.len()
    {
        return Err(WIFI_ERR_INVALID_PWD_LEN);
    }
    Ok(WifiCredentials {
        ssid,
        password: &buf[pwd_start..pwd_start + pwd_len],
    })
}

fn parse_host_token(buf: &[u8]) -> Result<ParsedWifiCommand<'_>, u8> {
    if buf.len() < 2 {
        return Err(WIFI_ERR_TOKEN_INVALID);
    }
    let host_len = buf[0] as usize;
    if host_len == 0 || host_len > WIFI_CLOUD_HOST_MAX || 1 + host_len >= buf.len() {
        return Err(WIFI_ERR_TOKEN_INVALID);
    }
    let host = &buf[1..1 + host_len];
    let device_len_idx = 1 + host_len;
    let device_len = buf[device_len_idx] as usize;
    let device_start = device_len_idx + 1;
    if device_len == 0 || device_len > WIFI_DEVICE_ID_MAX || device_start + device_len >= buf.len()
    {
        return Err(WIFI_ERR_TOKEN_INVALID);
    }
    let token_len_idx = device_start + device_len;
    let token_len = buf[token_len_idx] as usize;
    let token_start = token_len_idx + 1;
    if token_len == 0 || token_len > WIFI_TOKEN_MAX || token_start + token_len > buf.len() {
        return Err(WIFI_ERR_TOKEN_INVALID);
    }
    Ok(ParsedWifiCommand::CloudToken {
        host,
        device_id: &buf[device_start..device_start + device_len],
        token: &buf[token_start..token_start + token_len],
    })
}

pub fn parse_ble_command_with_home_enabled(
    buf: &[u8],
    home_enabled: bool,
) -> ParsedWifiCommand<'_> {
    if buf.is_empty() {
        return ParsedWifiCommand::Error(WIFI_ERR_INVALID_LEN);
    }
    match classify_command(buf[0]) {
        WifiBleCommand::Setup => match parse_credentials(&buf[1..]) {
            Ok(creds) => ParsedWifiCommand::Setup(creds),
            Err(code) => ParsedWifiCommand::Error(code),
        },
        WifiBleCommand::Start => ParsedWifiCommand::Start,
        WifiBleCommand::Shutdown => ParsedWifiCommand::Shutdown,
        WifiBleCommand::DeleteAll => ParsedWifiCommand::DeleteAll,
        WifiBleCommand::HomeSetup if !home_enabled => {
            ParsedWifiCommand::Error(WIFI_ERR_HOME_DISABLED)
        }
        WifiBleCommand::HomeSetup => match parse_credentials(&buf[1..]) {
            Ok(creds) => ParsedWifiCommand::HomeSetup(creds),
            Err(code) => ParsedWifiCommand::Error(code),
        },
        WifiBleCommand::HomeClear if !home_enabled => {
            ParsedWifiCommand::Error(WIFI_ERR_HOME_DISABLED)
        }
        WifiBleCommand::HomeClear => ParsedWifiCommand::HomeClear,
        WifiBleCommand::CloudToken if !home_enabled => {
            ParsedWifiCommand::Error(WIFI_ERR_HOME_DISABLED)
        }
        WifiBleCommand::CloudToken => match parse_host_token(&buf[1..]) {
            Ok(command) => command,
            Err(code) => ParsedWifiCommand::Error(code),
        },
        WifiBleCommand::Unknown(_) => ParsedWifiCommand::Error(WIFI_ERR_UNKNOWN_CMD),
    }
}

pub fn parse_ble_command(buf: &[u8]) -> ParsedWifiCommand<'_> {
    parse_ble_command_with_home_enabled(buf, true)
}

pub fn encode_softap_header(
    read_seq: u64,
    write_seq: u64,
    packet_bytes: u16,
    out: &mut [u8],
) -> usize {
    if out.len() < SOFTAP_HEADER_LEN {
        return 0;
    }
    let packet_count = write_seq.saturating_sub(read_seq);
    out[0] = SOFTAP_STREAM_MAGIC;
    out[1] = SOFTAP_STREAM_VERSION;
    out[2..10].copy_from_slice(&read_seq.to_be_bytes());
    out[10..18].copy_from_slice(&write_seq.to_be_bytes());
    out[18..20].copy_from_slice(&packet_bytes.to_be_bytes());
    out[20..24].copy_from_slice(&(packet_count as u32).to_be_bytes());
    SOFTAP_HEADER_LEN
}

pub fn encode_softap_done(next_seq: u64, status: u8, out: &mut [u8]) -> usize {
    if out.len() < 10 {
        return 0;
    }
    out[0] = SOFTAP_DONE_MAGIC;
    out[1] = status;
    out[2..10].copy_from_slice(&next_seq.to_be_bytes());
    10
}

pub fn encode_home_upload_preamble(
    device_id: &[u8],
    start_seq: u64,
    packet_count: u32,
    packet_bytes: u16,
    out: &mut [u8],
) -> usize {
    if device_id.is_empty() || device_id.len() > 64 || out.len() < 16 + device_id.len() {
        return 0;
    }
    let mut i = 0;
    out[i] = HOME_UPLOAD_MAGIC;
    i += 1;
    out[i] = HOME_UPLOAD_VERSION;
    i += 1;
    out[i] = device_id.len() as u8;
    i += 1;
    out[i..i + device_id.len()].copy_from_slice(device_id);
    i += device_id.len();
    out[i..i + 8].copy_from_slice(&start_seq.to_be_bytes());
    i += 8;
    out[i..i + 4].copy_from_slice(&packet_count.to_be_bytes());
    i += 4;
    out[i..i + 2].copy_from_slice(&packet_bytes.to_be_bytes());
    i += 2;
    i
}

pub fn selftest() -> i32 {
    let mut failures = 0;

    let setup = [
        WIFI_CMD_SETUP,
        4,
        b'h',
        b'o',
        b'm',
        b'e',
        8,
        b'p',
        b'a',
        b's',
        b's',
        b'w',
        b'o',
        b'r',
        b'd',
    ];
    match parse_ble_command(&setup) {
        ParsedWifiCommand::Setup(c) if c.ssid == b"home" && c.password == b"password" => {}
        _ => failures += 1,
    }

    if !matches!(
        parse_ble_command(&[WIFI_CMD_START]),
        ParsedWifiCommand::Start
    ) {
        failures += 1;
    }

    let mut hdr = [0u8; SOFTAP_HEADER_LEN];
    if encode_softap_header(10, 15, 444, &mut hdr) != SOFTAP_HEADER_LEN {
        failures += 1;
    }
    if hdr[0] != SOFTAP_STREAM_MAGIC || hdr[1] != SOFTAP_STREAM_VERSION {
        failures += 1;
    }

    let mut done = [0u8; 10];
    if encode_softap_done(15, 0, &mut done) != 10 || done[0] != SOFTAP_DONE_MAGIC {
        failures += 1;
    }

    let mut pre = [0u8; 64];
    let n = encode_home_upload_preamble(b"dev1", 1, 2, 444, &mut pre);
    if n == 0 || pre[0] != HOME_UPLOAD_MAGIC {
        failures += 1;
    }

    if parse_ble_command(&[]) != ParsedWifiCommand::Error(WIFI_ERR_INVALID_LEN) {
        failures += 1;
    }

    if parse_ble_command_with_home_enabled(&[WIFI_CMD_HOME_CLEAR], false)
        != ParsedWifiCommand::Error(WIFI_ERR_HOME_DISABLED)
    {
        failures += 1;
    }

    failures
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_softap_setup() {
        let buf = [
            WIFI_CMD_SETUP,
            3,
            b'a',
            b'b',
            b'c',
            8,
            b'1',
            b'2',
            b'3',
            b'4',
            b'5',
            b'6',
            b'7',
            b'8',
        ];
        match parse_ble_command(&buf) {
            ParsedWifiCommand::Setup(c) => {
                assert_eq!(c.ssid, b"abc");
                assert_eq!(c.password, b"12345678");
            }
            other => panic!("unexpected {other:?}"),
        }
    }

    #[test]
    fn hw_unavailable_code_is_0xfe() {
        assert_eq!(WIFI_ERR_HW_UNAVAILABLE, 0xFE);
    }

    #[test]
    fn cloud_provisioning_carries_device_identity() {
        let mut command = vec![WIFI_CMD_CLOUD_TOKEN, 12];
        command.extend_from_slice(b"example.test");
        command.push(5);
        command.extend_from_slice(b"dev-1");
        command.push(5);
        command.extend_from_slice(b"token");
        assert!(matches!(
            parse_ble_command(&command),
            ParsedWifiCommand::CloudToken {
                host: b"example.test",
                device_id: b"dev-1",
                token: b"token"
            }
        ));
    }

    #[test]
    fn softap_header_counts_packets() {
        let mut out = [0u8; SOFTAP_HEADER_LEN];
        assert_eq!(
            encode_softap_header(100, 110, 444, &mut out),
            SOFTAP_HEADER_LEN
        );
        assert_eq!(&out[20..24], &10u32.to_be_bytes());
    }

    #[test]
    fn selftest_passes() {
        assert_eq!(selftest(), 0);
    }

    #[test]
    fn disabled_home_commands_do_not_parse_credentials() {
        assert_eq!(
            parse_ble_command_with_home_enabled(&[WIFI_CMD_HOME_SETUP], false),
            ParsedWifiCommand::Error(WIFI_ERR_HOME_DISABLED)
        );
    }

    #[test]
    fn missing_password_length_is_invalid_password() {
        assert_eq!(
            parse_ble_command(&[WIFI_CMD_SETUP, 3, b'a', b'b', b'c']),
            ParsedWifiCommand::Error(WIFI_ERR_INVALID_PWD_LEN)
        );
    }

    #[test]
    fn credential_error_statuses_match_the_ble_handler() {
        assert_eq!(
            parse_ble_command(&[WIFI_CMD_SETUP]),
            ParsedWifiCommand::Error(WIFI_ERR_INVALID_SETUP)
        );
        assert_eq!(
            parse_ble_command(&[WIFI_CMD_SETUP, 0]),
            ParsedWifiCommand::Error(WIFI_ERR_INVALID_SSID)
        );
    }
}
