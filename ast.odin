package hephaistos

import "base:intrinsics"

import spv "spirv-odin"

@(require)
import "core:mem"

Ast_Node :: struct {
	start, end: Location,
	derived:    Any_Node,
}

Ast_Expr :: struct {
	using expr_base: Ast_Node,
	derived_expr:    Any_Expr,
	type:           ^Type,
	const_value:     Const_Value,
}

Ast_Stmt :: struct {
	using stmt_base: Ast_Node,
	attributes:    []Ast_Field,
	derived_stmt:    Any_Stmt,
}

Ast_Decl :: struct {
	using decl_base: Ast_Stmt,
	derived_decl:    Any_Decl,
}

Ast_Field :: struct {
	name:        ^Expr_Ident,
	type:        ^Ast_Expr,
	value:       ^Ast_Expr,
	location:    ^Ast_Expr, // location for proc params, libraries for attributes
	flags:        Entity_Flags,
	member_index: int,
	swizzle:    []u32,
}


Expr_Binary :: struct {
	using node: Ast_Expr,
	op:         Token_Kind,
	lhs, rhs:  ^Ast_Expr,
}

Expr_Unary :: struct {
	using node: Ast_Expr,
	op:         Token_Kind,
	expr:      ^Ast_Expr,
}

Expr_Ternary :: struct {
	using node: Ast_Expr,
	cond:      ^Ast_Expr,
	then_expr: ^Ast_Expr,
	else_expr: ^Ast_Expr,
}

Expr_Constant :: struct {
	using node: Ast_Expr,
	value:      Const_Value,
	imaginary:  Imaginary,
}

Expr_Ident :: struct {
	using node: Ast_Expr,
	text:       string,
	entity:    ^Entity,
	library:    string,
}

Expr_Interface :: struct {
	using node: Ast_Expr,
	ident:      Token,
	library:    Token,
}

Directive :: enum {
	Invalid = 0,
	Assert,
	Panic,
	Import,
	Config,
	Capability,
}

@(rodata)
directive_names: [Directive]string = {
	.Invalid    = "<invalid>",
	.Assert     = "assert",
	.Panic      = "panic",
	.Import     = "import",
	.Config     = "config",
	.Capability = "capability",
}

Expr_Directive :: struct {
	using node: Ast_Expr,
	directive:  Directive,
	token:      Token,
}

Shader_Stage :: enum {
	Invalid = 0,
	Vertex,
	Fragment,
	Geometry,
	Tesselation_Control,
	Tesselation_Evaluation,
	Compute,
	Ray_Generation,
	Intersection,
	Any_Hit,
	Closest_Hit,
	Miss,
}

@(rodata)
shader_stage_names: [Shader_Stage]string = {
	.Invalid                = "<invalid shader stage>",
	.Vertex                 = "vertex_shader",
	.Fragment               = "fragment_shader",
	.Geometry               = "geometry_shader",
	.Tesselation_Control    = "tesselation_control_shader",
	.Tesselation_Evaluation = "tesselation_evaluation_shader",
	.Compute                = "compute_shader",

	.Ray_Generation         = "raytracing.ray_generation_shader",
	.Intersection           = "raytracing.intersection_shader",
	.Any_Hit                = "raytracing.any_hit_shader",
	.Closest_Hit            = "raytracing.closest_hit_shader",
	.Miss                   = "raytracing.miss_shader",
}

Expr_Proc_Lit :: struct {
	using sig: Expr_Proc_Sig,
	body:   []^Ast_Stmt,
	scope:    ^Scope,
}

Expr_Proc_Sig :: struct {
	using node: Ast_Expr,
	args:     []Ast_Field,
	returns:  []Ast_Field,
	diverging:  bool,
}

Expr_Proc_Group :: struct {
	using node: Ast_Expr,
	members: []^Ast_Expr,
}

