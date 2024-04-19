const std = @import("std");
const lib = @import("lib.zig");

const c = lib.c;
const Date = lib.Date;
const Time = lib.Time;
const Interval = lib.Interval;
const Vector = lib.Vector;
const DuckDBError = c.DuckDBError;
const Allocator = std.mem.Allocator;

pub const Appender = struct {
	// Error message, if any
	err: ?[]const u8,

	// the row of the current chunk that we're writing at
	row_index: usize,

	// c.duckdb_vector_size (2048)..when row_index == 2047, we flush and create
	// a new chunk
	vector_size: usize,

	allocator: Allocator,

	// 1 vector per column. Part of the vector data is initialied upfront (the
	// type information). Part of it is initialized for each data_chunk (the
	// underlying duckdb vector data and the validity data).
	vectors: []Vector,

	// This is duplicate of data available from vectors, but we need it as a slice
	// to pass to c.duckdb_create_data_chunk
	types: []c.duckdb_logical_type,

	// The collection of vectors for the appender. While we store data directly
	// in the vector, most operations (e.g. flush) happen on the data chunk.
	data_chunk: ?c.duckdb_data_chunk,
	appender: *c.duckdb_appender,

	pub fn init(allocator: Allocator, appender: *c.duckdb_appender) !Appender {
		const column_count = c.duckdb_appender_column_count(appender.*);

		var types = try allocator.alloc(c.duckdb_logical_type, column_count);
		errdefer allocator.free(types);

		var vectors = try allocator.alloc(Vector, column_count);
		errdefer allocator.free(vectors);

		var initialized: usize = 0;
		errdefer for (0..initialized) |i| {
			vectors[i].deinit();
		};

		for (0..column_count) |i| {
			const logical_type = c.duckdb_appender_column_type(appender.*, i);
			types[i] = logical_type;
			vectors[i] = try Vector.init(undefined, logical_type);
			initialized += 1;

			switch (vectors[i].type) {
				.list => {},
				.scalar => |scalar| switch (scalar) {
					.simple => {},
					.decimal => {},
					.@"enum" => return error.CannotAppendToEnum, // https://github.com/duckdb/duckdb/pull/11704
				},
			}
		}

		return .{
			.err = null,
			.row_index = 0,
			.types = types,
			.vectors = vectors,
			.data_chunk = null,
			.appender = appender,
			.allocator = allocator,
			.vector_size = c.duckdb_vector_size(),
		};
	}

	pub fn deinit(self: *Appender) void {
		for (self.vectors) |*v| {
			v.deinit();
		}

		const allocator = self.allocator;
		allocator.free(self.types);
		allocator.free(self.vectors);

		if (self.data_chunk) |*data_chunk| {
			_ = c.duckdb_destroy_data_chunk(data_chunk);
		}


		const appender = self.appender;
		_ = c.duckdb_appender_destroy(appender);
		allocator.destroy(appender);
	}

	fn newDataChunk(types: []c.duckdb_logical_type, vectors: []Vector) c.duckdb_data_chunk {
		const data_chunk = c.duckdb_create_data_chunk(types.ptr, types.len);

		for (0..types.len) |i| {
			const v = c.duckdb_data_chunk_get_vector(data_chunk, i);
			const vector = &vectors[i];
			vector.loadVector(v);
			vector.validity = null;
		}
		return data_chunk;
	}

	pub fn flush(self: *Appender) !void {
		var data_chunk = self.data_chunk orelse return;
		// if (self.row_index < self.vector_size) {
			c.duckdb_data_chunk_set_size(data_chunk, self.row_index);
		// }

		const appender = self.appender;
		if (c.duckdb_append_data_chunk(appender.*, data_chunk) == DuckDBError) {
			if (c.duckdb_appender_error(appender.*)) |c_err| {
				self.err = std.mem.span(c_err);
			}
			return error.DuckDBError;
		}

		if (c.duckdb_appender_flush(self.appender.*) == DuckDBError) {
			if (c.duckdb_appender_error(appender.*)) |c_err| {
				self.err = std.mem.span(c_err);
			}
			return error.DuckDBError;
		}

		c.duckdb_destroy_data_chunk(&data_chunk);
		self.data_chunk = null;
	}

	pub fn appendRow(self: *Appender, values: anytype) !void {
		self.beginRow();

		inline for (values, 0..) |value, i| {
			try self.appendValue(value, i);
		}
		try self.endRow();
	}

	// The appender has two apis. The simplest is to call appendRow, passing the full
	// row. When using appendRow, things mostly just work.
	// It's also possible to call appendValue for each column. This API is used
	// when the "row" isn't known at comptime - the app has no choice but to
	// call appendValue for each column. In such cases, we require an explicit
	// call to beginRow, bindValue and endRow.
	pub fn beginRow(self: *Appender) void {
		if (self.data_chunk == null) {
			self.data_chunk = newDataChunk(self.types, self.vectors);
			self.row_index = 0;
		}
	}

	pub fn endRow(self: *Appender) !void {
		const row_index = self.row_index  + 1;
		self.row_index = row_index;
		if (row_index == self.vector_size) {
			try self.flush();
		}
	}

	pub fn appendValue(self: *Appender, value: anytype, column: usize) !void {
		var vector = &self.vectors[column];
		const row_index = self.row_index;

		const T = @TypeOf(value);
		const type_info = @typeInfo(T);
		switch (type_info) {
			.Null => {
				const validity = vector.validity orelse blk: {
					c.duckdb_vector_ensure_validity_writable(vector.vector);
					const v = c.duckdb_vector_get_validity(vector.vector);
					vector.validity = v;
					break :blk v;
				};
				c.duckdb_validity_set_row_invalid(validity, row_index);
				return;
			},
			.Optional => return self.appendValue(if (value) |v| v else null, column),
			.Pointer => |ptr| {
				switch (ptr.size) {
					.Slice => return self.appendSlice(vector, @as([]const ptr.child, value), row_index),
					.One => switch (@typeInfo(ptr.child)) {
						.Array => {
							const Slice = []const std.meta.Elem(ptr.child);
							return self.appendSlice(vector, @as(Slice, value), row_index);
						},
						else => appendError(T),
					},
					else => appendError(T),
				}
			},
			.Array => return self.appendValue(&value, column),
			else => {},
		}

		switch (vector.data) {
			.list => return self.appendTypeError("list", T),
			.scalar => |scalar| switch (scalar) {
				.bool => |data| {
					switch (type_info) {
						.Bool => data[row_index] = value,
						else => return self.appendTypeError("boolean", T)
					}
				},
				.i8 => |data| {
					switch (type_info) {
						.Int, .ComptimeInt => {
							if (value < lib.TINYINT_MIN or value > lib.TINYINT_MAX) return self.appendIntRangeError("tinyint");
							data[row_index] = @intCast(value);
						},
						else => return self.appendTypeError("tinyint", T)
					}
				},
				.i16 => |data| {
					switch (type_info) {
						.Int, .ComptimeInt => {
							if (value < lib.SMALLINT_MIN or value > lib.SMALLINT_MAX) return self.appendIntRangeError("smallint");
							data[row_index] = @intCast(value);
						},
						else => return self.appendTypeError("smallint", T)
					}
				},
				.i32 => |data| {
					switch (type_info) {
						.Int, .ComptimeInt => {
							if (value < lib.INTEGER_MIN or value > lib.INTEGER_MAX) return self.appendIntRangeError("integer");
							data[row_index] = @intCast(value);
						},
						else => return self.appendTypeError("integer", T)
					}
				},
				.i64 => |data| {
					switch (type_info) {
						.Int, .ComptimeInt => {
							if (value < lib.BIGINT_MIN or value > lib.BIGINT_MAX) return self.appendIntRangeError("bigint");
							data[row_index] = @intCast(value);
						},
						else => return self.appendTypeError("bigint", T)
					}
				},
				.i128 => |data| {
					switch (type_info) {
						.Int, .ComptimeInt => {
							if (value < lib.HUGEINT_MIN or value > lib.HUGEINT_MAX) return self.appendIntRangeError("hugeint");
							data[row_index] = @intCast(value);
						},
						else => return self.appendTypeError("hugeint", T)
					}
				},
				.u8 => |data| {
					switch (type_info) {
						.Int, .ComptimeInt => {
							if (value < lib.UTINYINT_MIN or value > lib.UTINYINT_MAX) return self.appendIntRangeError("utinyint");
							data[row_index] = @intCast(value);
						},
						else => return self.appendTypeError("utinyint", T)
					}
				},
				.u16 => |data| {
					switch (type_info) {
						.Int, .ComptimeInt => {
							if (value < lib.USMALLINT_MIN or value > lib.USMALLINT_MAX) return self.appendIntRangeError("usmallint");
							data[row_index] = @intCast(value);
						},
						else => return self.appendTypeError("usmallint", T)
					}
				},
				.u32 => |data| {
					switch (type_info) {
						.Int, .ComptimeInt => {
							if (value < lib.UINTEGER_MIN or value > lib.UINTEGER_MAX) return self.appendIntRangeError("uinteger");
							data[row_index] = @intCast(value);
						},
						else => return self.appendTypeError("uinteger", T)
					}
				},
				.u64 => |data| {
					switch (type_info) {
						.Int, .ComptimeInt => {
							if (value < lib.UBIGINT_MIN or value > lib.UBIGINT_MAX) return self.appendIntRangeError("ubingint");
							data[row_index] = @intCast(value);
						},
						else => return self.appendTypeError("ubingint", T)
					}
				},
				.u128 => |data| {
					switch (type_info) {
						.Int, .ComptimeInt => {
							if (value < lib.UHUGEINT_MIN or value > lib.UHUGEINT_MAX) return self.appendIntRangeError("uhugeint");
							data[row_index] = @intCast(value);
						},
						else => return self.appendTypeError("uhugeint", T)
					}
				},
				.f32 => |data| {
					switch (type_info) {
						.Int, .ComptimeInt => data[row_index] = @floatFromInt(value),
						.Float, .ComptimeFloat => data[row_index] = @floatCast(value),
						else => return self.appendTypeError("real", T)
					}
				},
				.f64 => |data| {
					switch (type_info) {
						.Int, .ComptimeInt => data[row_index] = @floatFromInt(value),
						.Float, .ComptimeFloat => data[row_index] = @floatCast(value),
						else => return self.appendTypeError("double", T)
					}
				},
				.date => |data| if (T == Date) {
					data[row_index] = c.duckdb_to_date(value);
				} else {
					return self.appendTypeError("date", T);
				},
				.time => |data| if (T == Time) {
					data[row_index] = c.duckdb_to_time(value);
				} else {
					return self.appendTypeError("time", T);
				},
				.interval => |data| if (T == Interval) {
					data[row_index] = value;
				} else {
					return self.appendTypeError("interval", T);
				},
				.timestamp => |data| {
					switch (type_info) {
						.Int, .ComptimeInt => {
							if (value < lib.BIGINT_MIN or value > lib.BIGINT_MAX) return self.appendIntRangeError("i64");
							data[row_index] = .{.micros = @intCast(value)};
						},
						else => return self.appendTypeError("timestamp", T)
					}
				},
				.decimal => |d| switch (type_info) {
					.Int, .ComptimeInt => switch (d.internal) {
						.i16 => |data| {
							if (value < lib.SMALLINT_MIN or value > lib.SMALLINT_MAX) return self.appendIntRangeError("smallint");
							data[row_index] = @intCast(value);
						},
						.i32 => |data| {
							if (value < lib.INTEGER_MIN or value > lib.INTEGER_MAX) return self.appendIntRangeError("integer");
							data[row_index] = @intCast(value);
						},
						.i64 => |data| {
							if (value < lib.BIGINT_MIN or value > lib.BIGINT_MAX) return self.appendIntRangeError("bigint");
							data[row_index] = @intCast(value);
						},
						.i128 => |data| {
							if (value < lib.HUGEINT_MIN or value > lib.HUGEINT_MAX) return self.appendIntRangeError("hugeint");
							data[row_index] = @intCast(value);
						},
					},
					.Float, .ComptimeFloat => {
						// YES, there's a lot of duplication going on. But, I don't think the float and int codepaths can be merged
						// without forcing int value to an i128, which seems wasteful to me.
						const huge: i128 = switch (vector.type.scalar.decimal.scale) {
							0 => @intFromFloat(value),
							1 => @intFromFloat(value * 10),
							2 => @intFromFloat(value * 100),
							3 => @intFromFloat(value * 1000),
							4 => @intFromFloat(value * 10000),
							5 => @intFromFloat(value * 100000),
							6 => @intFromFloat(value * 1000000),
							7 => @intFromFloat(value * 10000000),
							8 => @intFromFloat(value * 100000000),
							9 => @intFromFloat(value * 1000000000),
							10 => @intFromFloat(value * 10000000000),
							else => |n| @intFromFloat(value * std.math.pow(f64, 10, @floatFromInt(n))),
						};
						switch (d.internal) {
							.i16 => |data| {
								if (huge < lib.SMALLINT_MIN or huge > lib.SMALLINT_MAX) return self.appendIntRangeError("smallint");
								data[row_index] = @intCast(huge);
							},
							.i32 => |data| {
								if (huge < lib.INTEGER_MIN or huge > lib.INTEGER_MAX) return self.appendIntRangeError("integer");
								data[row_index] = @intCast(huge);
							},
							.i64 => |data| {
								if (huge < lib.BIGINT_MIN or huge > lib.BIGINT_MAX) return self.appendIntRangeError("bigint");
								data[row_index] = @intCast(huge);
							},
							.i128 => |data| {
								if (huge < lib.HUGEINT_MIN or huge > lib.HUGEINT_MAX) return self.appendIntRangeError("hugeint");
								data[row_index] = @intCast(huge);
							},
						}
					},
					else => return self.appendTypeError("decimal", T)
				},
				else => unreachable,
			}
		}
	}

	fn appendSlice(self: *Appender, vector: *Vector, values: anytype, row_index: usize) !void {
		const T = @TypeOf(values);
		switch (vector.data) {
			.list => |list| {
				const size = c.duckdb_list_vector_get_size(vector.vector);
				const new_size = size + values.len;

				switch (list.child) {
					.i8 => |data| if (T == []i8 or T == []const i8) {
						@memcpy(data[size..new_size], values);
					} else {
						return self.appendTypeError("tinyint[]", T);
					},
					.i16 => |data| if (T == []i16 or T == []const i16) {
						@memcpy(data[size..new_size], values);
					} else {
						return self.appendTypeError("smallint[]", T);
					},
					.i32 => |data| if (T == []i32 or T == []const i32) {
						@memcpy(data[size..new_size], values);
					} else {
						return self.appendTypeError("integer[]", T);
					},
					.i64 => |data| if (T == []i64 or T == []const i64) {
						@memcpy(data[size..new_size], values);
					} else {
						return self.appendTypeError("bigint[]", T);
					},
					.i128 => |data| if (T == []i128 or T == []const i128) {
						@memcpy(data[size..new_size], values);
					} else {
						return self.appendTypeError("hugeint[]", T);
					},
					.u8 => |data| if (T == []u8 or T == []const u8) {
						@memcpy(data[size..new_size], values);
					} else {
						return self.appendTypeError("utinyint[]", T);
					},
					.u16 => |data| if (T == []u16 or T == []const u16) {
						@memcpy(data[size..new_size], values);
					} else {
						return self.appendTypeError("usmallint[]", T);
					},
					.u32 => |data| if (T == []u32 or T == []const u32) {
						@memcpy(data[size..new_size], values);
					} else {
						return self.appendTypeError("uinteger[]", T);
					},
					.u64 => |data| if (T == []u64 or T == []const u64) {
						@memcpy(data[size..new_size], values);
					} else {
						return self.appendTypeError("ubigint[]", T);
					},
					.u128 => |data| if (T == []u128 or T == []const u128) {
						@memcpy(data[size..new_size], values);
					} else {
						return self.appendTypeError("uhugeint[]", T);
					},
					.f32 => |data| if (T == []f32 or T == []const f32) {
						@memcpy(data[size..new_size], values);
					} else {
						return self.appendTypeError("real[]", T);
					},
					.f64 => |data| if (T == []f64 or T == []const f64) {
						@memcpy(data[size..new_size], values);
					} else {
						return self.appendTypeError("double[]", T);
					},
					.bool => |data| if (T == []bool or T == []const bool) {
						@memcpy(data[size..new_size], values);
					} else {
						return self.appendTypeError("bool[]", T);
					},
					.blob, .varchar => if (T == []const []const u8) {
						const child_vector = list.child_vector;
						for (values, size..) |value, i| {
							c.duckdb_vector_assign_string_element_len(child_vector, i, value.ptr, value.len);
						}
					} else {
						return self.appendTypeError("text[] / blob[]", T);
					},
					else => unreachable,
					// bool: [*c]bool,
					// f32: [*c]f32,
					// f64: [*c]f64,
					// date: [*]c.duckdb_date,
					// time: [*]c.duckdb_time,
					// timestamp: [*]c.duckdb_timestamp,
					// interval: [*]c.duckdb_interval,
					// decimal: Vector.Decimal,
					// uuid: [*c]i128,
					// @"enum": Vector.Enum,
				}
				list.entries[row_index] = .{
					.offset = size,
					.length = values.len,
				};

				if (c.duckdb_list_vector_set_size(vector.vector, new_size) == DuckDBError) {
					return error.DuckDBError;
				}
				if (c.duckdb_list_vector_reserve(vector.vector, new_size) == DuckDBError) {
					return error.DuckDBError;
				}
			},
			.scalar => |scalar| switch (scalar) {
				.varchar, .blob  => {
					// We have a []u8 or []const u8. This could either be a text value
					// or a utinyint[]. The type of the vector resolves the ambiguity.
					if (T == []u8 or T == []const u8) {
						c.duckdb_vector_assign_string_element_len(vector.vector, row_index, values.ptr, values.len);
					} else {
						return self.appendTypeError("varchar/blob", T);
					}
				},
				.i128 => |data| {
					// maybe we have a []u8 that represents a UUID (either in binary or hex)
					if (T == []u8 or T == []const u8) {
						var n: i128 = 0;
						if (values.len == 36) {
							n = try uuidToInt(values);
						} else if (values.len == 16) {
							n = std.mem.readInt(i128, values[0..16], .big);
						} else {
							return error.InvalidUUID;
						}
						data[row_index] = n ^ (@as(i128, 1) << 127);
					} else {
						return self.appendTypeError(".i128", T);
					}
				},
				else => return self.appendTypeError("???", T),
			},
		}
	}

	fn appendTypeError(self: *Appender, comptime data_type: []const u8, value_type: type) error{AppendError} {
		self.err = "cannot bind a " ++ @typeName(value_type) ++ " to a column of type " ++ data_type;

		return error.AppendError;
	}

	fn appendIntRangeError(self: *Appender, comptime data_type: []const u8) error{AppendError} {
		self.err = "value is outside of range for a column of type " ++ data_type;
		return error.AppendError;
	}
};

