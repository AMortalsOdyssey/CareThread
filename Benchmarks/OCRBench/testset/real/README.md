# OCR 真实照片回归集（仅本机）

这里是 R 组真实病历照片的本机入口。除本说明和 `.gitignore` 外，目录内
所有图片、参考文本和 `manifest.json` 都被 Git 忽略，禁止强制加入版本库。

准备规则：

- 文件名与样本 `id` 只能使用 `r001`、`r002` 这类无语义编号，不写姓名、
  医院或病种。
- 图片放在 `images/`，逐页人工校对文本放在 `references/`。
- 多页报告按页标注；续页没有的字段不要写入 `expected`，不会被算作识别失败。
- `reference_normalized` 可省略；评分器会读取 `reference` 文件并执行 NFKC
  归一化、移除空白。

本地 `manifest.json` 示例：

```json
{
  "schema_version": 2,
  "samples": [
    {
      "id": "r001",
      "group": "R",
      "subgroup": "real",
      "image": "images/r001.jpg",
      "reference": "references/r001.txt",
      "scored": true,
      "expected": {
        "date": "2026-07-31",
        "type": "lab"
      }
    }
  ]
}
```

在仓库根目录一键运行：

```sh
Benchmarks/OCRBench/run_real.sh
```

含 OCR 原文的所有中间结果只写入权限为 `0700` 的临时目录，命令退出即清理。
仓库内只会生成 `results/real/results.json` 与 `RESULTS.md`，其中只有不可逆
SHA-256、字符/字段计数、CER、延迟和换引擎判定。
