package hephaistos_types

import "base:runtime"

import "core:fmt"
import "core:hash"
import "core:io"
import "core:mem"
import "core:strings"

import "../tokenizer"

Field :: struct {
	name:     tokenizer.Token,
	type:     ^Type,
	value:    Const_Value,
	offset:   int,
	location: int,
}

Enum_Value :: struct {
	name:  tokenizer.Token,
	value: int,
}

Const_Value :: union {
	i64,
	f64,
	bool,
	string,
}

Struct :: struct {
	using base: Type,
	fields:     []Field,
}

Vector :: struct {
	using base: Type,
	count:      int,
	elem:       ^Type,
}

Complex :: struct {
	using base: Type,
	vector:     ^Vector,
}

Buffer :: struct {
	using base: Type,
	elem:       ^Type,
	physical:   bool,
}

Matrix :: struct {
	using base: Type,
	cols:       int,
	col_type:   ^Vector,
}

Proc :: struct {
	using base:  Type,
	args:        []Field,
	returns:     []Field,
	return_type: ^Type,
}

Proc_Group :: struct {
	using base:  Type,
	members:     []^Proc,
}

Image :: struct {
	using base: Type,
	dimensions: int,
	texel_type: ^Type,
	format:     string,
}

Enum :: struct {
	using base: Type,
	values:     []Enum_Value,
	backing:    ^Type,
}

Bit_Set :: struct {
	using base: Type,
	enum_type:  ^Type,
	backing:    ^Type,
}

Kind :: enum {
	Invalid,

	Uint,
	Int,
	Bool,
	Float,

	Struct,
	Matrix,
	Vector,
	Buffer,
	Proc,
	Proc_Group,
	Sampler,
	Image,
	Enum,
	Bit_Set,
	Complex,
	Quaternion,

	Tuple,
}

Type :: struct {
	kind:    Kind,
	size:    int,
	align:   int,
	variant: union {
		^Struct,
		^Matrix,
		^Vector,
		^Buffer,
		^Proc,
		^Proc_Group,
		^Image,
		^Enum,
		^Bit_Set,
		^Complex,
	},
}

@(require_results)
new_any :: proc(allocator: mem.Allocator) -> ^Type {
	size := max(
		size_of(Struct),
		size_of(Matrix),
		size_of(Vector),
		size_of(Buffer),
		size_of(Proc),
		size_of(Image),
		size_of(Enum),
		size_of(Bit_Set),
	)
	p, _ := mem.alloc(size, allocator = allocator)
	return (^Type)(p)
}

@(require_results)
new :: proc(kind: Kind, $T: typeid, allocator: mem.Allocator) -> ^T {
	t, _ := mem.new(T, allocator)
	t.kind    = kind
	t.variant = t
	return t
}

t_invalid := &Type{kind = .Invalid, size = 0, align = 1}
t_bool    := &Type{kind = .Bool,    size = 1, align = 1}
t_int     := &Type{kind = .Int,     size = 0, align = 0}
t_uint    := &Type{kind = .Uint,    size = 0, align = 0}
t_float   := &Type{kind = .Float,   size = 0, align = 0}

t_i8      := &Type{kind = .Int,     size = 1, align = 1}
t_i16     := &Type{kind = .Int,     size = 2, align = 2}
t_i32     := &Type{kind = .Int,     size = 4, align = 4}
t_i64     := &Type{kind = .Int,     size = 8, align = 8}

t_u8      := &Type{kind = .Uint,    size = 1, align = 1}
t_u16     := &Type{kind = .Uint,    size = 2, align = 2}
t_u32     := &Type{kind = .Uint,    size = 4, align = 4}
t_u64     := &Type{kind = .Uint,    size = 8, align = 8}

t_f16     := &Type{kind = .Float,   size = 2, align = 2}
t_f32     := &Type{kind = .Float,   size = 4, align = 4}
t_f64     := &Type{kind = .Float,   size = 8, align = 8}

t_vec2,  t_vec3,  t_vec4:  ^Type
t_ivec2, t_ivec3, t_ivec4: ^Type

t_complex64,     t_complex128:    ^Type
t_quaternion128, t_quaternion256: ^Type

_base_type_arena_mem: [1 << 12]byte
_base_type_arena: mem.Arena

