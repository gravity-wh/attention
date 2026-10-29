for t in iverilog verilator vcs verdi yosys gtkwave python3; do
  if command -v "$t" >/dev/null 2>&1; then
    printf '%-10s OK  %s\n' "$t" "$(command -v "$t")"
  else
    printf '%-10s --\n' "$t"
  fi
done