fn appendError(comptime T: type) void {
	@compileError("cannot append value of type " ++ @typeName(T));
}

fn uuidToInt(hex: []const u8) !i128 {
	var bin: [16]u8 = undefined;

	std.debug.assert(hex.len == 36);
	if (hex[8] != '-' or hex[13] != '-' or hex[18] != '-' or hex[23] != '-') {
		return error.InvalidUUID;
	}

	inline for (encoded_pos, 0..) |i, j| {
		const hi = hex_to_nibble[hex[i + 0]];
		const lo = hex_to_nibble[hex[i + 1]];
		if (hi == 0xff or lo == 0xff) {
			return error.InvalidUUID;
		}
		bin[j] = hi << 4 | lo;
	}
	return std.mem.readInt(i128, &bin, .big);
}

const encoded_pos = [16]u8{ 0, 2, 4, 6, 9, 11, 14, 16, 19, 21, 24, 26, 28, 30, 32, 34 };
const hex_to_nibble = [_]u8{0xff} ** 48 ++ [_]u8{
	0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
	0x08, 0x09, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
	0xff, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0xff,
	0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
	0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
	0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff,
	0xff, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f, 0xff,
} ++ [_]u8{0xff} ** 152;

const t = std.testing;
const DB = lib.DB;
test "Appender: bind errors" {
	const db = try DB.init(t.allocator, ":memory:", .{});
	defer db.deinit();

	var conn = try db.conn();
	defer conn.deinit();

	_ = try conn.exec("create table x (a integer)", .{});
	{
		var appender = try conn.appender(null, "x");
		defer appender.deinit();
		try t.expectError(error.AppendError, appender.appendRow(.{true}));
		try t.expectEqualStrings("cannot bind a bool to a column of type integer", appender.err.?);
	}

	{
		var appender = try conn.appender(null, "x");
		defer appender.deinit();
		try t.expectError(error.AppendError, appender.appendRow(.{9147483647}));
		try t.expectEqualStrings("value is outside of range for a column of type integer", appender.err.?);
	}
}

