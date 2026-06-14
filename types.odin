package hephaistos

import "base:runtime"

import "core:fmt"
import "core:io"
import "core:mem"
import "core:strings"

Const_Value :: union {
	i64,
	f64,
	bool,
	string,
}

Type_Struct :: struct {
	using base: Type,
	fields:  []^Entity,
	scope:     ^Scope,
}

Type_Array :: struct {
	using base: Type,
	count:      i64,
	elem:      ^Type,
}

Type_Complex :: struct {
	using base: Type,
	array:     ^Type_Array,
}

Type_Buffer :: struct {
	using base: Type,
	elem:      ^Type,
	physical:   bool,
}

Type_Matrix :: struct {
	using base: Type,
	cols:       i64,
	col_type:  ^Type_Array,
}

Type_Proc :: struct {
	using base:   Type,
	args:      []^Entity,
	returns:   []^Entity,
	return_type: ^Type,
	diverging:    bool,
	scope:       ^Scope,
}

Type_Proc_Group :: struct {
	using base:  Type,
	members:     []^Type_Proc,
}

Type_Image :: struct {
	using base: Type,
	dimensions: i64,
	texel_type: ^Type,
	format:     string,
}

Type_Enum :: struct {
	using base: Type,
	values:  []^Entity,
	scope:     ^Scope,
	backing:   ^Type,
}

Type_Bit_Set :: struct {
	using base: Type,
	enum_type: ^Type,
	backing:   ^Type,
}

// A deliberately opaque type such as OpTypeAccelerationStructureKHR
Type_Opaque :: struct {
	using base: Type,
	name:       string,
	backing:   ^Type,
}

Type_Named :: struct {
	using base: Type,
	name:       string,
	type:      ^Type,
}

Type_Fixed :: struct {
	using base:      Type,
	fractional_bits: i64,
	signed:          bool,
	backing:        ^Type,
}

Type_Kind :: enum {
	Invalid,

	Uint,
	Int,
	Bool,
	Float,
	Any,

	Struct,
	Matrix,
	Array,
	Buffer,
	Proc,
	Proc_Group,
	Sampler,
	Image,
	Enum,
	Bit_Set,
	Complex,
	Quaternion,
	Opaque,
	Named,
	Fixed,

	Tuple,
}

Type :: struct {
	kind:    Type_Kind,
	size:    i64,
	align:   i64,
	variant: union {
		^Type_Struct,
		^Type_Matrix,
		^Type_Array,
		^Type_Buffer,
		^Type_Proc,
		^Type_Proc_Group,
		^Type_Image,
		^Type_Enum,
		^Type_Bit_Set,
		^Type_Complex,
		^Type_Opaque,
		^Type_Named,
		^Type_Fixed,
	},
}

@(require_results)
type_new :: proc(kind: Type_Kind, $T: typeid, allocator: mem.Allocator) -> ^T {
	t, _ := mem.new(T, allocator)
	t.kind    = kind
	t.variant = t
	return t
}

t_invalid := &Type{ kind = .Invalid, size = 0, align = 1, }
t_bool    := &Type{ kind = .Bool,    size = 1, align = 1, }
t_int     := &Type{ kind = .Int,     size = 0, align = 0, }
t_uint    := &Type{ kind = .Uint,    size = 0, align = 0, }
t_float   := &Type{ kind = .Float,   size = 0, align = 0, }

t_i8      := &Type{ kind = .Int,     size = 1, align = 1, }
t_i16     := &Type{ kind = .Int,     size = 2, align = 2, }
t_i32     := &Type{ kind = .Int,     size = 4, align = 4, }
t_i64     := &Type{ kind = .Int,     size = 8, align = 8, }

t_u8      := &Type{ kind = .Uint,    size = 1, align = 1, }
t_u16     := &Type{ kind = .Uint,    size = 2, align = 2, }
t_u32     := &Type{ kind = .Uint,    size = 4, align = 4, }
t_u64     := &Type{ kind = .Uint,    size = 8, align = 8, }

