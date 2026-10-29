//! Every example the guide embeds. Each file is a complete program
//! that `zig build test` compiles and runs, so a guide page cannot
//! show code that does not build.

const std = @import("std");
const builtin = @import("builtin");

pub const base32_token = @import("base32_token.zig");
pub const btree_ordered_map = @import("btree_ordered_map.zig");
pub const bounded_writer_response = @import("bounded_writer_response.zig");
pub const containers_bit_set_scratch = @import("containers_bit_set_scratch.zig");
pub const containers_bloom = @import("containers_bloom.zig");
pub const containers_bounded_map = @import("containers_bounded_map.zig");
pub const containers_buffer_array = @import("containers_buffer_array.zig");
pub const containers_buffer_queue = @import("containers_buffer_queue.zig");
pub const containers_buffer_slice = @import("containers_buffer_slice.zig");
pub const containers_config_field = @import("containers_config_field.zig");
pub const containers_multi_array = @import("containers_multi_array.zig");
pub const containers_priority_queue = @import("containers_priority_queue.zig");
pub const containers_set = @import("containers_set.zig");
pub const containers_static_map = @import("containers_static_map.zig");
pub const containers_swiss_map = @import("containers_swiss_map.zig");
pub const enums_classify = @import("enums_classify.zig");
pub const hash_keyed_map = @import("hash_keyed_map.zig");
pub const heap_slab_records = @import("heap_slab_records.zig");
pub const jsonc_config = @import("jsonc_config.zig");
pub const jsonc_diagnostics = @import("jsonc_diagnostics.zig");
pub const lru_cache = @import("lru_cache.zig");
pub const mem_secret = @import("mem_secret.zig");
pub const net_classify = @import("net_classify.zig");
pub const net_host_port = @import("net_host_port.zig");
pub const net_key = @import("net_key.zig");
pub const net_parse = @import("net_parse.zig");
pub const net_prefix = @import("net_prefix.zig");
pub const net_range = @import("net_range.zig");
pub const net_std_types = @import("net_std_types.zig");
pub const once_lazy = @import("once_lazy.zig");
pub const parsing_atoi = @import("parsing_atoi.zig");
pub const parsing_bool = @import("parsing_bool.zig");
pub const prefix_map_routes = @import("prefix_map_routes.zig");
pub const parsing_leading_zeros = @import("parsing_leading_zeros.zig");
pub const random_token = @import("random_token.zig");
// slot_ring is Linux only, so its example is too: elsewhere the module is
// `void`. The import is lazy, so the file is not analyzed off Linux.
const slot_ring_logging_example = @import("slot_ring_logging.zig");
pub const slot_ring_logging = if (builtin.os.tag == .linux)
    slot_ring_logging_example
else
    struct {};
pub const sort_radix = @import("sort_radix.zig");
pub const stdio_stream = @import("stdio_stream.zig");
pub const time_cached_clock = @import("time_cached_clock.zig");
pub const time_deadline = @import("time_deadline.zig");
pub const time_rate_limit = @import("time_rate_limit.zig");
pub const time_rfc3339 = @import("time_rfc3339.zig");
pub const time_wall_from_awake = @import("time_wall_from_awake.zig");
pub const timers_loop = @import("timers_loop.zig");
pub const uuid_roundtrip = @import("uuid_roundtrip.zig");
pub const wire_backpatch = @import("wire_backpatch.zig");

test {
    std.testing.refAllDecls(@This());
}