Builtin_Id :: enum {
	Invalid = 0,

	Min,
	Max,
	Clamp,

	Inverse,
	Transpose,
	Determinant,

	Dot,
	Cross,
	Distance,
	Normalize,
	Length,
	Reflect,
	Refract,

	Pow,
	Sqrt,
	Sin,
	Cos,
	Tan,
	Sinh,
	Cosh,
	Tanh,
	Asin,
	Acos,
	Atan,
	Asinh,
	Acosh,
	Atanh,
	Atan2,
	Exp,
	Log,
	Exp2,
	Log2,
	Fract,
	Floor,
	Ceil,
	Round,
	Trunc,
	Inverse_Sqrt,
	Abs,
	Sign,
	Copy_Sign,
	Card,

	Smooth_Step,
	Lerp,

	Real,
	Imag,
	Jmag,
	Kmag,
	Conj,

	Texture_Size,
	Image_Size,

	Discard,

	Ddx,
	Ddy,
	Fwidth,

	Size_Of,
	Align_Of,
	Type_Of,

	/* intrinsics */

	Type_Is_Uint,
	Type_Is_Int,
	Type_Is_Bool,
	Type_Is_Float,
	Type_Is_Any,
	Type_Is_Struct,
	Type_Is_Matrix,
	Type_Is_Array,
	Type_Is_Buffer,
	Type_Is_Proc,
	Type_Is_Proc_Group,
	Type_Is_Sampler,
	Type_Is_Image,
	Type_Is_Enum,
	Type_Is_Bit_Set,
	Type_Is_Complex,
	Type_Is_Quaternion,
	Type_Is_Opaque,
	Type_Is_Named,

	Count_Ones,
	Count_Zeros,
	Count_Leading_Zeros,
	Count_Trailing_Zeros,
	Count_Leading_Ones,
	Count_Trailing_Ones,
	Find_Lsb,
	Find_Msb,
	Reverse_Bits,

	Barrier,
}

Expr_Call :: struct {
	using node:   Ast_Expr,
	lhs:         ^Ast_Expr,
	args:       []Ast_Field,
	group_member: Maybe(int),
	builtin:      Builtin_Id,
	is_cast:      bool,
	is_directive: bool,
}

Expr_Paren :: struct {
	using node: Ast_Expr,
	expr:      ^Ast_Expr,
}

Expr_Selector :: struct {
	using node:  Ast_Expr,
	lhs:        ^Ast_Expr,
	selector:   ^Expr_Ident,
	swizzle:   []u32,
}

Expr_Compound :: struct {
	using node: Ast_Expr,
	type_expr: ^Ast_Expr,
	fields:   []Ast_Field,
	named:      bool,
	constant:   bool,
}

Expr_Index :: struct {
	using node: Ast_Expr,
	lhs, rhs:  ^Ast_Expr,
}

Expr_Cast :: struct {
	using node: Ast_Expr,
	value:     ^Ast_Expr,
	type_expr: ^Ast_Expr,
}

Expr_Ellipsis :: struct {
	using node: Ast_Expr,
	expr:      ^Ast_Expr,
}


Expr_Type_Struct :: struct {
	using node: Ast_Expr,
	fields:   []Ast_Field,
}

Expr_Type_Array :: struct {
	using node: Ast_Expr,
	count:     ^Ast_Expr,
	elem:      ^Ast_Expr,
	physical:   bool,
}

Expr_Type_Matrix :: struct {
	using node: Ast_Expr,
	rows:      ^Ast_Expr,
	cols:      ^Ast_Expr,
	elem:      ^Ast_Expr,
}

Expr_Type_Image :: struct {
	using node:  Ast_Expr,
	dimensions: ^Ast_Expr,
	texel_type: ^Ast_Expr,
	is_sampler:  bool,
	format:      Token,
}

Expr_Type_Enum :: struct {
	using node: Ast_Expr,
	values:   []Ast_Field,
	backing:   ^Ast_Expr,
}

Expr_Type_Bit_Set :: struct {
	using node: Ast_Expr,
	enum_type: ^Ast_Expr,
	backing:   ^Ast_Expr,
}

Expr_Type_Opaque :: struct {
	using node: Ast_Expr,
	name:      ^Expr_Ident,
	backing:   ^Ast_Expr,
}