test "CannotAppendToDecimal" {
	const db = try DB.init(t.allocator, ":memory:", .{});
	defer db.deinit();

	var conn = try db.conn();
	defer conn.deinit();

	_ = try conn.exec(
		\\ create table x (
		\\   col_tinyint tinyint,
		\\   col_smallint smallint,
		\\   col_integer integer,
		\\   col_bigint bigint,
		\\   col_hugeint hugeint,
		\\   col_utinyint utinyint,
		\\   col_usmallint usmallint,
		\\   col_uinteger uinteger,
		\\   col_ubigint ubigint,
		\\   col_uhugeint uhugeint,
		\\   col_bool bool,
		\\   col_real real,
		\\   col_double double,
		\\   col_text text,
		\\   col_blob blob,
		\\   col_uuid uuid,
		\\   col_date date,
		\\   col_time time,
		\\   col_interval interval,
		\\   col_timestamp timestamp,
		\\   col_decimal decimal(18, 6),
		\\ )
	, .{});

	{
		var appender = try conn.appender(null, "x");
		defer appender.deinit();
		try appender.appendRow(.{
			-128, lib.SMALLINT_MIN, lib.INTEGER_MIN, lib.BIGINT_MIN, lib.HUGEINT_MIN,
			lib.UTINYINT_MAX, lib.USMALLINT_MAX, lib.UINTEGER_MAX, lib.UBIGINT_MAX, lib.UHUGEINT_MAX,
			true, -1.23, 1994.848288123, "over 9000!", &[_]u8{1, 2, 3, 254}, "34c667cd-638e-40c2-b256-0f78ccab7013",
			Date{.year = 2023, .month = 5, .day = 10}, Time{.hour = 21, .min = 4, .sec = 49, .micros = 123456},
			Interval{.months = 3, .days = 7, .micros = 982810}, 1711506018088167, 39858392.36212
		});
		try appender.flush();

		try t.expectEqual(null, appender.err);

		var row = (try conn.row("select * from x", .{})).?;
		defer row.deinit();
		try t.expectEqual(-128, row.get(i8, 0));
		try t.expectEqual(lib.SMALLINT_MIN, row.get(i16, 1));
		try t.expectEqual(lib.INTEGER_MIN, row.get(i32, 2));
		try t.expectEqual(lib.BIGINT_MIN, row.get(i64, 3));
		try t.expectEqual(lib.HUGEINT_MIN, row.get(i128, 4));
		try t.expectEqual(lib.UTINYINT_MAX, row.get(u8, 5));
		try t.expectEqual(lib.USMALLINT_MAX, row.get(u16, 6));
		try t.expectEqual(lib.UINTEGER_MAX, row.get(u32, 7));
		try t.expectEqual(lib.UBIGINT_MAX, row.get(u64, 8));
		try t.expectEqual(lib.UHUGEINT_MAX, row.get(u128, 9));
		try t.expectEqual(true, row.get(bool, 10));
		try t.expectEqual(-1.23, row.get(f32, 11));
		try t.expectEqual(1994.848288123, row.get(f64, 12));
		try t.expectEqualStrings("over 9000!", row.get([]u8, 13));
		try t.expectEqualStrings(&[_]u8{1, 2, 3, 254}, row.get([]u8, 14));
		try t.expectEqualStrings("34c667cd-638e-40c2-b256-0f78ccab7013", &row.get(lib.UUID, 15));
		try t.expectEqual(Date{.year = 2023, .month = 5, .day = 10}, row.get(Date, 16));
		try t.expectEqual(Time{.hour = 21, .min = 4, .sec = 49, .micros = 123456}, row.get(Time, 17));
		try t.expectEqual(Interval{.months = 3, .days = 7, .micros = 982810}, row.get(Interval, 18));
		try t.expectEqual(1711506018088167, row.get(i64, 19));
		try t.expectEqual(39858392.36212, row.get(f64, 20));
	}
}

