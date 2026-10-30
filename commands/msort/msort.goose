// msort in Goose.
//
// The input buffer owns every line. Sorting moves only fixed-size line spans,
// and field keys are compared as slices into the original buffer.

import std;
import os;

const TEXT = 0;
const TEXT_REVERSE = 1;
const NUMBER = 2;
const NUMBER_REVERSE = 3;

struct KeyField {
    field: i64,
    range_end: i64, // 0 means a single field.
    kind: i64,
}

struct Line {
    start: i64,
    end: i64,
}

struct Span {
    start: i64,
    end: i64,
    ok: bool,
}

struct FastLine {
    start: i64,
    end: i64,
    key1_start: i64,
    key1_end: i64,
    key2_start: i64,
    key2_end: i64,
    number1: f64,
    number2: f64,
}

struct RadixItem {
    order: u64,
    index: i64,
}

fn usage() {
    write_stderr("Usage   : msort key=<key> <file>\nOptions : -e\n          -s<c>\n          -p<n>\nVersion : Tue Jan 12 23:04:38 JST 2021\nEdition : 5\n");
}

fn fail(message: u8[:]) {
    write_stderr(message);
    write_stderr("\n");
    exit(1);
}

fn msort_is_space(c: u8) -> bool { c == ' ' || c == '\t' }

fn has_prefix(s: u8[:], prefix: u8[:]) -> bool {
    s.len >= prefix.len && s[..prefix.len] == prefix
}

fn ends_with(s: u8[:], suffix: u8[:]) -> bool {
    s.len >= suffix.len && s[s.len - suffix.len..] == suffix
}

fn find_byte(s: u8[:], needle: u8) -> i64 {
    for i in s.len { if s[i] == needle { return i; } }
    return -1;
}

fn parse_key_field(token: u8[:]) -> KeyField, bool {
    var body_end = token.len;
    var kind = TEXT;

    if ends_with(token, "nr") || ends_with(token, "rn") {
        body_end -= 2;
        kind = NUMBER_REVERSE;
    } else if ends_with(token, "N") {
        body_end--;
        kind = NUMBER_REVERSE;
    } else if ends_with(token, "r") {
        body_end--;
        kind = TEXT_REVERSE;
    } else if ends_with(token, "n") {
        body_end--;
        kind = NUMBER;
    }

    let body = token[..body_end];
    if body == "NF" {
        return KeyField { field: -1, range_end: 0, kind: kind }, true;
    }
    if has_prefix(body, "NF-") {
        let offset, ok = parse_int(body[3..]);
        if !ok || offset < 0 {
            return KeyField { field: 0, range_end: 0, kind: kind }, false;
        }
        return KeyField { field: -1 - offset, range_end: 0, kind: kind }, true;
    }
    let field, ok = parse_int(body);
    if !ok || field <= 0 {
        return KeyField { field: 0, range_end: 0, kind: kind }, false;
    }
    return KeyField { field: field, range_end: 0, kind: kind }, true;
}

fn append_key_segment(segment: u8[:], keys: KeyField[>..]&) -> bool {
    let slash = find_byte(segment, '/');
    if slash >= 0 {
        if find_byte(segment[slash + 1..], '/') >= 0 { return false; }
        let first, first_ok = parse_key_field(segment[..slash]);
        let last, last_ok = parse_key_field(segment[slash + 1..]);
        if !first_ok || !last_ok { return false; }
        keys.push(KeyField { field: first.field, range_end: last.field, kind: first.kind });
        return true;
    }
    let field, ok = parse_key_field(segment);
    if !ok { return false; }
    keys.push(field);
    return true;
}

fn parse_key_spec(text: u8[:], keys: KeyField[>..]&) -> bool {
    keys.clear();
    var start = 0;
    var i = 0;
    while i <= text.len {
        if i == text.len || text[i] == '@' {
            if !append_key_segment(text[start..i], keys) {
                keys.clear();
                return false;
            }
            start = i + 1;
        }
        i++;
    }
    return keys.len > 0;
}

fn resolve_field(field: i64, field_count: i64) -> i64 {
    if field >= 0 { return field; }
    let offset = -1 - field;
    if field_count > offset { field_count - offset } else { 1 }
}

fn count_fields(data: u8[:], line: Line) -> i64 {
    var count = 0;
    var i = line.start;
    while i < line.end {
        while i < line.end && msort_is_space(data[i]) { i++; }
        if i >= line.end { break; }
        count++;
        while i < line.end && !msort_is_space(data[i]) { i++; }
    }
    return count;
}