@(init)
_base_types_init :: proc "contextless" () {
	context = runtime.default_context()

	mem.arena_init(&_base_type_arena, _base_type_arena_mem[:])
	allocator := mem.arena_allocator(&_base_type_arena)

	t_vec2 = vector_new(t_f32, 2, allocator)
	t_vec3 = vector_new(t_f32, 3, allocator)
	t_vec4 = vector_new(t_f32, 4, allocator)

	t_ivec2 = vector_new(t_i32, 2, allocator)
	t_ivec3 = vector_new(t_i32, 3, allocator)
	t_ivec4 = vector_new(t_i32, 4, allocator)

	t_complex64  = complex_new(t_f32, allocator)
	t_complex128 = complex_new(t_f64, allocator)

	t_quaternion128 = quaternion_new(t_f32, allocator)
	t_quaternion256 = quaternion_new(t_f64, allocator)
}

print_writer :: proc(w: io.Writer, type: ^Type) {
	if type == nil {
		fmt.wprint(w, "<nil>")
		return
	}

	switch type.kind {
	case .Invalid:
		fmt.wprint(w, "invalid type")
	case .Struct:
		s := type.variant.(^Struct)
		fmt.wprint(w, "struct{")
		for field, i in s.fields {
			if i > 0 {
				fmt.wprint(w, ", ")
			}
			fmt.wprint(w, field.name.text)
			fmt.wprint(w, ": ")
			print_writer(w, field.type)
		}
		fmt.wprint(w, "}")
	case .Enum:
		e := type.variant.(^Enum)
		fmt.wprint(w, "enum{")
		for field, i in e.values {
			if i > 0 {
				fmt.wprint(w, ", ")
			}
			fmt.wprint(w, field.name.text)
			fmt.wprint(w, " = ")
			fmt.wprint(w, field.value)
		}
		fmt.wprint(w, "}")
	case .Matrix:
		m := type.variant.(^Matrix)
		c := m.col_type
		fmt.wprintf(w, "matrix[%d, %d]", m.cols, c.count)
		print_writer(w, c.elem)
	case .Vector:
		v := type.variant.(^Vector)
		fmt.wprintf(w, "vector[%d]", v.count)
		print_writer(w, v.elem)
	case .Buffer:
		v := type.variant.(^Buffer)
		fmt.wprintf(w, "buffer[]")
		print_writer(w, v.elem)
	case .Proc:
		b := type.variant.(^Proc)
		fmt.wprint(w, "proc(")
		for arg, i in b.args {
			if i > 0 {
				fmt.wprint(w, ", ")
			}
			fmt.wprint(w, arg.name.text)
			fmt.wprint(w, ": ")
			print_writer(w, arg.type)
		}
		fmt.wprint(w, ") -> (")
		for ret, i in b.returns {
			if i > 0 {
				fmt.wprint(w, ", ")
			}
			if len(ret.name.text) != 0 {
				fmt.wprint(w, ret.name.text)
				fmt.wprint(w, ": ")
			}
			print_writer(w, ret.type)
		}
		fmt.wprint(w, ")")
	case .Proc_Group:
		g := type.variant.(^Proc_Group)
		fmt.wprint(w, "proc{ ")
		for member in g.members {
			print_writer(w, member)
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
		for type, i in type.variant.(^Struct).fields {
			if i > 0 {
				fmt.wprint(w, ", ")
			}
			print_writer(w, type.type)
		}
		fmt.wprint(w, ")")
	case .Sampler:
		type := type.variant.(^Image)
		fmt.wprintf(w, "sampler[%d]", type.dimensions)
		print_writer(w, type.texel_type)
	case .Image:
		type := type.variant.(^Image)
		fmt.wprintf(w, "image[%d]", type.dimensions)
		print_writer(w, type.texel_type)
	case .Bit_Set:
		type := type.variant.(^Bit_Set)
		fmt.wprintf(w, "bit_set[")
		print_writer(w, type.enum_type)
		fmt.wprintf(w, ";")
		print_writer(w, type.backing)
		fmt.wprintf(w, "]")
	}
}

@(require_results)
print_string :: proc(type: ^Type, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	print_writer(strings.to_writer(&b), type)
	return strings.to_string(b)
}

@(require_results)
equal :: proc(a, b: ^Type) -> bool {
	if a == b {
		return true
	}

	if a == nil || b == nil {
		return false
	}

	if a.kind != b.kind {
		return false
	}

	#partial switch a.kind {
	case .Int, .Bool, .Float:
		return a.size == b.size && a.align == b.align

	case .Struct:
		a := a.variant.(^Struct)
		b := b.variant.(^Struct)
		if len(a.fields) != len(b.fields) {
			return false
		}

		for i in 0 ..< len(a.fields) {
			if a.fields[i].offset != b.fields[i].offset {
				return false
			}
			if a.fields[i].location != b.fields[i].location {
				return false
			}
			if !equal(a.fields[i].type, b.fields[i].type) {
				return false
			}
		}

		return true

	case .Matrix:
		a := a.variant.(^Matrix)
		b := b.variant.(^Matrix)

		if a.cols != b.cols {
			return false
		}

		return equal(a.col_type, b.col_type)
	case .Vector:
		a := a.variant.(^Vector)
		b := b.variant.(^Vector)

		if a.count != b.count {
			return false
		}

		return equal(a.elem, b.elem)
	case .Proc:
		a := a.variant.(^Proc)
		b := b.variant.(^Proc)
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
			if !equal(a.args[i].type, b.args[i].type) {
				return false
			}
		}

		for i in 0 ..< len(a.returns) {
			if a.returns[i].location != b.returns[i].location {
				return false
			}
			if !equal(a.returns[i].type, b.returns[i].type) {
				return false
			}
		}

		return true

	case .Sampler, .Image:
		a := a.variant.(^Image)
		b := b.variant.(^Image)

		if a.dimensions != b.dimensions {
			return false
		}

		if a.format != b.format {
			return false
		}

		return equal(a.texel_type, b.texel_type)
	}

	return true
}

