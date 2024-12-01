// Import necessary modules from the Zig standard library.
const std = @import("std");

// Import built-in features of Zig.
const builtin = @import("builtin");

// Import a custom module for metadata handling.
const Metadata = @import("Metadata.zig");

// Import C functions and types from the "expat" XML parsing library.
const c = @cImport({
    @cInclude("expat.h");
});

// Define a structure to hold user data passed to the XML parser.
const Userdata = struct {
    points_out: std.io.AnyWriter, // A writer to output parsed points (latitude/longitude).
    metadata: Metadata = .{},    // Metadata to track bounds of parsed coordinates.
    num_nodes: u64 = 0,          // Counter for the number of nodes parsed.
};

// Callback function to handle the start of an XML element.
// This is invoked by the XML parser when a new element begins.
fn startElement(ctx: ?*anyopaque, name_c: [*c]const c.XML_Char, attrs: [*c][*c]const c.XML_Char) callconv(.C) void {
    // Retrieve the user data from the parser context.
    const user_data: *Userdata = @ptrCast(@alignCast(ctx));

    // Convert the element name from a C-style string to a Zig slice.
    const name = std.mem.span(name_c);

    // Only process "node" elements, skip others.
    if (!std.mem.eql(u8, name, "node")) {
        return;
    }

    // Variables to store optional latitude and longitude values.
    var i: usize = 0;
    var lat_opt: ?[]const u8 = null;
    var lon_opt: ?[]const u8 = null;

    // Iterate over the attributes of the "node" element.
    while (true) {
        if (attrs[i] == null) {
            break;
        }
        defer i += 2; // Move to the next attribute pair (name-value).

        // Extract the attribute name and value.
        const field_name = std.mem.span(attrs[i]);
        const field_val = std.mem.span(attrs[i + 1]);

        // Match the attribute name to "lat" or "lon" and store the value.
        if (std.mem.eql(u8, field_name, "lat")) {
            lat_opt = field_val;
        } else if (std.mem.eql(u8, field_name, "lon")) {
            lon_opt = field_val;
        }
    }

    // Ensure both latitude and longitude are present; otherwise, skip.
    const lat_s = lat_opt orelse return;
    const lon_s = lon_opt orelse return;

    // Parse latitude and longitude strings into floating-point numbers.
    const lat = std.fmt.parseFloat(f32, lat_s) catch return;
    const lon = std.fmt.parseFloat(f32, lon_s) catch return;

    // Update the metadata bounds with the new latitude and longitude values.
    user_data.metadata.max_lon = @max(lon, user_data.metadata.max_lon);
    user_data.metadata.min_lon = @min(lon, user_data.metadata.min_lon);
    user_data.metadata.max_lat = @max(lat, user_data.metadata.max_lat);
    user_data.metadata.min_lat = @min(lat, user_data.metadata.min_lat);

    // Assert the system is using little-endian byte order.
    std.debug.assert(builtin.cpu.arch.endian() == .little);

    // Write longitude and latitude to the output writer in binary format.
    user_data.points_out.writeAll(std.mem.asBytes(&lon)) catch unreachable;
    user_data.points_out.writeAll(std.mem.asBytes(&lat)) catch unreachable;
}

// The entry point of the program.
pub fn main() !void {
    // Create an XML parser instance.
    const parser = c.XML_ParserCreate(null);
    defer c.XML_ParserFree(parser); // Free the parser when the program exits.

    // Initialize a general-purpose allocator.
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const alloc = gpa.allocator();

    // Parse command-line arguments.v
    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    // Open the output file for points.
    const out_f = try std.fs.cwd().createFile(args[2], .{});
    var points_out_buf_writer = std.io.bufferedWriter(out_f.writer());
    defer points_out_buf_writer.flush() catch unreachable;

    const points_out_writer = points_out_buf_writer.writer().any();

    // Open the output file for metadata.
    const metadata_out_f = try std.fs.cwd().createFile(args[3], .{});

    // Open the input XML file.
    const f = try std.fs.cwd().openFile(args[1], .{});
    defer f.close();

    // Set up a buffered reader for the input file.
    var buffered_reader = std.io.bufferedReader(f.reader());

    // Ensure the XML parser was created successfully.
    if (parser == null) {
        return error.NoParser;
    }

    // Set up user data for the XML parser.
    var userdata = Userdata{
        .points_out = points_out_writer,
    };

    c.XML_SetUserData(parser, &userdata);
    c.XML_SetElementHandler(parser, startElement, null);

    // Parse the XML file in chunks.
    while (true) {
        const buf_size = 4096; // Size of each read buffer.
        const buf = c.XML_GetBuffer(parser, buf_size);
        if (buf == null) {
            return error.NoBuffer;
        }

        // Read data into the parser's buffer.
        const buf_u8: [*]u8 = @ptrCast(buf);
        const buf_slice = buf_u8[0..buf_size];
        const read_data_len = try buffered_reader.read(buf_slice);

        // Stop reading if end of file is reached.
        if (read_data_len == 0) {
            break;
        }

        // Parse the buffer content.
        const parse_ret = c.XML_ParseBuffer(parser, @intCast(read_data_len), 0);
        if (parse_ret == c.XML_STATUS_ERROR) {
            return error.ParseError;
        }
    }

    // Write metadata as JSON to the metadata output file.
    try std.json.stringify(userdata.metadata, .{}, metadata_out_f.writer());
}
