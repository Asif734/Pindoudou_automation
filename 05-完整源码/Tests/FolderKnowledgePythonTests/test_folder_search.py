import importlib.util
import unittest
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('folder_search', ROOT / 'Resources/FolderKnowledge/serve_folder.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class FolderSearchTests(unittest.TestCase):
    def test_semantic_retry_uses_only_cosine_similarity(self):
        engine = module.FolderSearch.__new__(module.FolderSearch)
        engine.documents = [
            {'id': 'keyword_favorite', 'issue': 'exact lexical match'},
            {'id': 'semantic_winner', 'issue': 'different wording', 'risk_level': 'high'},
            {'id': 'irrelevant', 'issue': 'unrelated'},
        ]
        engine.vectors = np.array([[0.3, 0.95], [0.99, 0.1], [-1, 0]])
        class Model:
            def encode(self, queries, **kwargs):
                self.queries = queries
                return np.array([[1., 0.]])
        engine.model = Model()
        engine.prepare_semantic = lambda: None
        engine.search = lambda *args, **kwargs: self.fail('Semantic search called lexical search')
        result = engine.retrieve('standalone customer question', semantic_only=True)
        self.assertEqual(result['documents'], ['semantic_winner', 'keyword_favorite'])
        self.assertEqual(engine.model.queries, ['standalone customer question'])
        self.assertEqual(result['version'], 'folder-semantic')
        self.assertNotIn('irrelevant', result['context'])

    def test_blank_query_returns_no_evidence(self):
        engine = module.FolderSearch.__new__(module.FolderSearch)
        result = engine.retrieve('  ', semantic_only=True)
        self.assertEqual(result['documents'], [])
        self.assertEqual(result['context'], '')

    def test_multiple_queries_are_independent_semantic_searches_with_model_eligibility(self):
        engine = module.FolderSearch.__new__(module.FolderSearch)
        engine.cards = []
        engine.documents = [
            {'id': 'wrong_model', 'models': ['M880'], 'product_line': 'attendance_machine'},
            {'id': 'first_query_hit', 'models': ['TD630G'], 'product_line': 'dot_matrix_printer'},
            {'id': 'second_query_hit', 'models': ['TD630G'], 'product_line': 'dot_matrix_printer'},
        ]
        engine.vectors = np.array([[1., 0.], [0.8, 0.2], [0.1, 0.99]])
        class Model:
            def encode(self, queries, **kwargs):
                self.queries = queries
                return np.array([[1., 0.], [0., 1.]])
        engine.model = Model()
        engine.prepare_semantic = lambda: None
        engine.search = lambda *args, **kwargs: self.fail('Retry must not call lexical retrieval')
        result = engine.retrieve('first', semantic_only=True, queries=[
            'first\nExact product model: td630g\nRequired product category: dot_matrix_printer',
            'second\nExact product model: td630g\nRequired product category: dot_matrix_printer'])
        self.assertEqual(engine.model.queries, ['first', 'second'])
        self.assertEqual(result['documents'], ['second_query_hit', 'first_query_hit'])
        self.assertNotIn('wrong_model', result['context'])


if __name__ == '__main__':
    unittest.main()
