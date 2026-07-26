#![no_main]
#![no_std]

use cortex_m_rt::entry;
use cortex_m_semihosting::{debug, hprintln};
use panic_semihosting as _;

#[path = "../../src/button.rs"]
mod button;
#[path = "../../src/framing.rs"]
mod framing;

#[entry]
fn main() -> ! {
    assert_eq!(button::selftest(), 0);
    assert_eq!(framing::selftest(), 0);
    hprintln!("Omi v4 production Rust checks passed");
    debug::exit(debug::EXIT_SUCCESS);
    loop {
        cortex_m::asm::bkpt();
    }
}
