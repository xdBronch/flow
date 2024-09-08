pub const StyleBits = packed struct(u5) {
    is_struck: bool = false,
    is_bold: bool = false,
    is_undercurl: bool = false,
    is_underline: bool = false,
    is_italic: bool = false,

    pub const struck: StyleBits = .{ .is_struck = true };
    pub const bold: StyleBits = .{ .is_bold = true };
    pub const undercurl: StyleBits = .{ .is_undercurl = true };
    pub const underline: StyleBits = .{ .is_underline = true };
    pub const italic: StyleBits = .{ .is_italic = true };
    pub const normal: StyleBits = .{};
};
