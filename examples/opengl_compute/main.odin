package gl_compute

import "base:runtime"

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

import gl "vendor:OpenGL"
import "vendor:glfw"
import stbi "vendor:stb/image"

import hep "../.."

compile_compute_shaders :: proc(
	$path:        string,
	shared_types: []typeid   = {},
	entry_points: [$N]string = [1]string{ "main", },
) -> (programs: [N]u32, ok: bool) {
	source := #load(path, string)
	spirv, errors := hep.compile_shader(
		string(source),
		path,
		shared_types    = shared_types,
		spirv_version   = hep.SPIR_V_VERSION_1_0,
		allocator       = context.temp_allocator,
		error_allocator = context.temp_allocator,
	)
	if len(errors) != 0 {
		lines := strings.split_lines(string(source))
		for e in errors {
			hep.print_error(os.to_stream(os.stderr), path, lines, e)
		}
		return
	}

	_ = os.write_entire_file("a.spv", slice.to_bytes(spirv))

	shaders: [N]u32
	for &s in shaders {
		s = gl.CreateShader(gl.COMPUTE_SHADER)
	}
	gl.ShaderBinary(i32(len(shaders)), raw_data(&shaders), gl.SHADER_BINARY_FORMAT_SPIR_V, raw_data(spirv), i32(len(spirv) * size_of(u32)))
	for e, i in entry_points {
		gl.SpecializeShader(shaders[i], strings.clone_to_cstring(e, context.temp_allocator), 0, nil, nil)
		programs[i] = gl.CreateProgram()
		gl.AttachShader(programs[i], shaders[i])
		gl.LinkProgram(programs[i])
		gl.DeleteShader(shaders[i])
	}

	ok = true
	return
}

main :: proc() {
	glfw.Init()
	defer glfw.Terminate()

	glfw.WindowHint(glfw.VISIBLE, false)
	window := glfw.CreateWindow(1, 1, "OpenGL compute dummy window", nil, nil)
	defer glfw.DestroyWindow(window)

	glfw.MakeContextCurrent(window)
	gl.load_up_to(4, 6, glfw.gl_set_proc_address)

	when ODIN_DEBUG do gl.DebugMessageCallback(
		proc "c" (source: u32, type: u32, id: u32, severity: u32, length: i32, message: cstring, userParam: rawptr) {
			context = runtime.default_context()

			source_str: string
			switch source {
			case gl.DEBUG_SOURCE_API:
				source_str = "API"
			case gl.DEBUG_SOURCE_WINDOW_SYSTEM:
				source_str = "WINDOW SYSTEM"
			case gl.DEBUG_SOURCE_SHADER_COMPILER:
				source_str = "SHADER COMPILER"
			case gl.DEBUG_SOURCE_THIRD_PARTY:
				source_str = "THIRD PARTY"
			case gl.DEBUG_SOURCE_APPLICATION:
				source_str = "APPLICATION"
			case gl.DEBUG_SOURCE_OTHER:
				source_str = "OTHER"
			}

			type_string: string
			switch type {
			case gl.DEBUG_TYPE_ERROR:
				type_string = "ERROR"
			case gl.DEBUG_TYPE_DEPRECATED_BEHAVIOR:
				type_string = "DEPRECATED_BEHAVIOR"
			case gl.DEBUG_TYPE_UNDEFINED_BEHAVIOR:
				type_string = "UNDEFINED_BEHAVIOR"
			case gl.DEBUG_TYPE_PORTABILITY:
				type_string = "PORTABILITY"
			case gl.DEBUG_TYPE_PERFORMANCE:
				type_string = "PERFORMANCE"
			case gl.DEBUG_TYPE_MARKER:
				type_string = "MARKER"
			case gl.DEBUG_TYPE_OTHER:
				type_string = "OTHER"
			}

			fmt.eprintfln(
				"[OpenGL(%s: %s)]: %v (Code: %d)",
				source_str,
				type_string,
				message,
				id,
			)
		},
		nil,
	)

	Compute_Uniforms :: struct {
		image_size: [2]i32,
		tint:       [4]f32,
	}

	Binding_Point :: enum {
		Input_Image,
		Output_Image,
		Uniform_Buffer,
		Storage_Buffer,
	}

	Uniform_Location :: enum {
		Tint,
	}

	shaders, ok := compile_compute_shaders("compute.hep", { Compute_Uniforms, Binding_Point, Uniform_Location, })
	if !ok {
		fmt.eprintln("Failed to compile compute shaders")
		return
	}

	w, h, c: i32
	p := stbi.load("input.png", &w, &h, &c, 4)
	assert(p != nil)

	input_texture: u32
	gl.CreateTextures(gl.TEXTURE_2D, 1, &input_texture)
	gl.TextureStorage2D(input_texture, 1, gl.RGBA8, w, h)
	gl.TextureSubImage2D(
		input_texture,
		0,
		0,
		0,
		w,
		h,
		gl.RGBA,
		gl.UNSIGNED_BYTE,
		p,
	)

	output_texture: u32
	gl.CreateTextures(gl.TEXTURE_2D, 1, &output_texture)
	gl.TextureStorage2D(output_texture, 1, gl.RGBA8, w, h)

	gl.UseProgram(shaders[0])

	ubo: u32
	gl.CreateBuffers(1, &ubo)
	gl.NamedBufferStorage(
		ubo,
		size_of(Compute_Uniforms),
		&Compute_Uniforms{
			image_size = { w, h, },
			tint       = 1,
		},
		0,
	)
	gl.BindBufferRange(gl.UNIFORM_BUFFER, u32(Binding_Point.Uniform_Buffer), ubo, 0, size_of(Compute_Uniforms))

	ssbo: u32
	gl.CreateBuffers(1, &ssbo)
	gl.NamedBufferStorage(ssbo, size_of([4]f32), &[4]f32{0, 1, 0, 1}, 0)
	gl.BindBufferRange(gl.SHADER_STORAGE_BUFFER, u32(Binding_Point.Storage_Buffer), ssbo, 0, size_of([4]f32))

	gl.Uniform4f(i32(Uniform_Location.Tint), 1, 0.5, 0.5, 1)

	gl.BindImageTexture(u32(Binding_Point.Input_Image),  input_texture,  0, false, 0, gl.READ_ONLY,  gl.RGBA8)
	gl.BindImageTexture(u32(Binding_Point.Output_Image), output_texture, 0, false, 0, gl.WRITE_ONLY, gl.RGBA8)
	gl.DispatchCompute(u32(w), u32(h), 1)
	gl.MemoryBarrier(gl.SHADER_IMAGE_ACCESS_BARRIER_BIT)

	gl.GetTextureImage(output_texture, 0, gl.RGBA, gl.UNSIGNED_BYTE, w * h * 4, p)
	stbi.write_png("output.png", w, h, 4, p, 0)
}
