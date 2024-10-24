const builtin = @import("builtin");

frame_rate: usize = 60,
theme: []const u8 = "default",
input_mode: []const u8 = "flow",
modestate_show: bool = true,
selectionstate_show: bool = true,
modstate_show: bool = false,
keystate_show: bool = false,
gutter_line_numbers: bool = true,
gutter_line_numbers_relative: bool = false,
vim_normal_gutter_line_numbers_relative: bool = true,
vim_visual_gutter_line_numbers_relative: bool = true,
vim_insert_gutter_line_numbers_relative: bool = false,
enable_terminal_cursor: bool = false,
enable_terminal_color_scheme: bool = builtin.os.tag != .windows,
highlight_current_line: bool = true,
highlight_current_line_gutter: bool = true,
show_whitespace: bool = false,
animation_min_lag: usize = 0, //milliseconds
animation_max_lag: usize = 150, //milliseconds
