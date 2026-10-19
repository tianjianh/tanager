# Tanager riscv.scr, step 4's stub (docs/spec/soc-d4-modes.md): the mode check's RISC-V path without the RISC-V. It
# says it ran and returns, so the hook goes on to boot Ubuntu, with the record now at trial 1.
# (U-Boot's hush takes an apostrophe inside double quotes as a syntax error and then crashes: none in strings.)
echo "tanager riscv.scr: the step 4 stub, returning to Ubuntu"
exit
