category: fixed

- `up status`, `up add`, `up update`, and align print their result lines when the terminal default is `:progress`. `setup --check` prints its failure and warning lines in that mode as well, before `Prerequisites not met`. `:quiet` still keeps those lines on the kit log. The live progress bar is unchanged.
