package hephaistos_driver

import "base:runtime"

import "core:flags"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"

import hep ".."

parse_const_value :: proc(
	data:           rawptr,
	data_type:      typeid,
	unparsed_value: string,
	args_tag:       string,
) -> (
	error:       string,
	handled:     bool,
	alloc_error: runtime.Allocator_Error,
) {
	if data_type != hep.Const_Value {
		return
	}
	handled = true

	data := (^hep.Const_Value)(data)

	switch unparsed_value {
	case "true":
		data^ = true
		return
	case "false":
		data^ = false
		return
	}

	if strings.contains(unparsed_value, ".") {
		v, ok := strconv.parse_f64(unparsed_value)
		if !ok {
			error = "Failed to parse argument as float"
			return
		}
		data^ = v
	} else {
		v, ok := strconv.parse_i64(unparsed_value)
		if !ok {
			error = "Failed to parse argument as integer"
			return
		}
		data^ = v
	}

	return
}

main :: proc() {
	Target_Env :: enum {
		OpenGL,
		Vulkan,
	}

	Options :: struct {
		input:      string                     `args:"pos=0,required" usage:"Input file."`,
		output:     string                     `usage:"Output file. Defaults to 'a.spv'."`,
		check:      bool                       `usage:"Stop after type-checking and don't emit a SPIR-V file."`,
		target_env: Target_Env                 `usage:"The target environment."`,
		defines:    map[string]hep.Const_Value `args:"name=define" usage:"Define compile time constants."`,
		libraries:  map[string]string          `args:"name=library" usage:"Path to a library."`,
	}

	options: Options
	flags.register_type_setter(parse_const_value)
	flags.parse_or_exit(&options, os.args)

	libraries: map[string]hep.Library
	for name, path in options.libraries {
		source, err := os.read_entire_file(path, context.temp_allocator)
		if err != nil {
			fmt.eprintln("Failed to open library file:", path, err)
		}
		lib, errors := hep.check_library(string(source), path)

		if len(errors) != 0 {
			file_name := filepath.base(options.input)
			lines     := strings.split_lines(string(source))
			for error in errors {
				hep.print_error(os.to_stream(os.stdout), file_name, lines, error)
			}
			continue
		}

		libraries[name] = lib
	}

	if options.output == "" {
		options.output = "a.spv"
	}
	source, err := os.read_entire_file(options.input, context.temp_allocator)
	if err != nil {
		fmt.eprintln("Failed to open input file")
		return
	}

	errors: []hep.Error
	defer if len(errors) != 0 {
		file_name := filepath.base(options.input)
		lines     := strings.split_lines(string(source))
		for error in errors {
			hep.print_error(os.to_stream(os.stdout), file_name, lines, error)
		}
	}

	tokens: []hep.Token
	tokens, errors = hep.tokenize(string(source), false, allocator = context.temp_allocator)

	if len(errors) != 0 {
		return
	}

	stmts: []^hep.Ast_Stmt
	stmts, errors = hep.parse(tokens, context.temp_allocator)
	if len(errors) != 0 {
		return
	}

	flags: hep.Checker_Flags
	spirv_version: u32
	switch options.target_env {
	case .OpenGL:
		spirv_version = hep.SPIR_V_VERSION_1_0
		flags         = { .Auto_Map_Locations, .Auto_Bind_Uniforms, }
	case .Vulkan:
		spirv_version = hep.SPIR_V_VERSION_1_6
	}

	checker: hep.Checker
	checker, errors = hep.check(stmts, options.defines, libraries = libraries, flags = flags, allocator = context.temp_allocator)
	if len(errors) != 0 {
		return
	}

	if options.check {
		return
	}

	code := hep.cg_generate(&checker, stmts, options.input, string(source), spirv_version)
	err   = os.write_entire_file(options.output, slice.to_bytes(code))
	if err != nil {
		fmt.eprintln("Failed to write output file")
	}
}
