import importlib.util
import os
from pathlib import Path
import tempfile
import time
import unittest

spec = importlib.util.spec_from_file_location('cache_prune', Path(__file__).resolve().parents[1] / 'priv/core/atdd_thumbnail_cache_prune.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class CachePruneTest(unittest.TestCase):
    def test_expiry_budget_and_unrelated_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            folder = root / ('a' * 64)
            folder.mkdir()
            unrelated = folder / 'keep-me.txt'
            unrelated.write_text('original')
            images = []
            for index in range(3):
                image = folder / (str(index) * 64 + '.webp')
                checksum = image.with_suffix('.webp.sha256')
                image.write_bytes(b'x' * 10)
                checksum.write_text('hash')
                modified = time.time() - (8 * 86400 if index == 0 else 10 - index)
                for path in (image, checksum):
                    os.utime(path, (modified, modified))
                images.append(image)
            self.assertEqual(module.prune(root, 14, 7), 2)
            self.assertFalse(images[0].exists())
            self.assertFalse(images[1].exists())
            self.assertTrue(images[2].exists())
            self.assertEqual(unrelated.read_text(), 'original')
            self.assertEqual(module.prune(root, 14, 7), 0)

    def test_symlinked_directories_and_files_are_preserved(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / 'cache'
            root.mkdir()
            outside = Path(temporary) / 'outside'
            outside.mkdir()
            target = outside / ('b' * 64 + '.webp')
            target.write_text('preserved')
            (root / ('a' * 64)).symlink_to(outside, target_is_directory=True)
            local = root / ('c' * 64)
            local.mkdir()
            (local / target.name).symlink_to(target)
            self.assertEqual(module.prune(root, 0, 0), 0)
            self.assertEqual(target.read_text(), 'preserved')
            with self.assertRaises(ValueError):
                module.prune(root / ('a' * 64), 0, 0)


if __name__ == '__main__':
    unittest.main()
