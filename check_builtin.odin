package hephaistos

@(rodata)
builtin_names: [Builtin_Id]string = {
	.Invalid              = "invalid",

	.Min                  = "min",
	.Max                  = "max",
	.Clamp                = "clamp",

	.Inverse              = "inverse",
	.Transpose            = "transpose",
	.Determinant          = "determinant",

	.Dot                  = "dot",
	.Cross                = "cross",
	.Distance             = "distance",
	.Normalize            = "normalize",
	.Length               = "length",
	.Reflect              = "reflect",
	.Refract              = "refract",

	.Pow                  = "pow",
	.Sqrt                 = "sqrt",
	.Sin                  = "sin",
	.Cos                  = "cos",
	.Tan                  = "tan",
	.Sinh                 = "sinh",
	.Cosh                 = "cosh",
	.Tanh                 = "tanh",
	.Asin                 = "asin",
	.Acos                 = "acos",
	.Atan                 = "atan",
	.Asinh                = "asinh",
	.Acosh                = "acosh",
	.Atanh                = "atanh",
	.Atan2                = "atan2",
	.Exp                  = "exp",
	.Log                  = "log",
	.Exp2                 = "exp2",
	.Log2                 = "log2",
	.Fract                = "fract",
	.Floor                = "floor",
	.Ceil                 = "ceil",
	.Round                = "round",
	.Trunc                = "trunc",
	.Inverse_Sqrt         = "inverse_sqrt",
	.Abs                  = "abs",
	.Sign                 = "sign",

	.Card                 = "card",

	.Smooth_Step          = "smooth_step",
	.Lerp                 = "lerp",

	.Real                 = "real",
	.Imag                 = "imag",
	.Jmag                 = "jmag",
	.Kmag                 = "kmag",
	.Conj                 = "conj",

	.Texture_Size         = "texture_size",
	.Image_Size           = "image_size",

	.Discard              = "discard",

	.Ddx                  = "ddx",
	.Ddy                  = "ddy",

	.Size_Of              = "size_of",
	.Align_Of             = "align_of",
	.Type_Of              = "type_of",

	.Type_Is_Uint         = "base:intrinsics.type_is_uint",
	.Type_Is_Int          = "base:intrinsics.type_is_int",
	.Type_Is_Bool         = "base:intrinsics.type_is_bool",
	.Type_Is_Float        = "base:intrinsics.type_is_float",
	.Type_Is_Any          = "base:intrinsics.type_is_any",
	.Type_Is_Struct       = "base:intrinsics.type_is_struct",
	.Type_Is_Matrix       = "base:intrinsics.type_is_matrix",
	.Type_Is_Array        = "base:intrinsics.type_is_array",
	.Type_Is_Buffer       = "base:intrinsics.type_is_buffer",
	.Type_Is_Proc         = "base:intrinsics.type_is_proc",
	.Type_Is_Proc_Group   = "base:intrinsics.type_is_proc_group",
	.Type_Is_Sampler      = "base:intrinsics.type_is_sampler",
	.Type_Is_Image        = "base:intrinsics.type_is_image",
	.Type_Is_Enum         = "base:intrinsics.type_is_enum",
	.Type_Is_Bit_Set      = "base:intrinsics.type_is_bit_set",
	.Type_Is_Complex      = "base:intrinsics.type_is_complex",
	.Type_Is_Quaternion   = "base:intrinsics.type_is_quaternion",
	.Type_Is_Opaque       = "base:intrinsics.type_is_opaque",
	.Type_Is_Named        = "base:intrinsics.type_is_named",

	.Count_Ones           = "base:intrinsics.count_ones",
	.Count_Zeros          = "base:intrinsics.count_zeros",
	.Count_Leading_Zeros  = "base:intrinsics.count_leading_zeros",
	.Count_Trailing_Zeros = "base:intrinsics.count_trailing_zeros",
	.Count_Leading_Ones   = "base:intrinsics.count_leading_ones",
	.Count_Trailing_Ones  = "base:intrinsics.count_trailing_ones",
	.Find_Lsb             = "base:intrinsics.find_lsb",
	.Find_Msb             = "base:intrinsics.find_msb",
	.Reverse_Bits         = "base:intrinsics.reverse_bits",

	.Barrier              = "base:intrinsics.barrier",
}

