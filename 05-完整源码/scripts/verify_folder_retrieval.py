#!/usr/bin/env python3
"""Compile real retrieval sources and run simulated Codex retry checks.

This keeps UI macro/XCTest availability independent from retrieval verification.
It never launches Pinduoduo or sends messages.
"""
from pathlib import Path
import shutil
import subprocess

root = Path(__file__).resolve().parents[1]
target = root / '.build/retrieval-validation'
sources = target / 'Sources/PDDAXReader'
sources.mkdir(parents=True, exist_ok=True)
excluded = {'ContentView.swift', 'SingleAXParseView.swift', 'AutoReplyView.swift',
            'AutoReplyFloatingProgress.swift', 'PDDAXReaderApp.swift'}
for path in (root / 'Sources/PDDAXReader').glob('*.swift'):
    if path.name not in excluded:
        shutil.copy2(path, sources / path.name)
smoke = target / 'Sources/RetrievalSmoke'
smoke.mkdir(exist_ok=True)
for path in (root / 'Tests/FolderKnowledgeSmoke').glob('*.swift'):
    shutil.copy2(path, smoke / path.name)
shutil.copytree(root / 'Resources/CustomerService', target / 'Resources/CustomerService', dirs_exist_ok=True)
(target / 'Package.swift').write_text('''// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "RetrievalValidation", platforms: [.macOS(.v14)], targets: [
    .target(name: "PDDAXReader"),
    .executableTarget(name: "RetrievalSmoke", dependencies: ["PDDAXReader"],
                      swiftSettings: [.unsafeFlags(["-parse-as-library"])])
])
''')
subprocess.run(['swift', 'run', '--package-path', str(target), '--build-system', 'native',
                'RetrievalSmoke', str(root)], cwd=root, check=True)
