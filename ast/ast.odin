package hephaistos_ast

import "base:intrinsics"

@(require)
import "core:mem"

import "../tokenizer"
import "../types"

Node :: struct {
	start, end: tokenizer.Location,
	derived:    Any_Node,
}

Expr :: struct {
	using expr_base: Node,
	derived_expr:    Any_Expr,
	type:           ^types.Type,
	const_value:     types.Const_Value,
}

Stmt :: struct {
	using stmt_base: Node,
	attributes:    []Field,
	derived_stmt:    Any_Stmt,
}

Decl :: struct {
	using decl_base: Stmt,
	derived_decl:    Any_Decl,
}

Field :: struct {
	name:       ^Expr_Ident,
	type:       ^Expr,
	value:      ^Expr,
	location:   ^Expr, // location for proc params, libraries for attributes
	member_index: int,
	swizzle:    []u32,
}


Expr_Binary :: struct {
	using node: Expr,
	op:         tokenizer.Token_Kind,
	lhs, rhs:  ^Expr,
}

Expr_Unary :: struct {
	using node: Expr,
	op:         tokenizer.Token_Kind,
	expr:      ^Expr,
}

Expr_Ternary :: struct {
	using node: Expr,
	cond:      ^Expr,
	then_expr: ^Expr,
	else_expr: ^Expr,
}

Expr_Constant :: struct {
	using node: Expr,
	value:      types.Const_Value,
	imaginary:  tokenizer.Imaginary,
}

Expr_Ident :: struct {
	using node: Expr,
	text:       string,
	entity:    ^Entity,
	library:    string,
}

Expr_Interface :: struct {
	using node: Expr,
	ident:      tokenizer.Token,
	library:    tokenizer.Token,
}

Directive :: enum {
	Invalid = 0,
	Assert,
	Panic,
	Import,
	Config,
}

@(rodata)
directive_names: [Directive]string = {
	.Invalid = "<invalid>",
	.Assert  = "assert",
	.Panic   = "panic",
	.Import  = "import",
	.Config  = "config",
}

Expr_Directive :: struct {
	using node: Expr,
	directive:  Directive,
	token:      tokenizer.Token,
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
	body:   []^Stmt,
	scope:    ^Scope,
}

Expr_Proc_Sig :: struct {
	using node: Expr,
	args:     []Field,
	returns:  []Field,
}

Expr_Proc_Group :: struct {
	using node: Expr,
	members: []^Expr,
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

	Smooth_Step,
	Lerp,

	Real,
	Imag,
	Jmag,
	Kmag,

	Texture_Size,
	Image_Size,

	Discard,

	Ddx,
	Ddy,

	Size_Of,
	Align_Of,
	Type_Of,

	/* intrinsics */

	Type_Is_Array,
	Type_Is_Float,
	Type_Is_Boolean,
	Type_Is_Integer,
	Type_Is_Numeric,
	Type_Is_Complex,
	Type_Is_Quaternion,
	Type_Is_Matrix,

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

	/** extensions **/

	/* clock */
	Read_Subgroup_Clock,
	Read_Device_Clock,

	/* raytracing */
	Trace_Ray,
	Report_Intersection,
	Ignore_Intersection,
	Terminate_Ray,

	/* ray query */
	Ray_Query_Initialize,
	Generate_Intersection,
	Terminate,
	Confirm_Intersection,
	Proceed,

	Get_Ray_T_Min,
	Get_Ray_Flags,
	Get_Intersection_Candidate_AABB_Opaque,
	Get_World_Ray_Direction,
	Get_World_Ray_Origin,

	Get_Candidate_Intersection_Type,
	Get_Commited_Intersection_Type,

	Get_Candidate_Intersection_T,
	Get_Commited_Intersection_T,

	Get_Candidate_Intersection_Instance_Custom_Index,
	Get_Commited_Intersection_Instance_Custom_Index,

	Get_Candidate_Intersection_Instance_Id,
	Get_Commited_Intersection_Instance_Id,

	Get_Candidate_Intersection_Instance_Sbt_Offset,
	Get_Commited_Intersection_Instance_Sbt_Offset,

	Get_Candidate_Intersection_Geometry_Index,
	Get_Commited_Intersection_Geometry_Index,

	Get_Candidate_Intersection_Primitive_Index,
	Get_Commited_Intersection_Primitive_Index,

	Get_Candidate_Intersection_Barycentrics,
	Get_Commited_Intersection_Barycentrics,

	Get_Candidate_Intersection_Front_Face,
	Get_Commited_Intersection_Front_Face,

	Get_Candidate_Intersection_Object_Ray_Direction,
	Get_Commited_Intersection_Object_Ray_Direction,

	Get_Candidate_Intersection_Object_Ray_Origin,
	Get_Commited_Intersection_Object_Ray_Origin,

	Get_Candidate_Intersection_Object_To_World,
	Get_Commited_Intersection_Object_To_World,

	Get_Candidate_Intersection_World_To_Object,
	Get_Commited_Intersection_World_To_Object,
}

