package hephaistos_tokenizer

import "base:runtime"

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:reflect"

Token_Kind :: enum u16 {
	Invalid       = 0,

	Bit_And       = '&',
	Bit_Or        = '|',
	Xor           = '~',
	Not           = '!',
	Add           = '+',
	Subtract      = '-',
	Multiply      = '*',
	Divide        = '/',
	Modulo        = '%',
	Pointer       = '^',
	Colon         = ':',
	Assign        = '=',
	Semicolon     = ';',
	Open_Paren    = '(',
	Close_Paren   = ')',
	Open_Brace    = '{',
	Close_Brace   = '}',
	Open_Bracket  = '[',
	Close_Bracket = ']',
	Period        = '.',
	Comma         = ',',
	Less          = '<',
	Greater       = '>',
	Question_Mark = '?',
	Attribute     = '@',
	Directive     = '#',
	Dollar        = '$',

	// avoid enum value collision
	Ident = 128,

	Comment,
	Literal,

	Arrow, // ->

	EOF,

	Range_Equal,
	Range_Less,

	Equal,
	Not_Equal,
	Less_Equal,
	Greater_Equal,

	And,
	Or,
	Shift_Left,
	Shift_Right,

	Modulo_Floored,

	Return, _Keyword_Start = Return,
	If,
	Else,
	For,
	Break,
	Continue,
	Switch,
	Case,
	Fallthrough,
	In,
	When,
	Import,

	Struct,
	Enum,
	Bit_Set,
	Proc,
	Matrix,
	Sampler,
	Image,

	Cast,
}

keyword_strings: map[string]Token_Kind

@(init)
_init_keyword_strings :: proc "contextless" () {
	context = runtime.default_context()
	for k in Token_Kind._Keyword_Start ..= max(Token_Kind) {
		keyword_strings[strings.to_lower(reflect.enum_string(k))] = k
	}
}

when ODIN_DEBUG {
	@(init)
	check_token_strings :: proc "contextless" () {
		for t in Token_Kind._Keyword_Start ..< max(Token_Kind) {
			found: bool
			for _, keyword in keyword_strings {
				if t == keyword {
					found = true
					break
				}
			}
			assert_contextless(found)
		}
	}
}

Imaginary :: enum u8 {
	real = 0,
	i    = 'i',
	j    = 'j',
	k    = 'k',
}

Token :: struct {
	location: Location,
	text:     string,
	value:    struct #raw_union {
		bool:  bool,
		int:   i64,
		float: f64,
		op:    Token_Kind,
	},
	kind:       Token_Kind,
	value_kind: enum u8 {
		Bool,
		Int,
		Float,
		Op,
		String,
	},
	imaginary: Imaginary,
}

Location :: struct {
	line, column, offset: int,
}

Error :: struct {
	using location: Location,
	end:            Location,
	message:        string,
}

