//! Every example the guide embeds. Each file is a complete program
//! that `zig build test` compiles and runs, so a guide page cannot
//! show code that does not build.

const std = @import("std");

pub const containers_bloom = @import("containers_bloom.zig");
pub const containers_bounded_map = @import("containers_bounded_map.zig");
pub const containers_buffer_array = @import("containers_buffer_array.zig");
pub const containers_buffer_slice = @import("containers_buffer_slice.zig");
pub const containers_config_field = @import("containers_config_field.zig");
pub const containers_multi_array = @import("containers_multi_array.zig");
pub const containers_priority_queue = @import("containers_priority_queue.zig");
pub const containers_set = @import("containers_set.zig");
pub const containers_static_map = @import("containers_static_map.zig");
pub const containers_swiss_map = @import("containers_swiss_map.zig");
pub const net_classify = @import("net_classify.zig");
pub const net_key = @import("net_key.zig");
pub const net_parse = @import("net_parse.zig");
pub const net_prefix = @import("net_prefix.zig");
pub const net_range = @import("net_range.zig");
pub const net_std_types = @import("net_std_types.zig");
pub const parsing_atoi = @import("parsing_atoi.zig");
pub const parsing_leading_zeros = @import("parsing_leading_zeros.zig");
pub const slot_ring_logging = @import("slot_ring_logging.zig");
pub const time_cached_clock = @import("time_cached_clock.zig");
pub const time_deadline = @import("time_deadline.zig");
pub const time_rate_limit = @import("time_rate_limit.zig");
pub const time_wall_from_awake = @import("time_wall_from_awake.zig");
pub const uuid_roundtrip = @import("uuid_roundtrip.zig");

test {
    std.testing.refAllDecls(@This());
}