@(require_results)
base_type :: proc(type: ^Type, keep_complex := false) -> ^Type {
	type := type
	for {
		#partial switch type.kind {
		case .Tuple: 
			return type
		case .Enum:
			type = type.variant.(^Enum).backing
		case .Bit_Set:
			type = type.variant.(^Bit_Set).backing
		case .Quaternion, .Complex:
			if keep_complex {
				return type
			}
			type = type.variant.(^Complex).vector
		case:
			return type
		}
	}
	return type
}

@(require_results)
implicitly_castable :: proc(from, to: ^Type) -> bool {
	to   := base_type(to)
	from := base_type(from)

	if equal(from, to) {
		return true
	}

	if from.size == 0 {
		if to.kind == .Int && from.kind == .Float {
			return false
		}
		return true
	}

	if is_numeric(from) && to.kind == .Vector {
		return implicitly_castable(from, vector_elem(to))
	}

	if is_numeric(from) && to.kind == .Matrix {
		return implicitly_castable(from, matrix_elem(to))
	}

	return false
}

@(require_results)
op_result_type :: proc(a, b: ^Type, is_multiply: bool = false, allocator: mem.Allocator = {}) -> ^Type {
	if is_multiply && (is_matrix(a) || is_matrix(b)) {
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
	// type := base_type(type)

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
	if equal(from, to) {
		return true
	}

	if implicitly_castable(from, to) {
		return true
	}

	if is_numeric(from) && is_numeric(to) {
		return true
	}

	if is_bool(from) && is_integer(to) {
		return true
	}

	if is_numeric(from) && is_vector(to) {
		return true
	}

	if is_vector(from) && is_vector(to) {
		return vector_len(from) == vector_len(to)
	}

	return false
}

@(require_results)
is_vector :: proc(type: ^Type) -> bool {
	return type.kind == .Vector
}

@(require_results)
is_complex :: proc(type: ^Type) -> bool {
	return type.kind == .Complex
}

@(require_results)
is_quaternion :: proc(type: ^Type) -> bool {
	return type.kind == .Quaternion
}

@(require_results)
is_tuple :: proc(type: ^Type) -> bool {
	return type.kind == .Tuple
}

@(require_results)
is_buffer :: proc(type: ^Type) -> bool {
	return type.kind == .Buffer
}

@(require_results)
is_matrix :: proc(type: ^Type) -> bool {
	return type.kind == .Matrix
}

@(require_results)
is_struct :: proc(type: ^Type) -> bool {
	return type.kind == .Struct
}

@(require_results)
is_bool :: proc(type: ^Type) -> bool {
	return type.kind == .Bool
}

@(require_results)
is_numeric :: proc(type: ^Type) -> bool {
	#partial switch type.kind {
	case .Float, .Int, .Uint:
		return true
	}
	return false
}

@(require_results)
is_integer :: proc(type: ^Type) -> bool {
	#partial switch type.kind {
	case .Int, .Uint:
		return true
	}
	return false
}

@(require_results)
is_float :: proc(type: ^Type) -> bool {
	#partial switch type.kind {
	case .Float:
		return true
	}
	return false
}

@(require_results)
is_boolean :: proc(type: ^Type) -> bool {
	#partial switch type.kind {
	case .Bool:
		return true
	}
	return false
}

