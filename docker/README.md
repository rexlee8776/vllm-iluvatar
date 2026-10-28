# 分层构建镜像

基础环境与四个源码组件分开维护：

| Dockerfile | 内容 | 何时重建 |
| --- | --- | --- |
| `Dockerfile.base` | Ubuntu、Python、CoreX toolkit/SDK、Torch、TorchVision、Triton、系统编译工具及 Python 依赖 | SDK、Torch、Triton、Python 或依赖变更 |
| `Dockerfile` | ixinfer、ixformer、vLLM 框架、vllm-iluvatar 插件 | 对应源码版本变更 |

vLLM 在独立阶段构建，不依赖 ixinfer/ixformer 的编译缓存。插件使用当前构建目录的源码；其余三项用 commit 固定版本。四个组件都不放入基础镜像。本次拆分保持原有源码版本，不自动升级到各仓库最新提交。

## 首次构建基础镜像

在仓库根目录执行，同一份源码、参数分别生成两个 target：

```bash
BASE=10.150.9.98:80/aac-llmfp/vllm-iluvatar-base-0.31.0:corex5.0.1-ubuntu24.04-python3.12-x86_64-ivcore11-20261023
BUILD_BASE=${BASE}-build

docker build --platform linux/amd64 --network=host --build-arg CPU_ARCH=x86_64 --build-arg COREX_ARCH=ivcore11 -f Dockerfile.base --target runtime-base -t "$BASE" .
docker build --platform linux/amd64 --network=host --build-arg CPU_ARCH=x86_64 --build-arg COREX_ARCH=ivcore11 -f Dockerfile.base --target build-base -t "$BUILD_BASE" .
```

两个 target 共享依赖层。`runtime-base` 不包含 driver；`build-base` 仅多出编译时导入 Torch 所需的用户态驱动库，从安装包提取，不安装内核驱动。运行最终镜像时仍使用匹配宿主的驱动映射方式。不要将 build-base 当作运行时基础镜像。

默认 CoreX 5.0.1 / Python 3.12 / ivcore11，SDK 与 Torch/Triton 来自 Dockerfile 固定的同一发布目录。改变 `COREX_PKG_URL`、`TORCH_PKG_URL`、`TRITON_PKG_URL`、`COREX_ARCH` 或 `PYTHON_VERSION` 时，两个 target 必须传入相同参数，并使用新标签。发布后建议通过 digest 引用，避免同名标签漂移。

## 后续只构建四项源码

```bash
# 使用已获内部 Git 权限的 SSH agent；密钥不会复制进镜像。
# BASE / BUILD_BASE 沿用上文变量，或指定已经发布的配套镜像。
docker build --platform linux/amd64 --network=host --ssh default \
  --build-arg CPU_ARCH=x86_64 \
  --build-arg TARGET_COREX_ARCH=ivcore11 \
  --build-arg BASE_IMAGE="$BASE" \
  --build-arg BUILD_BASE_IMAGE="$BUILD_BASE" \
  --build-arg VLLM_ILUVATAR_COMMIT="$(git rev-parse HEAD)" \
  --build-arg MAX_JOBS=64 \
  -t 10.150.9.98:80/aac-llmfp/vllm-iluvatar-0.31.0:corex5.0.1-ubuntu24.04-python3.12-x86_64-ivcore11-20261023 .
```

通过 `IXFORMER_COMMIT`、`VLLM_COMMIT` 覆盖外部源码版本；ixinfer commit 自动读取 ixformer 的 gitlink，不单独覆盖。分支参数分别为 `IXINFER_BRANCH`、`IXFORMER_BRANCH`、`VLLM_BRANCH`。ixinfer 必须与指定 ixformer 的 `third_party/ixinfer` gitlink 一致，否则构建失败。vLLM 使用 `build_vllm.sh`，不构建可选 Rust frontend；插件使用 `build_vllm_iluvatar.sh`。

