"""Tokenizer-budget contract without loading/downloading an MLX model."""
import unittest
from types import SimpleNamespace

import numpy as np

from digup_worker import Embedder


class Tokenizer:
    def __init__(self):
        self.calls = []

    def __call__(self, texts, **options):
        self.calls.append(options)
        rows = [[0] + list(text.encode('utf-8')) + [1] for text in texts]
        if options.get('padding'):
            width = max(map(len, rows))
            rows = [row + [0] * (width - len(row)) for row in rows]
        return {'input_ids': rows}


class TextBudgetTests(unittest.TestCase):
    def setUp(self):
        self.embedder = Embedder.__new__(Embedder)
        self.embedder.tokenizer = Tokenizer()
        self.embedder.info = {'text_token_limit': 8}
        self.embedder.mx = SimpleNamespace(array=np.array, float32=np.float32)
        self.model_calls = []

        def model(**tokens):
            self.model_calls.append(tokens)
            return SimpleNamespace(text_embeds=np.ones((len(tokens['input_ids']), 768), dtype=np.float32))

        self.embedder.model = model

    def test_special_tokens_count_and_empty_batch(self):
        self.assertEqual(self.embedder.token_counts(['abc', '租房']), [5, 8])
        self.assertEqual(self.embedder.token_counts([]), [])
        self.assertTrue(self.embedder.tokenizer.calls[0]['add_special_tokens'])
        self.assertFalse(self.embedder.tokenizer.calls[0]['truncation'])

    def test_exact_boundary_is_accepted_without_truncation(self):
        vectors, errors = self.embedder.text(['租房'])
        self.assertEqual(vectors.shape, (1, 768))
        self.assertEqual(errors, [None])
        self.assertEqual(self.model_calls[0]['input_ids'].shape, (1, 8))
        self.assertTrue(all(call['truncation'] is False for call in self.embedder.tokenizer.calls))

    def test_overflow_rejected_before_any_model_call(self):
        with self.assertRaisesRegex(ValueError, 'tokenizer budget'):
            self.embedder.text(['ok', '租房x'])
        self.assertEqual(self.model_calls, [])


if __name__ == '__main__':
    unittest.main()
