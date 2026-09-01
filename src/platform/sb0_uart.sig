//! PL011 UART driver for the SB0 bare-metal target (QEMU `virt` / SB0K).
//!
//! Minimal blocking console: the QEMU `virt` machine and the SB0 reference
//! boards place a PL011 at 0x0900_0000. We only need TX for the slicker
//! self-test to announce its result over the serial console.

const PL011_BASE: usize = 0x0900_0000;
const UARTDR: usize = PL011_BASE + 0x00; // data register
const UARTFR: usize = PL011_BASE + 0x18; // flag register
const FR_TXFF: u32 = 1 << 5; // transmit FIFO full

fn mmioRead32(addr: usize) u32 {
    const p: *volatile u32 = @ptrFromInt(addr);
    return p.*;
}

fn mmioWrite32(addr: usize, value: u32) void {
    const p: *volatile u32 = @ptrFromInt(addr);
    p.* = value;
}

/// Write one byte, spinning while the TX FIFO is full.
pub fn putc(c: u8) void {
    while (mmioRead32(UARTFR) & FR_TXFF != 0) {}
    mmioWrite32(UARTDR, c);
}

/// Write a byte slice to the console.
pub fn write(bytes: []const u8) void {
    for (bytes) |b| putc(b);
}
