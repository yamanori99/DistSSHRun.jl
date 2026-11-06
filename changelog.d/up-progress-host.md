category: fixed

- At `:progress`, `up` result and failure lines name the host. `:verbose` keeps the spinner prefix and does not repeat it. `up status` still prints each host when the parent's juliaup exists but cannot be launched; that parent patch is unknown, and those hosts are not failed. `setup --check` diagnostics start on their own line. The phase bar does not redraw on the final failure line.