Expr_Call :: struct {
	using node:   Expr,
	lhs:         ^Expr,
	args:       []Field,
	group_member: Maybe(int),
	builtin:      Builtin_Id,
	is_cast:      bool,
	is_directive: bool,
}

Expr_Paren :: struct {
	using node: Expr,
	expr:      ^Expr,
}

Expr_Selector :: struct {
	using node:  Expr,
	lhs:        ^Expr,
	entity:     ^Entity,
	selector:   ^Expr_Ident,
	field_index: int,
	swizzle:     []u32,
}

Expr_Compound :: struct {
	using node: Expr,
	type_expr: ^Expr,
	fields:   []Field,
	named:      bool,
	constant:   bool,
}

Expr_Index :: struct {
	using node: Expr,
	lhs, rhs:  ^Expr,
}

Expr_Cast :: struct {
	using node: Expr,
	value:     ^Expr,
	type_expr: ^Expr,
}

Expr_Ellipsis :: struct {
	using node: Expr,
	expr:      ^Expr,
}


Type_Struct :: struct {
	using node: Expr,
	fields:   []Field,
}

Type_Array :: struct {
	using node: Expr,
	count:     ^Expr,
	elem:      ^Expr,
	physical:   bool,
}

Type_Matrix :: struct {
	using node: Expr,
	rows:      ^Expr,
	cols:      ^Expr,
	elem:      ^Expr,
}

Type_Image :: struct {
	using node:  Expr,
	dimensions: ^Expr,
	texel_type: ^Expr,
	is_sampler:  bool,
	format:      tokenizer.Token,
}

Type_Enum :: struct {
	using node: Expr,
	values:   []Field,
	backing:   ^Expr,
}

Type_Bit_Set :: struct {
	using node: Expr,
	enum_type: ^Expr,
	backing:   ^Expr,
}


Interface_Kind :: enum {
	None = 0,
	Uniform,
	Uniform_Buffer,
	Push_Constant,
	Storage_Buffer,
	Shared,

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

	.Ray_Payload          = "raytracing.ray_payload",
	.Hit_Attribute        = "raytracing.hit_attribute",
	.Incoming_Ray_Payload = "raytracing.incoming_ray_payload",
}

Decl_Value :: struct {
	using node:     Decl,
	lhs:         []^Expr_Ident,
	type_expr:     ^Expr,
	values:      []^Expr,
	mutable:        bool,
	readonly:       bool,
	binding:        int,
	location:       int,
	descriptor_set: int,
	link_name:      string,
	local_size:  [3]i32,
	shader_stage:   Shader_Stage,
	interface:      Interface_Kind,
}

Decl_Import :: struct {
	using node: Decl,
	path:      ^Expr,
	alias:     ^Expr_Ident,
	name:       string,
}

Stmt_Return :: struct {
	using node: Stmt,
	values:  []^Expr,
}

