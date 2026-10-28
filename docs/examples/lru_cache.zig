const std = @import("std");
const lru = @import("stdx").lru;

const Cache = lru.String(u32, 2);

test "keep the two most recent" {
    var cache: Cache = .empty;
    _ = cache.put("a", 1);
    _ = cache.put("b", 2);

    try std.testing.expectEqual(@as(u32, 1), cache.get("a").?.*);
    const result = cache.put("c", 3);
    try std.testing.expectEqualStrings("b", result.evicted.?.key);
    try std.testing.expectEqual(@as(u32, 2), result.evicted.?.value);
    try std.testing.expect(!cache.contains("b"));

    var it = cache.iterator();
    try std.testing.expectEqualStrings("c", it.next().?.key);
    try std.testing.expectEqualStrings("a", it.next().?.key);
    try std.testing.expect(it.next() == null);
}
