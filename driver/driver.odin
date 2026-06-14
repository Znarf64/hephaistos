package hephaistos_driver

import "base:runtime"

import "core:flags"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

import hep ".."

main :: proc() {
	options, error := hep.parse_options(os.args)
	flags.print_errors(hep.Command_Line_Options, error, os.args[0])
	if error != nil {
		_, help := error.(flags.Help_Request)
		os.exit(help ? 0 : 1)
	}

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
	case .Vulkan, .Vulkan_1_0:
		spirv_version = hep.SPIR_V_VERSION_1_0
	case .Vulkan_1_1:
		spirv_version = hep.SPIR_V_VERSION_1_3
	case .Vulkan_1_2:
		spirv_version = hep.SPIR_V_VERSION_1_5
	case .Vulkan_1_3:
		spirv_version = hep.SPIR_V_VERSION_1_6
	case .Vulkan_1_4:
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

	code := hep.cg_file(&checker, stmts, options.input, string(source), spirv_version)
	err   = os.write_entire_file(options.output, slice.to_bytes(code))
	if err != nil {
		fmt.eprintln("Failed to write output file")
	}
}