fn field_span(data: u8[:], line: Line, wanted: i64) -> Span {
    if wanted <= 0 { return Span { start: 0, end: 0, ok: false }; }
    var count = 0;
    var i = line.start;
    while i < line.end {
        while i < line.end && msort_is_space(data[i]) { i++; }
        if i >= line.end { break; }
        let start = i;
        while i < line.end && !msort_is_space(data[i]) { i++; }
        count++;
        if count == wanted { return Span { start: start, end: i, ok: true }; }
    }
    return Span { start: 0, end: 0, ok: false };
}

// Find both absolute fast-path fields in a single scan of the line.
fn fast_field_spans(data: u8[:], line: Line, first_wanted: i64,
                    second_wanted: i64, has_second: bool) -> Span, Span {
    var first = Span { start: 0, end: 0, ok: false };
    var second = Span { start: 0, end: 0, ok: false };
    var count = 0;
    var i = line.start;
    while i < line.end {
        while i < line.end && msort_is_space(data[i]) { i++; }
        if i >= line.end { break; }
        let start = i;
        while i < line.end && !msort_is_space(data[i]) { i++; }
        count++;
        if count == first_wanted {
            first = Span { start: start, end: i, ok: true };
        }
        if has_second && count == second_wanted {
            second = Span { start: start, end: i, ok: true };
        }
        if first.ok && (!has_second || second.ok) { break; }
    }
    return first, second;
}

fn append_escaped(out: u8[>..]&, s: u8[:], escape_char: u8) {
    var i = 0;
    while i < s.len {
        let c = s[i];
        if c == escape_char {
            out.push(' ');
        } else if c == '\\' && i + 1 < s.len {
            let n = s[i + 1];
            if n == '0' { out.push(0); i++; }
            else if n == 't' { out.push('\t'); i++; }
            else if n == 'n' { out.push('\n'); i++; }
            else if n == 'r' { out.push('\r'); i++; }
            else if n == '_' { out.push('_'); i++; }
            else if n == '\\' { out.push('\\'); i++; }
            else { out.push(c); }
        } else {
            out.push(c);
        }
        i++;
    }
}

fn compare_spans(data: u8[:], a: Span, b: Span, kind: i64,
                 escape_enabled: bool, escape_char: u8) -> i64 {
    let av = if a.ok { data[a.start..a.end] } else { data[0..0] };
    let bv = if b.ok { data[b.start..b.end] } else { data[0..0] };
    var result = 0;

    if escape_enabled {
        var ae: u8[>..] = [];
        var be: u8[>..] = [];
        append_escaped(ae, av, escape_char);
        append_escaped(be, bv, escape_char);
        if kind == NUMBER || kind == NUMBER_REVERSE {
            let an, _ = parse_flt(ae);
            let bn, _ = parse_flt(be);
            result = if an < bn { -1 } else if an > bn { 1 } else { 0 };
        } else {
            result = compare(ae, be);
        }
    } else if kind == NUMBER || kind == NUMBER_REVERSE {
        let an, _ = parse_flt(av);
        let bn, _ = parse_flt(bv);
        result = if an < bn { -1 } else if an > bn { 1 } else { 0 };
    } else {
        result = compare(av, bv);
    }

    if kind == TEXT_REVERSE || kind == NUMBER_REVERSE { -result } else { result }
}

fn compare_fast_key(data: u8[:], a_start: i64, a_end: i64, a_number: f64,
                    b_start: i64, b_end: i64, b_number: f64, kind: i64) -> i64 {
    var result = 0;
    if kind == NUMBER || kind == NUMBER_REVERSE {
        result = if a_number < b_number { -1 } else if a_number > b_number { 1 } else { 0 };
    } else {
        result = compare(data[a_start..a_end], data[b_start..b_end]);
    }
    if kind == TEXT_REVERSE || kind == NUMBER_REVERSE { -result } else { result }
}

fn compare_fast_lines(data: u8[:], first_kind: i64, second_kind: i64,
                      has_second: bool, a: FastLine, b: FastLine) -> i64 {
    let first = compare_fast_key(data, a.key1_start, a.key1_end, a.number1,
                                 b.key1_start, b.key1_end, b.number1, first_kind);
    if first != 0 { return first; }
    if !has_second { return 0; }
    compare_fast_key(data, a.key2_start, a.key2_end, a.number2,
                     b.key2_start, b.key2_end, b.number2, second_kind)
}