t_f16     := &Type{ kind = .Float,   size = 2, align = 2, }
t_f32     := &Type{ kind = .Float,   size = 4, align = 4, }
t_f64     := &Type{ kind = .Float,   size = 8, align = 8, }

t_any     := &Type{ kind = .Any,     size = 0, align = 0, }

t_vec2,  t_vec3,  t_vec4:  ^Type
t_ivec2, t_ivec3, t_ivec4: ^Type

t_complex64,     t_complex128:    ^Type
t_quaternion128, t_quaternion256: ^Type

t_mat4x3:            ^Type
t_Hit_Kind:          ^Type
t_Ray_Flags:         ^Type
// t_Intersection_Type: ^Type

_base_types_init :: proc() {
	@(static)
	arena_mem: [1 << 12]byte
	arena: mem.Arena
	mem.arena_init(&arena, arena_mem[:])
	allocator := mem.arena_allocator(&arena)

	t_vec2 = type_array_new(t_f32, 2, allocator)
	t_vec3 = type_array_new(t_f32, 3, allocator)
	t_vec4 = type_array_new(t_f32, 4, allocator)

	t_ivec2 = type_array_new(t_i32, 2, allocator)
	t_ivec3 = type_array_new(t_i32, 3, allocator)
	t_ivec4 = type_array_new(t_i32, 4, allocator)

	t_complex64  = type_complex_new(t_f32, allocator)
	t_complex128 = type_complex_new(t_f64, allocator)

	t_quaternion128 = type_quaternion_new(t_f32, allocator)
	t_quaternion256 = type_quaternion_new(t_f64, allocator)

	t_mat4x3 = type_matrix_new(t_vec3.variant.(^Type_Array), 4, allocator)

	@(require_results)
	make_enum :: proc(values: []struct { name: string, value: i64, }, backing: ^Type, allocator: mem.Allocator) -> ^Type_Enum {
		e        := type_new(.Enum, Type_Enum, allocator)
		e.backing = backing

		entities  := make([dynamic]^Entity, allocator)
		scope     := new(Scope, allocator)
		scope.kind = .Enum
		for value in values {
			e                         := new(Entity, allocator)
			e.name                     = value.name
			e.value                    = value.value
			e.kind                     = .Enum_Value
			scope.entities[value.name] = e

			append(&entities, e)
		}
		e.values = entities[:]

		return e
	}

	t_Hit_Kind = make_enum({
		{ "Front", 0xFE, },
		{ "Back",  0xFF, },
	}, t_u32, allocator)

	ray_flags_bits := make_enum({
		{ "Opaque",                      0, },
		{ "NoOpaque",                    1, },
		{ "TerminateOnFirstHit",         2, },
		{ "SkipClosestHitShader",        3, },
		{ "CullBackFacingTriangles",     4, },
		{ "CullFrontFacingTriangles",    5, },
		{ "CullOpaque",                  6, },
		{ "CullNoOpaque",                7, },
		{ "SkipTriangles",               8, },
		{ "SkipAABBs",                   9, },
		{ "ForceOpacityMicromap2State", 10, },
	}, t_i32, allocator)

	t_Ray_Flags = type_bit_set_new(ray_flags_bits, t_i32, allocator)
}

