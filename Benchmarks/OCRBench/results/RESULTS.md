# CareThread OCR Benchmark Results

Generated from 30 scored fictional samples (P=6, H=16, D=8) plus one
observation-only fictional invoice. CER uses Unicode NFKC and ignores
whitespace/line-break differences. Field hits are produced by the shipping
`ExtractionEngine` for date, hospital, type, and one key indicator per page.

## Raw metrics

| Engine | Print CER | Handwriting CER | Field hits | P95 macOS | P95 simulator | Peak memory Δ | arm64 size Δ |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Apple Vision | 5.98% | 3.92% | 113/120 (94.17%) | 229 ms | 695 ms | 59.6 MB | 0.0 MB |
| RapidOCR PP-OCRv5 mobile / ONNX Runtime | 2.34% | 2.37% | 105/120 (87.50%) | 640 ms | not integrated | 1567.3 MB | 48.9 MB |

## §5 weighted score

| Engine | H CER /35 | P CER /25 | Fields /15 | Risk /10 | Latency /8 | Size /4 | Active /3 | Total |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| RapidOCR PP-OCRv5 mobile / ONNX Runtime | 35.00 | 25.00 | 0.00 | 7.00 | 8.00 | 1.74 | 3.00 | **79.74** |
| Apple Vision | 0.00 | 0.00 | 15.00 | 10.00 | 8.00 | 4.00 | 3.00 | **40.00** |

Min–max normalization is applied only to the three dimensions whose rule
says “best = full points, linear decrease”; ties receive full points.

## Fixed-rule decision

**Maintain Apple Vision as the single shipping OCR engine.**

- Weighted-score winner: RapidOCR PP-OCRv5 mobile / ONNX Runtime.
- Handwriting CER improvement over Vision: 1.56 percentage points (required ≥10.00).
- Print CER change versus Vision: -3.64 percentage points (must not be worse by >1.00).
- Switch thresholds passed: no.