test "Appender: basic variants" {
	const db = try DB.init(t.allocator, ":memory:", .{});
	defer db.deinit();

	var conn = try db.conn();
	defer conn.deinit();

	_ = try conn.exec(
		\\ create table x (
		\\   id integer,
		\\   col_bool bool,
		\\   col_uuid uuid
		\\ )
	, .{});

	var appender = try conn.appender(null, "x");
	defer appender.deinit();
	try appender.appendRow(.{1, false, &[_]u8{0xf9,0x3b,0x64,0xe0,0x91,0x62,0x40,0xf5,0xaa,0xb8,0xa0,0x1f,0x5c,0xe9,0x90,0x32}});
	try appender.appendRow(.{2, null, null});
	try appender.flush();

	try t.expectEqual(null, appender.err);

	{
		var row = (try conn.row("select * from x where id = 1", .{})).?;
		defer row.deinit();
		try t.expectEqual(false, row.get(bool, 1));
		try t.expectEqualStrings("f93b64e0-9162-40f5-aab8-a01f5ce99032", &row.get(lib.UUID, 2));
	}

	{
		var row = (try conn.row("select * from x where id = 2", .{})).?;
		defer row.deinit();
		try t.expectEqual(null, row.get(?bool, 1));
		try t.expectEqual(null, row.get(?lib.UUID, 2));
	}
}