type_print_writer :: proc(w: io.Writer, type: ^Type, indent := min(int)) {
	if type == nil {
		fmt.wprint(w, "<nil>")
		return
	}

	switch type.kind {
	case .Invalid:
		fmt.wprint(w, "invalid type")
	case .Struct:
		s := type.variant.(^Type_Struct)
		if len(s.fields) == 0 {
			fmt.wprint(w, "struct {}")
			return
		}

		fmt.wprint(w, "struct {")
		if indent >= 0 {
			fmt.wprint(w, "\n")
		}
		for field, i in s.fields {
			for _ in 0 ..< indent + 1 {
				fmt.wprint(w, "    ")
			}

			if indent < 0 && i > 0 {
				fmt.wprint(w, ", ")
			}

			fmt.wprint(w, field.name)
			fmt.wprint(w, ": ")
			type_print_writer(w, field.type, indent + 1)

			if indent >= 0 {
				fmt.wprint(w, ",\n")
			}
		}

		for _ in 0 ..< indent {
			fmt.wprint(w, "    ")
		}

		fmt.wprint(w, "}")
	case .Enum:
		e := type.variant.(^Type_Enum)
		if len(e.values) == 0 {
			fmt.wprint(w, "enum {}")
			return
		}

		fmt.wprint(w, "enum {")
		if indent >= 0 {
			fmt.wprint(w, "\n")
		}
		for field, i in e.values {
			for _ in 0 ..< indent + 1 {
				fmt.wprint(w, "    ")
			}

			if indent < 0 && i > 0 {
				fmt.wprint(w, ", ")
			}

			fmt.wprint(w, field.name)
			fmt.wprint(w, " = ")
			fmt.wprint(w, field.value)

			if indent >= 0 {
				fmt.wprint(w, ",\n")
			}
		}

		for _ in 0 ..< indent {
			fmt.wprint(w, "\t")
		}

		fmt.wprint(w, "}")
	case .Matrix:
		m := type.variant.(^Type_Matrix)
		c := m.col_type
		fmt.wprintf(w, "matrix[%d, %d]", m.cols, c.count)
		type_print_writer(w, c.elem, indent)
	case .Array:
		v := type.variant.(^Type_Array)
		fmt.wprintf(w, "[%d]", v.count)
		type_print_writer(w, v.elem, indent)
	case .Buffer:
		v := type.variant.(^Type_Buffer)
		fmt.wprintf(w, "[^]" if v.physical else "[]")
		type_print_writer(w, v.elem, indent)
	case .Proc:
		b := type.variant.(^Type_Proc)
		fmt.wprint(w, "proc(")
		for arg, i in b.args {
			if i > 0 {
				fmt.wprint(w, ", ")
			}
			for flag in arg.flags {
				#partial switch flag {
				case .By_Ptr:
					fmt.wprint(w, "#by_ptr ")
				case .Const:
					fmt.wprint(w, "#const ")
				}
			}
			fmt.wprint(w, arg.name)
			fmt.wprint(w, ": ")
			type_print_writer(w, arg.type)
		}
		fmt.wprint(w, ")")

		if len(b.returns) == 0 {
			break
		}

		fmt.wprint(w, " -> (")

		for ret, i in b.returns {
			if i > 0 {
				fmt.wprint(w, ", ")
			}
			if len(ret.name) != 0 {
				fmt.wprint(w, ret.name)
				fmt.wprint(w, ": ")
			}
			type_print_writer(w, ret.type)
		}
		fmt.wprint(w, ")")
	case .Proc_Group:
		g := type.variant.(^Type_Proc_Group)
		fmt.wprint(w, "proc{ ")
		for member in g.members {
			type_print_writer(w, member)
			fmt.wprint(w, ", ")
		}
		fmt.wprint(w, "}")
	case .Int:
		if type.size == 0 {
			fmt.wprintf(w, "int")
		} else {
			fmt.wprintf(w, "i%d", type.size * 8)
		}
	case .Uint:
		fmt.wprintf(w, "u%d", type.size * 8)
	case .Bool:
		fmt.wprintf(w, "bool")
	case .Float:
		if type.size == 0 {
			fmt.wprintf(w, "float")
		} else {
			fmt.wprintf(w, "f%d", type.size * 8)
		}
	case .Complex:
		fmt.wprintf(w, "complex%d", type.size * 8)
	case .Quaternion:
		fmt.wprintf(w, "quaternion%d", type.size * 8)
	case .Tuple:
		fmt.wprint(w, "(")
		for type, i in type.variant.(^Type_Struct).fields {
			if i > 0 {
				fmt.wprint(w, ", ")
			}
			type_print_writer(w, type.type, indent)
		}
		fmt.wprint(w, ")")
	case .Sampler:
		type := type.variant.(^Type_Image)
		fmt.wprintf(w, "sampler[%d]", type.dimensions)
		type_print_writer(w, type.texel_type, indent)
	case .Image:
		type := type.variant.(^Type_Image)
		fmt.wprintf(w, "image[%d]", type.dimensions)
		type_print_writer(w, type.texel_type, indent)
	case .Bit_Set:
		type := type.variant.(^Type_Bit_Set)
		fmt.wprintf(w, "bit_set[")
		type_print_writer(w, type.enum_type, indent)
		fmt.wprintf(w, "; ")
		type_print_writer(w, type.backing, indent)
		fmt.wprintf(w, "]")
	case .Opaque:
		type := type.variant.(^Type_Opaque)
		fmt.wprintf(w, `opaque("%v")`, type.name)
	case .Any:
		fmt.wprintf(w, "any")
	case .Named:
		type := type.variant.(^Type_Named)
		fmt.wprint(w, type.name)
	case .Fixed:
		type := type.variant.(^Type_Fixed)
		fmt.wprint(w, "fixed[")
		if type.signed {
			fmt.wprint(w, "+")
		}
		fmt.wprintf(w, "%d.%d]", type.size * 8 - type.fractional_bits, type.fractional_bits)
	}
}

