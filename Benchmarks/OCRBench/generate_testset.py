#!/usr/bin/env python3
"""Generate CareThread's deterministic, entirely fictional OCR benchmark set."""

from __future__ import annotations

import argparse
import json
import math
import random
import unicodedata
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont


ROOT = Path(__file__).resolve().parents[2]
BENCH_ROOT = Path(__file__).resolve().parent
TESTSET = BENCH_ROOT / "testset"
FIXTURES = ROOT / "CareThreadTests" / "Fixtures"

FONT_FILES = {
    "pingfang": Path(
        "/System/Library/AssetsV2/com_apple_MobileAsset_Font8/"
        "86ba2c91f017a3749571a82f2c6d890ac7ffb2fb.asset/AssetData/PingFang.ttc"
    ),
    "hannotate": Path(
        "/System/Library/AssetsV2/com_apple_MobileAsset_Font8/"
        "00bfc46ccb002b730e29def5116e0a571fb617d8.asset/AssetData/Hannotate.ttc"
    ),
    "hanzipen": Path(
        "/System/Library/AssetsV2/com_apple_MobileAsset_Font8/"
        "a3c69464b629577766c23bcdb12ffbfe3759b923.asset/AssetData/Hanzipen.ttc"
    ),
}
FONT_INDEX = {"pingfang": 3, "hannotate": 0, "hanzipen": 0}

NEW_PRESCRIPTIONS = {
    "rx1": """虚构市中心医院 处方笺
姓名：李青禾  性别：女  年龄：41岁
开具日期：2026-04-18  科室：内分泌科
Rx 左甲状腺素钠片 75µg 每日1次 晨起空腹口服
医嘱：三个月后复查甲状腺功能。""",
    "rx2": """虚构市康宁医院 处方笺
姓名：陈明川  性别：男  年龄：58岁
开具日期：2026-05-06  科室：心内科
Rx 阿司匹林肠溶片 100mg 每日1次 餐后口服
医嘱：如有不适及时就诊。""",
}

INVOICE = """虚构市中心医院 门诊收费票据
票据号码：TEST-20260418-0007
患者姓名：李青禾    开票日期：2026-04-18
项目名称                 数量       单价       金额
甲状腺功能五项              1      168.00     168.00
静脉采血费                  1        6.00       6.00
合计金额（人民币）：壹佰柒拾肆元整      ¥174.00
说明：本票据为 OCR 测试虚构样张，不可用于报销。"""

EXPECTED = {
    "f1": {
        "date": "2024-08-22",
        "hospital": "四川大学华西医院",
        "type": "pathology",
        "indicator": "甲状腺乳头状癌",
    },
    "f2": {
        "date": "2024-09-02",
        "hospital": "四川大学华西医院",
        "type": "discharge",
        "indicator": "100",
    },
    "f3": {
        "date": "2026-03-15",
        "hospital": "四川大学华西医院",
        "type": "lab",
        "indicator": "22.8",
    },
    "f4": {
        "date": "2026-03-15",
        "hospital": "四川大学华西医院",
        "type": "imaging",
        "indicator": "未见明确复发",
    },
    "f5": {
        "date": "2026-03-15",
        "hospital": "四川大学华西医院",
        "type": "outpatient",
        "indicator": "75",
    },
    "f6": {
        "date": "2025-11-03",
        "hospital": "成都市第三人民医院",
        "type": "imaging",
        "indicator": "未见明显异常",
    },
    "rx1": {
        "date": "2026-04-18",
        "hospital": "虚构市中心医院",
        "type": "prescription",
        "indicator": "75",
    },
    "rx2": {
        "date": "2026-05-06",
        "hospital": "虚构市康宁医院",
        "type": "prescription",
        "indicator": "100",
    },
}


def load_sources() -> dict[str, str]:
    fixtures = {
        f"f{index}": (FIXTURES / f"f{index}.txt").read_text(encoding="utf-8").strip()
        for index in range(1, 7)
    }
    return fixtures | NEW_PRESCRIPTIONS


def font(name: str, size: int) -> ImageFont.FreeTypeFont:
    path = FONT_FILES[name]
    if not path.exists():
        raise FileNotFoundError(f"Required macOS font is unavailable: {path}")
    return ImageFont.truetype(str(path), size=size, index=FONT_INDEX[name])


def wrap_line(draw: ImageDraw.ImageDraw, line: str, selected_font, max_width: int) -> list[str]:
    if not line:
        return [""]
    output: list[str] = []
    current = ""
    for character in line:
        candidate = current + character
        if current and draw.textlength(candidate, font=selected_font) > max_width:
            output.append(current)
            current = character
        else:
            current = candidate
    if current:
        output.append(current)
    return output


def render(text: str, font_name: str, output: Path, font_size: int = 34) -> None:
    selected_font = font(font_name, font_size)
    width, margin, spacing = 1_240, 72, 16
    measuring = Image.new("RGB", (width, 200), "white")
    draw = ImageDraw.Draw(measuring)
    wrapped: list[str] = []
    for source_line in text.splitlines():
        wrapped.extend(wrap_line(draw, source_line, selected_font, width - margin * 2))
    line_height = selected_font.getbbox("示例Ag")[3] - selected_font.getbbox("示例Ag")[1] + spacing
    height = max(360, margin * 2 + line_height * len(wrapped))
    image = Image.new("RGB", (width, height), "white")
    draw = ImageDraw.Draw(image)
    y = margin
    for line in wrapped:
        draw.text((margin, y), line, fill=(20, 24, 28), font=selected_font)
        y += line_height
    output.parent.mkdir(parents=True, exist_ok=True)
    image.save(output, optimize=True)