Expr_Type_Distinct :: struct {
	using node: Ast_Expr,
	backing:   ^Ast_Expr,
}

Expr_Type_Fixed :: struct {
	using node:      Ast_Expr,
	signed:          bool,
	integral_bits:   i64,
	fractional_bits: i64,
}


Interface_Kind :: enum {
	None = 0,
	Uniform,
	Uniform_Buffer,
	Push_Constant,
	Storage_Buffer,
	Shared,

	Input,
	Output,

	Ray_Payload,
	Incoming_Ray_Payload,
	Hit_Attribute,
}

@(rodata)
interface_kind_names := [Interface_Kind]string {
	.None                 = "none",
	.Uniform              = "uniform",
	.Uniform_Buffer       = "uniform_buffer",
	.Push_Constant        = "push_constant",
	.Storage_Buffer       = "storage_buffer",
	.Shared               = "shared",

	.Input                = "input",
	.Output               = "output",

	.Ray_Payload          = "raytracing.ray_payload",
	.Hit_Attribute        = "raytracing.hit_attribute",
	.Incoming_Ray_Payload = "raytracing.incoming_ray_payload",
}

Decl_Value :: struct {
	using node:     Ast_Decl,
	lhs:         []^Expr_Ident,
	type_expr:     ^Ast_Expr,
	values:      []^Ast_Expr,
	mutable:        bool,
	binding:        i64,
	location:       i64,
	descriptor_set: i64,
	link_name:      string,
	local_size:  [3]i32,
	shader_stage:   Shader_Stage,
	interface:      Interface_Kind,
	builtin:        Maybe(spv.BuiltIn),
}

Decl_Import :: struct {
	using node: Ast_Decl,
	path:      ^Expr_Constant,
	alias:     ^Expr_Ident,
	entity:    ^Entity,
}

Decl_Extension :: struct {
	using node: Ast_Decl,
	extension: ^Ast_Expr,
	body:    []^Ast_Stmt,
}

Stmt_Return :: struct {
	using node: Ast_Stmt,
	values:  []^Ast_Expr,
}

Stmt_Break :: struct {
	using node: Ast_Stmt,
	label:     ^Expr_Ident,
}

Stmt_Continue :: struct {
	using node: Ast_Stmt,
	label:     ^Expr_Ident,
}

Stmt_For_Range :: struct {
	using node:  Ast_Stmt,
	label:      ^Expr_Ident,
	start_expr: ^Ast_Expr,
	end_expr:   ^Ast_Expr,
	variable:   ^Expr_Ident,
	body:     []^Ast_Stmt,
	inclusive:   bool,
	init_scope: ^Scope,
	scope:      ^Scope,
}

Stmt_For :: struct {
	using node:  Ast_Stmt,
	label:      ^Expr_Ident,
	init:       ^Ast_Stmt,
	cond:       ^Ast_Expr,
	post:       ^Ast_Stmt,
	body:     []^Ast_Stmt,
	init_scope: ^Scope,
	scope:      ^Scope,
}

Stmt_Block :: struct {
	using node: Ast_Stmt,
	label:     ^Expr_Ident,
	body:    []^Ast_Stmt,
	scope:     ^Scope,
}

Stmt_If :: struct {
	using node:    Ast_Stmt,
	label:        ^Expr_Ident,
	init:         ^Ast_Stmt,
	init_scope:   ^Scope,
	cond:         ^Ast_Expr,
	then_block: []^Ast_Stmt,
	then_scope:   ^Scope,
	else_block: []^Ast_Stmt,
	else_scope:   ^Scope,
}

Stmt_When :: struct {
	using node:    Ast_Stmt,
	label:        ^Expr_Ident,
	cond:         ^Ast_Expr,
	then_block: []^Ast_Stmt,
	else_block: []^Ast_Stmt,
	scope:        ^Scope,
}

Switch_Case :: struct {
	token:   Token,
	value:  ^Ast_Expr,
	body: []^Ast_Stmt,
	scope:  ^Scope,
}

