const std = @import("std");
const Style = @import("theme").Style;
const FontStyle = @import("theme").FontStyle;
const StyleBits = @import("style.zig").StyleBits;
const Cell = @import("Cell.zig");
const vaxis = @import("vaxis");
const Buffer = @import("Buffer");

const Plane = @This();

window: vaxis.Window,
row: i32 = 0,
col: i32 = 0,
name_buf: [128]u8,
name_len: usize,
cache: GraphemeCache = .{},
style: vaxis.Cell.Style = .{},
style_base: vaxis.Cell.Style = .{},
scrolling: bool = false,
transparent: bool = false,

pub const Options = struct {
    y: usize = 0,
    x: usize = 0,
    rows: usize = 0,
    cols: usize = 0,
    name: [*:0]const u8,
    flags: option = .none,
};

pub const option = enum {
    none,
    VSCROLL,
};

pub fn init(nopts: *const Options, parent_: Plane) !Plane {
    const opts = .{
        .x_off = nopts.x,
        .y_off = nopts.y,
        .width = .{ .limit = nopts.cols },
        .height = .{ .limit = nopts.rows },
        .border = .{},
    };
    var plane: Plane = .{
        .window = parent_.window.child(opts),
        .name_buf = undefined,
        .name_len = std.mem.span(nopts.name).len,
        .scrolling = nopts.flags == .VSCROLL,
    };
    @memcpy(plane.name_buf[0..plane.name_len], nopts.name);
    return plane;
}

pub fn deinit(_: *Plane) void {}

pub fn name(self: Plane, buf: []u8) []const u8 {
    @memcpy(buf[0..self.name_len], self.name_buf[0..self.name_len]);
    return buf[0..self.name_len];
}

pub fn above(_: Plane) ?Plane {
    return null;
}

pub fn below(_: Plane) ?Plane {
    return null;
}

pub fn erase(self: Plane) void {
    self.window.fill(.{ .style = self.style_base });
}

pub inline fn abs_y(self: Plane) c_int {
    return @intCast(self.window.y_off);
}

pub inline fn abs_x(self: Plane) c_int {
    return @intCast(self.window.x_off);
}

pub inline fn dim_y(self: Plane) c_uint {
    return @intCast(self.window.height);
}

pub inline fn dim_x(self: Plane) c_uint {
    return @intCast(self.window.width);
}

pub fn abs_yx_to_rel(self: Plane, y: c_int, x: c_int) struct { c_int, c_int } {
    return .{ y - self.abs_y(), x - self.abs_x() };
}

pub fn rel_yx_to_abs(self: Plane, y: c_int, x: c_int) struct { c_int, c_int } {
    return .{ self.abs_y() + y, self.abs_x() + x };
}

pub fn hide(_: Plane) void {}

pub fn move_yx(self: *Plane, y: c_int, x: c_int) !void {
    self.window.y_off = @intCast(y);
    self.window.x_off = @intCast(x);
}

pub fn resize_simple(self: *Plane, ylen: c_uint, xlen: c_uint) !void {
    self.window.height = @intCast(ylen);
    self.window.width = @intCast(xlen);
}

pub fn home(self: *Plane) void {
    self.row = 0;
    self.col = 0;
}

pub fn print(self: *Plane, comptime fmt: anytype, args: anytype) !usize {
    var buf: [fmt.len + 4096]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, fmt, args);
    return self.putstr(text);
}

pub fn print_aligned_right(self: *Plane, y: c_int, comptime fmt: anytype, args: anytype) !usize {
    var buf: [fmt.len + 4096]u8 = undefined;
    const width = self.window.width;
    const text = try std.fmt.bufPrint(&buf, fmt, args);
    const text_width = self.egc_chunk_width(text, 0, 8);
    self.row = @intCast(y);
    self.col = @intCast(if (text_width >= width) 0 else width - text_width);
    return self.putstr(text);
}

pub fn print_aligned_center(self: *Plane, y: c_int, comptime fmt: anytype, args: anytype) !usize {
    var buf: [fmt.len + 4096]u8 = undefined;
    const width = self.window.width;
    const text = try std.fmt.bufPrint(&buf, fmt, args);
    const text_width = self.egc_chunk_width(text, 0, 8);
    self.row = @intCast(y);
    self.col = @intCast(if (text_width >= width) 0 else (width - text_width) / 2);
    return self.putstr(text);
}

pub fn putstr(self: *Plane, text: []const u8) !usize {
    var result: usize = 0;
    const height = self.window.height;
    const width = self.window.width;
    var iter = self.window.screen.unicode.graphemeIterator(text);
    while (iter.next()) |grapheme| {
        const s = grapheme.bytes(text);
        if (std.mem.eql(u8, s, "\n")) {
            if (self.scrolling and self.row == height - 1)
                self.window.scroll(1)
            else
                self.row += 1;
            self.col = 0;
            result += 1;
            continue;
        }
        if (self.col >= width) {
            if (self.scrolling) {
                self.row += 1;
                self.col = 0;
            } else return result;
        }
        self.write_cell(@intCast(self.col), @intCast(self.row), s);
        result += 1;
    }
    return result;
}

