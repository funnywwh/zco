const std = @import("std");

// 导出所有HTTP框架模块
pub const server = @import("./server.zig");
pub const request = @import("./request.zig");
pub const response = @import("./response.zig");
pub const router = @import("./router.zig");
pub const middleware = @import("./middleware.zig");
pub const jwt = @import("./jwt.zig");
pub const context = @import("./context.zig");
pub const static_files = @import("./static.zig");
pub const template = @import("./template.zig");
pub const upload = @import("./upload.zig");
pub const parser = @import("./parser.zig");
pub const header_buffer = @import("./header_buffer.zig");
pub const streaming_request = @import("./streaming_request.zig");
pub const upgrade = @import("./upgrade.zig");

// 公共类型和常量
pub const Server = server.Server;
pub const Request = request.Request;
pub const Response = response.Response;
pub const Router = router.Router;
pub const Middleware = middleware.Middleware;
pub const Context = context.Context;
pub const JWT = jwt.JWT;

// 常用状态码
pub const StatusCode = enum(u16) {
    OK = 200,
    Created = 201,
    NoContent = 204,
    BadRequest = 400,
    Unauthorized = 401,
    Forbidden = 403,
    NotFound = 404,
    MethodNotAllowed = 405,
    Conflict = 409,
    InternalServerError = 500,
    NotImplemented = 501,
    BadGateway = 502,
    ServiceUnavailable = 503,
};

// HTTP方法
pub const Method = enum {
    GET,
    POST,
    PUT,
    DELETE,
    PATCH,
    OPTIONS,
    HEAD,
    CONNECT,
    TRACE,
};
