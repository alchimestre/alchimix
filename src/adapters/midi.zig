//! Controller input: CC messages from every MIDI source on the machine.
//!
//! CoreMIDI hands packets over on its own thread, so the read callback only
//! copies bytes into a lock-free ring and returns; the frame drains the ring.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("midi-c");

pub const Message = struct {
    channel: u4,
    /// Controller number, 0..127.
    control: u7,
    value: u7,

    /// A CC only: note on, pitch bend and everything else are not controls.
    pub fn fromBytes(bytes: []const u8) ?Message {
        if (bytes.len < 3) return null;
        const status = bytes[0];
        // 0xB0..0xBF are control changes; the low nibble is the channel.
        if (status & 0xF0 != 0xB0) return null;
        const control = bytes[1];
        const value = bytes[2];
        if (control > 127 or value > 127) return null;
        return .{
            .channel = @truncate(status & 0x0F),
            .control = @intCast(control),
            .value = @intCast(value),
        };
    }
};

const capacity = 128;

/// A ring of the last messages, with a single producer (CoreMIDI's thread) and
/// a single consumer (the frame). Dropping is correct under pressure: a knob
/// sends faster than the eye, and the newest value is the one that matters.
pub const Ring = struct {
    messages: [capacity]Message = undefined,
    head: std.atomic.Value(usize) = .init(0),
    tail: std.atomic.Value(usize) = .init(0),

    pub fn push(self: *Ring, message: Message) void {
        const head = self.head.load(.monotonic);
        const tail = self.tail.load(.acquire);
        if (head - tail >= capacity) return;
        self.messages[head % capacity] = message;
        self.head.store(head + 1, .release);
    }

    /// Copies what is waiting into `out`, oldest first.
    pub fn drain(self: *Ring, out: []Message) []Message {
        const tail = self.tail.load(.monotonic);
        const head = self.head.load(.acquire);
        const waiting = @min(head - tail, out.len);
        for (0..waiting) |index| out[index] = self.messages[(tail + index) % capacity];
        self.tail.store(tail + waiting, .release);
        return out[0..waiting];
    }
};

/// The open CoreMIDI client and its input port. Hot-plugging is not tracked: a
/// controller plugged in after startup needs a restart.
pub const Source = struct {
    ring: Ring = .{},
    client: if (macos) c.MIDIClientRef else void = if (macos) 0 else {},
    port: if (macos) c.MIDIPortRef else void = if (macos) 0 else {},
    started: bool = false,
    /// How many sources were connected at startup.
    connected: usize = 0,

    const macos = builtin.os.tag == .macos;

    pub fn start(self: *Source, name: []const u8) void {
        if (comptime !macos) return;
        if (self.started) return;

        var client: c.MIDIClientRef = 0;
        if (c.MIDIClientCreate(cfString(name), null, null, &client) != 0) return;

        var port: c.MIDIPortRef = 0;
        if (c.MIDIInputPortCreate(client, cfString(name), readProc, &self.ring, &port) != 0) {
            _ = c.MIDIClientDispose(client);
            return;
        }

        const sources = c.MIDIGetNumberOfSources();
        var index: usize = 0;
        while (index < sources) : (index += 1) {
            const source = c.MIDIGetSource(index);
            if (source == 0) continue;
            if (c.MIDIPortConnectSource(port, source, null) == 0) self.connected += 1;
        }

        self.client = client;
        self.port = port;
        self.started = true;
    }

    pub fn stop(self: *Source) void {
        if (comptime !macos) return;
        if (!self.started) return;
        _ = c.MIDIPortDispose(self.port);
        _ = c.MIDIClientDispose(self.client);
        self.started = false;
    }

    pub fn drain(self: *Source, out: []Message) []Message {
        return self.ring.drain(out);
    }

    fn cfString(name: []const u8) c.CFStringRef {
        return @ptrCast(c.CFStringCreateWithCString(null, name.ptr, c.ALCHIMIX_UTF8));
    }

    fn readProc(list: [*c]const c.MIDIPacketList, ref: ?*anyopaque, src: ?*anyopaque) callconv(.c) void {
        _ = src;
        const ring: *Ring = @ptrCast(@alignCast(ref orelse return));
        var packet = c.alchimix_midi_packet_first(list);
        var packet_index: u32 = 0;
        while (packet_index < c.alchimix_midi_packet_count(list)) : (packet_index += 1) {
            const length = c.alchimix_midi_packet_length(packet);
            const bytes = c.alchimix_midi_packet_bytes(packet)[0..length];
            // One packet may carry several messages, each three bytes here.
            var offset: usize = 0;
            while (offset + 3 <= bytes.len) : (offset += 3) {
                if (Message.fromBytes(bytes[offset..][0..3])) |message| ring.push(message);
            }
            packet = c.alchimix_midi_packet_next(packet);
        }
    }
};

const testing = std.testing;

test "only control changes become messages" {
    const cc = Message.fromBytes(&.{ 0xB2, 7, 96 }) orelse return error.NotControl;
    try testing.expectEqual(@as(u4, 2), cc.channel);
    try testing.expectEqual(@as(u7, 7), cc.control);
    try testing.expectEqual(@as(u7, 96), cc.value);

    try testing.expectEqual(@as(?Message, null), Message.fromBytes(&.{ 0x90, 60, 100 }));
    try testing.expectEqual(@as(?Message, null), Message.fromBytes(&.{ 0xE0, 0, 64 }));
    try testing.expectEqual(@as(?Message, null), Message.fromBytes(&.{ 0xB0, 7 }));
}

test "the ring keeps the newest messages and drops the rest" {
    var ring = Ring{};
    var out: [8]Message = undefined;

    // More than it can hold: the oldest are gone, the newest survive.
    for (0..capacity + 12) |value| {
        ring.push(.{ .channel = 0, .control = 1, .value = @intCast(value % 128) });
    }
    var total: usize = 0;
    while (true) {
        const batch = ring.drain(&out);
        if (batch.len == 0) break;
        total += batch.len;
    }
    try testing.expectEqual(capacity, total);

    ring.push(.{ .channel = 0, .control = 9, .value = 64 });
    const batch = ring.drain(&out);
    try testing.expectEqual(@as(usize, 1), batch.len);
    try testing.expectEqual(@as(u7, 64), batch[0].value);
    try testing.expectEqual(@as(usize, 0), ring.drain(&out).len);
}

test "a drain fills the caller's buffer in order" {
    var ring = Ring{};
    var out: [4]Message = undefined;
    ring.push(.{ .channel = 1, .control = 2, .value = 10 });
    ring.push(.{ .channel = 1, .control = 2, .value = 11 });

    const first = ring.drain(&out);
    try testing.expectEqual(@as(usize, 2), first.len);
    try testing.expectEqual(@as(u7, 10), first[0].value);
    try testing.expectEqual(@as(u7, 11), first[1].value);
}
