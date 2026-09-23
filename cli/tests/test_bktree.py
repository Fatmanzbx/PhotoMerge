"""The BK-tree — D1, and the pruning must not change the answer."""

from __future__ import annotations

import itertools
import random
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from photomerge.bktree import (
    BKTree, candidate_pairs, connected_components, hamming, to_int,
)


def brute_force(items, radius):
    return {(a, b) if a < b else (b, a)
            for (ka, a), (kb, b) in itertools.combinations(items, 2)
            if hamming(ka, kb) <= radius}


@pytest.mark.parametrize("radius", [0, 1, 3, 6, 12, 64])
def test_pruning_returns_exactly_what_brute_force_returns(radius):
    """The whole tree is an optimisation. If it ever disagrees with the
    definition, it is not an optimisation, it is a different algorithm."""
    rnd = random.Random(20260917)
    items = [(rnd.getrandbits(64), i) for i in range(400)]
    assert candidate_pairs(items, radius) == brute_force(items, radius)


def test_clustered_hashes_not_just_uniform_ones():
    """Random 64-bit values are almost all ~32 bits apart; real dHashes come in
    tight families. Pruning has to be correct on those too."""
    rnd = random.Random(7)
    items = []
    for family in range(20):
        base = rnd.getrandbits(64)
        for member in range(10):
            noise = 0
            for _ in range(rnd.randint(0, 5)):
                noise |= 1 << rnd.randrange(64)
            items.append((base ^ noise, len(items)))
    for radius in (1, 2, 4, 8):
        assert candidate_pairs(items, radius) == brute_force(items, radius)


def test_identical_hashes_share_a_node_but_not_an_identity():
    tree = BKTree()
    for i in range(5):
        tree.add(0xDEADBEEF, i)
    tree.add(0xDEADBEEE, 99)
    assert len(tree) == 6
    assert tree.nodes == 2          # one node per *distinct* hash
    found = {v for _, values in tree.query(0xDEADBEEF, 0) for v in values}
    assert found == {0, 1, 2, 3, 4}


def test_a_file_is_never_its_own_candidate():
    items = [(0xFF, 1), (0xFF, 2)]
    assert candidate_pairs(items, 0) == {(1, 2)}


def test_empty_and_single_element_trees():
    assert candidate_pairs([], 4) == set()
    assert candidate_pairs([(1, 1)], 4) == set()
    assert BKTree().query(0, 10) == []


def test_bytes_convert_big_endian():
    assert to_int(b"\x00\x01") == 1
    assert hamming(to_int(b"\x00"), to_int(b"\xff")) == 8


def test_connected_components_groups_transitively():
    groups = connected_components([(1, 2), (2, 3), (10, 11)])
    assert sorted(sorted(g) for g in groups) == [[1, 2, 3], [10, 11]]


def test_the_tree_stays_small_where_a_matrix_would_not():
    """D1: v0 allocated an N x N x 64 boolean array — 27 GB at this library's
    size, 160 GB at 50k files. One node per distinct hash instead."""
    rnd = random.Random(1)
    items = [(rnd.getrandbits(64), i) for i in range(20000)]
    tree = BKTree()
    tree.extend(items)
    assert tree.nodes <= len(items)
    assert len(tree) == 20000