@(require_results)
vector_len :: proc(type: ^Type) -> int {
	return type.variant.(^Vector).count
}

@(require_results)
vector_elem :: proc(type: ^Type) -> ^Type {
	return type.variant.(^Vector).elem
}

@(require_results)
complex_elem :: proc(type: ^Type) -> ^Type {
	return type.variant.(^Complex).vector.elem
}

@(require_results)
buffer_elem :: proc(type: ^Type) -> ^Type {
	return type.variant.(^Buffer).elem
}

@(private="file")
to_bytes :: proc(v: $P/^$T) -> []byte {
	return ([^]byte)(v)[:size_of(T)]
}

@(require_results)
type_hash :: proc(type: ^Type, seed: u64 = 0xcbf29ce484222325) -> u64 {
	h := hash.fnv64a(to_bytes(type)[:offset_of(Type, variant)], seed)

	switch v in type.variant {
	case ^Struct:
		for field in v.fields {
			h = type_hash(field.type, h)
		}
	case ^Matrix:
		h = type_hash(v.col_type, h)
		h = hash.fnv64a(to_bytes(&v.cols), h)
	case ^Vector:
		h = type_hash(v.elem, h)
		h = hash.fnv64a(to_bytes(&v.count), h)
	case ^Complex:
		h = type_hash(v.vector, h)
	case ^Proc:
		for field in v.args {
			h = type_hash(field.type, h)
		}
		for field in v.returns {
			h = type_hash(field.type, h)
		}
	case ^Proc_Group:
		unimplemented()
	case ^Image:
		h = type_hash(v.texel_type, h)
		h = hash.fnv64a(to_bytes(&v.dimensions), h)
		h = hash.fnv64a(transmute([]byte)v.format, h)
	case ^Enum:
		for &val in v.values {
			h = hash.fnv64a(to_bytes(&val.value), h)
		}
	case ^Buffer:
		h = hash.fnv64a(to_bytes(&v.physical), h)
		h = type_hash(v.elem, h)
	case ^Bit_Set:
		h = type_hash(v.enum_type, h)
		h = type_hash(v.backing,   h)
	}

	return h
}

@(require_results)
matrix_multiply_type :: proc(a, b: ^Type, allocator: mem.Allocator) -> ^Type {
	if a == nil || b == nil {
		return t_invalid
	}

	assert(a.kind == .Matrix || b.kind == .Matrix)

	if a.kind == .Matrix && b.kind == .Matrix {
		a := a.variant.(^Matrix)
		b := b.variant.(^Matrix)

		if a.cols != b.col_type.count {
			return t_invalid
		}

		if !equal(a.col_type.elem, b.col_type.elem) {
			return t_invalid
		}

		col := vector_new(a.col_type.elem, a.col_type.count, allocator)
		return matrix_new(col, b.cols, allocator)
	}

	if a.kind == .Matrix && b.kind == .Vector {
		a := a.variant.(^Matrix)
		v := b.variant.(^Vector)

		if a.cols != v.count {
			return t_invalid
		}

		if !equal(v.elem, matrix_elem(a)) {
			return t_invalid
		}

		return vector_new(v.elem, a.col_type.count, allocator)
	}

	if a.kind == .Vector && b.kind == .Matrix {
		v := a.variant.(^Vector)
		b := b.variant.(^Matrix)

		if v.count != b.col_type.count {
			return t_invalid
		}

		if !equal(v.elem, matrix_elem(b)) {
			return t_invalid
		}

		return vector_new(v.elem, b.cols, allocator)
	}

	if a.kind == .Float {
		if op_result_type(a, matrix_elem(b)) == t_invalid {
			return t_invalid
		}
		return b
	}

	if b.kind == .Float {
		if op_result_type(b, matrix_elem(a)) == t_invalid {
			return t_invalid
		}
		return a
	}

	return t_invalid
}

@(require_results)
matrix_elem :: proc(type: ^Type) -> ^Type {
	return type.variant.(^Matrix).col_type.elem
}

@(require_results)
matrix_is_square :: proc(t: ^Type) -> bool {
	m := t.variant.(^Matrix)
	return m.col_type.count == m.cols
}

@(require_results)
vector_new :: proc(elem: ^Type, count: int, allocator: mem.Allocator) -> ^Vector {
	assert(elem      != nil)
	assert(elem.size != 0)

	type := new(.Vector, Vector, allocator)
	type.elem  = elem
	type.count = count
	type.align = elem.align
	type.size  = mem.align_forward_int(count * elem.size, type.align)

	return type
}

