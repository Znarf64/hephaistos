#pragma once

#include <stdint.h>

typedef uint8_t Hep_Bool;

typedef struct {
  char const *data;
  intptr_t    len;
} Hep_String;

typedef struct {
  intptr_t line, column, offset;
} Hep_Location;

typedef struct {
  Hep_Location start, end;
  Hep_String   message;
} Hep_Error;

typedef struct {
  Hep_Error *errors;
  intptr_t   n_errors;
  uint32_t  *instructions;
  intptr_t   n_instructions;
  void      *_error_arena;
} Hep_Result;

typedef enum {
  HEP_CONST_VALUE_KIND_NIL,
  HEP_CONST_VALUE_KIND_INT64,
  HEP_CONST_VALUE_KIND_FLOAT64,
  HEP_CONST_VALUE_KIND_BOOLEAN,
  HEP_CONST_VALUE_KIND_STRING,
} Hep_Const_Value_Kind;

typedef struct {
  union {
    int64_t    int64;
    double     float64;
    Hep_Bool   boolean;
    Hep_String string;
  } value;
  Hep_Const_Value_Kind kind;
} Hep_Const_Value;

typedef struct {
  Hep_String      name;
  Hep_Const_Value value;
} Hep_Define;

typedef struct {
  Hep_Define *defines;
  intptr_t    len;
} Hep_Defines;

typedef enum {
  HEP_TYPE_KIND_INVALID,

  HEP_TYPE_KIND_UINT,
  HEP_TYPE_KIND_INT,
  HEP_TYPE_KIND_BOOL,
  HEP_TYPE_KIND_FLOAT,

  HEP_TYPE_KIND_STRUCT,
  HEP_TYPE_KIND_MATRIX,
  HEP_TYPE_KIND_ARRAY,
  HEP_TYPE_KIND_BUFFER,
  HEP_TYPE_KIND_PROC,
  HEP_TYPE_KIND_PROC_GROUP,
  HEP_TYPE_KIND_SAMPLER,
  HEP_TYPE_KIND_IMAGE,
  HEP_TYPE_KIND_ENUM,
  HEP_TYPE_KIND_BIT_SET,
  HEP_TYPE_KIND_COMPLEX,
  HEP_TYPE_KIND_QUATERNION,
  HEP_TYPE_KIND_OPAQUE,

  HEP_TYPE_KIND_TUPLE,
} Hep_Type_Kind;

struct Hep_Type_Struct;
struct Hep_Type_Matrix;
struct Hep_Type_Array;
struct Hep_Type_Buffer;
struct Hep_Type_Enum;
struct Hep_Type_Bit_Set;
struct Hep_Type_Complex;

typedef struct {
  Hep_Type_Kind kind;
  intptr_t      size, align;
  union {
    struct Hep_Type_Struct     *struct_;
    struct Hep_Type_Matrix     *matrix;
    struct Hep_Type_Array      *array;
    struct Hep_Type_Buffer     *buffer;
    struct Hep_Type_Enum       *enum_;
    struct Hep_Type_Bit_Set    *bit_set;
    struct Hep_Type_Complex    *complex;
  } variant;
} Hep_Type;

typedef struct {
  Hep_String      name;
  Hep_Type       *type;
  Hep_Const_Value value;
  intptr_t        offset;
  intptr_t        location;
  void           *_entity;
} Hep_Field;

typedef struct {
  Hep_Field *data;
  intptr_t   len;
} Hep_Field_List;

typedef struct Hep_Type_Struct {
  Hep_Type       base;
  Hep_Field_List fields;
} Hep_Type_Struct;

typedef struct Hep_Type_Array {
  Hep_Type  base;
  intptr_t  count;
  Hep_Type *elem;
} Hep_Type_Array;

typedef struct Hep_Type_Matrix {
  Hep_Type        base;
  intptr_t        cols;
  Hep_Type_Array *col_type;
} Hep_Type_Matrix;

typedef struct Hep_Type_Complex {
  Hep_Type        base;
  Hep_Type_Array *array;
} Hep_Type_Complex;

typedef struct Hep_Type_Buffer {
  Hep_Type  base;
  Hep_Type *elem;
  Hep_Bool  physical;
} Hep_Type_Buffer;

typedef struct {
  struct {
    Hep_String name;
    int64_t    value;
    void      *_entity;
  } *data;
} Hep_Enum_Value_List;

typedef struct Hep_Type_Enum {
  Hep_Type            base;
  Hep_Enum_Value_List values;
  Hep_Type           *backing;
} Hep_Type_Enum;

typedef struct Hep_Type_Bit_Set {
  Hep_Type       base;
  Hep_Type_Enum *enum_type;
  Hep_Type      *backing;
} Hep_Type_Bit_Set;

typedef struct {
  struct {
    Hep_String name;
    Hep_Type  *type;
  }       *data;
  intptr_t len;
} Hep_Named_Types;

// use with OpenGL
#define HEP_SPIR_V_VERSION_1_0 0x00010000
#define HEP_SPIR_V_VERSION_1_1 0x00010100
#define HEP_SPIR_V_VERSION_1_2 0x00010200
#define HEP_SPIR_V_VERSION_1_3 0x00010300
#define HEP_SPIR_V_VERSION_1_4 0x00010400
#define HEP_SPIR_V_VERSION_1_5 0x00010500
#define HEP_SPIR_V_VERSION_1_6 0x00010600

extern Hep_Result hep_compile_shader(
  char const     *source,
  char const     *path,
  Hep_Defines     defines,
  Hep_Named_Types shared_types,
  uint32_t        spirv_version
);
extern void       hep_result_free(Hep_Result const *);
extern intptr_t   hep_error_print(Hep_Error const *error, char const *file_name, Hep_String const lines[], char *buf);
