"""A BK-tree over fixed-width hashes, queried by Hamming distance.

This replaces the v0 script's `bits[:,None,:] != bits[None,:,:]` (D1), which
materialises an N×N×64 boolean array: about 160 GB at 50,000 files, so the
process dies before it compares anything. A BK-tree stores one node per
*distinct* hash and answers a radius query by walking a few branches.

The structure works because Hamming distance is a metric, so the triangle
inequality holds: if `d(query, node)` is known, any subtree at distance `k` from
that node can only contain matches when `|k - d| <= radius`. Everything else is
pruned without being looked at.

Hashes arrive as bytes and are held as ints — `int.bit_count()` is a single
instruction's worth of work and beats unpacking bits into arrays.
"""

from __future__ import annotations

from collections import deque
from typing import Iterable


def to_int(digest: bytes) -> int:
    return int.from_bytes(digest, "big")


def hamming(a: int, b: int) -> int:
    return (a ^ b).bit_count()


class BKTree:
    """Multi-valued: several files routinely share one hash, and a duplicate
    hash must not become a duplicate node."""

    __slots__ = ("_keys", "_values", "_children", "_root")

    def __init__(self) -> None:
        self._keys: list[int] = []
        self._values: list[list] = []
        self._children: list[dict[int, int]] = []
        self._root: int | None = None

    def __len__(self) -> int:
        return sum(len(v) for v in self._values)

    @property
    def nodes(self) -> int:
        return len(self._keys)

    def add(self, key: int, value) -> None:
        if self._root is None:
            self._root = self._new(key, value)
            return
        node = self._root
        while True:
            distance = hamming(key, self._keys[node])
            if distance == 0:
                self._values[node].append(value)
                return
            child = self._children[node].get(distance)
            if child is None:
                self._children[node][distance] = self._new(key, value)
                return
            node = child

    def extend(self, items: Iterable[tuple[int, object]]) -> None:
        for key, value in items:
            self.add(key, value)

    def query(self, key: int, radius: int) -> list[tuple[int, list]]:
        """Every stored hash within `radius` of `key`, as `(distance, values)`."""
        if self._root is None:
            return []
        out: list[tuple[int, list]] = []
        stack = [self._root]
        while stack:
            node = stack.pop()
            distance = hamming(key, self._keys[node])
            if distance <= radius:
                out.append((distance, self._values[node]))
            # The triangle inequality: only these branches can hold a match.
            low, high = distance - radius, distance + radius
            for edge, child in self._children[node].items():
                if low <= edge <= high:
                    stack.append(child)
        return out

    def _new(self, key: int, value) -> int:
        self._keys.append(key)
        self._values.append([value])
        self._children.append({})
        return len(self._keys) - 1


def candidate_pairs(items: list[tuple[int, int]], radius: int) -> set[tuple[int, int]]:
    """`(file_id_a, file_id_b)` pairs whose hashes are within `radius`.

    Candidates only — PLAN §3.1-C. Nothing here is a merge; every pair still has
    to survive the verification cascade.
    """
    tree = BKTree()
    tree.extend((key, fid) for key, fid in items)
    pairs: set[tuple[int, int]] = set()
    for key, fid in items:
        for _, ids in tree.query(key, radius):
            for other in ids:
                if other != fid:
                    pairs.add((fid, other) if fid < other else (other, fid))
    return pairs


def connected_components(pairs: Iterable[tuple[int, int]]) -> list[set[int]]:
    """Group confirmed pairs into clusters.

    Deliberately *not* used on raw candidates: transitive closure over unverified
    near-matches is how a whole afternoon of similar photos becomes one asset.
    """
    adjacency: dict[int, set[int]] = {}
    for a, b in pairs:
        adjacency.setdefault(a, set()).add(b)
        adjacency.setdefault(b, set()).add(a)
    seen: set[int] = set()
    groups: list[set[int]] = []
    for start in adjacency:
        if start in seen:
            continue
        group = {start}
        seen.add(start)
        queue = deque([start])
        while queue:
            node = queue.popleft()
            for neighbour in adjacency[node]:
                if neighbour not in seen:
                    seen.add(neighbour)
                    group.add(neighbour)
                    queue.append(neighbour)
        groups.append(group)
    return groups