pub fn putc(self: *Plane, cell: *const Cell) !usize {
    return self.putc_yx(@intCast(self.row), @intCast(self.col), cell);
}

pub fn putc_yx(self: *Plane, y: c_int, x: c_int, cell: *const Cell) !usize {
    try self.cursor_move_yx(y, x);
    const w = if (cell.cell.char.width == 0) self.window.gwidth(cell.cell.char.grapheme) else cell.cell.char.width;
    if (w == 0) return w;
    self.window.writeCell(@intCast(self.col), @intCast(self.row), cell.cell);
    self.col += @intCast(w);
    return w;
}

fn write_cell(self: *Plane, col: usize, row: usize, egc: []const u8) void {
    var cell: vaxis.Cell = self.window.readCell(col, row) orelse .{ .style = self.style };
    const w = self.window.gwidth(egc);
    cell.char.grapheme = self.cache.put(egc);
    cell.char.width = w;
    if (self.transparent) {
        cell.style.fg = self.style.fg;
    } else {
        cell.style = self.style;
    }
    self.window.writeCell(col, row, cell);
    self.col += @intCast(w);
}

pub fn cursor_yx(self: Plane, y: *c_uint, x: *c_uint) void {
    y.* = @intCast(self.row);
    x.* = @intCast(self.col);
}

pub fn cursor_y(self: Plane) c_uint {
    return @intCast(self.row);
}

pub fn cursor_x(self: Plane) c_uint {
    return @intCast(self.col);
}

pub fn cursor_move_yx(self: *Plane, y: c_int, x: c_int) !void {
    if (self.window.height == 0 or self.window.width == 0) return;
    if (self.window.height <= y or self.window.width <= x) return;
    if (y >= 0)
        self.row = @intCast(y);
    if (x >= 0)
        self.col = @intCast(x);
}

pub fn cursor_move_rel(self: *Plane, y: c_int, x: c_int) !void {
    if (self.window.height == 0 or self.window.width == 0) return error.OutOfBounds;
    const new_y: isize = @as(c_int, @intCast(self.row)) + y;
    const new_x: isize = @as(c_int, @intCast(self.col)) + x;
    if (new_y < 0 or new_x < 0) return error.OutOfBounds;
    if (self.window.height <= new_y or self.window.width <= new_x) return error.OutOfBounds;
    self.row = @intCast(new_y);
    self.col = @intCast(new_x);
}

pub fn cell_init(self: Plane) Cell {
    return .{ .cell = .{ .style = self.style } };
}

pub fn cell_load(self: *Plane, cell: *Cell, gcluster: [:0]const u8) !usize {
    var cols: c_int = 0;
    const bytes = self.egc_length(gcluster, &cols, 0, 1);
    cell.cell.char.grapheme = self.cache.put(gcluster[0..bytes]);
    cell.cell.char.width = @intCast(cols);
    return bytes;
}

pub fn at_cursor_cell(self: Plane, cell: *Cell) !usize {
    cell.* = .{};
    if (self.window.readCell(@intCast(self.col), @intCast(self.row))) |cell_| cell.cell = cell_;
    return if (std.mem.eql(u8, cell.cell.char.grapheme, " ")) 0 else cell.cell.char.grapheme.len;
}

pub fn set_styles(self: *Plane, stylebits: StyleBits) void {
    self.style.strikethrough = false;
    self.style.bold = false;
    self.style.ul_style = .off;
    self.style.italic = false;
    self.on_styles(stylebits);
}

pub fn on_styles(self: *Plane, stylebits: StyleBits) void {
    if (stylebits.is_struck) self.style.strikethrough = true;
    if (stylebits.is_bold) self.style.bold = true;
    if (stylebits.is_undercurl) self.style.ul_style = .curly;
    if (stylebits.is_underline) self.style.ul_style = .single;
    if (stylebits.is_italic) self.style.italic = true;
}

pub fn off_styles(self: *Plane, stylebits: StyleBits) void {
    if (stylebits.is_struck) self.style.strikethrough = false;
    if (stylebits.is_bold) self.style.bold = false;
    if (stylebits.is_undercurl) self.style.ul_style = .off;
    if (stylebits.is_underline) self.style.ul_style = .off;
    if (stylebits.is_italic) self.style.italic = false;
}

pub fn set_fg_rgb(self: *Plane, channel: u32) !void {
    self.style.fg = vaxis.Cell.Color.rgbFromUint(@intCast(channel));
}

pub fn set_bg_rgb(self: *Plane, channel: u32) !void {
    self.style.bg = vaxis.Cell.Color.rgbFromUint(@intCast(channel));
}

pub fn set_fg_palindex(self: *Plane, idx: c_uint) !void {
    self.style.fg = .{ .index = @intCast(idx) };
}

pub fn set_bg_palindex(self: *Plane, idx: c_uint) !void {
    self.style.bg = .{ .index = @intCast(idx) };
}