tokenize :: proc(
	source:   string,
	comments: bool,
	allocator       := context.allocator,
	error_allocator := context.allocator,
) -> ([]Token, []Error) {
	tokens := make([dynamic]Token,       allocator)
	errors := make([dynamic]Error, error_allocator)

	line   := 1
	column := 1

	last_token_kind: Token_Kind

	current: int
	for current < len(source) {
		start := current
		token := Token {
			location = {
				line   = line,
				column = column,
				offset = current,
			},
		}

		set_column := true
		defer if set_column {
			column += current - start
		}

		potential_assign_op: bool

		char    := source[current]
		current += 1
		switch char {
		case '=', '!':
			token.kind = Token_Kind(char)
			if current < len(source) && source[current] == '=' {
				current += 1
				switch char {
				case '=':
					token.kind = .Equal
				case '!':
					token.kind = .Not_Equal
				}
			}

		case '<', '>':
			token.kind = Token_Kind(char)
			if current < len(source) {
				switch source[current] {
				case '=':
					current += 1
					if char == '<' {
						token.kind  = .Less_Equal
					} else {
						token.kind  = .Greater_Equal
					}
				case char:
					current += 1
					if char == '<' {
						token.kind = .Shift_Left
					} else {
						token.kind = .Shift_Right
					}
					potential_assign_op = true
				}
			}
		case '&', '|', '%':
			potential_assign_op = true
			token.kind          = Token_Kind(char)
			if current < len(source) && source[current] == char {
				current += 1
				#partial switch token.kind {
				case .Bit_And:
					token.kind = .And
				case .Bit_Or:
					token.kind = .Or
				case .Modulo:
					token.kind = .Modulo_Floored
				}
			}
		case '+', '*', '^', '~':
			potential_assign_op = true
			token.kind          = Token_Kind(char)
		case '/':
			if current < len(source) && source[current] == '/' {
				for current < len(source) && source[current] != '\n' {
					current += 1
				}
				token.kind = .Comment
				if !comments {
					continue
				}
			} else if current < len(source) && source[current] == '*' {
				column    += 2 // manual correction for the two consumed characters
				current   += 1
				set_column = false

				depth := 1
				for current + 1 < len(source) && depth != 0 {
					if source[current] == '\n' {
						line   += 1
						column  = 1
					} else {
						column += 1
					}
					if source[current] == '*' && source[current + 1] == '/' {
						depth   -= 1
						current += 1
						column  += 1
					} else if source[current] == '/' && source[current + 1] == '*' {
						depth   += 1
						current += 1
						column  += 1
					}

					current += 1
				}

				if current >= len(source) - 1 {
					append(&errors, Error {
						location = token.location,
						message  = "unterminated multi-line comment",
					})
				}

				token.kind = .Comment
				if !comments {
					continue
				}
			} else {
				potential_assign_op = true
				token.kind = Token_Kind(char)
			}
		case '-':
			if current < len(source) && source[current] == '>' {
				current   += 1
				token.kind = .Arrow
			} else {
				potential_assign_op = true
				token.kind = Token_Kind(char)
			}
		case '.':
			if current < len(source) && source[current] == '.' {
				current += 1
				if current == len(source) {
					append(&errors, Error {
						location = token.location,
						message  = "expected < or = after .., got EOF",
					})
					break
				}
				switch source[current] {
				case '<':
					token.kind = .Range_Less
					current   += 1
				case '=':
					token.kind = .Range_Equal
					current   += 1
				case:
					append(&errors, Error {
						location = token.location,
						message  = fmt.aprintf("expected < or = after .., got '%c'", source[current], error_allocator),
					})
				}
			} else {
				token.kind = Token_Kind(char)
			}

		case ':', ';', '(', ')', '{', '}', '[', ']', ',', '?', '#', '@', '$':
			token.kind = Token_Kind(char)

		case '"':
			// TODO: maybe handle escaping
			for current < len(source) && source[current] != '"' {
				if source[current] == '\n' {
					break
				}
				current += 1
			}

			if current <= len(source) && source[current] == '"' {
				current += 1
			} else {
				append(&errors, Error {
					location = token.location,
					message  = fmt.aprintf("unterminated string literal", error_allocator),
				})
			}

			token.kind       = .Literal
			token.value_kind = .String

		case 'a' ..= 'z', 'A' ..= 'Z', '_':
			for current < len(source) {
				switch source[current] {
				case 'a' ..= 'z', 'A' ..= 'Z', '_', '0' ..= '9':
					current += 1
					continue
				}
				break
			}

			token.kind = .Ident
			if keyword, ok := keyword_strings[source[start:current]]; ok {
				token.kind = keyword
			} else if source[start:current] == "true" {
				token.kind       = .Literal
				token.value.bool = true
				token.value_kind = .Bool
			} else if source[start:current] == "false" {
				token.kind       = .Literal
				token.value.bool = false
				token.value_kind = .Bool
			}

		case '0' ..= '9':
			if char == '0' && current < len(source) {
				switch source[current] {
				case 'x', 'o', 'b', 'X', 'O', 'B':
					current += 1
				}
			}

			for current < len(source) {
				switch source[current] {
				case '_', '0' ..= '9':
					current += 1
					continue
				}
				break
			}

			has_decimal: bool
			if current <= len(source) && source[current] == '.' {
				current += 1
				has_decimal = true
				for current < len(source) {
					switch source[current] {
					case '_', '0' ..= '9':
						current += 1
						continue
					}
					break
				}
			}

			if has_decimal {
				float_value, ok := strconv.parse_f64(source[start:current])
				if ok {
					token.value.float = float_value
					token.value_kind  = .Float
				} else {
					append(&errors, Error {
						location = token.location,
						message  = fmt.aprintf("failed to parse float literal: '%s'", source[start:current], error_allocator),
					})
				}
			} else {
				int_value, ok := strconv.parse_i64(source[start:current])
				if ok {
					token.value.int = int_value
					token.value_kind = .Int
				} else {
					append(&errors, Error {
						location = token.location,
						message  = fmt.aprintf("failed to parse integer literal: '%s'", source[start:current], error_allocator),
					})
				}
			}

			switch source[current] {
			case 'i', 'j', 'k':
				token.imaginary = Imaginary(source[current])
				current        += 1
			}

			token.kind = .Literal

		case '\n':
			#partial switch last_token_kind {
			case .Ident, .Close_Brace, .Close_Paren, .Close_Bracket, .Literal:
				fallthrough
			case ._Keyword_Start ..= max(Token_Kind):
				token.kind = .Semicolon
				append(&tokens, token)
			}
			last_token_kind = nil

			line  += 1
			column = 0
			continue
		case ' ', '\r', '\t':
			continue
		case '\\':
			last_token_kind = nil
			continue
		case:
			append(&errors, Error {
				location = token.location,
				message  = fmt.aprintf("unexecpected character: '%c'", char, error_allocator),
			})
			continue
		}

		if potential_assign_op && current < len(source) && source[current] == '=' {
			token.value.op   = token.kind
			token.value_kind = .Op
			current         += 1
			token.kind       = .Assign
		}

		token.text = source[start:current]
		append(&tokens, token)
		last_token_kind = token.kind
	}

	append(&tokens, Token {
		location = {
			line   = line,
			column = column,
		},
		kind = .EOF,
	})

	return tokens[:], errors[:]
}