test "Appender: multiple chunks" {
	const db = try DB.init(t.allocator, ":memory:", .{});
	defer db.deinit();

	var conn = try db.conn();
	defer conn.deinit();

	_ = try conn.exec("create table x (a integer, b integer)", .{});

	{
		var appender = try conn.appender(null, "x");
		defer appender.deinit();

		for (0..1000) |i| {
			appender.beginRow();
			try appender.appendValue(i, 0);
			if (@mod(i, 3) == 0) {
				try appender.appendValue(null, 1);
			} else {
				try appender.appendValue(i * 2, 1);
			}
			try appender.endRow();
		}
		try appender.flush();
	}

	var rows = try conn.query("select * from x order by a", .{});
	defer rows.deinit();

	var i: i32 = 0;
	while (try rows.next()) |row| {
		try t.expectEqual(i, row.get(i32, 0));

		if (@mod(i, 3) == 0) {
			try t.expectEqual(null, row.get(?i32, 1));
		} else {
			try t.expectEqual(i*2, row.get(i32, 1));
		}
		i += 1;
	}
	try t.expectEqual(1000, i);
}

test "Appender: implicit and explicit flush" {
	const db = try DB.init(t.allocator, ":memory:", .{});
	defer db.deinit();

	var conn = try db.conn();
	defer conn.deinit();

	_ = try conn.exec("create table x (a integer)", .{});

	{
		var appender = try conn.appender(null, "x");
		defer appender.deinit();

		try appender.appendRow(.{0});

		appender.beginRow();
		try appender.appendValue(1, 0);
		try appender.endRow();

		try appender.flush();

		for (2..5000) |i| {
			appender.beginRow();
			try appender.appendValue(i, 0);
			try appender.endRow();
		}

		try appender.appendRow(.{5000});

		appender.beginRow();
		try appender.appendValue(5001, 0);
		try appender.endRow();

		try appender.flush();
	}

	var rows = try conn.query("select * from x order by a", .{});
	defer rows.deinit();

	var i: i32 = 0;
	while (try rows.next()) |row| {
		try t.expectEqual(i, row.get(i32, 0));
		i += 1;
	}
	try t.expectEqual(5002, i);
}