@(require_results)
type_to_string :: proc(type: ^Type, pretty := false, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	type_print_writer(strings.to_writer(&b), type, pretty ? 0 : min(int))
	return strings.to_string(b)
}

@(require_results)
type_equal :: proc(a, b: ^Type) -> bool {
	if a == b {
		return true
	}

	if a == nil || b == nil {
		return false
	}

	if a.kind != b.kind {
		return false
	}

	switch a.kind {
	case .Int, .Bool, .Float, .Uint:
		return a.size == b.size && a.align == b.align

	case .Struct:
		a := a.variant.(^Type_Struct)
		b := b.variant.(^Type_Struct)
		if len(a.fields) != len(b.fields) {
			return false
		}

		for i in 0 ..< len(a.fields) {
			if a.fields[i].location != b.fields[i].location {
				return false
			}
			if !type_equal(a.fields[i].type, b.fields[i].type) {
				return false
			}
		}

		return true

	case .Matrix:
		a := a.variant.(^Type_Matrix)
		b := b.variant.(^Type_Matrix)

		if a.cols != b.cols {
			return false
		}

		return type_equal(a.col_type, b.col_type)
	case .Array:
		a := a.variant.(^Type_Array)
		b := b.variant.(^Type_Array)

		if a.count != b.count {
			return false
		}

		return type_equal(a.elem, b.elem)
	case .Proc:
		a := a.variant.(^Type_Proc)
		b := b.variant.(^Type_Proc)
		if len(a.args) != len(b.args) {
			return false
		}
		if len(a.returns) != len(b.returns) {
			return false
		}

		for i in 0 ..< len(a.args) {
			if a.args[i].location != b.args[i].location {
				return false
			}
			if !type_equal(a.args[i].type, b.args[i].type) {
				return false
			}
		}

		for i in 0 ..< len(a.returns) {
			if a.returns[i].location != b.returns[i].location {
				return false
			}
			if !type_equal(a.returns[i].type, b.returns[i].type) {
				return false
			}
		}

		return true

	case .Sampler, .Image:
		a := a.variant.(^Type_Image)
		b := b.variant.(^Type_Image)

		if a.dimensions != b.dimensions {
			return false
		}

		if a.format != b.format {
			return false
		}

		return type_equal(a.texel_type, b.texel_type)
	case .Opaque:
		return type_opaque_name(a) == type_opaque_name(b)
	case .Invalid, .Any, .Tuple:
		return true
	case .Buffer:
		a := a.variant.(^Type_Buffer)
		b := b.variant.(^Type_Buffer)

		if a.physical != b.physical {
			return false
		}

		return type_equal(a.elem, b.elem)
	case .Proc_Group:
		a := a.variant.(^Type_Proc_Group)
		b := b.variant.(^Type_Proc_Group)

		if len(a.members) != len(b.members) {
			return false
		}

		for i in 0 ..< len(a.members) {
			if !type_equal(a.members[i], b.members[i]) {
				return false
			}
		}

		return true
	case .Enum:
		a := a.variant.(^Type_Enum)
		b := b.variant.(^Type_Enum)

		for i in 0 ..< len(a.values) {
			if a.values[i].value != b.values[i].value {
				return false
			}
			if a.values[i].name != b.values[i].name {
				return false
			}
		}

		return true
	case .Bit_Set:
		a := a.variant.(^Type_Bit_Set)
		b := b.variant.(^Type_Bit_Set)

		return type_equal(a.backing, b.backing) && type_equal(a.enum_type, b.enum_type)
	case .Complex, .Quaternion:
		a := a.variant.(^Type_Complex)
		b := b.variant.(^Type_Complex)

		return type_equal(a.array, b.array)
	case .Named:
		a := a.variant.(^Type_Named)
		b := b.variant.(^Type_Named)

		return a.name == b.name
	case .Fixed:
		a := a.variant.(^Type_Fixed)
		b := b.variant.(^Type_Fixed)

		(a.size            == b.size)            or_return
		(a.fractional_bits == b.fractional_bits) or_return
		(a.signed          == b.signed)          or_return

		return true
	case:
		unreachable()
	}
}

