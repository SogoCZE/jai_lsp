// This file contains code for running compiler for getting errors and warning.

reset_diagnostics :: () {
    if server.previously_errored_file {
        lsp_send(LSP_Client_Message(LSP_Publish_Diagnostics).{
            method="textDocument/publishDiagnostics",
            params = .{
                uri = server.previously_errored_file,
                diagnostics = LSP_Diagnostic.[]
            }
        });
    }
}

// Currently, parse only the first error (maybe parsing multiple errors is not that useful because Jai mostly report one error at a time)
// @TODO: Make it work with multiple errors
// @todo: add support for warnings
run_diagnostics :: () {
    if server.build_root.count == 0 return;
    build_root_absolute := join(server.project_root, server.build_root, separator="/");
    defer free(build_root_absolute);

    log("Running diagnostics %", build_root_absolute);

    command: [..] string;
    defer array_free(command);

    array_add(*command, "jai");
    array_add(*command, build_root_absolute, "-quiet", "-no_color", "-plug", "jails_diagnostics");

    // Use fast x64 backend on supported CPUs.
    if CPU == .X64 {
        array_add(*command, "-x64");
    }

    for local_module_folder: server.local_modules {
        array_add(*command, "-import_dir", local_module_folder);
    }

    array_add(*command, "---", "import_dir", server.diagnostics_metaprogram_path);

    reset_diagnostics();

    result, _, error := run_command(..command, working_directory=server.project_root, capture_and_return_output=true, timeout_ms=2500);
    if result.exit_code == 0 {
        return;
    }

    lines := split(error, "\n");
    defer array_free(lines);

    file: string;
    diagnostic: LSP_Diagnostic;

    ERROR_MARKER :: ": Error:";
    // Get the first error
    for output_line: lines {
        if !contains(output_line, ERROR_MARKER) continue;

        message_index := find_index_from_right(output_line, ERROR_MARKER);
        message := slice(output_line, message_index + ERROR_MARKER.count, output_line.count - message_index);
        rest := slice(output_line, 0, message_index);

        ok: bool;
        location: string;
        ok, file, location = split_from_right(rest, ":");
        if !ok continue;

        line_and_character := split(location, ",");
        if line_and_character.count < 2 continue;

        line, l_ok := parse_int(*line_and_character[0], u32);
        if !l_ok continue;

        character, c_ok := parse_int(*line_and_character[1], u32);
        if !c_ok continue;

        diagnostic.message = message;
        diagnostic.serverity = xx LSP_Diagnostic_Severity.ERROR;

        diagnostic.range.start.line = line-1;
        diagnostic.range.start.character = character-1;
    }

    highlight_found := false;
    highlighted_chars: u32;

    for line: lines {
        if highlight_found || !contains(line, #char "^") continue;

        for char: cast([]u8) line {
            if char != #char "^" continue;
            highlighted_chars += 1;
        }

        highlight_found = true;
    }

    diagnostic.range.end.line = diagnostic.range.start.line;
    diagnostic.range.end.character = diagnostic.range.start.character+highlighted_chars;

    diagnostics: [1]LSP_Diagnostic;
    diagnostics[0] = diagnostic;

    file = path_to_lsp_path(normalize_path(file,, temp)); // split_from_right and slice don't allocate memory so copy the file in case the string with compiler output is freed

    lsp_send(LSP_Client_Message(LSP_Publish_Diagnostics).{
        method="textDocument/publishDiagnostics",
        params = .{
            uri = file,
            diagnostics = diagnostics
        }
    });

    if file != server.previously_errored_file {
        free(server.previously_errored_file);
    }

    server.previously_errored_file = file;
}