源码阶段和最终装包阶段禁止从 PyPI 下载依赖，所有 wheel 均以 `--no-deps` 安装。`requirements.txt` 变更时会明确要求重建 base，避免运行镜像缺少新依赖；配套 base 的版本、依赖摘要和核心 Python 包版本也会核对。新增构建依赖应写入 `docker/requirements-build.txt` 并重建基础镜像。

Docker 缓存按依赖关系复用：只改插件通常只重建插件；改 vLLM 只重建 vLLM 与插件；改 ixformer 重建 ixformer 与插件；改 ixinfer 会重建依赖它的 ixformer 与插件。首次构建或清理缓存后仍需完整编译。

## 运行

最终镜像仍保留 toolkit、编译器，以及源码编译的 libcuinfer 和配套 ixinfer.h，可继续在容器内编译 ixformer 与插件。用户态 driver 由宿主映射到容器；使用之前经过验证的容器启动方式。修改本次分层结构不代表扩展 GPU 架构或执行模式的支持范围。

## 查看源码版本

最终镜像和 `builder` target 的 labels 记录四项源码 commit；镜像内还保留版本清单，包含 SDK、Torch、Triton 等基础环境版本。构建时必须传入当前插件的完整 commit，如上文 `VLLM_ILUVATAR_COMMIT` 参数。可用 Git 信息存在时会核对 HEAD，并记录插件是否有已跟踪文件的未提交改动；无法读取 Git worktree 指针时该改动标记为 null，不能据此宣称工作区干净。

```bash
docker image inspect <image> --format '{{json .Config.Labels}}'
docker run --rm --entrypoint iluvatar-build-info <image>
# 已进入容器时：
iluvatar-build-info
# 文件位置：/etc/iluvatar-build-info.json
```

base 不包含这四项源码产物，其基础环境清单位于 `/opt/iluvatar-base/manifest.json`。同一标签不能跨 GPU 架构复用；本标签对应 ivcore11，其他架构应替换对应架构字段并独立验证。

镜像标签统一采用 `corex<CoreX版本>-ubuntu<Ubuntu版本>-python<Python版本>-<CPU架构>-<GPU架构>-<YYYYMMDD>`，日期为北京时间实际发布日。业务镜像仓库为 `aac-llmfp/vllm-iluvatar-0.31.0`；base 为 `aac-llmfp/vllm-iluvatar-base-0.31.0`，编译 base 在完整标签末尾加 `-build`。base 仓库名中的 vLLM 版本表示配套的环境版本，不代表 base 内已安装 vLLM。

## CPU / GPU 架构选择

两种架构独立管理：`CPU_ARCH=x86_64` 对应 Docker `--platform linux/amd64`，`aarch64` 对应 `linux/arm64`；`COREX_ARCH=ivcore11|ivcore30` 指定 GPU 编译目标。base 在安装SDK前核对运行平台与 CPU_ARCH，并将 CPU/GPU 架构标签同时写入 runtime-base 和 build-base。

CPU_ARCH 参与默认 SDK 下载路径；切换 CPU/GPU 时必须核对 COREX_PKG_URL、TORCH_PKG_URL、TRITON_PKG_URL 中实际安装包的支持范围。参数化不表示 ARM 或 ivcore30 已通过模型验收，不允许只改标签复用 ivcore11 的环境。

成品构建通过 BASE_IMAGE / BUILD_BASE_IMAGE 选取配套环境，从 base 继承 COREX_ARCH/CUDA_ARCH。CPU_ARCH 与 TARGET_COREX_ARCH 是独立的期望值：任一 base 与期望值不一致即提前失败，避免参数覆盖掩盖错误架构。现有 manifest 匹配继续检查 runtime/build base 环境一致性。

脚本用法：`CPU_ARCH=x86_64 COREX_ARCH=ivcore11 bash scripts/build_image.sh`。非默认架构还必须显式设置已验证的 BASE_IMAGE 和 BUILD_BASE_IMAGE；脚本传入对应 --platform 和架构期望参数。ARCH 仍作为 CPU_ARCH 的兼容别名。日期按北京时间生成，顺序固定为 CPU → GPU → 日期，build base 在日期后追加 -build。
