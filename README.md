# NyxLang

NyxLang is a compiler built with Zig, Flex, and Bison. It accepts a subset of C syntax, builds and semantically checks an abstract syntax tree, lowers the program to a custom three-address intermediate representation, and emits RISC-V assembly.

## Compiler Stages

```text
source file
  -> Flex lexer
  -> Bison parser
  -> Zig AST
  -> semantic analysis and symbol tables
  -> NYAC three-address IR
  -> liveness analysis
  -> interference graph and register coloring
  -> RISC-V lowering
```

The implementation is under `src`:

- `c11.l` and `c11.y` define the lexer and parser. The generated C sources are linked into the Zig executable.
- `ast.zig` defines the AST representation and parser-facing node construction.
- `scope.zig` and `semanticAnalyzer.zig` implement symbol tables, scopes, and semantic checks.
- `3ac.zig` lowers supported AST nodes to NYAC, the project's three-address IR.
- `assembler.zig` performs register allocation and lowers supported NYAC instructions to RISC-V assembly.
- `main.zig` drives parsing, semantic analysis, IR generation, and assembly generation.

## Building

NyxLang was developed against Zig 0.15.1 and requires Flex and Bison.

From the repository root:

```sh
zig build
```

The build invokes Flex and Bison to generate the parser and lexer C sources in the Zig build cache, then links them with the Zig compiler driver.

On some rolling-release distributions, Zig 0.15.1 fails to link against the system C runtime (`unhandled relocation type R_X86_64_PC64 ... crt1.o:.sframe`). Building against Zig's bundled glibc avoids this. Pass the option to every `zig build` command, before any `--`:

```sh
zig build -Dtarget=x86_64-linux-gnu
zig build run -Dtarget=x86_64-linux-gnu -- tests/fixtures/factorial.nyx
zig build test -Dtarget=x86_64-linux-gnu
```

## Usage

Run the compiler from the repository root and pass a source file:

```sh
zig build run -- tests/fixtures/factorial.nyx
```

An optional flag after the source file controls diagnostic output and the assembly backend:

```sh
zig build run -- tests/fixtures/array_initializer.nyx -a
```

| Flag  | Behavior                                                          |
| ----- | ----------------------------------------------------------------- |
| `-d`  | Enable verbose compiler output, including AST and IR diagnostics. |
| `-a`  | Run the RISC-V lowering pass after NYAC generation.               |
| `-ad` | Enable both debug output and RISC-V lowering.                     |

Flags must be combined into a single argument (`-ad`, not `-a -d`).

NYAC output is written to `a.nyac`. When assembly lowering is enabled, the current backend writes `a.s`.

## Examples

`examples/` has one small program per supported language feature. Each one prints its results, so you can compile it to RISC-V, run it, and see the output.

Running the programs needs `qemu-riscv64` (user-mode QEMU: `qemu-user` on Arch, Debian, and Ubuntu). Zig's bundled `zig cc` assembles and links the output against musl, so no RISC-V toolchain is required.

Build the compiler once, then compile, link, and run any example:

```sh
zig build
./zig-out/bin/NyxLang examples/hello_world.nyx -a # writes a.nyac and a.s
zig cc -target riscv64-linux-musl -static a.s -o zig-out/hello_world
qemu-riscv64 zig-out/hello_world
```

```text
Hello from NyxLang!
```

To run every example:

```sh
for f in examples/*.nyx; do
    [ "$f" = examples/semantic_errors.nyx ] && continue
    echo "== $f"
    ./zig-out/bin/NyxLang "$f" -a > /dev/null &&
    zig cc -target riscv64-linux-musl -static a.s -o zig-out/example &&
    qemu-riscv64 zig-out/example
done
```

On systems that need the `-Dtarget=x86_64-linux-gnu` workaround above, pass it to `zig build`.

## Testing

```sh
zig build test    # unit tests
zig build smoke   # end-to-end: run the compiler on tests/fixtures and check its output
```

Test programs live in `tests/fixtures`. The smoke tests check exit status, generated NYAC, diagnostics, and RISC-V output structurally rather than byte-for-byte, because the IR and backend still have known gaps.

## Current limitations

The parser accepts a broader C-style grammar than the compiler fully supports. Several constructs are explicitly rejected or only partially implemented, including `_Generic`, casts, enums, atomics, several storage-class and type qualifiers, and some function features.

Not supported yet:

- array indexing
- struct pointers
- floating-point values
- the ternary operator, `do`/`while`, `switch`, `break`, `continue`, and `goto`, parse but generate no code
- short-circuit evaluation
- register spilling
