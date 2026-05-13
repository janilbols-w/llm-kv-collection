# vLLM Sleep / Benchmark Scripts

这个目录包含两个脚本：

- `vllm_sleep_wake_cli.py`：调用 vLLM Sleep Mode 开发接口的 CLI
- `run_evalscope_perf_random_case.sh`：基于 EvalScope perf 的可重复 benchmark 用例
- `preprocess_evalscope_perf_data.py`：为 benchmark 生成固定输入数据

支持接口：
- `POST /sleep`
- `POST /wake_up`
- `GET /is_sleeping`

## 1. 前置条件

1. 已启动 vLLM 服务，并开启 sleep mode 相关能力。
2. vLLM 服务启用了开发端点（通常需要设置 `VLLM_SERVER_DEV_MODE=1`）。
3. Python 3.9+（脚本使用标准库，无第三方依赖）。

参考启动示例（按你的环境调整）：

```bash
VLLM_SERVER_DEV_MODE=1 vllm serve <model_name_or_path> \
  --enable-sleep-mode \
  --port 12358
```

## 2. 快速开始

在当前目录执行：

```bash
python vllm_sleep_wake_cli.py --help
python vllm_sleep_wake_cli.py sleep --help
python vllm_sleep_wake_cli.py wake --help
python vllm_sleep_wake_cli.py status --help
```

默认连接地址：`http://127.0.0.1:12358`

Benchmark 默认入口：

```bash
bash run_evalscope_perf_random_case.sh
```

## 3. 命令说明

### 3.1 sleep

调用 `POST /sleep`。

```bash
python vllm_sleep_wake_cli.py sleep [--level 1|2] [--mode MODE] [--query KEY=VALUE ...]
```

参数：
- `--level`：sleep 级别，`1` 或 `2`，默认 `1`。
- `--mode`：对应接口的 `mode` 查询参数，默认 `abort`。
- `--query KEY=VALUE`：追加额外 query 参数，可重复传入。

示例：

```bash
# level=1（默认）
python vllm_sleep_wake_cli.py sleep

# level=2 + mode=wait
python vllm_sleep_wake_cli.py sleep --level 2 --mode wait

# 透传额外参数（示例）
python vllm_sleep_wake_cli.py sleep --level 1 --query foo=bar --query x=1
```

### 3.2 wake

调用 `POST /wake_up`。

```bash
python vllm_sleep_wake_cli.py wake [--tag weights|kv_cache ...] [--query KEY=VALUE ...]
```

参数：
- `--tag`：可选，重复传入；支持：`weights`、`kv_cache`。
- `--query KEY=VALUE`：追加额外 query 参数，可重复传入。

说明：
- 不传 `--tag` 时，等价于唤醒全部组件。

示例：

```bash
# 唤醒全部
python vllm_sleep_wake_cli.py wake

# 仅唤醒 weights
python vllm_sleep_wake_cli.py wake --tag weights

# 依次唤醒 weights + kv_cache
python vllm_sleep_wake_cli.py wake --tag weights --tag kv_cache
```

### 3.3 status

调用 `GET /is_sleeping`。

```bash
python vllm_sleep_wake_cli.py status [--query KEY=VALUE ...]
```

参数：
- `--query KEY=VALUE`：追加额外 query 参数，可重复传入。

示例：

```bash
python vllm_sleep_wake_cli.py status
```

## 4. 全局参数

可放在子命令前：

- `--base-url`：vLLM 服务地址，默认 `http://127.0.0.1:12358`。
- `--timeout`：HTTP 超时秒数，默认 `30`。
- `--raw`：仅输出原始响应体，不打印 `HTTP <status>` 前缀。

示例：

```bash
python vllm_sleep_wake_cli.py --base-url http://127.0.0.1:8000 status
python vllm_sleep_wake_cli.py --timeout 5 sleep --level 1
python vllm_sleep_wake_cli.py --raw status
```

## 5. 返回码与输出

- 进程退出码：
  - `0`：HTTP 状态码在 `2xx`。
  - `1`：HTTP 状态码非 `2xx`。
  - `2`：参数错误（argparse）。

- 默认输出：
  1. 第一行打印 `HTTP <status_code>`。
  2. 若响应体是 JSON，格式化后打印。
  3. 非 JSON 则按原文本打印。

## 6. 常见问题

### 6.1 返回 404

