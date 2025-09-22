const std = @import("std");
const c = @import("c.zig");
const ray = c.raylib;

const PRNG = std.Random.DefaultPrng;

const State = FluidState(600, 600);

pub fn main() !void {
    var dba = std.heap.DebugAllocator(.{}){};
    defer _ = dba.deinit();
    const alloc = dba.allocator();

    // const monitor = ray.GetCurrentMonitor();
    // const width = ray.GetMonitorWidth(monitor);
    // const height = ray.GetMonitorHeight(monitor);
    const width = 2000;
    const height = 1600;

    ray.InitWindow(width, height, "Fluid Sim");
    defer ray.CloseWindow();

    ray.SetTargetFPS(120);

    var rng = PRNG.init(blk: {
        var seed: u64 = undefined;
        try std.posix.getrandom(std.mem.asBytes(&seed));
        break :blk seed;
    });

    var state = State.initRand(0.5, &rng);
    var selector = ValSelector{
        .x = 10,
        .y = 50,
        .w = 200,
        .h = 200,
        .mx = 110,
        .my = 150,
        .vx_min = 0,
        .vx_max = 1,
        .vy_min = 0,
        .vy_max = -4,
    };

    while (!ray.WindowShouldClose()) {
        ray.BeginDrawing();
        defer ray.EndDrawing();
        ray.ClearBackground(ray.BLACK);

        selector.update();
        const temp, const chem = selector.extract();

        state.update(&rng, 100000, temp, chem);

        selector.draw();
        state.draw(400, 40, 2, 5);

        const temp_text = try std.fmt.allocPrintZ(alloc, "T = {d}", .{temp});
        defer alloc.free(temp_text);
        const chem_text = try std.fmt.allocPrintZ(alloc, "C = {d}", .{chem});
        defer alloc.free(chem_text);

        ray.DrawText(temp_text, 30, 300, 24, ray.WHITE);
        ray.DrawText(chem_text, 30, 340, 24, ray.WHITE);

        ray.DrawFPS(10, 10);
    }
}