pub inline fn set_base_style(self: *Plane, _: [*c]const u8, style_: Style) void {
    self.style_base.fg = if (style_.fg) |color| vaxis.Cell.Color.rgbFromUint(@intCast(color)) else .default;
    self.style_base.bg = if (style_.bg) |color| vaxis.Cell.Color.rgbFromUint(@intCast(color)) else .default;
    if (style_.fs) |fs| set_font_style(&self.style, fs);
    self.set_style(style_);
}

pub fn set_base_style_transparent(self: *Plane, _: [*:0]const u8, style_: Style) void {
    self.style_base.fg = if (style_.fg) |color| vaxis.Cell.Color.rgbFromUint(@intCast(color)) else .default;
    self.style_base.bg = if (style_.bg) |color| vaxis.Cell.Color.rgbFromUint(@intCast(color)) else .default;
    if (style_.fs) |fs| set_font_style(&self.style, fs);
    self.set_style(style_);
    self.transparent = true;
}

pub fn set_base_style_bg_transparent(self: *Plane, _: [*:0]const u8, style_: Style) void {
    self.style_base.fg = if (style_.fg) |color| vaxis.Cell.Color.rgbFromUint(@intCast(color)) else .default;
    self.style_base.bg = if (style_.bg) |color| vaxis.Cell.Color.rgbFromUint(@intCast(color)) else .default;
    if (style_.fs) |fs| set_font_style(&self.style, fs);
    self.set_style(style_);
    self.transparent = true;
}

pub inline fn set_style(self: *Plane, style_: Style) void {
    if (style_.fg) |color| self.style.fg = vaxis.Cell.Color.rgbFromUint(@intCast(color));
    if (style_.bg) |color| self.style.bg = vaxis.Cell.Color.rgbFromUint(@intCast(color));
    if (style_.fs) |fs| set_font_style(&self.style, fs);
    self.transparent = false;
}

pub inline fn set_style_bg_transparent(self: *Plane, style_: Style) void {
    if (style_.fg) |color| self.style.fg = vaxis.Cell.Color.rgbFromUint(@intCast(color));
    if (style_.bg) |color| self.style.bg = vaxis.Cell.Color.rgbFromUint(@intCast(color));
    if (style_.fs) |fs| set_font_style(&self.style, fs);
    self.transparent = true;
}

inline fn set_font_style(style: *vaxis.Cell.Style, fs: FontStyle) void {
    switch (fs) {
        .normal => {
            style.bold = false;
            style.italic = false;
            style.dim = false;
        },
        .bold => style.bold = true,
        .italic => style.italic = true,
        .underline => style.ul_style = .single,
        .undercurl => style.ul_style = .curly,
        .strikethrough => style.strikethrough = true,
    }
}

pub fn egc_length(self: *const Plane, egcs: []const u8, colcount: *c_int, abs_col: usize, tab_width: usize) usize {
    if (egcs[0] == '\t') {
        colcount.* = @intCast(tab_width - (abs_col % tab_width));
        return 1;
    }
    var iter = self.window.screen.unicode.graphemeIterator(egcs);
    const grapheme = iter.next() orelse {
        colcount.* = 1;
        return 1;
    };
    const s = grapheme.bytes(egcs);
    const w = self.window.gwidth(s);
    colcount.* = @intCast(w);
    return s.len;
}

pub fn egc_chunk_width(self: *const Plane, chunk_: []const u8, abs_col_: usize, tab_width: usize) usize {
    var abs_col = abs_col_;
    var chunk = chunk_;
    var colcount: usize = 0;
    var cols: c_int = 0;
    while (chunk.len > 0) {
        const bytes = self.egc_length(chunk, &cols, abs_col, tab_width);
        colcount += @intCast(cols);
        abs_col += @intCast(cols);
        if (chunk.len < bytes) break;
        chunk = chunk[bytes..];
    }
    return colcount;
}

pub fn metrics(self: *const Plane, tab_width: usize) Buffer.Metrics {
    return .{
        .ctx = self,
        .egc_length = struct {
            fn f(self_: Buffer.Metrics, egcs: []const u8, colcount: *c_int, abs_col: usize) usize {
                const plane: *const Plane = @ptrCast(@alignCast(self_.ctx));
                return plane.egc_length(egcs, colcount, abs_col, self_.tab_width);
            }
        }.f,
        .egc_chunk_width = struct {
            fn f(self_: Buffer.Metrics, chunk_: []const u8, abs_col_: usize) usize {
                const plane: *const Plane = @ptrCast(@alignCast(self_.ctx));
                return plane.egc_chunk_width(chunk_, abs_col_, self_.tab_width);
            }
        }.f,
        .tab_width = tab_width,
    };
}

const GraphemeCache = struct {
    buf: [1024 * 16]u8 = undefined,
    idx: usize = 0,

    pub fn put(self: *GraphemeCache, bytes: []const u8) []u8 {
        if (self.idx + bytes.len > self.buf.len) self.idx = 0;
        defer self.idx += bytes.len;
        @memcpy(self.buf[self.idx .. self.idx + bytes.len], bytes);
        return self.buf[self.idx .. self.idx + bytes.len];
    }
};
