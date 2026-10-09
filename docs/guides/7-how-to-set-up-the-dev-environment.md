# 如何搭建 vllm-iluvatar 开发环境

vllm-iluvatar 的运行依赖 vllm 和 ixformer 两个组件。此前两者各自独立获取、版本互不关联,容易造成开发环境不一致,出现编译失败或精度对不齐等问题。为此,现将这两个组件以 git submodule 的形式纳入 vllm-iluvatar,由本仓库统一管理其 commit,确保所有开发者获取到一致的版本。本文介绍代码获取、编译、安装的方法,以及在该结构下的日常开发流程。

## 目录结构

```text
vllm-iluvatar/
└── third_party/
    ├── vllm       (branch: iluvatar_main)
    └── ixformer   (branch: master)
```

各组件锁定的 commit 记录在 `version.json` 的 `pins` 中(包含 branch 与 commit),并与 submodule 指针保持一致。

> ixformer 自身的底层依赖由 ixformer 仓库管理,vllm-iluvatar 仅关注 ixformer 的 commit。相关说明参见 ixformer 仓库的《如何搭建 ixformer 开发环境》。

## 环境搭建

```bash
# 1. 递归拉取组件,对齐锁定的 commit
cd vllm-iluvatar
git submodule update --init --recursive

# 2. 一键编译安装,顺序为 ixformer、vllm
bash scripts/build_third_party.sh
```

常用环境变量:

- `CUDA_ARCH` / `COREX_ARCH`:目标架构,默认 `ivcore11`。
- `COREX_HOME`:corex 工具链路径,默认 `/usr/local/corex`,会传递给 ixformer 的构建脚本。
- `SW_HOME`:同样会传递给 ixformer 的构建脚本。
- `SKIP_IXFORMER=1`、`SKIP_VLLM=1`:用于跳过对应组件。

## 日常开发流程

基本原则:在哪个仓库修改,就在该仓库创建分支并提交 PR,待合入后再更新 submodule 指针。执行 `git submodule update` 后通常处于 detached HEAD 状态,修改前请先切换到分支。

- **修改 ixformer**:进入 `third_party/ixformer`,创建分支进行修改,并在该仓库内完成编译、测试与 PR 提交(详见 ixformer 的开发环境文档)。合入后返回 vllm-iluvatar 更新 ixformer 的指针。
- **修改 vllm**:进入 `third_party/vllm`,创建分支进行修改并提交 PR。合入后返回 vllm-iluvatar 更新 vllm 的指针。

## 更新 submodule 指针

更新指针指的是将父仓库中的 gitlink 指向新的 commit 并提交。

```bash
cd vllm-iluvatar
git -C third_party/ixformer fetch origin        # third_party/vllm 同理
git -C third_party/ixformer checkout <目标 SHA>
$EDITOR version.json                             # 同步更新 pins 中的 commit
git add third_party/ixformer version.json
git commit -m "[NO-JIRA] bump ixformer submodule"
```

注意事项:

- `git add third_party/ixformer` 提交的是指针本身,而非目录内的文件。提交前可用 `git diff --cached` 确认,应仅出现 `-Subproject commit ...` 与 `+Subproject commit ...` 两行。
- 请勿使用 `git add third_party/ixformer/`(结尾带斜杠),否则会将子仓库工作区中的文件作为普通文件加入。
- `version.json` 中的 commit 需与 submodule 指针同步修改,保持两者一致。
