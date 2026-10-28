#!/usr/bin/env python3
"""Download public model weights only; never upload knowledge or chat data."""
import json
import os
from pathlib import Path

root = Path(__file__).resolve().parents[1]
os.environ['HF_HOME'] = str(root / '.knowledge-hf-cache')
os.environ['HF_HUB_DISABLE_TELEMETRY'] = '1'
from huggingface_hub import snapshot_download

config = json.loads((root / 'Resources/FolderKnowledge/config.json').read_text())
path = snapshot_download(
    config['model_id'], revision=config.get('model_revision'), local_dir=config['model_path'], token=False,
    allow_patterns=['*.json', '*.safetensors', '*.txt', 'tokenizer*'],
)
print(f'Semantic model ready: {path}')