def degrade(source: Path, output: Path, seed: int, angle: float, blur: float, quality: int) -> None:
    rng = random.Random(seed)
    image = Image.open(source).convert("RGB")
    image = image.rotate(
        angle,
        resample=Image.Resampling.BICUBIC,
        expand=True,
        fillcolor=(244, 242, 237),
    )
    image = image.filter(ImageFilter.GaussianBlur(radius=blur))
    pixels = image.load()
    width, height = image.size
    shadow_side = rng.choice(("left", "right"))
    maximum_shadow = rng.randint(42, 64)
    for x in range(width):
        normalized = x / max(1, width - 1)
        if shadow_side == "right":
            normalized = 1 - normalized
        strength = int(maximum_shadow * math.pow(1 - normalized, 2.1))
        for y in range(height):
            r, g, b = pixels[x, y]
            pixels[x, y] = (max(0, r - strength), max(0, g - strength), max(0, b - strength))
    output.parent.mkdir(parents=True, exist_ok=True)
    image.save(output, format="JPEG", quality=quality, optimize=True)


def normalized_reference(text: str) -> str:
    return "".join(
        character
        for character in unicodedata.normalize("NFKC", text)
        if not character.isspace()
    )


def build() -> None:
    sources = load_sources()
    for directory in ("images", "references"):
        (TESTSET / directory).mkdir(parents=True, exist_ok=True)

    samples: list[dict] = []
    for fixture_id in [f"f{index}" for index in range(1, 7)]:
        source = sources[fixture_id]
        sample_id = f"p_{fixture_id}"
        image_path = TESTSET / "images" / f"{sample_id}.png"
        render(source, "pingfang", image_path)
        samples.append(sample(sample_id, "P", "print", fixture_id, source, image_path))

    for source_id in [f"f{index}" for index in range(1, 7)] + ["rx1", "rx2"]:
        for font_name in ("hannotate", "hanzipen"):
            source = sources[source_id]
            sample_id = f"h_{source_id}_{font_name}"
            image_path = TESTSET / "images" / f"{sample_id}.png"
            render(source, font_name, image_path, font_size=38)
            samples.append(sample(sample_id, "H", "handwriting", source_id, source, image_path))

    degradation_plan = [
        ("p_f1", "print", 31, 3.0, 0.8, 58),
        ("p_f3", "print", 37, -4.0, 1.0, 52),
        ("p_f4", "print", 41, 5.0, 0.7, 61),
        ("p_f6", "print", 43, -3.5, 1.1, 55),
        ("h_f2_hannotate", "handwriting", 47, 3.5, 0.8, 58),
        ("h_f3_hanzipen", "handwriting", 53, -5.0, 1.0, 50),
        ("h_rx1_hannotate", "handwriting", 59, 4.5, 0.9, 54),
        ("h_rx2_hanzipen", "handwriting", 61, -3.0, 1.1, 57),
    ]
    indexed = {entry["id"]: entry for entry in samples}
    for source_sample_id, subgroup, seed, angle, blur, quality in degradation_plan:
        base = indexed[source_sample_id]
        sample_id = f"d_{source_sample_id}"
        image_path = TESTSET / "images" / f"{sample_id}.jpg"
        degrade(
            TESTSET / base["image"],
            image_path,
            seed=seed,
            angle=angle,
            blur=blur,
            quality=quality,
        )
        entry = sample(
            sample_id,
            "D",
            subgroup,
            base["source_id"],
            sources[base["source_id"]],
            image_path,
        )
        entry["degradation"] = {
            "seed": seed,
            "rotation_degrees": angle,
            "gaussian_blur_radius": blur,
            "jpeg_quality": quality,
            "shadow": "deterministic one-sided quadratic gradient",
        }
        samples.append(entry)

    invoice_path = TESTSET / "images" / "o_invoice.png"
    render(INVOICE, "pingfang", invoice_path, font_size=32)
    invoice_reference = TESTSET / "references" / "invoice.txt"
    invoice_reference.write_text(INVOICE + "\n", encoding="utf-8")
    samples.append(
        {
            "id": "o_invoice",
            "group": "O",
            "subgroup": "observation",
            "source_id": "invoice",
            "image": str(invoice_path.relative_to(TESTSET)),
            "reference": str(invoice_reference.relative_to(TESTSET)),
            "reference_normalized": normalized_reference(INVOICE),
            "scored": False,
            "expected": {},
        }
    )

    manifest = {
        "schema_version": 1,
        "fictional_data_only": True,
        "render_scale": "2x equivalent; PingFang 34px represents 17pt",
        "samples": samples,
    }
    (TESTSET / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"Generated {len(samples)} fictional OCR samples at {TESTSET}")


def sample(
    sample_id: str,
    group: str,
    subgroup: str,
    source_id: str,
    source: str,
    image_path: Path,
) -> dict:
    reference_path = TESTSET / "references" / f"{sample_id}.txt"
    reference_path.write_text(source + "\n", encoding="utf-8")
    return {
        "id": sample_id,
        "group": group,
        "subgroup": subgroup,
        "source_id": source_id,
        "image": str(image_path.relative_to(TESTSET)),
        "reference": str(reference_path.relative_to(TESTSET)),
        "reference_normalized": normalized_reference(source),
        "scored": True,
        "expected": EXPECTED[source_id],
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.parse_args()
    build()