通常表示服务未开启开发接口或路径不可用：
- 确认已设置 `VLLM_SERVER_DEV_MODE=1`。
- 确认 vLLM 版本支持 sleep mode 接口。
- 确认 `--base-url` 与服务实际地址一致。

### 6.2 返回连接错误

- 检查服务是否启动。
- 检查端口是否正确（脚本默认是 `12358`）。
- 检查机器网络与防火墙策略。

### 6.3 需要传自定义 query 参数

直接使用可重复的 `--query KEY=VALUE`：

```bash
python vllm_sleep_wake_cli.py wake --query a=1 --query b=2
```

## 7. EvalScope perf benchmark

`run_evalscope_perf_random_case.sh` 用于压测 TTFT、TPOT、吞吐等指标。

### 默认行为

脚本默认启用固定数据模式，也就是：

1. 首次根据测试参数生成一份固定 JSONL 数据
2. 后续重复测试直接复用这份数据
3. 如果文件已经存在，默认不会重新生成

这意味着同一组测试参数下，多轮重复跑到的是同一批输入。

### 常用参数

- `MODEL`：模型名
- `URL`：vLLM OpenAI 兼容接口地址，默认 `http://127.0.0.1:12358/v1/chat/completions`
- `PARALLEL`：并发数，支持空格分隔的多个值
- `NUMBER`：每个并发配置对应的请求数，必须和 `PARALLEL` 数量一致
- `MULTI_TURN=1`：开启多轮对话 benchmark
- `MIN_TURNS` / `MAX_TURNS`：多轮会话轮数范围
- `MIN_PROMPT_LENGTH` / `MAX_PROMPT_LENGTH`：单轮输入长度控制
- `MIN_TOKENS` / `MAX_TOKENS`：输出长度控制
- `REPEAT`：重复跑同一组 benchmark 的次数
- `SEED`：固定样本生成种子
- `FIXED_DATASET=1`：启用固定数据复用模式，默认开启
- `FIXED_DATASET_REGENERATE=1`：强制重新生成固定数据
- `FIXED_DATASET_DIR`：固定数据落盘目录
- `FIXED_DATASET_LENGTH_UNIT`：固定数据长度单位，支持 `token` / `char`，默认 `token`
- `FIXED_DATASET_NAME_TEMPLATE`：固定数据文件名模板

### 长度单位说明（重要）

`evalscope perf` 在设置了 `--tokenizer-path` 时，会按 token 数检查 `min/max_prompt_length`。

因此推荐默认使用：

- `FIXED_DATASET_LENGTH_UNIT=token`
- 同时配置 `TOKENIZER_PATH`

这样预处理生成的数据长度与 EvalScope 的过滤口径一致，避免出现 `Dataset is empty!`。

如果使用 `char` 模式，需要注意：

- 预处理按字符长度生成
- EvalScope 可能仍按 token 长度过滤（取决于是否传入 tokenizer）
- 两者口径不一致时，可能导致样本被全部过滤

### 文件命名模板

默认模板如下：

```bash
{prefix}_{mode}_seed{seed}{turns_suffix}_len{length}_{unit}_n{size}.jsonl
```

可用占位符：

- `{prefix}`：`NAME_PREFIX`
- `{mode}`：`single` 或 `multi`
- `{seed}`：`SEED`
- `{size}`：`FIXED_DATASET_SIZE`
- `{prompt_length}`：单轮长度
- `{turn_length}`：多轮单 turn 长度
- `{turns}`：多轮 turns 数
- `{length}`：自动映射到单轮或多轮的长度字段
- `{turns_suffix}`：多轮时自动补 `_turnsN`，单轮时为空
- `{unit}`：长度单位（`token` 或 `char`）

### 示例

```bash
# 单轮，默认复用固定数据
bash run_evalscope_perf_random_case.sh

# 多轮 + 重复 3 次 + 强制重建固定数据
MULTI_TURN=1 \
REPEAT=3 \
FIXED_DATASET_REGENERATE=1 \
bash run_evalscope_perf_random_case.sh

# 自定义命名模板
FIXED_DATASET_NAME_TEMPLATE='{prefix}_{mode}_seed{seed}_p{prompt_length}_n{size}.jsonl' \
bash run_evalscope_perf_random_case.sh
```

### 预处理脚本

如果你想单独生成数据，可以直接调用：

```bash
python preprocess_evalscope_perf_data.py --help
```

它支持：

- `--mode single`
- `--mode multi-turn`
- `--overwrite` 强制覆盖已有文件