fn FluidState(w: u32, h: u32) type {
    std.debug.assert(w > 0);
    std.debug.assert(h > 0);

    const ValueType = [w][h]bool;

    return struct {
        pub const size = w * h;
        pub const width = w;
        pub const height = h;
        active: ValueType,
        count: i32,

        pub fn initValue(val: bool) @This() {
            return @This(){
                .active = .{.{val} ** height} ** width,
                .count = if (val) size else 0,
            };
        }

        pub fn initRand(prob: f32, rng: *PRNG) @This() {
            const rand = rng.random();

            var active_array: [width][height]bool = undefined;
            var cn: i32 = 0;
            for (&active_array) |*col| {
                for (col) |*val| {
                    val.* = (rand.float(f32) < prob);
                    if (val.*) {
                        cn += 1;
                    }
                }
            }

            return @This(){
                .active = active_array,
                .count = cn,
            };
        }

        pub fn draw(self: @This(), x: u32, y: u32, cell_size: u32, border_size: u32) void {
            const px_width: c_int = @intCast(width * cell_size);
            const px_height: c_int = @intCast(height * cell_size);
            const _x: c_int = @intCast(x);
            const _y: c_int = @intCast(y);

            // Border
            const _border_size: c_int = @intCast(border_size);
            const border_x = _x - _border_size;
            const border_y = _y - _border_size;
            const border_end_x = _x + px_width;
            const border_end_y = _y + px_height;
            ray.DrawRectangle(border_x, border_y, px_width + 2 * _border_size, _border_size, ray.WHITE); // top
            ray.DrawRectangle(border_x, border_y, _border_size, px_height + 2 * _border_size, ray.WHITE); // left
            ray.DrawRectangle(border_x, border_end_y, px_width + 2 * _border_size, _border_size, ray.WHITE); // bottom
            ray.DrawRectangle(border_end_x, border_y, _border_size, px_height + 2 * _border_size, ray.WHITE); // right

            // Cells
            const c_size: c_int = @intCast(cell_size);
            for (0..width) |i_x| {
                const c_x = _x + @as(c_int, @intCast(i_x)) * c_size;
                var offset_y: c_int = -1;
                for (0..height) |i_y| {
                    if (offset_y < 0 and self.active[i_x][i_y]) {
                        offset_y = @intCast(i_y);
                    } else if (offset_y >= 0 and !self.active[i_x][i_y]) {
                        const c_height: c_int = (@as(c_int, @intCast(i_y)) - offset_y) * c_size;
                        const c_y = _y + offset_y * c_size;
                        ray.DrawRectangle(c_x, c_y, c_size, c_height, ray.SKYBLUE);
                        offset_y = -1;
                    }
                }
                if (offset_y >= 0) {
                    const c_height: c_int = (@as(c_int, height) - offset_y) * c_size;
                    const c_y = _y + offset_y * c_size;
                    ray.DrawRectangle(c_x, c_y, c_size, c_height, ray.SKYBLUE);
                }
            }
        }

        pub fn update(self: *@This(), rng: *PRNG, iterations: u32, temp: f32, chem: f32) void {
            for (0..iterations) |_| {
                self._update(rng, temp, chem);
            }
        }

        fn _update(self: *@This(), rng: *PRNG, temp: f32, chem: f32) void {
            const rand = rng.random();

            const x = rand.intRangeLessThan(u32, 0, width);
            const y = rand.intRangeLessThan(u32, 0, height);
            const val = self.active[x][y];

            var energy: f32 = 0;
            if (x > 0 and self.active[x - 1][y]) {
                energy += 1;
            }
            if (x < width - 1 and self.active[x + 1][y]) {
                energy += 1;
            }
            if (y > 0 and self.active[x][y - 1]) {
                energy += 1;
            }
            if (y < height - 2 and self.active[x][y + 1]) {
                energy += 1;
            }

            const delta_energy = if (val) -energy else energy;

            const delta_chem = if (val) -chem else chem;

            const q = @exp((delta_energy + delta_chem) / temp);

            const prob = q / (1 + q);

            if (rand.float(f32) < prob) {
                self.active[x][y] = !val;
                self.count += if (val) -1 else 1;
            }
        }
    };
}

const ValSelector = struct {
    x: c_int,
    y: c_int,
    w: c_int,
    h: c_int,
    mx: c_int,
    my: c_int,
    vx_min: f32,
    vx_max: f32,
    vy_min: f32,
    vy_max: f32,

    pub fn update(self: *ValSelector) void {
        if (!ray.IsMouseButtonDown(ray.MOUSE_BUTTON_LEFT)) {
            return;
        }

        const _mx = ray.GetMouseX();
        const _my = ray.GetMouseY();

        if (_mx < self.x or _mx > self.x + self.w) {
            return;
        }
        if (_my < self.y or _my > self.y + self.h) {
            return;
        }

        self.mx = _mx;
        self.my = _my;
    }

    pub fn draw(self: ValSelector) void {
        // border
        const border_size: c_int = 3;
        const border_x = self.x - border_size;
        const border_y = self.y - border_size;
        const border_end_x = self.x + self.w;
        const border_end_y = self.y + self.h;
        ray.DrawRectangle(border_x, border_y, self.w + 2 * border_size, border_size, ray.WHITE); // top
        ray.DrawRectangle(border_x, border_y, border_size, self.h + 2 * border_size, ray.WHITE); // left
        ray.DrawRectangle(border_x, border_end_y, self.w + 2 * border_size, border_size, ray.WHITE); // bottom
        ray.DrawRectangle(border_end_x, border_y, border_size, self.h + 2 * border_size, ray.WHITE); // right

        ray.DrawCircle(self.mx, self.my, 5, ray.RED);
    }

    pub fn extract(self: ValSelector) struct { f32, f32 } {
        return .{
            std.math.lerp(self.vx_min, self.vx_max, @as(f32, @floatFromInt(self.mx - self.x)) / @as(f32, @floatFromInt(self.w))),
            std.math.lerp(self.vy_min, self.vy_max, @as(f32, @floatFromInt(self.my - self.y)) / @as(f32, @floatFromInt(self.h))),
        };
    }
};