// The bits of a double, without a C helper or an allocation that escapes.
inline fn f64_bits(value: f64) -> u64 {
    let values: f64[1] = [value];
    let bytes = bytes_of(values);
    return bytes[0] | (bytes[1] as u64) << 8 | (bytes[2] as u64) << 16 |
        (bytes[3] as u64) << 24 | (bytes[4] as u64) << 32 |
        (bytes[5] as u64) << 40 | (bytes[6] as u64) << 48 |
        (bytes[7] as u64) << 56;
}

// Convert a non-NaN f64 to a key whose unsigned order is its numeric order.
// Numeric comparison treats -0.0 and +0.0 as equal, so both map to one key.
inline fn numeric_order(value: f64) -> u64 {
    var bits = if value == 0.0 { 0 as u64 } else { f64_bits(value) };
    if bits >> 63 == 1 { return bits ^ 0xffffffffffffffff; }
    return bits ^ 0x8000000000000000;
}

// The first eight bytes as a big-endian abbreviated lexicographic key.
// Missing bytes are zero. That can create extra ties (short string vs NUL),
// but never reverses the byte-string order; equal prefixes are resolved below.
inline fn text_order(data: u8[:], span: Span) -> u64, bool {
    var value: u64 = 0;
    var complete = span.end - span.start <= 8;
    for offset in 8 {
        value <<= 8;
        let at = span.start + offset;
        if at < span.end {
            let byte = data[at];
            value |= byte;
            if byte == 0 { complete = false; }
        }
    }
    return value, complete;
}

inline fn fast_order(data: u8[:], span: Span, number: f64, kind: i64) -> u64, bool {
    var value: u64 = 0;
    var complete = true;
    if kind == NUMBER || kind == NUMBER_REVERSE {
        value = numeric_order(number);
    } else {
        value, complete = text_order(data, span);
    }
    if kind == TEXT_REVERSE || kind == NUMBER_REVERSE {
        value ^= 0xffffffffffffffff;
    }
    return value, complete;
}

// Stable four-pass LSD radix over 16-bit digits. Only compact indices move;
// the line spans and parsed keys stay in their original contiguous storage.
fn radix_pass(source: RadixItem[:], destination: RadixItem[:],
              counts: i64[:], shift: i64) {
    fill(counts, 0);
    for item in source {
        let digit = ((item.order >> shift) & 65535) as i64;
        counts[digit]++;
    }
    var position = 0;
    for bucket in counts.len {
        let count = counts[bucket];
        counts[bucket] = position;
        position += count;
    }
    for item in source {
        let digit = ((item.order >> shift) & 65535) as i64;
        let at = counts[digit];
        destination[at] = item;
        counts[digit] = at + 1;
    }
}

fn radix_order(indices: i64[:], orders: u64[:]) {
    if indices.len < 2 { return; }
    var items: RadixItem[..] = [..indices.len];
    for index in indices { items.push(RadixItem { order: orders[index], index: index }); }
    var temporary: RadixItem[>..] = [];
    temporary.resize(indices.len, RadixItem { order: 0, index: 0 });
    var counts: i64[>..] = [];
    counts.resize(65536, 0);

    var differing: u64 = 0;
    let first = items[0].order;
    for item in items[1..] { differing |= item.order ^ first; }
    var in_items = true;
    for pass in 4 {
        let shift = pass * 16;
        if ((differing >> shift) & 65535) == 0 { continue; }
        if in_items {
            radix_pass(items, temporary, counts, shift);
        } else {
            radix_pass(temporary, items, counts, shift);
        }
        in_items = !in_items;
    }
    if in_items {
        for i in indices.len { indices[i] = items[i].index; }
    } else {
        for i in indices.len { indices[i] = temporary[i].index; }
    }
}

// Sort one key stably. Numeric order keys are complete. Text keys are an
// abbreviation, so only equal-prefix runs need the full byte comparison.
fn radix_fast_key(data: u8[:], indices: i64[:], decorated: FastLine[:],
                  orders: u64[:], kind: i64, second: bool, complete: bool) {
    if indices.len < 2 { return; }
    var varied = false;
    let first = orders[indices[0]];
    for index in indices[1..] {
        if orders[index] != first { varied = true; break; }
    }
    if varied { radix_order(indices, orders); }
    if kind == NUMBER || kind == NUMBER_REVERSE || complete { return; }

    var start = 0;
    while start < indices.len {
        let prefix = orders[indices[start]];
        var end = start + 1;
        while end < indices.len && orders[indices[end]] == prefix {
            end++;
        }
        if end - start > 1 {
            stable_sort(indices[start..end]) { a, b =>
                let left = decorated[a];
                let right = decorated[b];
                if second {
                    compare_fast_key(data, left.key2_start, left.key2_end, left.number2,
                                     right.key2_start, right.key2_end, right.number2, kind) < 0
                } else {
                    compare_fast_key(data, left.key1_start, left.key1_end, left.number1,
                                     right.key1_start, right.key1_end, right.number1, kind) < 0
                }
            };
        }
        start = end;
    }
}

