//! Clasificación de errores reintentables.

const std = @import("std");
const testing = std.testing;
const client = @import("invima").client;

test "transient connection errors are retried" {
    try testing.expect(client.isTransient(error.TlsInitializationFailed));
    try testing.expect(client.isTransient(error.ConnectionResetByPeer));
    try testing.expect(client.isTransient(error.ConnectionRefused));
    try testing.expect(client.isTransient(error.ConnectionTimedOut));
    try testing.expect(client.isTransient(error.NetworkUnreachable));
}

test "errors that would repeat or hide a real fault are not retried" {
    try testing.expect(!client.isTransient(error.HttpRequestFailed));
    try testing.expect(!client.isTransient(error.OutOfMemory));
    try testing.expect(!client.isTransient(error.JsonParseError));
    try testing.expect(!client.isTransient(error.UriParseError));
    try testing.expect(!client.isTransient(error.InvalidHttpResponse));
}
