# CareThread OCR Benchmark

This directory contains a deterministic OCR benchmark made only from fictional
CareThread fixtures. It implements the fixed P/H/D protocol from the OCR task:

- P: six PingFang SC 17 pt-equivalent printed samples.
- H: eight source texts rendered in both Hannotate SC and HanziPen SC.
- D: eight deterministic degraded derivatives with 3–5 degree rotation,
  Gaussian blur, a one-sided shadow gradient, and low-quality JPEG compression.
- O: one fictional, observation-only invoice sample.

The source texts, exact rendering/degradation parameters, per-engine raw output,
and final Markdown table are retained for review. Spaces and line breaks are
removed and Unicode NFKC normalization is applied before CER calculation.

Run the complete benchmark from the repository root:

```sh
Benchmarks/OCRBench/run.sh
```

No patient data is used. The benchmark may download candidate weights only into
its isolated development environment; the shipping App contains no download or
network code.

## Private real-photo regression (R group)

Real photos are never committed. Prepare the ignored local directory by
following `testset/real/README.md`, then run:

```sh
Benchmarks/OCRBench/run_real.sh
```

The real-set gate follows the fixed task protocol: a challenger must improve
handwriting CER by at least 10 percentage points versus Vision while degrading
print CER by no more than 1 percentage point. Print and handwriting field-hit
rates are reported separately but do not replace either gate. Raw OCR and
extracted values live only in a permission-restricted temporary directory and
are deleted on exit. Repository results contain only SHA-256 hashes and scores.
