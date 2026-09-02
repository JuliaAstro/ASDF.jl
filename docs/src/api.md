# API

## Public

```@autodocs
Modules = [ASDF]
Private = false
```

## Custom type writing

```@docs
ASDF.WriteContext
ASDF.to_tree
ASDF.TaggedMapping
ASDF.TaggedSequence
ASDF.TaggedScalar
```

## Private
```@autodocs
Modules = [ASDF]
Public = false
Filter = value -> value ∉ (ASDF.WriteContext, ASDF.to_tree, ASDF.TaggedMapping, ASDF.TaggedSequence, ASDF.TaggedScalar)
```