@(require_results)
check_builtin :: proc(checker: ^Checker, v: ^Expr_Call, fn: Operand) -> (operand: Operand) {
	operand.type = t_invalid
	operand.mode = .Invalid
	operand.expr = v

	v.builtin          = fn.builtin_id
	operand.builtin_id = fn.builtin_id

	allow_types := false
	#partial switch v.builtin {
	case .Size_Of,
	     .Align_Of,
	     .Min,
	     .Max,
	     .Type_Is_Uint,
	     .Type_Is_Int,
	     .Type_Is_Bool,
	     .Type_Is_Float,
	     .Type_Is_Any,
	     .Type_Is_Struct,
	     .Type_Is_Matrix,
	     .Type_Is_Array,
	     .Type_Is_Buffer,
	     .Type_Is_Proc,
	     .Type_Is_Proc_Group,
	     .Type_Is_Sampler,
	     .Type_Is_Image,
	     .Type_Is_Enum,
	     .Type_Is_Bit_Set,
	     .Type_Is_Complex,
	     .Type_Is_Quaternion,
	     .Type_Is_Opaque,
	     .Type_Is_Named:
		allow_types = true
	}

	args := make([]Operand, len(v.args), context.temp_allocator)
	for &arg, i in args {
		if allow_types {
			arg = check_expr_or_type(checker, v.args[i].value)
		} else {
			arg = check_expr(checker, v.args[i].value)
		}
	}

	switch v.builtin {
	case .Invalid:
		panic("invalid builtin")
	case .Size_Of, .Align_Of:
		if len(v.args) != 1 {
			error(checker, v, "builtin '%s' expects one argument, got %d", builtin_names[v.builtin], len(v.args))
			break
		}
		type := default_type(args[0].type)
		if v.builtin == .Size_Of {
			operand.value = i64(type.size)
		} else {
			operand.value = i64(type.align)
		}
		operand.mode = .Const
		operand.type = t_int
	case .Type_Of:
		if len(v.args) != 1 {
			error(checker, v, "builtin '%s' expects one argument, got %d", builtin_names[v.builtin], len(v.args))
			break
		}
		operand.type = args[0].type
		operand.mode = .Type
	case .Dot:
		if len(v.args) != 2 {
			error(checker, v, "builtin 'dot' expects two arguments, got %d", len(v.args))
			break
		}
		a    := args[0]
		b    := args[1]
		type := op_result_type(a.type, b.type)
		if !type_is_array(type) {
			error(checker, v, "builtin 'dot' expects two vectors of the same type, got %v and %v", a.type, b.type)
			break
		}
		v.args[0].value.type = type
		v.args[1].value.type = type
		operand.type = type_array_elem(type)
		operand.mode = .RValue
	case .Cross:
		if len(v.args) != 2 {
			error(checker, v, "builtin 'cross' expects two arguments, got %d", len(v.args))
			break
		}
		a    := args[0]
		b    := args[1]
		type := op_result_type(a.type, b.type)
		if vec, ok := type.variant.(^Type_Array); !ok || vec.count != 3 {
			error(checker, v, "builtin 'cross' expects two 3 dimensional vectors, got %v and %v", a.type, b.type)
			break
		}
		v.args[0].value.type = type
		v.args[1].value.type = type
		operand.type = type
		operand.mode = .RValue
	case .Min, .Max:
		if len(v.args) < 2 {
			error(checker, v, "builtin '%s' expects at least two arguments", builtin_names[v.builtin])
			break
		}
		type := args[0].type
		for arg in args[1:] {
			prev := type
			type  = op_result_type(type, arg.type)
			if type.kind == .Invalid {
				error(checker, arg, "builtin '%s' expects all arguments to be of the same type, expected %v, got %v", builtin_names[v.builtin], prev, arg.type)
				return
			}
		}
		for &arg in v.args {
			arg.value.type = type
		}
		if !type_is_numeric(type) && !type_is_array(type) {
			error(checker, v, "builtin '%s' expects at least two vectors or scalars of the same type, got %v", builtin_names[v.builtin], type)
			break
		}
		operand.type = type
		operand.mode = .RValue
	case .Clamp:
		if len(v.args) != 3 {
			error(checker, v, "builtin 'clamp' expects three arguments, got %d", len(v.args))
			break
		}
		type := args[0].type
		for arg in args[1:] {
			prev := type
			type  = op_result_type(type, arg.type)
			if type.kind == .Invalid {
				error(checker, arg, "builtin 'clamp' expects all arguments to be of the same type, expected %v, got %v", prev, arg.type)
				return
			}
		}
		if !type_is_numeric(type) && !type_is_array(type) {
			error(checker, v, "builtin 'clamp' expects 3 vectors or scalars of the same type, got %v", type)
			break
		}
		for arg in v.args {
			arg.value.type = type
		}
		operand.type = type
		operand.mode = .RValue
	case .Lerp, .Smooth_Step:
		if len(v.args) != 3 {
			error(checker, v, "builtin '%s' expects three arguments, got %d", builtin_names[v.builtin], len(v.args))
			break
		}
		a, b, t := args[0].type, args[1].type, args[2].type
		type    := default_type(op_result_type(a, b))
		if type.kind == .Invalid {
			error(checker, v, "type mismatch in builtin '%s': %v vs %v", builtin_names[v.builtin], a, b)
			break
		}
		if !type_is_numeric(type) && !type_is_array(type) {
			error(checker, v, "builtin '%s' expects two vectors or scalars of the same type, got %v", builtin_names[v.builtin], type)
			break
		}
		t_valid := type_is_float(t)
		if type_is_array(t) && type_is_array(type) {
			t_valid = op_result_type(t, type).kind != .Invalid
		}
		if !t_valid {
			error(checker, v, "builtin '%s' expects a float for the interpolation value, got %v", builtin_names[v.builtin], t)
			break
		}
		for arg in v.args[:2] {
			arg.value.type = type
		}
		v.args[2].value.type = default_type(type)
		operand.type         = type
		operand.mode         = .RValue
	case .Inverse:
		if len(v.args) != 1 {
			error(checker, v, "builtin 'inverse' expects one argument, got %d", len(args))
			break
		}
		type := args[0].type
		if !type_is_matrix(type) {
			error(checker, v, "builtin 'inverse' expects a matrix, got %d", len(args))
			break
		}
		if !type_matrix_is_square(type) {
			error(checker, v, "builtin 'inverse' expects a square matrix, got %v", type)
			break
		}
		operand.type = type
		operand.mode = .RValue
	case .Transpose:
		if len(v.args) != 1 {
			error(checker, v, "builtin 'transpose' expects one argument, got %d", len(args))
			break
		}
		type := args[0].type
		if !type_is_matrix(type) {
			error(checker, v, "builtin 'transpose' expects a matrix, got %d", len(args))
			break
		}
		if !type_matrix_is_square(type) {
			m   := type.variant.(^Type_Matrix)
			type = type_matrix_new(type_array_new(type_matrix_elem(type), m.cols, checker.allocator), m.col_type.count, checker.allocator)
		}
		operand.type = type
		operand.mode = .RValue
	case .Determinant:
		if len(v.args) != 1 {
			error(checker, v, "builtin 'determinant' expects one argument, got %d", len(args))
			break
		}
		type := args[0].type
		if !type_is_matrix(type) {
			error(checker, v, "builtin 'determinant' expects a matrix, got %v", type)
			break
		}
		if !type_matrix_is_square(type) {
			error(checker, v, "builtin 'determinant' expects a square matrix, got %v", type)
			break
		}
		operand.type = type_matrix_elem(type)
		operand.mode = .RValue
	case .Ddx, .Ddy:
		if checker.shader_stage != .Fragment {
			error(checker, v, "builtin '%s' can only be used in fragment shaders", builtin_names[v.builtin])
			break
		}
		fallthrough
	case .Sqrt,
	     .Sin,
	     .Cos,
	     .Tan,
	     .Sinh,
	     .Cosh,
	     .Tanh,
	     .Asin,
	     .Acos,
	     .Atan,
	     .Asinh,
	     .Acosh,
	     .Atanh,
	     .Exp,
	     .Exp2,
	     .Log,
	     .Log2,
	     .Floor,
	     .Fract,
	     .Ceil,
	     .Round,
	     .Trunc,
	     .Inverse_Sqrt,
	     .Sign:
		if len(v.args) != 1 {
			error(checker, v, "builtin '%s' expects one argument, got %d", builtin_names[v.builtin], len(args))
			break
		}
		arg  := args[0]
		type := op_result_type(arg.type, t_f32)
		if type.kind == .Invalid || type.kind == .Matrix {
			error(checker, v, "builtin '%s' expects a float or vector, got %v", builtin_names[v.builtin], arg.type)
			return
		}
		v.args[0].value.type = type
		operand.mode         = .RValue
		operand.type         = type
	case .Atan2:
		if len(v.args) != 2 {
			error(checker, v, "builtin '%s' expects one argument, got %d", builtin_names[v.builtin], len(args))
			break
		}
		type := op_result_type(args[0].type, args[1].type)
		elem := type
		if type_is_array(type) {
			elem = type_array_elem(type)
		}
		if elem.kind == .Invalid || elem.kind != .Float {
			error(checker, v, "builtin '%s' expects a float or vector, got %v", builtin_names[v.builtin], type)
			return
		}
		v.args[0].value.type = type
		v.args[1].value.type = type
		operand.type         = type
		operand.mode         = .RValue
	case .Abs:
		if len(v.args) != 1 {
			error(checker, v, "builtin '%s' expects one argument, got %d", builtin_names[v.builtin], len(args))
			break
		}
		type := default_type(args[0].type)
		t    := type
		if type_is_array(type) {
			t = type_array_elem(type)
		}
		#partial switch t.kind {
		case .Float, .Int:
		case:
			error(checker, v, "builtin '%s' expects a signed scalar or a vector, got %v", builtin_names[v.builtin], type)
			return
		}
		v.args[0].value.type = type
		operand.mode         = .RValue
		operand.type         = type
	case .Pow:
		if len(v.args) != 2 {
			error(checker, v, "builtin 'pow' expects two arguments, got %d", len(args))
			break
		}
		x         := args[0]
		y         := args[1]
		type      := op_result_type(x.type, y.type)
		elem_type := type
		if type_is_array(type) {
			elem_type = type_array_elem(type)
		}
		if type.kind == .Invalid || !type_is_float(elem_type) {
			error(checker, v, "builtin 'tan' expects two float vectors or scalars, got %v and %v", x.type, y.type)
			return
		}
		v.args[0].value.type = type
		v.args[1].value.type = type
		operand.mode = .RValue
		operand.type = type
	case .Normalize, .Length:
		if len(v.args) != 1 {
			error(checker, v, "builtin '%v' expects one argument, got %d", builtin_names[v.builtin], len(v.args))
			return
		}
		x    := args[0]
		type := core_type(x.type, complex_to_array = true)
		if !type_is_array(type) || !type_is_float(type_array_elem(type)) {
			error(checker, x, "builtin '%v' expects a vector of floats, got %v", builtin_names[v.builtin], type)
			return
		}
		operand.mode = .RValue
		operand.type = x.type
		if v.builtin == .Length {
			operand.type = type_array_elem(type)
		}
	case .Distance, .Reflect:
		if len(v.args) != 2 {
			error(checker, v, "builtin '%s' expects two arguments, got %d", builtin_names[v.builtin], len(v.args))
			return
		}
		a, b := args[0].type, args[1].type
		type := op_result_type(a, b)
		if type.kind == .Invalid {
			error(checker, v, "type mismatch in builtin '%s': %v vs %v", builtin_names[v.builtin], a, b)
			break
		}
		if !type_is_array(type) {
			error(checker, v, "builtin '%s' expects a two vectors of the same type, got %v", builtin_names[v.builtin], type)
			break
		}
		v.args[0].value.type = type
		v.args[1].value.type = type
		operand.mode         = .RValue
		operand.type         = type_array_elem(type) if v.builtin == .Distance else type
	case .Refract:
		if len(v.args) != 3 {
			error(checker, v, "builtin '%s' expects three arguments, got %d", builtin_names[v.builtin], len(v.args))
			return
		}
		a, b := args[0].type, args[1].type
		type := op_result_type(a, b)
		if type.kind == .Invalid {
			error(checker, v, "type mismatch in builtin '%s': %v vs %v", builtin_names[v.builtin], a, b)
			break
		}
		if !type_is_array(type) {
			error(checker, v, "builtin '%s' expects a two vectors of the same type, got %v", builtin_names[v.builtin], type)
		}

		eta_type := args[2].type
		if !type_is_float(eta_type) {
			eta_type = op_result_type(type_array_elem(type), eta_type)
		}
		if !type_is_float(eta_type) {
			error(checker, v, "builtin '%s' expects a float as the third argument, got %v", builtin_names[v.builtin], args[2].type)
		}

		v.args[0].value.type = type
		v.args[1].value.type = type
		v.args[2].value.type = eta_type
		operand.mode         = .RValue
		operand.type         = type
	case .Discard:
		operand.diverging = true
		fallthrough
	case .Barrier:
		if len(v.args) != 0 {
			error(checker, v, "builtin '%s' expects no arguments, got %d", builtin_names[v.builtin], len(v.args))
			return
		}
		operand.type    = t_invalid
		operand.mode    = .No_Value
		operand.is_call = true
	case .Texture_Size:
		if len(v.args) != 1 {
			error(checker, v, "builtin 'texture_size' expects one argument, got %d", len(v.args))
			return
		}
		if args[0].type.kind != .Sampler {
			error(checker, v, "builtin 'texture_size' expects a sampler, got %v", args[0].type)
			return
		}
		sampler     := args[0].type.variant.(^Type_Image)
		operand.type = type_array_new(t_i32, sampler.dimensions, checker.allocator)
		operand.mode = .RValue
	case .Image_Size:
		if len(v.args) != 1 {
			error(checker, v, "builtin 'image_size' expects one argument, got %d", len(v.args))
			return
		}
		if args[0].type.kind != .Image {
			error(checker, v, "builtin 'image_size' expects a sampler, got %v", args[0].type)
			return
		}
		sampler     := args[0].type.variant.(^Type_Image)
		operand.type = type_array_new(t_i32, sampler.dimensions, checker.allocator)
		operand.mode = .RValue
	case .Count_Ones, .Count_Zeros, .Count_Leading_Zeros, .Count_Trailing_Zeros, .Count_Leading_Ones, .Count_Trailing_Ones, .Find_Lsb, .Find_Msb, .Reverse_Bits:
		if len(v.args) != 1 {
			error(checker, v, "builtin '%s' expects one argument, got %d", builtin_names[v.builtin], len(v.args))
			return
		}
		type := args[0].type
		if type_is_array(type) {
			type = type_array_elem(type)
		}
		type = default_type(type)
		if !type_is_integer(type) {
			error(checker, v, "builtin '%s' expects an integer scalar or vector, got %v", builtin_names[v.builtin], v.args[0].type)
			return
		}
		operand.type = args[0].type
		operand.mode = .RValue
	case .Real, .Imag:
		if len(v.args) != 1 {
			error(checker, v, "builtin '%s' expects one argument, got %d", builtin_names[v.builtin], len(v.args))
			return
		}
		type := args[0].type
		if !type_is_quaternion(type) && !type_is_complex(type) {
			error(checker, v, "builtin '%s' expects a complex number or quaternion, got %v", builtin_names[v.builtin], type)
			return
		}
		operand.type = type_complex_elem(type)
		operand.mode = .RValue
	case .Jmag, .Kmag:
		if len(v.args) != 1 {
			error(checker, v, "builtin '%s' expects one argument, got %d", builtin_names[v.builtin], len(v.args))
			return
		}
		type := args[0].type
		if !type_is_quaternion(type) {
			error(checker, v, "builtin '%s' expects a quaternion, got %v", builtin_names[v.builtin], type)
			return
		}
		operand.type = type_complex_elem(type)
		operand.mode = .RValue
	case .Conj:
		if len(v.args) != 1 {
			error(checker, v, "builtin '%s' expects one argument, got %d", builtin_names[v.builtin], len(v.args))
			return
		}
		type := args[0].type
		if !type_is_quaternion(type) && !type_is_complex(type) {
			error(checker, v, "builtin '%s' expects a quaternion or complex number, got %v", builtin_names[v.builtin], type)
			return
		}
		operand.type = type
		operand.mode = .RValue
	case .Type_Is_Uint,
	     .Type_Is_Int,
	     .Type_Is_Bool,
	     .Type_Is_Float,
	     .Type_Is_Any,
	     .Type_Is_Struct,
	     .Type_Is_Matrix,
	     .Type_Is_Array,
	     .Type_Is_Buffer,
	     .Type_Is_Proc,
	     .Type_Is_Proc_Group,
	     .Type_Is_Sampler,
	     .Type_Is_Image,
	     .Type_Is_Enum,
	     .Type_Is_Bit_Set,
	     .Type_Is_Complex,
	     .Type_Is_Quaternion,
	     .Type_Is_Opaque,
	     .Type_Is_Named:
		if len(v.args) != 1 {
			error(checker, v, "builtin '%s' expects one argument, got %d", builtin_names[v.builtin], len(v.args))
			return
		}
		if args[0].mode != .Type {
			error(checker, args[0], "builtin '%s' expects a type, got %v", builtin_names[v.builtin], addressing_mode_string[args[0].mode])
		}

		operand.mode = .Const
		operand.type = t_bool

		#partial switch v.builtin {
	    case .Type_Is_Uint:       operand.value = type_is_uint(args[0].type)
	    case .Type_Is_Int:        operand.value = type_is_int(args[0].type)
	    case .Type_Is_Bool:       operand.value = type_is_bool(args[0].type)
	    case .Type_Is_Float:      operand.value = type_is_float(args[0].type)
	    case .Type_Is_Any:        operand.value = type_is_any(args[0].type)
	    case .Type_Is_Struct:     operand.value = type_is_struct(args[0].type)
	    case .Type_Is_Matrix:     operand.value = type_is_matrix(args[0].type)
	    case .Type_Is_Array:      operand.value = type_is_array(args[0].type)
	    case .Type_Is_Buffer:     operand.value = type_is_buffer(args[0].type)
	    case .Type_Is_Proc:       operand.value = type_is_proc(args[0].type)
	    case .Type_Is_Proc_Group: operand.value = type_is_proc_group(args[0].type)
	    case .Type_Is_Sampler:    operand.value = type_is_sampler(args[0].type)
	    case .Type_Is_Image:      operand.value = type_is_image(args[0].type)
	    case .Type_Is_Enum:       operand.value = type_is_enum(args[0].type)
	    case .Type_Is_Bit_Set:    operand.value = type_is_bit_set(args[0].type)
	    case .Type_Is_Complex:    operand.value = type_is_complex(args[0].type)
	    case .Type_Is_Quaternion: operand.value = type_is_quaternion(args[0].type)
	    case .Type_Is_Opaque:     operand.value = type_is_opaque(args[0].type)
	    case .Type_Is_Named:      operand.value = type_is_named(args[0].type)
		}
	case .Card:
		if len(v.args) != 1 {
			error(checker, v, "builtin '%s' expects one argument, got %d", builtin_names[v.builtin], len(v.args))
			return
		}
		type := args[0].type
		if !type_is_bit_set(type) {
			error(checker, v, "builtin '%s' expects a bit_set, got %v", builtin_names[v.builtin], type)
			return
		}
		operand.type = t_i32
		operand.mode = .RValue
	}

	return
}
