# 如何搭建 vllm-iluvatar 开发环境

vllm-iluvatar 的运行依赖 vllm 和 ixformer 两个组件。两者锁定的 commit 由仓库根目录 `Dockerfile` 顶部的构建参数(`IXFORMER_BRANCH` / `IXFORMER_COMMIT` 与 `VLLM_BRANCH` / `VLLM_COMMIT`)统一管理,作为**唯一来源**:Docker 构建直接使用,本地开发也据此对齐,确保版本一致。

> 这两个组件曾以 git submodule 形式纳入本仓库,现已移除。请改用下文的"按 pin 克隆"流程,或直接使用仓库根目录的 `Dockerfile` 做可复现的整链路构建。

## 锁定的版本

查看根目录 `Dockerfile` 顶部的构建参数:

```bash
grep -E "^ARG (IXFORMER|VLLM)_(BRANCH|COMMIT)=" Dockerfile
```

> ixformer 自身的底层依赖由 ixformer 仓库管理,vllm-iluvatar 仅关注 ixformer 的 commit。相关说明参见 ixformer 仓库的《如何搭建 ixformer 开发环境》。

## 方式一(推荐):用 Dockerfile 做整链路构建

仓库根目录的 `Dockerfile` 会按其内置的 `*_COMMIT` 参数克隆并源码编译 ixinfer / ixformer / vllm,再用**构建上下文(即本仓库源码)**构建安装本插件,产出可直接运行的镜像。适合打包与可复现验证。详见根目录 README 的 Docker 构建小节。

## 方式二:本地按 pin 克隆后手动构建

```bash
# 从 Dockerfile 的构建参数读取锁定的 commit
IXFORMER_SHA=$(sed -n 's/^ARG IXFORMER_COMMIT=//p' Dockerfile)
VLLM_SHA=$(sed -n 's/^ARG VLLM_COMMIT=//p' Dockerfile)

# 1. 克隆并对齐 ixformer,随后编译安装(底层依赖见 ixformer 自带脚本)
git clone ssh://git@bitbucket.iluvatar.ai:7999/swapp/ixformer.git /tmp/ixformer
git -C /tmp/ixformer checkout "${IXFORMER_SHA}"
git -C /tmp/ixformer submodule update --init --recursive
CUDA_ARCH=ivcore11 COREX_HOME=/usr/local/corex bash /tmp/ixformer/scripts/build_dev_env.sh

# 2. 克隆并对齐 vllm,随后编译安装
git clone ssh://git@bitbucket.iluvatar.ai:7999/swapp/vllm.git /tmp/vllm
git -C /tmp/vllm checkout "${VLLM_SHA}"
bash /tmp/vllm/build_vllm.sh
bash /tmp/vllm/install_vllm.sh
```

常用环境变量:

- `CUDA_ARCH` / `COREX_ARCH`:目标架构,默认 `ivcore11`。
- `COREX_HOME`:corex 工具链路径,默认 `/usr/local/corex`,会传递给 ixformer 的构建脚本。
- `SW_HOME`:同样会传递给 ixformer 的构建脚本。

## 构建并安装插件

ixformer 与 vllm 就绪后,在本仓库根目录:

```bash
# 开发用可编辑安装
bash install_vllm_iluvatar_editable.sh

# 或 wheel 安装
bash build_vllm_iluvatar.sh
bash install_vllm_iluvatar.sh
```

## 日常开发流程

基本原则:在哪个仓库修改,就在该仓库创建分支并提交 PR,待合入后再回到 vllm-iluvatar 更新 `Dockerfile` 里对应的 `*_COMMIT`。

- **修改 ixformer**:在 ixformer 克隆目录创建分支修改,在该仓库内完成编译、测试与 PR 提交(详见 ixformer 的开发环境文档)。合入后更新本仓库 `Dockerfile` 的 `IXFORMER_COMMIT`。
- **修改 vllm**:在 vllm 克隆目录创建分支修改并提交 PR。合入后更新本仓库 `Dockerfile` 的 `VLLM_COMMIT`。

## 更新锁定的 commit

直接编辑根目录 `Dockerfile` 的 `ARG ..._COMMIT`,把对应组件的 commit 改成目标 SHA 并提交即可:

```bash
$EDITOR Dockerfile   # 修改 ARG IXFORMER_COMMIT= / ARG VLLM_COMMIT=
git add Dockerfile
git commit -m "[NO-JIRA] bump ixformer pin"
```

注意事项:

- `Dockerfile` 的构建参数是 pin 的唯一来源。
- 更新 pin 前,请确认目标 commit 已在对应仓库的目标分支上合入。
