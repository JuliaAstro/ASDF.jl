# Interoperability

The [PythonCall.jl](https://juliapy.github.io/PythonCall.jl/stable/) package makes writing and reading ASDF files from the Python implementation of ASDF fairly seamless. For example, here is one way we might reproduce the [Creating Files](https://www.asdf-format.org/projects/asdf/en/latest/asdf/overview.html#creating-files) section from the Python `asdf` documentation without leaving our Julia session:

## Accessing the IPython REPL from Julia

We start by creating a fresh [Julia environment](https://pkgdocs.julialang.org/v1/environments/) named `asdf` in a global location:

```shell
julia --proj=@asdf # Or --proj=<path to a custom location>
```

!!! tip
    To verify that this is a blank environment and to also display its location, run the `st` command (short for `status`) from the package REPL:

    ```julia-repl
    julia> # Press ] to enter the package mode REPL
    (@asdf) pkg> st
    Status `~/.julia/environments/asdf/Project.toml` (empty project)
    ```

We next install whichever Python packages we may need for our analysis, e.g., `asdf` and `astropy`. PythonCall.jl exports [CondaPkg.jl](https://github.com/JuliaPy/CondaPkg.jl), which has nice hooks for accomplishing this:

```julia-repl
(@asdf) pkg> add PythonCall

julia> using PythonCall

(@asdf) pkg> conda add asdf astropy

(@asdf) pkg> conda st
CondaPkg Status <path to your julia environment>/CondaPkg.toml
Environment
  <path to your julia environment>/.CondaPkg/.pixi/envs/default
Packages
  asdf v5.3.0
  astropy v7.2.0

(@asdf) pkg> conda run ipython
```

The last command (`conda run ipython`) starts an IPython REPL provided in the `astropy` installation directly from Julia. We can then enter regular Python syntax verbatim to create a sample ASDF file called `example.asdf`:

```python
from asdf import AsdfFile
import numpy as np

# Create some data
sequence = np.arange(100)
squares = sequence**2
random = np.random.random(100)

# Store the data in an arbitrarily nested dictionary
tree = {
    "foo": 42,
    "name": "Monty",
    "sequence": sequence,
    "powers": {"squares": squares},
    "random": random,
}

# Create the ASDF file object from our data tree
af = AsdfFile(tree)

# Write the data to a new file
af.write_to("example.asdf")
```

!!! note
    IPython does not come with PythonCall.jl/CondaPkg.jl by default. If working with packages other than `astropy` that do not bundle `ipython`, use `conda run python` instead.

## Julia REPL

PythonCall.jl also makes it easy to run Python syntax directly from the Julia REPL. For example, the above IPython commands could also be run directly using the [`PythonCall.@pyexec`](@extref) macro:

```shell
julia --proj=@asdf # Re-use the environment created earlier
```

```julia
using PythonCall

@pyexec """
from asdf import AsdfFile
import numpy as np

# Create some data
sequence = np.arange(100)
squares = sequence**2
random = np.random.random(100)

# Store the data in an arbitrarily nested dictionary
tree = {
    "foo": 42,
    "name": "Monty",
    "sequence": sequence,
    "powers": {"squares": squares},
    "random": random,
}

# Create the ASDF file object from our data tree
af = AsdfFile(tree)

# Write the data to a new file
af.write_to("example.asdf")
"""
```

The [`PythonCall.@py`](@extref) macro reduces the barrier between Python and Julia even further by allowing us to work with Python objects directly using Julia syntax:

```julia
@py begin
    import asdf: AsdfFile # Julia syntax version of `from asdf import AsdfFile`
    import numpy as np
end

sequence = np.arange(100)

squares = sequence^2 # Note that Julia uses `^` instead of `**`

random = np.random.random(100)

# Create a Python dict with PythonCall.pydict
tree = pydict(
    "foo" => 42,
    "name" => "Monty",
    "sequence" => sequence,
    "powers" => pydict("squares" => squares),
    "random" => random,
);

af = AsdfFile(tree)

af.write_to("example.asdf")
```

See the [PythonCall.jl documentation](https://juliapy.github.io/PythonCall.jl/stable/) for more.

## Compression

Which [compression schemes](@ref ASDF.Compression) the Python `asdf` reader understands depends on what is installed on the Python side:

- `C_Zlib`, `C_Bzip2`, and `C_Lz4` (the chunked LZ4 block format of Python's built-in `lz4` compressor) are readable by a stock `asdf` install (`lz4` additionally needs the [`lz4`](https://python-lz4.readthedocs.io/) Python package).
- `C_Lz4F` (`lz4f`, LZ4 frame), `C_Zstd`, and `C_Blosc`/`C_Blosc2` need the [asdf-compression](https://github.com/asdf-format/asdf-compression) extension.
- `C_Xz` currently has no Python counterpart.
