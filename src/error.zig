pub const InvimaError = error{
    InvalidStatus,
    UriParseError,
    HttpConnectionFailed,
    HttpRequestFailed,
    InvalidHttpResponse,
    JsonParseError,
    NullPointer,
    OutOfMemory,
};
