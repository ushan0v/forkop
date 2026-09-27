#!/usr/bin/env ucode

let fs = require("fs");
let uci_core = require("core.uci");

const CONFIG_NAME = getenv("FORKOP_CONFIG_NAME") || "forkop";

function as_string(value) {
    return value == null ? "" : "" + value;
}

function read_stdin() {
    let input = fs.open("/dev/stdin", "r");
    if (!input)
        return "";
    let data = input.read("all");
    input.close();
    return data == null ? "" : data;
}

function hex_digit_value(value) {
    let pos = index("0123456789abcdef", lc(as_string(value)));
    return pos >= 0 ? pos : null;
}

function parse_number(value) {
    value = lc(trim(as_string(value)));
    if (value == "")
        return null;

    if (substr(value, 0, 2) == "0x") {
        value = substr(value, 2);
        if (value == "")
            return null;

        let result = 0;
        for (let i = 0; i < length(value); i++) {
            let digit = hex_digit_value(substr(value, i, 1));
            if (digit == null)
                return null;
            result = result * 16 + digit;
        }
        return result;
    }

    return match(value, /^[0-9]+$/) == null ? null : int(value);
}

function rule_rows() {
    let rows = [];

    for (let line in split(read_stdin(), "\n")) {
        line = replace(as_string(line), /\r/g, "");
        if (trim(line) == "")
            continue;

        let fields = split(line, "\t");
        push(rows, {
            section: as_string(fields[0]),
            enabled: as_string(fields[1]) == "1",
            action: as_string(fields[2])
        });
    }

    return rows;
}

function bool_value(value) {
    value = lc(as_string(value));
    return value == "1" || value == "true" || value == "yes" || value == "on";
}

function uci_rule_rows() {
    let rows = [];

    for (let section in uci_core.section_objects(CONFIG_NAME, "section")) {
        let enabled = section.enabled == null ? true : bool_value(section.enabled);
        push(rows, {
            section: as_string(section[".name"]),
            enabled,
            action: as_string(section.action)
        });
    }
    return rows;
}

function rows_for_source(source) {
    return source == "uci" ? uci_rule_rows() : rule_rows();
}

function action_rule_count_from_rows(rows, action) {
    let count = 0;
    action = as_string(action);

    for (let row in rows)
        if (row.enabled && row.action == action)
            count++;

    return count;
}

function action_rule_count(action, source) {
    print(action_rule_count_from_rows(rows_for_source(source), action), "\n");
}

function action_rule_index_from_rows(rows, action, target_section) {
    let index = 0;
    action = as_string(action);
    target_section = as_string(target_section);

    for (let row in rows) {
        if (!row.enabled || row.action != action)
            continue;

        index++;
        if (row.section == target_section)
            return index;
    }

    return 0;
}

function action_rule_index(action, target_section, source) {
    print(action_rule_index_from_rows(rows_for_source(source), action, target_section), "\n");
}

function arithmetic_number(base_text, index_text, offset) {
    let base = parse_number(base_text);
    let index = parse_number(index_text);

    if (base == null || index == null)
        exit(1);

    return base + index + offset;
}

function mark_value(base_text, index_text) {
    print(arithmetic_number(base_text, index_text, 0), "\n");
}

function mark_hex(base_text, index_text) {
    print(sprintf("0x%08x", arithmetic_number(base_text, index_text, 0)), "\n");
}

function offset_number(base_text, index_text) {
    print(arithmetic_number(base_text, index_text, -1), "\n");
}

let mode = ARGV[0] || "";

if (mode == "count")
    action_rule_count(ARGV[1]);
else if (mode == "count-uci")
    action_rule_count(ARGV[1], "uci");
else if (mode == "index")
    action_rule_index(ARGV[1], ARGV[2]);
else if (mode == "index-uci")
    action_rule_index(ARGV[1], ARGV[2], "uci");
else if (mode == "has-enabled-uci")
    exit(action_rule_count_from_rows(uci_rule_rows(), ARGV[1]) > 0 ? 0 : 1);
else if (mode == "mark-value")
    mark_value(ARGV[1], ARGV[2]);
else if (mode == "mark-hex")
    mark_hex(ARGV[1], ARGV[2]);
else if (mode == "queue-number" || mode == "port-number")
    offset_number(ARGV[1], ARGV[2]);
else {
    warn("Usage: providers/rules.uc <count|index|mark-value|mark-hex|queue-number|port-number> ...\n");
    exit(1);
}
