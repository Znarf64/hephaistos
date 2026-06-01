package hephaistos

import "base:runtime"

import "core:fmt"
import "core:io"
import "core:os"
import "core:reflect"
import "core:strings"
import "core:terminal/ansi"

import spv "spirv-odin"

import vk "vendor:vulkan"

Buffer_Address :: struct($T: typeid) #raw_union {
	address: vk.DeviceAddress,
	_:       ^T `hephaistos:"buffer_device_address"`,
}

SPIR_V_VERSION_CURRENT :: spv.VERSION
SPIR_V_VERSION_1_0     :: 0x00010000 // use with OpenGL
SPIR_V_VERSION_1_1     :: 0x00010100
SPIR_V_VERSION_1_2     :: 0x00010200
SPIR_V_VERSION_1_3     :: 0x00010300
SPIR_V_VERSION_1_4     :: 0x00010400
SPIR_V_VERSION_1_5     :: 0x00010500
SPIR_V_VERSION_1_6     :: 0x00010600

_prev_assertion_failure_proc := runtime.default_assertion_failure_proc

_assertion_failure_proc :: proc(prefix, message: string, loc: runtime.Source_Code_Location) -> ! {
	runtime.print_string("This is a hephaistos compiler bug, please report this.\n")
	_prev_assertion_failure_proc(prefix, message, loc)
}

@(require_results)
check_library :: proc(
	source:        string,
	path:          string,
	defines:       map[string]Const_Value = {},
	shared_types:  []typeid               = {},
	libraries:     map[string]Library     = {},
	file_id:       i32                    = -1,
	allocator       := context.allocator,
	error_allocator := context.allocator,
) -> (library: Library, errors: []Error) {
	_prev_assertion_failure_proc   = context.assertion_failure_proc
	context.assertion_failure_proc = _assertion_failure_proc

	tokens: []Token
	tokens, errors = tokenize(source, false, file_id, context.temp_allocator, error_allocator)
	if len(errors) != 0 {
		return
	}

	stmts: []^Ast_Stmt
	stmts, errors = parse(tokens, allocator, error_allocator)
	if len(errors) != 0 {
		return
	}

	c: Checker
	c, errors = check(stmts, defines, shared_types, libraries, {}, allocator, error_allocator)
	if len(errors) != 0 {
		return
	}

	library.scope = c.scope
	library.stmts = stmts
	return
}

@(require_results)
compile_shader :: proc(
	source:        string,
	path:          string,
	defines:       map[string]Const_Value = {},
	shared_types:  []typeid               = {},
	libraries:     map[string]Library     = {},
	spirv_version: u32                    = SPIR_V_VERSION_CURRENT,
	allocator       := context.allocator,
	error_allocator := context.allocator,
) -> (code: []u32, errors: []Error) {
	_prev_assertion_failure_proc   = context.assertion_failure_proc
	context.assertion_failure_proc = _assertion_failure_proc

	tokens: []Token
	tokens, errors = tokenize(source, false, allocator = context.temp_allocator, error_allocator = error_allocator)
	if len(errors) != 0 {
		return
	}

	stmts: []^Ast_Stmt
	stmts, errors = parse(tokens, context.temp_allocator, error_allocator)
	if len(errors) != 0 {
		return
	}

	checker: Checker
	checker, errors = check(stmts, defines, shared_types, libraries, {}, context.temp_allocator, error_allocator)
	if len(errors) != 0 {
		return
	}

	code = cg_file(&checker, stmts, path, source, spirv_version, allocator = allocator)

	return
}

HEPHAISTOS_NO_TYPE_FORMATTER :: #config(HEPHAISTOS_NO_TYPE_FORMATTER, false)

