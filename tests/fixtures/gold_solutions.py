"""Handwritten solutions used to verify the grader, never sent to a model."""

import csv
import io
import re
from collections import Counter


def unique_by_id(records):
    """Replace values without changing each ID's original position."""
    latest = {}
    for record in records:
        latest[record["id"]] = record
    return list(latest.values())


def merge_intervals(intervals):
    if any(start > end for start, end in intervals):
        raise ValueError("Reversed interval")

    merged = []
    for start, end in sorted(intervals):
        if merged and start <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], end)
        else:
            # Copy the pair so later merges cannot mutate the input.
            merged.append([start, end])
    return merged


def parse_ports(text):
    ports = []
    seen = set()
    for token in text.split(","):
        token = token.strip()
        if not token:
            continue
        endpoints = token.split("-")
        if len(endpoints) > 2:
            raise ValueError("Malformed range")
        start, end = int(endpoints[0]), int(endpoints[-1])
        if not 1 <= start <= end <= 65535:
            raise ValueError("Invalid port range")
        for port in range(start, end + 1):
            if port not in seen:
                seen.add(port)
                ports.append(port)
    return ports


def moving_average(values, window):
    if window <= 0:
        raise ValueError("Window must be positive")
    return [sum(values[i : i + window]) / window for i in range(len(values) - window + 1)]


def adult_names(csv_text):
    names = []
    for row in csv.DictReader(io.StringIO(csv_text)):
        name, age, country = row.get("name"), row.get("age"), row.get("country")
        if name is None or age is None or country is None:
            continue
        try:
            adult = int(age.strip()) >= 18
        except ValueError:
            continue
        if adult and country.strip() == "US":
            names.append(name)
    return names


def top_words(text, k):
    if k <= 0:
        return []
    words = re.findall("[A-Za-z]+", text)
    counts = Counter(word.lower() for word in words)
    return sorted(counts, key=lambda word: (-counts[word], word))[:k]


def batch_items(items, size):
    if size <= 0:
        raise ValueError("Batch size must be positive")
    return [items[i : i + size] for i in range(0, len(items), size)]