Stmt_Break :: struct {
	using node: Stmt,
	label:     ^Expr_Ident,
}

Stmt_Continue :: struct {
	using node: Stmt,
	label:     ^Expr_Ident,
}

Stmt_For_Range :: struct {
	using node:  Stmt,
	label:      ^Expr_Ident,
	start_expr: ^Expr,
	end_expr:   ^Expr,
	variable:   ^Expr_Ident,
	body:     []^Stmt,
	inclusive:   bool,
	init_scope: ^Scope,
	scope:      ^Scope,
}

Stmt_For :: struct {
	using node:  Stmt,
	label:      ^Expr_Ident,
	init:       ^Stmt,
	cond:       ^Expr,
	post:       ^Stmt,
	body:     []^Stmt,
	init_scope: ^Scope,
	scope:      ^Scope,
}

Stmt_Block :: struct {
	using node: Stmt,
	label:     ^Expr_Ident,
	body:    []^Stmt,
	scope:     ^Scope,
}

Stmt_If :: struct {
	using node:    Stmt,
	label:        ^Expr_Ident,
	init:         ^Stmt,
	init_scope:   ^Scope,
	cond:         ^Expr,
	then_block: []^Stmt,
	then_scope:   ^Scope,
	else_block: []^Stmt,
	else_scope:   ^Scope,
}

Stmt_When :: struct {
	using node:    Stmt,
	label:        ^Expr_Ident,
	cond:         ^Expr,
	then_block: []^Stmt,
	else_block: []^Stmt,
	scope:        ^Scope,
}

Switch_Case :: struct {
	token:   tokenizer.Token,
	value:  ^Expr,
	body: []^Stmt,
	scope:  ^Scope,
}

Stmt_Switch :: struct {
	using node:     Stmt,
	label:         ^Expr_Ident,
	init:          ^Stmt,
	cond:          ^Expr,
	cases:        []Switch_Case,
	constant_cases: bool,
	scope:         ^Scope,
}

Stmt_Assign :: struct {
	using node:  Stmt,
	lhs, rhs: []^Expr,
	op:          tokenizer.Token_Kind,
}

Stmt_Expr :: struct {
	using node: Stmt,
	expr:      ^Expr,
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

	^Type_Struct,
	^Type_Array,
	^Type_Matrix,
	^Type_Image,
	^Type_Enum,
	^Type_Bit_Set,

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

	^Type_Struct,
	^Type_Array,
	^Type_Matrix,
	^Type_Image,
	^Type_Enum,
	^Type_Bit_Set,
}

Any_Decl :: union {
	^Decl_Value,
	^Decl_Import,
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
}

new :: proc($T: typeid, start, end: tokenizer.Location, allocator: mem.Allocator) -> ^T {
	n, _ := mem.new(T, allocator)
	n.start   = start
	n.end     = end
	n.derived = n
	base: ^Node = n // dummy check
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

Entity :: struct {
	kind:       Entity_Kind,
	ident:     ^Expr_Ident,
	name:       string,
	type:      ^types.Type,
	decl:      ^Decl,
	library:    string,
	value:      types.Const_Value,
	builtin_id: Builtin_Id,
	interface:  Interface_Kind,
	flags:      Entity_Flags,
	scope:     ^Scope,
}

Entity_Kind :: enum u32 {
	Invalid = 0,

	Const,
	Type,
	Var,
	Proc,
	Proc_Group,
	Builtin,
	Library,
	Label,

	Struct_Field,
	Enum_Value,
}

Entity_Flag :: enum {
	Readonly,

	In_Progress,
	Resolved,
}

Entity_Flags :: bit_set[Entity_Flag]

Scope :: struct {
	parent:    ^Scope,
	entities:   map[string]^Entity,
	proc_type: ^types.Proc,
	kind:       Scope_Kind,
}

Scope_Kind :: enum {
	Global,
	Proc,
	Block, // if or {}
	Loop,
	Switch,
}
