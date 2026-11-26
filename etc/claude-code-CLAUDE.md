<!-- gpushare:begin -->
## Shared GPUs on this server

The GPUs on this machine are shared through a cooperative queue. Before you use any GPU (training, inference, CUDA code, notebooks, benchmarks), read `/srv/gpushare/AGENTS.md` and follow it. `/srv/gpushare/bin/gpuq status` shows who is assigned to each GPU, who is running, and who is waiting. Never start GPU work without a lock, and never use a GPU you don't hold.
<!-- gpushare:end -->
