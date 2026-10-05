# Error diagnostics

The language used to explain reported failures without changing the original evidence.

## Language

**Artifact**:
Private build information used to interpret a reported failure. An artifact belongs to one project and one build identity.

**Build identity**:
The identifying information that distinguishes published code within its project, including the release, distribution and file or debug identifiers applicable to that artifact.

**Generated frame**:
A stack position reported by the running, compiled application. It remains the original evidence even when an artifact becomes available.

**Original frame**:
A source position resolved from a generated frame using a matching artifact. A mapped symbol is not necessarily the name of its enclosing function.

**Symbolication result**:
A separate interpretation of a reported stack, including the matching artifact and an explicit reason for every unresolved frame.

**Ambiguous reconstruction**:
Several compatible interpretations of an original stack retained together without choosing one as truth.

**Inlined frame**:
A source call folded into another compiled function, which may expand one reported stack position into several source positions.
