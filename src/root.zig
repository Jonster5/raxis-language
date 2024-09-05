const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

pub const TextScanner = struct {
    buffer: []const u8,
    index: usize,

    prev_len: usize,

    state_stack: std.ArrayList(SaveState),
    const SaveState = struct { index: usize };

    pub fn init(a: Allocator, src: []const u8) TextScanner {
        return .{
            .buffer = src,
            .index = 0,
            .prev_len = 0,
            .save_state = std.ArrayList(SaveState).init(a),
        };
    }

    pub fn ws(self: *TextScanner) void {
        while (std.ascii.isWhitespace(self.read())) self.move();
    }

    pub fn read(self: *TextScanner) u8 {
        if (self.index >= self.buffer.len) {
            self.prev_len = 0;
            return 0;
        }

        self.prev_len = 1;
        return self.buffer[self.index];
    }

    pub fn expect(self: TextScanner, comptime string_to_expect: []const u8) bool {
        const str_len = string_to_expect.len;
        const index_len = self.index + 1;

        if (index_len + str_len > self.buffer.len) return false;

        const success = std.mem.eql(u8, string_to_expect, self.buffer[self.index..(index_len + str_len)]);
        if (success) self.prev_len = str_len;
        return success;
    }

    pub fn save(self: *TextScanner) !void {
        try self.state_stack.append(.{ .index = self.index });
    }

    pub fn getSavedLen(self: *TextScanner) usize {
        const saved_index = if (self.state_stack.getLastOrNull()) |saved| saved.index else self.index;

        return self.index - saved_index;
    }

    pub fn getSavedSlice(self: *TextScanner) []const u8 {
        return self.buffer[self.index..(self.index + self.getSavedLen())];
    }

    pub fn accept(self: *TextScanner) void {
        _ = self.state_stack.popOrNull();
    }

    pub fn restore(self: *TextScanner) void {
        const top = self.state_stack.popOrNull() orelse return;

        self.index = top.index;
    }

    pub fn reset(self: TextScanner) void {
        self.prev_len = 0;
    }

    pub fn move(self: *TextScanner) void {
        self.index += self.prev_len;
        self.prev_len = 0;
        if (self.index > self.buffer.len) self.index = self.buffer.len;
    }

    pub fn moveOne(self: *TextScanner) void {
        self.index += 1;
        self.prev_len = 0;
        if (self.index > self.buffer.len) self.index = self.buffer.len;
    }
};

pub const Comment = struct {
    text_buffer: []const u8,

    pub fn parse(a: Allocator, text: *TextScanner) !Comment {
        _ = a; // autofix

        try text.save();
        defer text.accept();

        if (text.expect("//")) {
            text.move();
            while (text.read() != '\n') text.move();
            text.move();
        } else if (text.expect("/*")) {
            text.move();
            while (!text.expect("*/")) text.moveOne();
            text.move();
        }

        return .{ .text_buffer = text.getSavedSlice() };
    }
};

pub const Ident = struct {
    text_buffer: []const u8,

    pub fn parse(a: Allocator, text: *TextScanner) !Ident {
        _ = a; // autofix
        var len: usize = 0;

        if (text.len == 0 or (!std.ascii.isAlphabetic(text[0]) and text[0] != '_')) return error.ExpectedIdent;
        len += 1;

        while (len < text.len and (std.ascii.isAlphanumeric(text[len]) or text[len] == '_')) len += 1;

        return .{
            .len = len,
            .node = Ident{ .text_buffer = text[0..len] },
        };
    }

    test parse {
        try testing.expectEqualStrings("abcd", (try parse("abcd")).node.text_buffer);
        try testing.expectEqualStrings("foo", (try parse("foo int = 25")).node.text_buffer);
        try testing.expectError(error.ExpectedIdent, parse("(abcd"));
    }
};

pub const String = struct {
    text_buffer: []const u8,

    pub fn parse(a: Allocator, text: []const u8) !ParseResult(String) {
        _ = a; // autofix
        var index: usize = 0;

        if (text.len == 0 or text[index] != '"') {
            return error.ExpectedString;
        }

        index += 1;

        while (index < text.len and text[index] != '"') {
            index += 1;
        }

        if (index == text.len or text[index] != '"') {
            return error.ExpectedQuote;
        }

        return .{ .len = index + 1, .node = .{ .text_buffer = text[0..(index + 1)] } };
    }

    test parse {
        try testing.expectEqualStrings("\"wassup\"", (try parse("\"wassup\"")).text_buffer);
        try testing.expectError(error.ExpectedQuote, parse("\"hello there"));
        try testing.expectError(error.ExpectedString, parse("hello there"));
    }
};