@(require_results)
core_type :: proc(type: ^Type, complex_to_array := false) -> ^Type {
	type := type
	for {
		#partial switch type.kind {
		case .Enum:
			type = type.variant.(^Type_Enum).backing
		case .Bit_Set:
			type = type.variant.(^Type_Bit_Set).backing
		case .Named:
			type = type.variant.(^Type_Named).type
		case .Complex, .Quaternion:
			if !complex_to_array {
				return type
			}
			type = type.variant.(^Type_Complex).array
		case:
			return type
		}
	}
}

@(require_results)
base_type :: proc(type: ^Type) -> ^Type {
	type := type
	for type.kind == .Named {
		type = type.variant.(^Type_Named).type
	}
	return type
}

@(require_results)
implicitly_castable :: proc(from, to: ^Type) -> bool {
	if type_equal(from, to) {
		return true
	}

	if to.kind == .Any {
		return true
	}

	if !type_is_numeric(from) {
		return false
	}

	to := base_type(to) if from.size == 0 else to

	if from.size == 0 && type_is_numeric(to) {
		if type_is_integer(to) && from.kind == .Float {
			return false
		}
		return true
	}

	to_elem: ^Type
	#partial switch to.kind {
	case .Array:
		to_elem = type_array_elem(to)
	case .Matrix:
		to_elem = type_matrix_elem(to)
	case .Complex, .Quaternion:
		to_elem = type_complex_elem(to)
	}
	if to_elem != nil {
		return implicitly_castable(from, to_elem)
	}

	return false
}

@(require_results)
op_result_type :: proc(a, b: ^Type, is_multiply: bool = false, allocator: mem.Allocator = {}) -> ^Type {
	if is_multiply && (type_is_matrix(a) || type_is_matrix(b)) {
		assert(allocator.procedure != nil)
		return matrix_multiply_type(a, b, allocator)
	}

	if implicitly_castable(a, b) {
		return b
	}

	if implicitly_castable(b, a) {
		return a
	}

	return t_invalid
}

@(require_results)
default_type :: proc(type: ^Type) -> ^Type {
	if type == nil || type.size != 0 {
		return type
	}

	#partial switch type.kind {
	case .Uint:
		return t_u32
	case .Int:
		return t_i32
	case .Bool:
		return t_bool
	case .Float:
		return t_f32
	case:
		return type
	}

	unreachable()
}

@(require_results)
castable :: proc(from, to: ^Type) -> bool {
	from := core_type(from)
	to   := core_type(to)

	if v, ok := from.variant.(^Type_Complex); ok {
		from = v.array
	}
	if v, ok := to.variant.(^Type_Complex); ok {
		to = v.array
	}

	if type_equal(from, to) {
		return true
	}

	if implicitly_castable(from, to) {
		return true
	}

	if type_is_numeric(from) && type_is_numeric(to) {
		return true
	}

	if type_is_bool(from) && type_is_integer(to) {
		return true
	}

	if type_is_numeric(from) && type_is_array(to) {
		return true
	}

	if type_is_array(from) && type_is_array(to) {
		return type_array_len(from) == type_array_len(to) && castable(type_array_elem(from), type_array_elem(to))
	}

	if type_is_opaque(to) && type_opaque_backing(to) != nil {
		return castable(from, type_opaque_backing(to))
	}

	return false
}