Stmt_Switch :: struct {
	using node:     Ast_Stmt,
	label:         ^Expr_Ident,
	init:          ^Ast_Stmt,
	cond:          ^Ast_Expr,
	cases:        []Switch_Case,
	constant_cases: bool,
	scope:         ^Scope,
}

Stmt_Assign :: struct {
	using node:  Ast_Stmt,
	lhs, rhs: []^Ast_Expr,
	op:          Token_Kind,
}

Stmt_Expr :: struct {
	using node: Ast_Stmt,
	expr:      ^Ast_Expr,
}


Any_Node :: union {
	^Expr_Constant,
	^Expr_Binary,
	^Expr_Ident,
	^Expr_Proc_Lit,
	^Expr_Proc_Sig,
	^Expr_Proc_Group,
	^Expr_Paren,
	^Expr_Selector,
	^Expr_Call,
	^Expr_Compound,
	^Expr_Index,
	^Expr_Cast,
	^Expr_Unary,
	^Expr_Interface,
	^Expr_Directive,
	^Expr_Ternary,
	^Expr_Ellipsis,

	^Expr_Type_Struct,
	^Expr_Type_Array,
	^Expr_Type_Matrix,
	^Expr_Type_Image,
	^Expr_Type_Enum,
	^Expr_Type_Bit_Set,
	^Expr_Type_Opaque,
	^Expr_Type_Distinct,
	^Expr_Type_Fixed,

	^Stmt_Return,
	^Stmt_Break,
	^Stmt_Continue,
	^Stmt_For_Range,
	^Stmt_For,
	^Stmt_Block,
	^Stmt_If,
	^Stmt_Switch,
	^Stmt_Assign,
	^Stmt_Expr,
	^Stmt_When,

	^Decl_Value,
	^Decl_Import,
	^Decl_Extension,
}

Any_Expr :: union {
	^Expr_Constant,
	^Expr_Binary,
	^Expr_Ident,
	^Expr_Proc_Lit,
	^Expr_Proc_Sig,
	^Expr_Proc_Group,
	^Expr_Paren,
	^Expr_Selector,
	^Expr_Call,
	^Expr_Compound,
	^Expr_Index,
	^Expr_Cast,
	^Expr_Unary,
	^Expr_Interface,
	^Expr_Directive,
	^Expr_Ternary,
	^Expr_Ellipsis,

	^Expr_Type_Struct,
	^Expr_Type_Array,
	^Expr_Type_Matrix,
	^Expr_Type_Image,
	^Expr_Type_Enum,
	^Expr_Type_Bit_Set,
	^Expr_Type_Opaque,
	^Expr_Type_Distinct,
	^Expr_Type_Fixed,
}

Any_Decl :: union {
	^Decl_Value,
	^Decl_Import,
	^Decl_Extension,
}

Any_Stmt :: union {
	^Stmt_Return,
	^Stmt_Break,
	^Stmt_Continue,
	^Stmt_For_Range,
	^Stmt_For,
	^Stmt_Block,
	^Stmt_If,
	^Stmt_Switch,
	^Stmt_Assign,
	^Stmt_Expr,
	^Stmt_When,

	^Decl_Value,
	^Decl_Import,
	^Decl_Extension,
}

@(require_results)
ast_new :: proc($T: typeid, start, end: Location, allocator: mem.Allocator) -> ^T {
	n, _ := mem.new(T, allocator)
	n.start   = start
	n.end     = end
	n.derived = n
	base: ^Ast_Node = n // dummy check
	_ = base // "Use" type to make -vet happy
	when intrinsics.type_has_field(T, "derived_expr") {
		n.derived_expr = n
	}
	when intrinsics.type_has_field(T, "derived_stmt") {
		n.derived_stmt = n
	}
	when intrinsics.type_has_field(T, "derived_decl") {
		n.derived_decl = n
	}
	return n
}

Library :: struct {
	scope:   ^Scope,
	stmts: []^Ast_Stmt,
}