fn try_fast_sort(data: u8[:], lines: Line[>..]&, keys: KeyField[:],
                 escape_enabled: bool) -> bool {
    if escape_enabled || keys.len < 1 || keys.len > 2 { return false; }
    for key in keys {
        if key.range_end != 0 || key.field <= 0 { return false; }
    }

    let has_second = keys.len == 2;
    let first_kind = keys[0].kind;
    let second_kind = if has_second { keys[1].kind } else { TEXT };
    var decorated: FastLine[..] = [..lines.len];
    var first_orders: u64[..] = [..lines.len];
    var second_orders: u64[..] = [..lines.len];
    var first_complete = true;
    var second_complete = true;
    var has_nan = false;
    for line in lines {
        let second_field = if has_second { keys[1].field } else { 0 };
        let first, second = fast_field_spans(data, line, keys[0].field,
                                             second_field, has_second);
        if !first.ok || (has_second && !second.ok) {
            fail("Error(2408)[msort] : not enough fields.");
        }
        var first_number = 0.0;
        if first_kind == NUMBER || first_kind == NUMBER_REVERSE {
            let value, ok = parse_flt(data[first.start..first.end]);
            if !ok {
                var message: u8[>..] = [];
                format(message, "Error(2565)[msort] : invalid numeric field: ",
                       data[first.start..first.end]);
                fail(message);
            }
            first_number = value;
            if value != value { has_nan = true; }
        }

        var second_number = 0.0;
        if has_second {
            if second_kind == NUMBER || second_kind == NUMBER_REVERSE {
                let value, ok = parse_flt(data[second.start..second.end]);
                if !ok {
                    var message: u8[>..] = [];
                    format(message, "Error(2565)[msort] : invalid numeric field: ",
                           data[second.start..second.end]);
                    fail(message);
                }
                second_number = value;
                if value != value { has_nan = true; }
            }
        }
        decorated.push(FastLine {
            start: line.start,
            end: line.end,
            key1_start: first.start,
            key1_end: first.end,
            key2_start: second.start,
            key2_end: second.end,
            number1: first_number,
            number2: second_number,
        });
        let first_order, first_is_complete = fast_order(data, first, first_number, first_kind);
        first_orders.push(first_order);
        if !first_is_complete { first_complete = false; }
        if has_second {
            let second_order, second_is_complete = fast_order(data, second, second_number, second_kind);
            second_orders.push(second_order);
            if !second_is_complete { second_complete = false; }
        }
    }

    // Small inputs benefit from the standard library's natural merge sort.
    // NaN compares equal to every number in the established command contract,
    // which is not a radix total order, so it stays on the comparator path.
    if decorated.len < 4096 || has_nan {
        stable_sort(decorated) { a, b =>
            compare_fast_lines(data, first_kind, second_kind, has_second, a, b) < 0
        };
        for i in lines.len {
            lines[i] = Line { start: decorated[i].start, end: decorated[i].end };
        }
        return true;
    }

    var indices: i64[..] = [..decorated.len];
    for i in decorated.len { indices.push(i); }
    if has_second {
        radix_fast_key(data, indices, decorated, second_orders, second_kind, true,
                       second_complete);
    }
    radix_fast_key(data, indices, decorated, first_orders, first_kind, false,
                   first_complete);
    for i in lines.len {
        let index = indices[i];
        lines[i] = Line { start: decorated[index].start, end: decorated[index].end };
    }
    return true;
}

