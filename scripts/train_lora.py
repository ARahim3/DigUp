#!/usr/bin/env python3
"""
DigUp Local SLM Fine-Tuning Utility (`scripts/train_lora.py`)
=============================================================
Consumes the `.jsonl` files generated from DigUp user chat interactions:
  - `sft_train.jsonl` (ChatML Supervised Fine-Tuning format)
  - `dpo_train.jsonl` (Direct Preference Optimization format from user-edited answers)

Designed for local execution on an 8-core, 12GB RAM PC (CPU / iGPU or low-VRAM GPU):
  - Uses LoRA (r=8, alpha=16) on `Qwen/Qwen2.5-3B-Instruct` or `Qwen/Qwen2.5-1.5B-Instruct`
  - Uses gradient checkpointing and `batch_size=1` (`gradient_accumulation_steps=4`) to stay under 8 GB RAM
  - Automatically converts the trained LoRA adapter into `.gguf` (`digup-user-lora.gguf`) so
    `digup chat-service` can hot-load it via `llama_adapter_lora_init` without duplicating the base model.

Usage:
  python scripts/train_lora.py --jsonl "%LOCALAPPDATA%/DigUp/index/datasets/sft_train.jsonl" \
                               --base-model "Qwen/Qwen2.5-3B-Instruct" \
                               --output-dir "./lora_out"
"""

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path


def validate_jsonl(path: Path) -> list[dict]:
    if not path.is_file():
        raise FileNotFoundError(f"JSONL dataset not found: {path}")
    records = []
    with path.open("r", encoding="utf-8") as f:
        for line_no, line in enumerate(f, start=1):
            line = line.strip()
            if not line:
                continue
            obj = json.loads(line)
            if "messages" not in obj and "prompt" not in obj:
                raise ValueError(f"Line {line_no} in {path} is missing 'messages' or 'prompt' key")
            records.append(obj)
    if not records:
        raise ValueError(f"JSONL dataset at {path} contains 0 training records")
    return records


def run_sft_lora_training(jsonl_path: Path, base_model: str, output_dir: Path, epochs: int, lr: float) -> Path:
    import torch
    from datasets import load_dataset
    from peft import LoraConfig, get_peft_model
    from transformers import AutoModelForCausalLM, AutoTokenizer
    from trl import SFTConfig, SFTTrainer

    use_cuda = torch.cuda.is_available()
    device_label = "CUDA GPU" if use_cuda else f"CPU ({os.cpu_count() or 8} threads)"
    print(f"[DigUp LoRA] Training on {device_label} | Base model: {base_model}")

    if not use_cuda:
        torch.set_num_threads(max(2, min((os.cpu_count() or 8) - 2, 6)))

    tokenizer = AutoTokenizer.from_pretrained(base_model, use_fast=True)
    if tokenizer.pad_token is None:
        tokenizer.pad_token = tokenizer.eos_token

    dtype = torch.float16 if use_cuda else torch.float32
    model = AutoModelForCausalLM.from_pretrained(
        base_model,
        torch_dtype=dtype,
        low_cpu_mem_usage=True,
    )
    model.enable_input_require_grads()

    lora_config = LoraConfig(
        r=8,
        lora_alpha=16,
        lora_dropout=0.05,
        bias="none",
        task_type="CAUSAL_LM",
        target_modules=["q_proj", "k_proj", "v_proj", "o_proj", "gate_proj", "up_proj", "down_proj"],
    )
    model = get_peft_model(model, lora_config)
    model.print_trainable_parameters()

    dataset = load_dataset("json", data_files=str(jsonl_path), split="train")

    sft_args = SFTConfig(
        output_dir=str(output_dir),
        num_train_epochs=epochs,
        per_device_train_batch_size=1,
        gradient_accumulation_steps=4,
        learning_rate=lr,
        logging_steps=1,
        save_strategy="no",
        gradient_checkpointing=True,
        use_cpu=not use_cuda,
        fp16=use_cuda,
        max_seq_length=1024,
        report_to="none",
    )

    trainer = SFTTrainer(
        model=model,
        processing_class=tokenizer,
        train_dataset=dataset,
        args=sft_args,
    )
    trainer.train()

    adapter_dir = output_dir / "adapter"
    adapter_dir.mkdir(parents=True, exist_ok=True)
    model.save_pretrained(str(adapter_dir))
    tokenizer.save_pretrained(str(adapter_dir))
    print(f"[DigUp LoRA] Saved HuggingFace PEFT adapter to {adapter_dir}")

    # Convert PEFT LoRA adapter to GGUF if llama.cpp converter is present in Vendor/llama.cpp
    converter = Path(__file__).resolve().parent.parent / "Vendor" / "llama.cpp" / "convert_lora_to_gguf.py"
    gguf_out = output_dir / "digup-user-lora.gguf"
    if converter.is_file():
        print(f"[DigUp LoRA] Converting PEFT adapter to GGUF: {gguf_out}")
        subprocess.run(
            [sys.executable, str(converter), "--outfile", str(gguf_out), str(adapter_dir)],
            check=True,
        )
    else:
        print(
            f"[DigUp LoRA] Note: To convert to GGUF for llama.cpp hot-loading, run:\n"
            f"  python Vendor/llama.cpp/convert_lora_to_gguf.py --outfile {gguf_out} {adapter_dir}"
        )
    return adapter_dir


def main() -> int:
    parser = argparse.ArgumentParser(description="DigUp Local SLM JSONL LoRA Fine-Tuner")
    parser.add_argument("--jsonl", required=True, type=Path, help="Path to sft_train.jsonl")
    parser.add_argument("--base-model", default="Qwen/Qwen2.5-3B-Instruct", help="HuggingFace model ID or local path")
    parser.add_argument("--output-dir", default=Path("./lora_out"), type=Path, help="Directory for trained LoRA")
    parser.add_argument("--epochs", default=3, type=int)
    parser.add_argument("--lr", default=2e-4, type=float)
    parser.add_argument("--validate-only", action="store_true", help="Only validate the JSONL dataset and exit")
    args = parser.parse_args()

    records = validate_jsonl(args.jsonl)
    print(f"[DigUp LoRA] Validated {len(records)} training example(s) in {args.jsonl}")
    if args.validate_only:
        return 0

    run_sft_lora_training(args.jsonl, args.base_model, args.output_dir, args.epochs, args.lr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
