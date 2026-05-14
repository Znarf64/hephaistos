#include <assert.h>
#include <stdio.h>
#include <stdlib.h>

#include "hephaistos.h"

char *read_entire_file(char const *path) {
  FILE *f = fopen(path, "rb");
  if (!f) {
    return NULL;
  }
  if (fseek(f, 0, SEEK_END) != 0) {
    fclose(f);
    return NULL;
  }
  long size = ftell(f);
  if (size < 0) {
    fclose(f);
    return NULL;
  }
  if (fseek(f, 0, SEEK_SET) != 0) {
    fclose(f);
    return NULL;
  }
  char *buf = malloc((size_t)size + 1);
  if (!buf) {
    fclose(f);
    return NULL;
  }
  size_t read = fread(buf, 1, (size_t)size, f);
  fclose(f);
  if (read != (size_t)size) {
    free(buf);
    return NULL;
  }
  buf[size] = '\0';
  return buf;
}

int write_entire_file(char const *path, char const *data, size_t size) {
  FILE *f = fopen(path, "wb");
  if (!f) {
    return -1;
  }
  size_t written = fwrite(data, 1, size, f);
  fclose(f);
  if (written != size) {
    return -1;
  }
  return 0;
}

void print_errors(Hep_Result const *result, char const *path, char const *source) {
  int n_lines = 0;
  for (char const *c = source; *c != 0; c += 1) {
    if (*c == '\n') {
      n_lines += 1;
    }
  }
  Hep_String *lines        = malloc(sizeof(Hep_String) * n_lines);
  char const *line_start   = source;
  intptr_t    line_len     = 0;
  intptr_t    current_line = 0;
  for (char const *c = source; *c != 0; c += 1) {
    if (*c == '\n') {
      lines[current_line] = (Hep_String) {
        .data = line_start,
        .len  = line_len,
      };
      line_start    = c + 1;
      line_len      = 0;
      current_line += 1;
    } else {
      line_len += 1;
    }
  }

  intptr_t max_size = 0;
  for (int i = 0; i < result->n_errors; i += 1) {
    intptr_t size = hep_error_print(&i[result->errors], path, lines, NULL);
    if (size > max_size) {
      max_size = size;
    }
  }
  char *buf = malloc(max_size);
  for (int i = 0; i < result->n_errors; i += 1) {
    hep_error_print(&i[result->errors], path, lines, buf);
    fprintf(stderr, "%s", buf);
  }

  free(lines);
  free(buf);
}

int main(int argc, char const **argv) {
  if (argc != 3) {
    fprintf(stderr, "Usage: %s <input.hep> <output.spv>\n", argv[0]);
    return 1;
  }
  char const *path   = argv[1];
  char const *source = read_entire_file(path);
  assert(source != NULL);

  Hep_Result result = hep_compile_shader(source, path, (Hep_Defines){0}, (Hep_Named_Types){0}, HEP_SPIR_V_VERSION_1_6);
  if (result.n_errors != 0) {
    print_errors(&result, path, source);
  } else {
    write_entire_file(argv[2], (char *)result.instructions, result.n_instructions * sizeof(uint32_t));
  }
  hep_result_free(&result);
  free((void *)source);
}
