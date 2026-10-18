//! The one output stream every lane is mixed into.

const std = @import("std");
const sdl = @import("sdl3-c");

pub const sample_rate = 48000;
pub const channels = 2;

pub const Device = struct {
    stream: ?*sdl.SDL_AudioStream = null,

    /// Opens the default playback device. Safe to call repeatedly.
    pub fn open(self: *Device) !void {
        if (self.stream != null) return;
        if (!sdl.SDL_InitSubSystem(sdl.SDL_INIT_AUDIO)) return error.AudioInit;

        const spec = sdl.SDL_AudioSpec{
            .format = sdl.SDL_AUDIO_F32,
            .channels = channels,
            .freq = sample_rate,
        };
        const stream = sdl.SDL_OpenAudioDeviceStream(
            sdl.SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK,
            &spec,
            null,
            null,
        ) orelse return error.NoAudioDevice;
        _ = sdl.SDL_ResumeAudioStreamDevice(stream);
        self.stream = stream;
    }

    pub fn write(self: *Device, samples: []const f32) void {
        const stream = self.stream orelse return;
        const bytes = std.mem.sliceAsBytes(samples);
        _ = sdl.SDL_PutAudioStreamData(stream, bytes.ptr, @intCast(bytes.len));
    }

    /// Bytes handed to SDL and not yet played. Used to keep the pump ahead.
    pub fn queued(self: *Device) usize {
        const stream = self.stream orelse return 0;
        const bytes = sdl.SDL_GetAudioStreamQueued(stream);
        return if (bytes > 0) @intCast(bytes) else 0;
    }

    pub fn driver(self: *Device) []const u8 {
        _ = self;
        const name = sdl.SDL_GetCurrentAudioDriver() orelse return "";
        return std.mem.span(name);
    }

    pub fn close(self: *Device) void {
        if (self.stream) |stream| sdl.SDL_DestroyAudioStream(stream);
        self.stream = null;
    }
};