@(require_results) type_is_invalid    :: proc(type: ^Type) -> bool { return type.kind == .Invalid    }
@(require_results) type_is_uint       :: proc(type: ^Type) -> bool { return type.kind == .Uint       }
@(require_results) type_is_int        :: proc(type: ^Type) -> bool { return type.kind == .Int        }
@(require_results) type_is_bool       :: proc(type: ^Type) -> bool { return type.kind == .Bool       }
@(require_results) type_is_float      :: proc(type: ^Type) -> bool { return type.kind == .Float      }
@(require_results) type_is_any        :: proc(type: ^Type) -> bool { return type.kind == .Any        }
@(require_results) type_is_struct     :: proc(type: ^Type) -> bool { return type.kind == .Struct     }
@(require_results) type_is_matrix     :: proc(type: ^Type) -> bool { return type.kind == .Matrix     }
@(require_results) type_is_array      :: proc(type: ^Type) -> bool { return type.kind == .Array      }
@(require_results) type_is_buffer     :: proc(type: ^Type) -> bool { return type.kind == .Buffer     }
@(require_results) type_is_proc       :: proc(type: ^Type) -> bool { return type.kind == .Proc       }
@(require_results) type_is_proc_group :: proc(type: ^Type) -> bool { return type.kind == .Proc_Group }
@(require_results) type_is_sampler    :: proc(type: ^Type) -> bool { return type.kind == .Sampler    }
@(require_results) type_is_image      :: proc(type: ^Type) -> bool { return type.kind == .Image      }
@(require_results) type_is_enum       :: proc(type: ^Type) -> bool { return type.kind == .Enum       }
@(require_results) type_is_bit_set    :: proc(type: ^Type) -> bool { return type.kind == .Bit_Set    }
@(require_results) type_is_complex    :: proc(type: ^Type) -> bool { return type.kind == .Complex    }
@(require_results) type_is_quaternion :: proc(type: ^Type) -> bool { return type.kind == .Quaternion }
@(require_results) type_is_opaque     :: proc(type: ^Type) -> bool { return type.kind == .Opaque     }
@(require_results) type_is_named      :: proc(type: ^Type) -> bool { return type.kind == .Named      }
@(require_results) type_is_tuple      :: proc(type: ^Type) -> bool { return type.kind == .Tuple      }

@(require_results)
type_is_numeric :: proc(type: ^Type) -> bool {
	#partial switch type.kind {
	case .Float, .Int, .Uint, .Fixed:
		return true
	}
	return false
}

@(require_results)
type_is_integer :: proc(type: ^Type) -> bool {
	#partial switch type.kind {
	case .Int, .Uint:
		return true
	}
	return false
}

@(require_results)
type_array_len :: proc(type: ^Type) -> i64 {
	return type.variant.(^Type_Array).count
}

@(require_results)
type_array_elem :: proc(type: ^Type) -> ^Type {
	return type.variant.(^Type_Array).elem
}

@(require_results)
type_complex_elem :: proc(type: ^Type) -> ^Type {
	return type.variant.(^Type_Complex).array.elem
}

@(require_results)
type_buffer_elem :: proc(type: ^Type) -> ^Type {
	return type.variant.(^Type_Buffer).elem
}

@(require_results)
type_opaque_name :: proc(type: ^Type) -> string {
	return type.variant.(^Type_Opaque).name
}

@(require_results)
type_opaque_backing :: proc(type: ^Type) -> ^Type {
	return type.variant.(^Type_Opaque).backing
}

