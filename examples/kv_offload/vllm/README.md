# vLLM KV Offload

This directory contains the vLLM KV offload scripts, tests, and special-case launchers.

## Cross-instance test topology

The diagram below shows the call relationship for the cross-instance benchmark flow:

- `data_gen` builds or reuses the fixed EvalScope dataset
- `evalscope perf` drives the benchmark cases
- `instanceA` and `instanceB` are the two vLLM + LMCache servers
- `remote server` is the shared Redis/RESP backend used for cross-instance reuse

```mermaid
flowchart LR
    DG["data_gen\npreprocess_evalscope_perf_data.py\nrun_evalscope_perf_random_case.sh"]
    EP["evalscope perf\nrun_e2e_lmcache_cross_instance.sh\nrun_evalscope_perf_random_case.sh"]

    subgraph A["instanceA"]
        IA["run_lmcache_offload_instance.sh\nvLLM + LMCache"]
    end

    subgraph B["instanceB"]
        IB["run_lmcache_offload_instance.sh\nvLLM + LMCache"]
    end

    subgraph R["remote server"]
        RS["run_redis_remote_server.sh\nRESP / Redis backend"]
    end

    DG -->|fixed JSONL dataset| EP
    EP -->|case1 / case2 warm on A| IA
    EP -->|case3 / case4 reuse on B| IB
    EP -->|case5 / case6 sleep-wake then rerun| IA
    EP -->|case5 / case6 sleep-wake then rerun| IB
    IA <-->|shared remote_url| RS
    IB <-->|shared remote_url| RS
```

## Cross-project module call graph

The graph below summarizes how local scripts in this directory orchestrate
the third-party modules under `3rdparty/` during KV offload experiments.

- Solid arrows: default execution path in LMCache cross-instance tests.
- Dashed arrows: optional or alternative connector paths.

```mermaid
flowchart TD
        U[User or Test Trigger]

        subgraph Local[examples/kv_offload/vllm]
            E2E[tests/run_e2e_lmcache_cross_instance.sh]
            Multi[scripts/run_lmcache_offload_multi.sh]
            Single[scripts/run_lmcache_offload.sh]
            Eval[scripts/run_evalscope_perf_random_case.sh]
            Data[scripts/preprocess_evalscope_perf_data.py]
            RedisCtl[scripts/run_redis_remote_server.sh]
            SW[scripts/vllm_sleep_wake_cli.py]
            CfgA[config/lmcache.instance_a.template.yaml]
            CfgB[config/lmcache.instance_b.template.yaml]
        end

        subgraph ThirdParty[3rdparty modules]
            VLLM[vllm service]
            LMC[LMCacheConnectorV1 in vLLM]
            LMCore[lmcache runtime]
            RESP[RESP adapter]
            RDB[(Redis or Valkey)]
            EV[evalscope perf]
            FLEX[FlexKVConnectorV1]
            FLEXKV[FlexKV runtime]
            MCConn[MooncakeConnector in vLLM]
            MCStore[(Mooncake services)]
            Router[router optional frontend]
        end

        U --> E2E
        U --> Multi
        U --> Single

        E2E --> RedisCtl
        E2E --> CfgA
        E2E --> CfgB
        E2E --> Eval
        E2E --> SW

        Eval --> Data
        Eval --> EV

        Multi --> Single

        Single --> VLLM
        CfgA --> Single
        CfgB --> Single

        VLLM --> LMC
        LMC --> LMCore
        LMCore --> RESP
        RESP --> RDB

        VLLM -. alternative connector path .-> FLEX
        FLEX --> FLEXKV

        VLLM -. alternative connector path .-> MCConn
        MCConn --> MCStore

        Router -. optional gateway .-> VLLM
```

## Related scripts

- [scripts README](scripts/README.md)
- [cross-instance special case](tests/cross_instance_manual/README.md)
