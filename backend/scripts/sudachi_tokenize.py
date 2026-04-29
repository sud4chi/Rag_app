#!/usr/bin/env python3
import json
import sys

from sudachipy import dictionary, tokenizer


def build_tokenizer():
    return dictionary.Dictionary().create()


TOKENIZER = build_tokenizer()


def split_mode(name):
    return {
        "A": tokenizer.Tokenizer.SplitMode.A,
        "B": tokenizer.Tokenizer.SplitMode.B,
        "C": tokenizer.Tokenizer.SplitMode.C,
    }.get(name.upper(), tokenizer.Tokenizer.SplitMode.C)


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--healthcheck":
        print("ok")
        return

    payload = json.load(sys.stdin)
    text = payload.get("text", "")
    mode = split_mode(str(payload.get("mode", "C")))

    tokens = []
    for morpheme in TOKENIZER.tokenize(text, mode):
        tokens.append(
            {
                "surface": morpheme.surface(),
                "lemma": morpheme.dictionary_form(),
                "pos": list(morpheme.part_of_speech()),
            }
        )

    json.dump(tokens, sys.stdout, ensure_ascii=False)


if __name__ == "__main__":
    main()