@(require_results)
matrix_multiply_type :: proc(a, b: ^Type, allocator: mem.Allocator) -> ^Type {
	if a == nil || b == nil {
		return t_invalid
	}

	assert(a.kind == .Matrix || b.kind == .Matrix)

	if a.kind == .Matrix && b.kind == .Matrix {
		a := a.variant.(^Type_Matrix)
		b := b.variant.(^Type_Matrix)

		if a.cols != b.col_type.count {
			return t_invalid
		}

		if !type_equal(a.col_type.elem, b.col_type.elem) {
			return t_invalid
		}

		col := type_array_new(a.col_type.elem, a.col_type.count, allocator)
		return type_matrix_new(col, b.cols, allocator)
	}

	if a.kind == .Matrix && b.kind == .Array {
		a := a.variant.(^Type_Matrix)
		v := b.variant.(^Type_Array)

		if a.cols != v.count {
			return t_invalid
		}

		if !type_equal(v.elem, type_matrix_elem(a)) {
			return t_invalid
		}

		return type_array_new(v.elem, a.col_type.count, allocator)
	}

	if a.kind == .Array && b.kind == .Matrix {
		v := a.variant.(^Type_Array)
		b := b.variant.(^Type_Matrix)

		if v.count != b.col_type.count {
			return t_invalid
		}

		if !type_equal(v.elem, type_matrix_elem(b)) {
			return t_invalid
		}

		return type_array_new(v.elem, b.cols, allocator)
	}

	if a.kind == .Float {
		if op_result_type(a, type_matrix_elem(b)) == t_invalid {
			return t_invalid
		}
		return b
	}

	if b.kind == .Float {
		if op_result_type(b, type_matrix_elem(a)) == t_invalid {
			return t_invalid
		}
		return a
	}

	return t_invalid
}

@(require_results)
type_matrix_elem :: proc(type: ^Type) -> ^Type {
	return type.variant.(^Type_Matrix).col_type.elem
}

@(require_results)
type_matrix_is_square :: proc(t: ^Type) -> bool {
	m := t.variant.(^Type_Matrix)
	return m.col_type.count == m.cols
}

@(require_results)
align_forward_i64 :: #force_inline proc(ptr, align: i64) -> i64 {
	assert(align & (align - 1) == 0)
	return i64((u64(ptr) + u64(align) - 1) & ~(u64(align) - 1))
}


@(require_results)
type_array_new :: proc(elem: ^Type, count: i64, allocator: mem.Allocator) -> ^Type_Array {
	assert(elem      != nil)
	assert(elem.size != 0)

	type := type_new(.Array, Type_Array, allocator)
	type.elem  = elem
	type.count = count
	type.align = elem.align
	type.size  = align_forward_i64(count * elem.size, type.align)

	return type
}

@(require_results)
type_complex_new :: proc(elem: ^Type, allocator: mem.Allocator) -> ^Type_Complex {
	assert(elem      != nil)
	assert(elem.size != 0)

	type      := type_new(.Complex, Type_Complex, allocator)
	type.array = type_array_new(elem, 2, allocator)
	type.size  = type.array.size
	type.align = type.array.align

	return type
}

@(require_results)
type_quaternion_new :: proc(elem: ^Type, allocator: mem.Allocator) -> ^Type_Complex {
	assert(elem      != nil)
	assert(elem.size != 0)

	type      := type_new(.Quaternion, Type_Complex, allocator)
	type.array = type_array_new(elem, 4, allocator)
	type.size  = type.array.size
	type.align = type.array.align

	return type
}

@(require_results)
type_buffer_new :: proc(elem: ^Type, physical: bool, allocator: mem.Allocator) -> ^Type_Buffer {
	assert(elem      != nil)
	assert(elem.size != 0)

	type := type_new(.Buffer, Type_Buffer, allocator)
	type.elem     = elem
	type.size     = 8
	type.align    = 8
	type.physical = physical

	return type
}

@(require_results)
type_sampler_new :: proc(texel_type: ^Type, dimensions: i64, allocator: mem.Allocator) -> ^Type_Image {
	assert(texel_type      != nil)
	assert(texel_type.size != 0 || texel_type.kind == .Invalid)

	type           := type_new(.Sampler, Type_Image, allocator)
	type.texel_type = texel_type
	type.dimensions = dimensions

	return type
}