pub const Root = struct {
    decls: []Decl,

    pub fn parse(a: Allocator, text: []const u8) !ParseResult(Root) {
        var index: usize = 0;

        var decl_list = std.ArrayList(Decl).init(a);

        while (index < text.len) {
            const parse_result = try Decl.parse(a, text[index..]);
            try decl_list.append(parse_result.node);
            index += parse_result.len;
        }
    }
};

pub const Decl = union(enum) {
    ConstDecl: ConstDecl,
    TypeDecl: TypeDecl,
    FunctionDecl: FunctionDecl,
    SystemDecl: SystemDecl,

    pub fn parse(a: Allocator, text: *TextScanner) !Decl {
        const NodeTypes = comptime [4]type{ ConstDecl, TypeDecl, FunctionDecl, SystemDecl };

        text.ws();
        for (NodeTypes) |T| {
            text.save();
            if (T.parse(a, text)) |node| {
                text.accept();
                return @unionInit(Decl, @typeName(T), node);
            } else {
                text.restore();
            }
        }

        return error.ExpectedDecl;
    }

    test parse {
        const tests = .{
            "const yup = 25",
            "type Password uint",
        };
        _ = tests; // autofix
    }

    pub const ConstDecl = struct {
        has_pub: bool,
        ident: Ident,
        value_type: *Type,
        value: *Expr,

        pub fn parse(a: Allocator, text: *TextScanner) !ConstDecl {
            text.save();
            defer text.accept();
            errdefer text.restore();

            const has_pub = text.expect("pub");
            _ = has_pub; // autofix
            text.move();
            text.ws();

            if (!text.expect("const")) return error.ExpectedConstKeyword;
            text.move();
            text.ws();

            const ident = try Ident.parse(a, text);
            _ = ident; // autofix
            text.ws();

            const value_type = try Type.parse(a, text);
            _ = value_type; // autofix
            text.ws();

            if (!text.expect("=")) return error.ExpectedAssignment;
            text.move();
            text.ws();

            const value = try Expr.parse(a, text);
            _ = value; // autofix
        }
    };

    pub const TypeDecl = struct {
        has_pub: bool,
        ident: Ident,
        type: *Type,

        pub fn parse(a: Allocator, text: []const u8) !TypeDecl {
            _ = a; // autofix
            _ = text; // autofix

        }
    };

    pub const FunctionDecl = struct {
        has_pub: bool,
        ident: Ident,
        type_params: ?[]TypeParam,
        type_params_trailing_comma: bool,
        params: ?[]Param,
        params_trailing_comma: bool,
        return_type: ?*Type,
        body: []*Expr,

        pub fn parse(a: Allocator, text: []const u8) !FunctionDecl {
            _ = a; // autofix
            _ = text; // autofix

        }

        const Param = struct {
            ident: Ident,
            type: *Type,

            pub fn parse(a: Allocator, text: []const u8) !Param {
                var index: usize = 0;

                const ident_parse_result = try Ident.parse(a, text[index..]);
                const ident = ident_parse_result.node;
                _ = ident; // autofix
                index = ident_parse_result.len;
            }
        };

        const TypeParam = struct {
            ident: Ident,
            bounds: ?*Type,
        };
    };

    pub const SystemDecl = struct {
        has_pub: bool,
        ident: Ident,
        schedule: ?Schedule,
        body: []*Expr,

        pub fn parse(a: Allocator, text: []const u8) !SystemDecl {
            _ = a; // autofix
            _ = text; // autofix

        }

        const Schedule = union(enum) {
            Set: Set,
            Event: Event,

            const Set = struct {
                string: String,
            };

            const Event = struct {
                event_type: *Type,
            };
        };
    };
};

pub const Expr = union(enum) {
    Literal: Literal,
    Block: Block,
    Grouped: Grouped,
    PropertyAccess: PropertyAccess,
    FunctionCall: FunctionCall,
    Postfix: Postfix,
    Exponent: Exponent,
    Product: Product,
    Prefix: Prefix,
    Sum: Sum,
    BooleanComparison: BooleanComparison,
    Assignment: Assignment,
    ControlFlow: ControlFlow,
    Loop: Loop,
    If: If,

    pub const Literal = struct {};
    pub const Block = struct {};
    pub const Grouped = struct {};
    pub const PropertyAccess = struct {};
    pub const FunctionCall = struct {};
    pub const Postfix = struct {};
    pub const Exponent = struct {};
    pub const Product = struct {};
    pub const Prefix = struct {};
    pub const Sum = struct {};
    pub const BooleanComparison = struct {};
    pub const Assignment = struct {};
    pub const ControlFlow = struct {};
    pub const Loop = struct {};
    pub const If = struct {};
};

pub const Type = union(enum) {};

test {
    testing.refAllDeclsRecursive(@This());
}
