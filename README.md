# NyxLang

A compiler for a subset of C that emits RISC-V assembly, built in Zig with Flex and Bison.

## Pipeline

| Stage              | File                                        | What it does                                                         |
| ------------------ | ------------------------------------------- | -------------------------------------------------------------------- |
| Lexing and parsing | `src/c11.l`, `src/c11.y`                    | Flex/Bison grammar for C11 that builds the AST                       |
| AST                | `src/ast.zig`                               | Node types for declarations, statements, and expressions             |
| Semantic analysis  | `src/semanticAnalyzer.zig`, `src/scope.zig` | Nested scopes, symbol tables, and type checking                      |
| IR                 | `src/3ac.zig`                               | Lowers the AST to three-address code (NYAC)                          |
| Code generation    | `src/assembler.zig`                         | Liveness analysis, graph-coloring register allocation, RISC-V output |

## Build

Requires Zig 0.15.1, Flex, and Bison.

```sh
zig build
```

If linking fails with a `R_X86_64_PC64` relocation error, add `-Dtarget=x86_64-linux-gnu` to every `zig build` command.

## Run

```sh
./zig-out/bin/NyxLang examples/hello_world.nyx -a
zig cc -target riscv64-linux-musl -static a.s -o hello
qemu-riscv64 hello
```

`-a` writes RISC-V assembly, `-d` prints the AST and IR, and `-ad` does both. Running the output needs user-mode QEMU. `examples/` has one small program per supported feature.

## Limitations

The parser accepts more of C than the backend compiles. Not supported yet: array indexing, struct pointers, floats, short-circuit evaluation, `switch`, `break`, `continue`, `goto`, `do`/`while`, the ternary operator, and register spilling.
