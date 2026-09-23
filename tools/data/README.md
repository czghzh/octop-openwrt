# tools/data/ — 依赖清单数据

这些文件是**在宿主机解析出的目标环境依赖真值**，供 `tools/` 下的脚本使用。
它们让整个 wheel 集可以被复现，而不必重新跑一遍依赖求解。

| 文件 | 内容 | 行数 |
|---|---|---|
| `pkgs.tsv` | 完整依赖清单。4 列制表符分隔：`名称` `版本` `类型` `文件名`。类型为 `pure`（纯 Python）或 `OTHER`（含 C/Rust 扩展） | 197 |
| `needs-musl.txt` | 需要 musl 平台 wheel 的包，格式 `名称==版本` | 40 |
| `pure-list.txt` | 纯 Python 包，格式 `名称==版本`（从 `pkgs.tsv` 派生） | 157 |

## ⚠️ 关于 `pkgs.tsv` 的「文件名」列

该列记录的是**解析当时** pip 给出的 wheel 文件名。因为解析是在 x86_64 宿主机上做的，
带扩展的包（类型为 `OTHER`）这一列会显示 `manylinux...x86_64` 的包名 —— 
**这不代表目标设备用的包**。目标设备实际使用的是 `musllinux_1_2_aarch64` 版本，
由 `tools/fetch-musl-wheels.sh` 按平台参数重新拉取。

**名称与版本列是准确的**，可以直接用于复现。

## 需要重新生成时

```sh
# 1. 在宿主机解析出清单
python3 tools/resolve-full.py 'octop[all]' 3.14 > tools/data/pkgs.tsv

# 2. 拆分出两类清单
awk -F'\t' '$3=="OTHER" {print $1"=="$2}' tools/data/pkgs.tsv > tools/data/needs-musl.txt
awk -F'\t' '$3=="pure"  {print $1"=="$2}' tools/data/pkgs.tsv > tools/data/pure-list.txt
```
