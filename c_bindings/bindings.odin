package hephaistos_c_bindings

import "base:runtime"

import "core:io"
import vmem "core:mem/virtual"

import hep ".."

Result :: struct {
	errors:       []hep.Error,
	instructions: []u32,
	_error_arena: ^vmem.Arena,
}

Define :: struct {
	name:  string,
	value: hep.Const_Value,
}

Named_Type :: struct {
	name:  string,
	type: ^hep.Type,
}

Named_Library :: struct {
	name:    string,
	library: hep.Library,
}

@(require_results)
compile_shader :: proc(
	source:        string,
	path:          string,
	defines:       []Define,
	shared_types:  []Named_Type,
	libraries:     []Named_Library,
	spirv_version: u32,
	allocator       := context.allocator,
	error_allocator := context.allocator,
) -> (code: []u32, errors: []hep.Error) {
	tokens: []hep.Token
	tokens, errors = hep.tokenize(source, false, context.temp_allocator, error_allocator)
	if len(errors) != 0 {
		return
	}

	stmts: []^hep.Ast_Stmt
	stmts, errors = hep.parse(tokens, context.temp_allocator, error_allocator)
	if len(errors) != 0 {
		return
	}

	define_map      := make(map[string]hep.Const_Value, context.temp_allocator)
	shared_type_map := make(map[string]^hep.Type,       context.temp_allocator)
	library_map     := make(map[string]hep.Library,     context.temp_allocator)

	for define in defines {
		define_map[define.name] = define.value
	}
	for type in shared_types {
		shared_type_map[type.name] = type.type
	}
	for library in libraries {
		library_map[library.name] = library.library
	}

	checker: hep.Checker
	checker, errors = hep.check_with_types(
		stmts,
		define_map,
		shared_type_map,
		library_map,
		{},
		context.temp_allocator,
		error_allocator,
	)
	if len(errors) != 0 {
		return
	}

	code = hep.cg_file(&checker, stmts, path, source, spirv_version, allocator = allocator)

	return
}

@(export)
hep_compile_shader :: proc "c" (
	source:       cstring,
	path:         cstring,
	defines:      []Define,
	shared_types: []Named_Type,
	spirv_version: u32,
) -> (r: Result) {
	context = runtime.default_context()
	defer free_all(context.temp_allocator)

	error_arena := new(vmem.Arena)
	err         := vmem.arena_init_growing(error_arena)
	assert(err == nil)

	r.instructions, r.errors = compile_shader(
		string(source),
		string(path),
		defines,
		shared_types,
		{},
		spirv_version,
		allocator       = context.allocator,
		error_allocator = vmem.arena_allocator(error_arena),
	)

	if len(r.errors) == 0 {
		vmem.arena_destroy(error_arena)
		free(error_arena)
	} else {
		r._error_arena = error_arena
	}
	return
}

@(export)
hep_result_free :: proc "c" (#by_ptr r: Result) {
	context = runtime.default_context()
	if len(r.errors) != 0 {
		vmem.arena_destroy(r._error_arena)
		free(r._error_arena)
	} else {
		delete(r.instructions)
	}
}

@(export)
hep_error_print :: proc "c" (#by_ptr error: hep.Error, file_name: cstring, lines: [^]string, buf: [^]u8) -> int {
	context = runtime.default_context()
	buf := buf
	w: io.Writer
	if buf == nil {
		w = {
			procedure = proc(
				stream_data: rawptr,
				mode:        io.Stream_Mode,
				p:           []byte,
				offset:      i64,
				whence:      io.Seek_From,
			) -> (n: i64, err: io.Error) {
				return i64(len(p)), nil
			},
			data = nil,
		}
	} else {
		w = {
			procedure = proc(
				stream_data: rawptr,
				mode:        io.Stream_Mode,
				p:           []byte,
				offset:      i64,
				whence:      io.Seek_From,
			) -> (n: i64, err: io.Error) {
				if mode != .Write {
					return
				}
				buf := (^[^]u8)(stream_data)
				copy(buf[:len(p)], p)
				buf^ = buf[len(p):]
				return i64(len(p)), nil
			},
			data = &buf,
		}
	}
	defer if buf != nil {
		buf[0] = 0
	}
	return hep.print_error(w, string(file_name), lines[:max(int)], error) + 1
}