token_strings := #sparse[Token_Kind]string {
	.Invalid        = "<invalid>",
	.Bit_And        = "&",
	.Bit_Or         = "|",
	.Xor            = "~",
	.Not            = "!",
	.Add            = "+",
	.Subtract       = "-",
	.Multiply       = "*",
	.Divide         = "/",
	.Modulo         = "%",
	.Modulo_Floored = "%%",
	.Pointer        = "^",
	.Colon          = ":",
	.Assign         = "assignment",
	.Semicolon      = ";",
	.Open_Paren     = "(",
	.Close_Paren    = ")",
	.Open_Brace     = "{",
	.Close_Brace    = "}",
	.Open_Bracket   = "[",
	.Close_Bracket  = "]",
	.Period         = ".",
	.Comma          = ",",
	.Less           = "<",
	.Greater        = ">",
	.Question_Mark  = "?",
	.Attribute      = "@",
	.Directive      = "#",
	.Dollar         = "$",

	.Ident          = "identifier",

	.Comment        = "comment",
	.Literal        = "literal",

	.Arrow          = "arrow",

	.Range_Equal    = "..=",
	.Range_Less     = "..<",

	.EOF            = "EOF",

	.Equal          = "",
	.Not_Equal      = "",
	.Less_Equal     = "",
	.Greater_Equal  = "",

	.And            = "&&",
	.Or             = "||",
	.Shift_Left     = "<<",
	.Shift_Right    = ">>",

	.Return         = "return",
	.If             = "if",
	.Else           = "else",
	.For            = "for",
	.Break          = "break",
	.Continue       = "continue",
	.Switch         = "switch",
	.Case           = "case",
	.Fallthrough    = "fallthrough",
	.In             = "in",
	.When           = "when",
	.Import         = "import",

	.Struct         = "struct",
	.Enum           = "enum",
	.Bit_Set        = "bit_set",
	.Proc           = "proc",
	.Matrix         = "matrix",
	.Sampler        = "sampler",
	.Image          = "image",

	.Cast           = "cast",

}

to_string :: proc(token_kind: Token_Kind) -> string {
	return token_strings[token_kind]
}
