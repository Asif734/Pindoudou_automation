#!/usr/bin/env python3
"""Local JSONL retrieval worker. Semantic retry never uses lexical scores."""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
import re
from pathlib import Path


class FolderSearch:
    def __init__(self, folder, model_path, cache):
        self.folder = Path(folder).resolve()
        self.model_path = model_path
        self.cache = Path(cache)
        sys.path.insert(0, str(self.folder))
        from scripts.build_rag_index import load_cards, load_chunks, build_index
        from scripts.search_rag import search
        self.search = search
        self.cards = load_cards(self.folder / 'rag_cards/customer_service_rag_cards.jsonl')
        self.chunks = load_chunks(self.folder / 'rag_cards/source_chunks.jsonl')
        self.index = build_index(self.cards, self.chunks, self.folder / 'rag_cards/high_frequency_queries.json')
        self.documents = self.cards + self.chunks
        self.by_id = {doc['id']: doc for doc in self.documents}
        self.model = None
        self.vectors = None

    def source_stamp(self):
        return tuple((path, (self.folder / path).stat().st_mtime_ns,
                      (self.folder / path).stat().st_size) for path in (
            'rag_cards/customer_service_rag_cards.jsonl',
            'rag_cards/source_chunks.jsonl', 'rag_cards/high_frequency_queries.json'))

    @staticmethod
    def document_text(doc):
        if doc.get('type') == 'source_chunk':
            return '\n'.join([doc.get('title', ''), doc.get('content', '')])
        return '\n'.join([doc.get('issue', ''), ' '.join(doc.get('models', [])),
                          ' '.join(doc.get('keywords', []) + doc.get('synonyms', [])),
                          doc.get('reply_template', ''), json.dumps(doc.get('actions', []), ensure_ascii=False)])

    def prepare_semantic(self):
        if self.model is not None:
            return
        import numpy as np
        from sentence_transformers import SentenceTransformer
        # No runtime downloads or customer data uploads. Setup fetches the model.
        model = SentenceTransformer(self.model_path, local_files_only=True, device='cpu')
        texts = [self.document_text(doc) for doc in self.documents]
        digest = hashlib.sha256(json.dumps(texts, ensure_ascii=False).encode()).hexdigest()
        model_digest = hashlib.sha256()
        for item in sorted(Path(self.model_path).rglob('*')):
            if item.is_file():
                model_digest.update(str(item.relative_to(self.model_path)).encode())
                with item.open('rb') as handle:
                    for block in iter(lambda: handle.read(1024 * 1024), b''):
                        model_digest.update(block)
        self.cache.mkdir(parents=True, exist_ok=True)
        path = self.cache / f'{digest}-{model_digest.hexdigest()}.npy'
        vectors = np.load(path, allow_pickle=False) if path.exists() else None
        if vectors is None or vectors.shape != (len(texts), model.get_sentence_embedding_dimension()):
            vectors = model.encode(texts, normalize_embeddings=True, show_progress_bar=False)
            temporary = path.with_suffix('.tmp')
            with temporary.open('wb') as handle:
                np.save(handle, vectors, allow_pickle=False)
            temporary.replace(path)
        self.model, self.vectors = model, vectors

    @staticmethod
    def family(text):
        value = text.lower()
        if re.search(r'thermal|label.printer|热敏|标签打印', value):
            return 'thermal_label_printer'
        if re.search(r'dot.matrix|针式|针打|多联', value):
            return 'dot_matrix_printer'
        if re.search(r'attendance|考勤|打卡机', value):
            return 'attendance_machine'
        return None

    @staticmethod
    def model_names(values):
        if isinstance(values, str):
            values = [values]
        return {re.sub(r'[ -]', '', value.lower()) for value in values
                if re.fullmatch(r'[a-zA-Z]{1,5}[ -]?\d{2,5}[a-zA-Z]{0,3}', value)}

    def semantic_queries(self, queries):
        questions, models, required, excluded = [], set(), set(), set()
        for query in queries:
            body = []
            for line in query.splitlines():
                prefix, separator, value = line.partition(':')
                if separator and prefix == 'Exact product model':
                    models.update(self.model_names(value.split()))
                elif separator and prefix == 'Required product category':
                    required.update(value.split())
                elif separator and prefix == 'Exclude product category':
                    excluded.update(value.split())
                else:
                    body.append(line)
            question = '\n'.join(body).strip()
            if question:
                questions.append(question)
        # Only reviewed model metadata can supply a missing family constraint.
        if models and not required:
            families = {self.family(card.get('product_line', '')) for card in self.cards
                        if self.model_names(card.get('models', [])).intersection(models)} - {None}
            if len(families) == 1:
                required.update(families)
        return questions, models, required, excluded

    def eligible(self, doc, models, required, excluded):
        declared = self.model_names(doc.get('models', []))
        if declared and models and declared.isdisjoint(models):
            return False
        # Explicit section headings override broad inherited source labels.
        family = self.family(doc.get('title', '') + ' ' + doc.get('issue', '')) or self.family(doc.get('product_line', ''))
        return not (family in excluded or (family and required and family not in required))

    def retrieve(self, query, semantic_only=False, queries=None):
        query = query.strip()
        if not query:
            return {'version': 'folder-semantic' if semantic_only else 'folder-hybrid',
                    'documents': [], 'context': ''}
        if semantic_only:
            self.prepare_semantic()
            questions, models, required, excluded = self.semantic_queries(queries or [query])
            if not questions:
                return {'version': 'folder-semantic', 'documents': [], 'context': ''}
            vectors = self.model.encode(questions, normalize_embeddings=True, show_progress_bar=False)
            # Each new query searches the full corpus independently. Merge by
            # best cosine similarity only: no lexical or rank-boost scores.
            scores = (self.vectors @ vectors.T).max(axis=1)
            # Pure embedding cosine similarity: no keyword, risk, model, or route boosts.
            ranked = [(self.documents[int(i)], float(scores[i]))
                      for i in scores.argsort()[::-1] if scores[i] >= 0.25
                      and self.eligible(self.documents[int(i)], models, required, excluded)][:12]
        else:
            ranked = [(self.by_id[row['id']], row['score'])
                      for row in self.search(self.index, query, top_k=12, include_source_chunks=True)
                      if row['score'] > 0]
        sections, names = [], []
        for doc, score in ranked:
            name = doc['id']
            names.append(name)
            # Preserve restrictions as evidence; the model must not treat actions as completed.
            text = json.dumps(doc, ensure_ascii=False)
            sections.append(f'SOURCE: {name}\nSCORE: {score:.4f}\n{text[:5000]}')
        context = ('<most_relevant_original_sections>\n' + '\n\n'.join(sections)[:48000]
                   + '\n</most_relevant_original_sections>') if sections else ''
        return {'version': 'folder-semantic' if semantic_only else 'folder-hybrid',
                'documents': names, 'context': context}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--folder', required=True)
    parser.add_argument('--model-path', required=True)
    parser.add_argument('--cache', required=True)
    args = parser.parse_args()
    # Third-party imports/build helpers must not corrupt the JSONL protocol.
    protocol = sys.stdout
    sys.stdout = sys.stderr
    engine = FolderSearch(args.folder, args.model_path, args.cache)
    engine.prepare_semantic()
    stamp = engine.source_stamp()
    print(json.dumps({'type': 'ready', 'version': 'folder-hybrid'}), file=protocol, flush=True)
    for line in sys.stdin:
        request = {}
        try:
            request = json.loads(line)
            if engine.source_stamp() != stamp:
                engine = FolderSearch(args.folder, args.model_path, args.cache)
                engine.prepare_semantic()
                stamp = engine.source_stamp()
            result = engine.retrieve(request['query'], request.get('semantic_only', False), request.get('queries'))
            response = {'id': request['id'], 'ok': True, 'result': result}
        except Exception as error:
            response = {'id': request.get('id'), 'ok': False, 'error': str(error)}
        print(json.dumps(response, ensure_ascii=False), file=protocol, flush=True)


if __name__ == '__main__':
    main()
