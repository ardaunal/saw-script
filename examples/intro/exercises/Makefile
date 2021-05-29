
# Build commands for bitcode
.SUFFIXES: .c .bc

%.bc : %.c
	clang-11 -g -O1 -c -emit-llvm $< -o $@
# End build commands for bitcode