// necessary to get usable error messages
when !HEPHAISTOS_NO_TYPE_FORMATTER {
	_user_formatters: map[typeid]fmt.User_Formatter
	@(init)
	_register_type_formatter :: proc "contextless" () {
		context = runtime.default_context()

		formatter :: proc(fi: ^fmt.Info, arg: any, verb: rune) -> bool {
			#no_type_assert t := arg.(^Type)
			type_print_writer(fi.writer, t)
			return true
		}

		err := fmt.register_user_formatter(^Type, formatter)
		switch err {
		case .No_User_Formatter:
			fmt.set_user_formatters(&_user_formatters)
			err := fmt.register_user_formatter(^Type, formatter)
			assert(err == .None)
		case .Formatter_Previously_Found, .None:
			// don't care
		}

		ti := reflect.type_info_base(type_info_of(type_of(Type{}.variant)))
		for v in ti.variant.(reflect.Type_Info_Union).variants {
			err := fmt.register_user_formatter(v.id, formatter)
			assert(err == .None)
		}
	}

	@(fini)
	_destroy_user_formatter :: proc "contextless" () {
		context = runtime.default_context()

		delete(_user_formatters)
	}
} else {
	_ :: reflect
	_ :: runtime
}

print_error :: proc(w: io.Writer, file_name: string, lines: []string, error: Error) -> (n: int) {
	if error.line == 0 {
		return fmt.wprintf(w, ansi.CSI + ansi.FG_RED + ansi.SGR + "Error:" + ansi.CSI + ansi.RESET + ansi.SGR + " %s\n", error.message)
	}
	n += fmt.wprintf(w, ansi.CSI + ansi.BOLD   + ansi.SGR + "%s(%v:%v) ", file_name, error.line, error.column)
	n += fmt.wprintf(w, ansi.CSI + ansi.FG_RED + ansi.SGR + "Error:" + ansi.CSI + ansi.RESET + ansi.SGR + " %s\n", error.message)
	n += fmt.wprintln(w, lines[error.line - 1])
	for i in 1 ..< error.column {
		if lines[error.line - 1][i - 1] == '\t' {
			n += fmt.wprint(w, "\t")
		} else {
			n += fmt.wprint(w, " ")
		}
	}
	n += fmt.wprint(w, ansi.CSI + ansi.FG_GREEN + ansi.SGR + "^")
	for _ in error.column ..< error.end.column - 2 {
		n += fmt.wprint(w, "~")
	}
	if error.column < error.end.column - 1 {
		n += fmt.wprint(w, "^")
	}
	n += fmt.wprintln(w, ansi.CSI + ansi.RESET + ansi.SGR)
	return
}

core_library_source_files       := #load_directory("core")
extensions_library_source_files := #load_directory("extensions")

@(require_results)
check_core_libraries :: proc(
	enable_extensions := true,
	enable_core       := true,
	allocator         := context.allocator,
	error_writer: io.Writer = {},
) -> (libraries: map[string]Library, ok: bool = true) {
	error_writer := error_writer if error_writer.procedure != nil else os.to_stream(os.stderr)

	handle_directory :: proc(
		files:      []runtime.Load_Directory_File,
		prefix:       string,
		libraries:   ^map[string]Library,
		error_writer: io.Writer,
		allocator:    runtime.Allocator,
	) -> (ok: bool = true) {
		for file in files {
			source      := string(file.data)
			lib, errors := check_library(source, file.name, allocator = allocator, error_allocator = context.temp_allocator)
			if len(errors) != 0 {
				lines := strings.split_lines(source)
				for error in errors {
					print_error(error_writer, file.name, lines, error)
				}
				ok = false
			}
			name, _ := strings.concatenate({ prefix, file.name, }, allocator)
			name     = strings.trim_suffix(name, ".hep")
			libraries[name] = lib
		}
		return
	}

	libraries = make(map[string]Library, allocator)

	if enable_core {
		if !handle_directory(core_library_source_files, "core:", &libraries, error_writer, allocator) {
			ok = false
		}
	}

	if enable_extensions {
		if !handle_directory(extensions_library_source_files, "extensions:", &libraries, error_writer, allocator) {
			ok = false
		}
	}

	return
}