test "Appender: hugeint" {
	const db = try DB.init(t.allocator, ":memory:", .{});
	defer db.deinit();

	var conn = try db.conn();
	defer conn.deinit();

	_ = try conn.exec("create table x (a hugeint)", .{});

	const COUNT = 1000;
	var expected: [COUNT]i128 = undefined;
	{
		var seed: u64 = undefined;
		std.posix.getrandom(std.mem.asBytes(&seed)) catch unreachable;
		var prng = std.rand.DefaultPrng.init(seed);

		const random = prng.random();

		var appender = try conn.appender(null, "x");
		defer appender.deinit();

		for (0..COUNT) |i| {
			const value = random.int(i128);
			expected[i] = value;
			try appender.appendRow(.{value});
		}
		try appender.flush();
	}

	var rows = try conn.query("select * from x", .{});
	defer rows.deinit();

	var i: i32 = 0;
	while (try rows.next()) |row| {
		try t.expectEqual(expected[@intCast(i)], row.get(i128, 0));
		i += 1;
	}
	try t.expectEqual(COUNT, i);
}

test "Appender: decimal" {
	const db = try DB.init(t.allocator, ":memory:", .{});
	defer db.deinit();

	var conn = try db.conn();
	defer conn.deinit();

	_ = try conn.exec("create table appdec (id integer, d decimal(8, 4))", .{});

	{
		var appender = try conn.appender(null, "appdec");
		defer appender.deinit();
		try appender.appendRow(.{1, 12345678});
		try appender.flush();

		var row = (try conn.row("select d from appdec where id = 1", .{})).?;
		defer row.deinit();
		try t.expectEqual(1234.5678, row.get(f64, 0));
	}

	{
		var appender = try conn.appender(null, "appdec");
		defer appender.deinit();
		try appender.appendRow(.{2, 5323.224});
		try appender.flush();

		var row = (try conn.row("select d from appdec where id = 2", .{})).?;
		defer row.deinit();
		try t.expectEqual(5323.224, row.get(f64, 0));
	}
}