@(require_results)
type_image_new :: proc(texel_type: ^Type, dimensions: i64, format: string, allocator: mem.Allocator) -> ^Type_Image {
	assert(texel_type      != nil)
	assert(texel_type.size != 0 || texel_type.kind == .Invalid)

	type           := type_new(.Image, Type_Image, allocator)
	type.texel_type = texel_type
	type.dimensions = dimensions
	type.format     = format

	return type
}

@(require_results)
type_matrix_new :: proc(col_type: ^Type_Array, cols: i64, allocator: mem.Allocator) -> ^Type_Matrix {
	assert(col_type      != nil)
	assert(col_type.size != 0)

	type         := type_new(.Matrix, Type_Matrix, allocator)
	type.col_type = col_type
	type.cols     = cols
	type.size     = cols * col_type.size
	type.align    = col_type.align

	return type
}

@(require_results)
type_opaque_new :: proc(name: string, backing: ^Type, allocator: mem.Allocator) -> ^Type_Opaque {
	type        := type_new(.Opaque, Type_Opaque, allocator)
	type.name    = name
	type.backing = backing
	if backing != nil {
		type.size  = backing.size
		type.align = backing.align
	}

	return type
}

@(require_results)
type_named_new :: proc(name: string, backing: ^Type, allocator: mem.Allocator) -> ^Type_Named {
	type      := type_new(.Named, Type_Named, allocator)
	type.name  = name
	type.type  = backing
	type.size  = backing.size
	type.align = backing.align

	return type
}

@(require_results)
type_bit_set_new :: proc(enum_type: ^Type, backing: ^Type, allocator: mem.Allocator) -> ^Type_Bit_Set {
	assert(enum_type != nil)
	assert(backing   != nil)

	type          := type_new(.Bit_Set, Type_Bit_Set, allocator)
	type.enum_type = enum_type
	type.backing   = backing
	type.size      = backing.size
	type.align     = backing.align

	return type
}

@(require_results)
type_any_new :: proc(allocator: mem.Allocator) -> ^Type {
	size := max(
		size_of(Type_Struct),
		size_of(Type_Matrix),
		size_of(Type_Array),
		size_of(Type_Buffer),
		size_of(Type_Proc),
		size_of(Type_Proc_Group),
		size_of(Type_Image),
		size_of(Type_Enum),
		size_of(Type_Bit_Set),
		size_of(Type_Complex),
		size_of(Type_Opaque),
		size_of(Type_Named),
	)
	p, _ := mem.alloc(size, allocator = allocator)
	return (^Type)(p)
}

@(require_results)
type_is_comparable :: proc(type: ^Type) -> bool{
	#partial switch type.kind {
	case .Proc, .Tuple:
		return false
	}
	return true
}

@(require_results)
operator_applicable :: proc(type: ^Type, op: Token_Kind) -> bool {
	type := base_type(type)

	if type_is_invalid(type) {
		return true
	}

	if type_is_comparable(type) && (op == .Equal || op == .Not_Equal) {
		return true
	}

	if type_is_float(type) && op == .Modulo_Floored {
		return false
	}

	if type_is_numeric(type) {
		#partial switch op {
		case .Less, .Less_Equal, .Greater, .Greater_Equal:
			return true
		case .Add, .Subtract, .Multiply, .Divide:
			return true
		case .Modulo, .Modulo_Floored:
			return true
		}
	}

	#partial switch type.kind {
	case .Int, .Uint, .Enum:
		#partial switch op {
		case .Bit_Or, .Bit_And, .Xor, .Shift_Left, .Shift_Right:
			return true
		}
	case .Bit_Set:
		#partial switch op {
		case .Bit_Or, .Bit_And, .Xor, .Add, .Subtract:
			return true
		}
	case .Bool:
		#partial switch op {
		case .Not, .And, .Or:
			return true
		}
	case .Array:
		return operator_applicable(type_array_elem(type), op)
	case .Complex:
		return operator_applicable(type_complex_elem(type), op)
	case .Quaternion:
		return operator_applicable(type_complex_elem(type), op)
	case .Matrix:
		return operator_applicable(type_matrix_elem(type), op)
	}

	return false
}