fn compare_lines(data: u8[:], keys: KeyField[:], a: Line, b: Line,
                 escape_enabled: bool, escape_char: u8) -> i64 {
    let an = count_fields(data, a);
    let bn = count_fields(data, b);
    for key in keys {
        if key.range_end == 0 {
            let af = resolve_field(key.field, an);
            let bf = resolve_field(key.field, bn);
            let result = compare_spans(data, field_span(data, a, af), field_span(data, b, bf),
                                       key.kind, escape_enabled, escape_char);
            if result != 0 { return result; }
        } else {
            let a_start = resolve_field(key.field, an);
            let a_end = resolve_field(key.range_end, an);
            let b_start = resolve_field(key.field, bn);
            let b_end = resolve_field(key.range_end, bn);
            let ac = if a_end >= a_start { a_end - a_start + 1 } else { 0 };
            let bc = if b_end >= b_start { b_end - b_start + 1 } else { 0 };
            let count = if ac > bc { ac } else { bc };
            for i in count {
                let left = if i < ac { field_span(data, a, a_start + i) }
                           else { Span { start: 0, end: 0, ok: false } };
                let right = if i < bc { field_span(data, b, b_start + i) }
                            else { Span { start: 0, end: 0, ok: false } };
                let actual_kind = if i < ac { key.kind } else { TEXT };
                let result = compare_spans(data, left, right, actual_kind,
                                           escape_enabled, escape_char);
                if result != 0 { return result; }
            }
        }
    }
    return 0;
}

fn numeric_ok(raw: u8[:], escape_enabled: bool, escape_char: u8) -> bool {
    if !escape_enabled {
        let _, ok = parse_flt(raw);
        return ok;
    }
    var escaped: u8[>..] = [];
    append_escaped(escaped, raw, escape_char);
    let _, ok = parse_flt(escaped);
    return ok;
}

fn validate(data: u8[:], lines: Line[:], keys: KeyField[:],
            escape_enabled: bool, escape_char: u8) {
    for line in lines {
        let nf = count_fields(data, line);
        for key in keys {
            let start = resolve_field(key.field, nf);
            let finish = if key.range_end == 0 { start } else { resolve_field(key.range_end, nf) };
            if finish >= start {
                for field in start..finish + 1 {
                    let span = field_span(data, line, field);
                    if !span.ok { fail("Error(2408)[msort] : not enough fields."); }
                    if key.kind == NUMBER || key.kind == NUMBER_REVERSE {
                        let raw = data[span.start..span.end];
                        if !numeric_ok(raw, escape_enabled, escape_char) {
                            var message: u8[>..] = [];
                            format(message, "Error(2565)[msort] : invalid numeric field: ", raw);
                            fail(message);
                        }
                    }
                }
            }
        }
    }
}

fn main() {
    if arg_count() <= 1 { usage(); exit(1); }

    var keys: KeyField[>..] = [];
    var input_path: u8[>..] = [];
    input_path.append("-");
    var saw_key = false;
    var valid_key = false;
    var escape_enabled = false;
    var escape_char = '_' as u8;

    for index in 1..arg_count() {
        var value: u8[>..] = [];
        arg(index, value);
        if has_prefix(value, "key=") {
            saw_key = true;
            valid_key = parse_key_spec(value[4..], keys);
        } else if value == "-e" {
            escape_enabled = true;
        } else if has_prefix(value, "-s") && value.len >= 3 {
            escape_char = value[2];
        } else if has_prefix(value, "-p") && value.len >= 3 {
            let parallel, ok = parse_int(value[2..]);
            if !ok || parallel <= 0 { usage(); exit(1); }
        } else if value == "--help" {
            usage();
            exit(1);
        } else if value.len > 1 && value[0] == '-' {
            usage();
            exit(1);
        } else {
            input_path.clear();
            input_path.append(value);
        }
    }

    if !saw_key { usage(); exit(1); }

    var data: u8[>..] = [];
    if input_path == "-" {
        read_stdin(data);
    } else if !read_file(input_path, data) {
        var message: u8[>..] = [];
        format(message, "Error(6453)[msort] : file '", input_path, "' not found.");
        fail(message);
    }
    if data.len > 0 && data[data.len - 1] != '\n' {
        fail("Error(10255)[msort] : map_file: missing final '\\n'.");
    }

    var lines: Line[>..] = [];
    var start = 0;
    for i in data.len {
        if data[i] == '\n' {
            lines.push(Line { start: start, end: i });
            start = i + 1;
        }
    }

    if !valid_key {
        if lines.len == 0 { return; }
        fail("Error(1692)[msort] : invalid key value.");
    }

    if !try_fast_sort(data, lines, keys, escape_enabled) {
        validate(data, lines, keys, escape_enabled, escape_char);
        stable_sort(lines) { a, b =>
            compare_lines(data, keys, a, b, escape_enabled, escape_char) < 0
        };
    }

    var output: u8[..] = [..data.len];
    for line in lines {
        output.append(data[line.start..line.end]);
        output.push('\n');
    }
    write_stdout(output);
}