test "Appender: decimal fuzz" {
	const db = try DB.init(t.allocator, ":memory:", .{});
	defer db.deinit();

	var conn = try db.conn();
	defer conn.deinit();

	_ = try conn.exec("create table appdec (d1 decimal(3, 1), d2 decimal(9, 3), d3 decimal(17, 5), d4 decimal(30, 10))", .{});

	const COUNT = 1000;
	var expected_i16: [COUNT]f64 = undefined;
	var expected_i32: [COUNT]f64 = undefined;
	var expected_i64: [COUNT]f64 = undefined;
	var expected_i128: [COUNT]f64 = undefined;
	{
		var seed: u64 = undefined;
		std.posix.getrandom(std.mem.asBytes(&seed)) catch unreachable;
		var prng = std.rand.DefaultPrng.init(seed);
		const random = prng.random();

		var appender = try conn.appender(null, "appdec");
		defer appender.deinit();

		for (0..COUNT) |i| {
			const d1 = @trunc(random.float(f64) * 100) / 10;
			expected_i16[i] = d1;
			const d2 = @trunc(random.float(f64) * 100000000) / 1000;
			expected_i32[i] = d2;
			const d3 = @trunc(random.float(f64) * 10000000000000000) / 100000;
			expected_i64[i] = d3;
			const d4 = @trunc(random.float(f64) * 100000000000000000000000000000) / 10000000000;
			expected_i128[i] = d4;

			try appender.appendRow(.{d1, d2, d3, d4});
		}
		try appender.flush();
	}

	var rows = try conn.query("select * from appdec", .{});
	defer rows.deinit();

	var i: i32 = 0;
	while (try rows.next()) |row| {
		try t. expectApproxEqRel(expected_i16[@intCast(i)], row.get(f64, 0), 0.01);
		try t. expectApproxEqRel(expected_i32[@intCast(i)], row.get(f64, 1), 0.001);
		try t. expectApproxEqRel(expected_i64[@intCast(i)], row.get(f64, 2), 0.00001);
		try t. expectApproxEqRel(expected_i128[@intCast(i)], row.get(f64, 3), 0.0000000001);
		i += 1;
	}
	try t.expectEqual(COUNT, i);
}