@(require_results)
complex_new :: proc(elem: ^Type, allocator: mem.Allocator) -> ^Complex {
	assert(elem      != nil)
	assert(elem.size != 0)

	type       := new(.Complex, Complex, allocator)
	type.vector = vector_new(elem, 2, allocator)
	type.size   = type.vector.size
	type.align  = type.vector.align

	return type
}

@(require_results)
quaternion_new :: proc(elem: ^Type, allocator: mem.Allocator) -> ^Complex {
	assert(elem      != nil)
	assert(elem.size != 0)

	type       := new(.Quaternion, Complex, allocator)
	type.vector = vector_new(elem, 4, allocator)
	type.size   = type.vector.size
	type.align  = type.vector.align

	return type
}

@(require_results)
buffer_new :: proc(elem: ^Type, physical: bool, allocator: mem.Allocator) -> ^Buffer {
	assert(elem      != nil)
	assert(elem.size != 0)

	type := new(.Buffer, Buffer, allocator)
	type.elem     = elem
	type.size     = 8
	type.align    = 8
	type.physical = physical

	return type
}

@(require_results)
sampler_new :: proc(texel_type: ^Type, dimensions: int, allocator: mem.Allocator) -> ^Image {
	assert(texel_type      != nil)
	assert(texel_type.size != 0 || texel_type.kind == .Invalid)

	type           := new(.Sampler, Image, allocator)
	type.texel_type = texel_type
	type.dimensions = dimensions

	return type
}

@(require_results)
image_new :: proc(texel_type: ^Type, dimensions: int, format: string, allocator: mem.Allocator) -> ^Image {
	assert(texel_type      != nil)
	assert(texel_type.size != 0 || texel_type.kind == .Invalid)

	type           := new(.Image, Image, allocator)
	type.texel_type = texel_type
	type.dimensions = dimensions
	type.format     = format

	return type
}

@(require_results)
matrix_new :: proc(col_type: ^Vector, cols: int, allocator: mem.Allocator) -> ^Matrix {
	assert(col_type      != nil)
	assert(col_type.size != 0)

	type         := new(.Matrix, Matrix, allocator)
	type.col_type = col_type
	type.cols     = cols
	type.size     = cols * col_type.size
	type.align    = col_type.align

	return type
}

// @(require_results)
// struct_new :: proc(fields: []Field, allocator: mem.Allocator) -> ^Struct {
// 	type       := new(.Struct, Struct, allocator)
// 	type.fields = fields

// 	offset: int
// 	for &field in fields {
// 		if field.type.align != 0 {
// 			offset = mem.align_forward_int(offset, field.type.align)
// 		}
// 		field.offset = offset
// 		offset      += type.size
// 		type.align   = max(type.align, field.type.align)
// 	}
// 	type.size = offset
// 	return type
// }

@(require_results)
bit_set_new :: proc(enum_type: ^Type, backing: ^Type, allocator: mem.Allocator) -> ^Bit_Set {
	assert(enum_type != nil)
	assert(backing   != nil)

	type           := new(.Bit_Set, Bit_Set, allocator)
	type.enum_type  = enum_type
	type.backing    = backing
	type.size       = backing.size
	type.align      = backing.align

	return type
}

@(require_results)
is_comparable :: proc(type: ^Type) -> bool{
	#partial switch type.kind {
	case .Proc, .Tuple:
		return false
	}
	return true
}

@(require_results)
is_sampler :: proc(type: ^Type) -> bool {
	return type.kind == .Sampler
}

@(require_results)
is_image :: proc(type: ^Type) -> bool {
	return type.kind == .Image
}

@(require_results)
operator_applicable :: proc(type: ^Type, op: tokenizer.Token_Kind) -> bool {
	if is_comparable(type) && (op == .Equal || op == .Not_Equal) {
		return true
	}

	if is_float(type) && op == .Modulo_Floored {
		return false
	}

	if is_numeric(type) {
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
	case .Int, .Uint:
		#partial switch op {
		case .Bit_Or, .Bit_And, .Xor, .Shift_Left, .Shift_Right:
			return true
		}
	case .Bool:
		#partial switch op {
		case .Not, .And, .Or:
			return true
		}
	case .Vector:
		return operator_applicable(vector_elem(type), op)
	case .Complex:
		return operator_applicable(complex_elem(type), op)
	case .Quaternion:
		return operator_applicable(complex_elem(type), op)
	case .Matrix:
		return operator_applicable(matrix_elem(type), op)
	}

	return false
}
