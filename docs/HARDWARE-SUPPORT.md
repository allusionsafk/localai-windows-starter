# Hardware and runtime support

**Verified:** 2026-07-24

**Policy:** report facts and product support separately; fail closed on unknowns

Run:

```powershell
localai hardware
localai hardware --json
```

The bounded JSON form is intended for installers and diagnostics. It includes
the operating system, architecture, CPU, physical memory, multiple
accelerators, dedicated/shared/unified memory, driver/runtime status, evidence
quality, provenance, and warnings. Absolute user paths are scrubbed.

## Support matrix

| Platform/runtime | Detection | Product status | Evidence and boundary |
|---|---|---|---|
| Windows 11 x64 + NVIDIA CUDA | Implemented | First-class | Existing NVIDIA behavior is preserved; `nvidia-smi` is queried once with a bounded argument list and multiple GPUs are retained. |
| Windows/Linux/macOS CPU | Implemented | Safe fallback | Physical-memory probes fail closed; small-model practicality still depends on measured RAM and throughput. |
| Apple Silicon + Metal | Implemented | Experimental | Unified memory and Metal capability are reported, but the Windows installer and Docker-dependent stack are not ported. |
| Linux + NVIDIA CUDA | Partial | Research only | Hardware can be reported; installer, service lifecycle, and clean-machine evidence are absent. |
| AMD ROCm | Not selected | Research only | Upstream runtimes support subsets of AMD hardware; this product has no qualified matrix or installer lane. |
| Vulkan | Not selected | Research only | Useful llama.cpp portability lane; no product packaging or measured regression gate. |
| Windows ML / DirectML / ONNX Runtime | Not selected | Research only | Provider availability does not prove that current GGUF/Ollama models can use it. |
| Ryzen AI / OpenVINO / Qualcomm QNN | Adapter-ready | Unsupported | An NPU is reported as unsupported until a compatible model format, runtime, and benchmark are demonstrated. |
| Windows ARM64 acceleration | Architecture reported | Unavailable | Current Ollama Windows acceleration does not establish an ARM64 product path. |
| DGX Spark | Not selected | Research only | Unified-memory budgeting, Linux ARM64 packaging, and real hardware gates remain open. |

## Promotion gates

A runtime moves from research to experimental only after:

1. Official upstream install and compatibility documentation is captured.
2. A clean, pinned installation can be reproduced without unverified
   downloads.
3. Hardware, runtime, and memory evidence is machine-readable and fail-closed.
4. Representative models load, generate, unload, and stay within measured
   memory budgets.
5. Synthetic platform tests and real-hardware smoke tests pass.

First-class support additionally requires installer, chat, health,
backup/restore, update approval, rollback, sleep/wake where applicable, and
clean uninstall evidence on representative hardware.

## Official upstream references

- Ollama hardware support:
  <https://docs.ollama.com/gpu>
- llama.cpp backends and supported hardware:
  <https://github.com/ggml-org/llama.cpp>
- Windows ML overview and execution providers:
  <https://learn.microsoft.com/windows/ai/new-windows-ml/overview>
- ONNX Runtime execution providers:
  <https://onnxruntime.ai/docs/execution-providers/>
- AMD Ryzen AI software:
  <https://ryzenai.docs.amd.com/>
- Intel OpenVINO supported devices:
  <https://docs.openvino.ai/2026/about-openvino/compatibility-and-support/supported-devices.html>
- Qualcomm QNN execution provider:
  <https://onnxruntime.ai/docs/execution-providers/QNN-ExecutionProvider.html>

These links describe upstream capability. This document's product-status column
is the narrower promise made by this starter.
