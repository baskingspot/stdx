const std = @import("std");
const random = @import("stdx").random;

// No `Io` value, no error union: the generator never fails after it seeds.
fn newSessionToken() [16]u8 {
    var token: [16]u8 = undefined;
    random.fill(&token);
    return token;
}

test "two tokens differ" {
    const first = newSessionToken();
    const second = newSessionToken();
    try std.testing.expect(!std.mem.eql(u8, &first, &second));
}

test "the fill takes any byte slice" {
    var nonce: [12]u8 = undefined;
    random.fill(&nonce);
    random.fill(&.{});

    // A zero-length fill is a no-op, not an error.
    try std.testing.expect(nonce.len == 12);
}
