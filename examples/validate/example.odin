package example

import "base:runtime"

import "core:fmt"
import glm "core:math/linalg/glsl"
import "core:mem"
import "core:os"
import "core:prof/spall"
import "core:slice"
import "core:strings"

import hep "../.."

import spv_tools "spirv-tools-odin"

ENABLE_SPALL :: #config(ENABLE_SPALL, false)

when ENABLE_SPALL {
	spall_ctx:    spall.Context
	spall_buffer: spall.Buffer

	@(instrumentation_enter)
	spall_enter :: proc "contextless" (proc_address, call_site_return_address: rawptr, loc: runtime.Source_Code_Location) {
		spall._buffer_begin(&spall_ctx, &spall_buffer, "", "", loc)
	}

	@(instrumentation_exit)
	spall_exit :: proc "contextless" (proc_address, call_site_return_address: rawptr, loc: runtime.Source_Code_Location) {
		spall._buffer_end(&spall_ctx, &spall_buffer)
	}
} else {
	_ :: runtime
	_ :: spall
}

main :: proc() {
	when ODIN_DEBUG {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		defer mem.tracking_allocator_destroy(&track)
		context.allocator = mem.tracking_allocator(&track)

		defer for _, leak in track.allocation_map {
			fmt.printf("%v leaked %m\n", leak.location, leak.size)
		}
	}

	when ENABLE_SPALL {
		spall_ctx = spall.context_create("trace.spall")
		defer spall.context_destroy(&spall_ctx)

		buffer_backing := make([]u8, 1 << 24)
		defer delete(buffer_backing)

		spall_buffer = spall.buffer_create(buffer_backing)
		defer spall.buffer_destroy(&spall_ctx, &spall_buffer)
	}

	Binding_Location :: enum u64 {
		Image,
		Texture,
		Depth_Texture,
		Shadow_Uniforms,
		Some_Buffer,
	}

	Vertex_Shader_Uniforms :: struct {
		view, proj, model: glm.mat4,
		normal_matrix:     glm.mat3,
	}

	Shadow_Uniforms :: struct {
		shadow_matrix:   glm.mat4,
		light_direction: glm.vec3,
	}

	Some_Enum :: enum u64 {
		A, B, C,
	}

	Particle :: struct {
		position: [4]f32,
		velocity: [4]f32,
		color:    [4]f32,
	}

	defines: map[string]hep.Const_Value
	defines["SHADOW_PASS"] = false
	defer delete(defines)

	LIB_PATH :: "math.hep"
	lib_source := #load(LIB_PATH, string)
	math_lib, lib_errors := hep.check_library(
		lib_source,
		LIB_PATH,
		error_allocator = context.temp_allocator,
	)
	if len(lib_errors) != 0 {
		lines := strings.split_lines(lib_source, context.temp_allocator)
		for error in lib_errors {
			hep.print_error(os.to_stream(os.stderr), LIB_PATH, lines, error)
		}
		return
	}

	libraries: map[string]hep.Library
	defer delete(libraries)
	libraries["math"] = math_lib

	FILE_NAME :: "example.hep"
	source := #load(FILE_NAME, string)
	code, errors := hep.compile_shader(
		source,
		FILE_NAME,
		defines         = defines,
		shared_types    = { Vertex_Shader_Uniforms, Shadow_Uniforms, Some_Enum, Particle, Binding_Location, },
		libraries       = libraries,
		error_allocator = context.temp_allocator,
	)
	defer delete(code)

	if len(errors) != 0 {
		lines := strings.split_lines(source, context.temp_allocator)
		for error in errors {
			hep.print_error(os.to_stream(os.stderr), FILE_NAME, lines, error)
		}
		return
	}

	_ = os.write_entire_file("a.spv", slice.to_bytes(code))

	ctx := spv_tools.context_create(.Vulkan_1_4)
	defer spv_tools.context_destroy(ctx)

	{
		options := spv_tools.validator_options_create()
		defer spv_tools.validator_options_destroy(options)
		spv_tools.validator_options_set_relax_block_layout(options, true)
		spv_tools.validator_options_set_scalar_block_layout(options, true)

		diagnostic: ^spv_tools.Diagnostic
		spv_tools.validate_with_options(ctx, options, code, &diagnostic)
		if diagnostic != nil {
			spv_tools.diagnostic_print(diagnostic)
			spv_tools.diagnostic_destroy(diagnostic)
		}
	}

	options := spv_tools.optimizer_options_create()
	defer spv_tools.optimizer_options_destroy(options)

	spv_tools.optimizer_options_set_run_validator(options, false)

	spv_tools.optimizer_options_set_preserve_bindings(options, true)
	spv_tools.optimizer_options_set_preserve_spec_constants(options, true)

	optimizer := spv_tools.optimizer_create(.Vulkan_1_4)
	defer spv_tools.optimizer_destroy(optimizer)

	spv_tools.optimizer_register_performance_passes(optimizer)

	binary: ^spv_tools.Binary
	result := spv_tools.optimizer_run(optimizer, raw_data(code), len(code), &binary, options)
	assert(result == .Success)

	_ = os.write_entire_file("opt.spv", slice.to_bytes(binary^))
}