test "Appender: list" {
	const db = try DB.init(t.allocator, ":memory:", .{});
	defer db.deinit();

	var conn = try db.conn();
	defer conn.deinit();

	_ = try conn.exec(
		\\ create table applist (
		\\  id integer,
		\\  col_tinyint tinyint[],
		\\  col_smallint smallint[],
		\\  col_integer integer[],
		\\  col_bigint bigint[],
		\\  col_hugeint hugeint[],
		\\  col_utinyint utinyint[],
		\\  col_usmallint usmallint[],
		\\  col_uinteger uinteger[],
		\\  col_ubigint ubigint[],
		\\  col_uhugeint uhugeint[],
		\\  col_real real[],
		\\  col_double double[],
		\\  col_bool bool[],
		\\  col_text text[]
		\\ )
	, .{});

	{
		var appender = try conn.appender(null, "applist");
		defer appender.deinit();

		try appender.appendRow(.{
			1,
			&[_]i8{-128, 0, 100, 127},
			&[_]i16{-32768, 0, -299, 32767},
			&[_]i32{-2147483648, -4933, 0, 2147483647},
			&[_]i64{-9223372036854775808, -8223372036854775800, 0, 9223372036854775807},
			&[_]i128{-170141183460469231731687303715884105728, -1, 2, 170141183460469231731687303715884105727},
			&[_]u8{0, 200, 255},
			&[_]u16{0, 65535},
			&[_]u32{0, 4294967294, 4294967295},
			&[_]u64{0, 18446744073709551615},
			&[_]u128{0, 99999999999999999999998, 340282366920938463463374607431768211455},
			&[_]f32{-1.0, 3.44, 0.0, 99.9991},
			&[_]f64{-1.02, 9999.1303, 0.0, -8288133.11},
			&[_]bool{true, false, true, true, false},
			&[_][]const u8{"hello", "world"}
		});
		try appender.appendRow(.{2, null, null, null, null, null, null, null, null, null, null, null});
		try appender.flush();

		{
			var row = (try conn.row("select * from applist where id = 1", .{})).?;
			defer row.deinit();

			try assertList(&[_]i8{-128, 0, 100, 127}, row.list(i8, 1).?);
			try assertList(&[_]i16{-32768, 0, -299, 32767}, row.list(i16, 2).?);
			try assertList(&[_]i32{-2147483648, -4933, 0, 2147483647}, row.list(i32, 3).?);
			try assertList(&[_]i64{-9223372036854775808, -8223372036854775800, 0, 9223372036854775807}, row.list(i64, 4).?);
			try assertList(&[_]i128{-170141183460469231731687303715884105728, -1, 2, 170141183460469231731687303715884105727}, row.list(i128, 5).?);
			try assertList(&[_]u8{0, 200, 255}, row.list(u8, 6).?);
			try assertList(&[_]u16{0, 65535}, row.list(u16, 7).?);
			try assertList(&[_]u32{0, 4294967294, 4294967295}, row.list(u32, 8).?);
			try assertList(&[_]u64{0, 18446744073709551615}, row.list(u64, 9).?);
			try assertList(&[_]u128{0, 99999999999999999999998, 340282366920938463463374607431768211455}, row.list(u128, 10).?);
			try assertList(&[_]f32{-1.0, 3.44, 0.0, 99.9991}, row.list(f32, 11).?);
			try assertList(&[_]f64{-1.02, 9999.1303, 0.0, -8288133.11}, row.list(f64, 12).?);
			try assertList(&[_]bool{true, false, true, true, false}, row.list(bool, 13).?);

			const list_texts = row.list([]u8, 14).?;
			try t.expectEqualStrings("hello", list_texts.get(0));
			try t.expectEqualStrings("world", list_texts.get(1));
		}

		{
			var row = (try conn.row("select * from applist where id = 2", .{})).?;
			defer row.deinit();
			try t.expectEqual(null, row.list(?i8, 1));
			try t.expectEqual(null, row.list(?i16, 2));
			try t.expectEqual(null, row.list(?i32, 3));
			try t.expectEqual(null, row.list(?i64, 4));
			try t.expectEqual(null, row.list(?i128, 5));
			try t.expectEqual(null, row.list(?u8, 6));
			try t.expectEqual(null, row.list(?u16, 7));
			try t.expectEqual(null, row.list(?u32, 8));
			try t.expectEqual(null, row.list(?u64, 9));
			try t.expectEqual(null, row.list(?u128, 10));
			try t.expectEqual(null, row.list(?[]const u8, 11));
		}
	}
}

fn assertList(expected: anytype, actual: anytype) !void {
	try t.expectEqual(expected.len, actual.len);
	for (expected, 0..) |e, i| {
		try t.expectEqual(e, actual.get(i));
	}
}

// test "Appender: enum" {
// 	const db = try DB.init(t.allocator, ":memory:", .{});
// 	defer db.deinit();

// 	var conn = try db.conn();
// 	defer conn.deinit();

// 	_ = try conn.exec("create type my_enum as enum ('a', 'b', 'ddddd')", .{});
// 	_ = try conn.exec("create table xx (col_enum my_enum)", .{});
// 	var appender = try conn.appender(null, "xx");
// 	defer appender.deinit();
// }

// const size = c.duckdb_enum_dictionary_size(logical_type);
// const values = try allocator.alloc([*c]u8, size);
// defer allocator.free(values);
// const total = c.duckdb_enum_values(logical_type, values.ptr, values.len);
// std.debug.print("{d}\n", .{total});
// for (0..total) |i| {
// 	std.debug.print("{d} {s}\n", .{i, std.mem.span(values[i])});
// 	c.duckdb_free(values[i]);
// }
