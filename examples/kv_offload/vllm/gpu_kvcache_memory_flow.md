# GPU Memory and KV Cache Flow

```mermaid
flowchart LR
  A["GPU_MEMORY_SIZE (e.g. 5.5g)"] --> B["Auto-derive GMEM_UTIL"]
  B --> C[gpu_memory_utilization]
  C --> D["vLLM available KV cache memory"]

  E["LMCache config"] --> F[kv_transfer_config]
  F --> G[kv_buffer_size]
  F --> H[global_segment_size]
  F --> I[local_buffer_size]

  D --> J[GPU KV cache hit]
  J --> K["Lower TTFT; Case2 same-instance warm hit"]

  D --> L[GPU cache eviction pressure]
  L --> M[More external prefix cache hits]
  M --> N["LMCache / Mooncake retrieval"]
  N --> O["Case2 / Case3 depend more on external hit"]

  H --> P["Mooncake store capacity / segment pool"]
  I --> Q["Client-side staging buffer"]
  G --> R["Lookup buffer for long prompts"]
```

说明：
- `GPU_MEMORY_SIZE` 只是一个更直观的目标值，脚本里会换算成 `gpu_memory_utilization`。
- `gpu_memory_utilization` 决定 vLLM 能拿多少显存做 KV cache。
- `kv_buffer_size`、`global_segment_size`、`local_buffer_size` 是 LMCache / Mooncake 侧的不同容量参数。
- 如果你把 `gpu_memory_utilization` 调低，GPU KV cache 更容易被挤掉，case2 / case3 就更可能依赖 external hit。
