# Retrace fixture provenance

`r8-9.4.28-mapping.txt` was produced by official R8 9.4.28 from the owned benign `proof.Crash` program during CYRA-956 certification on 2026-10-04. It is actual compiler output, including semantic comments and three inlined original calls for generated line 1. It contains no source body or credentials. Its presence is a parser regression fixture, not a claim of SDK transport or deployed support.

## Recorded processor responses

`native-processor-response.json` and `retrace-processor-response.json` contain actual HTTP responses captured on 2026-10-05 from isolated local processors. Each records its image digest, processor version and input SHA-256. The native request used the Linux arm64 certification object and address `0x41e8`; it returned two inline locations. The R8 request used the mapping above with `java.lang.IllegalStateException: demo` and `\tat a.a.a(SourceFile:1)`; both lines were unchanged.

`linux-arm64-crash-manifest.json` contains the bounded report from the real SIGSEGV captured during native certification run `0172000000000901`, together with the minidump SHA-256. No raw minidump or process memory is included.

These fixtures exercise schema validation, retention and metadata selection without requiring processors in every CI shard. They do not replace the separate real-processor certification or prove runtime support on other platforms. Boundary tests deliberately mutate these inputs to verify rejection.
