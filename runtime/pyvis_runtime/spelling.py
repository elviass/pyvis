"""Offline spelling diagnostics for Python prose and identifier word segments.

Dictionary source and license: vendor/spelling/NOTICE.md. Never executes code.
"""
import builtins
from functools import lru_cache
import gzip
import io
import json
import keyword
from pathlib import Path
import re
import sys
import tokenize

_DATA = Path(__file__).parent / 'vendor' / 'spelling' / 'en.json.gz'
_TECH = set('pyvis utf stdin stdout stderr args kwargs cls self nums txt json py sqrt regex url http https api ui html xml yaml csv uuid sql init asyncio pytest numpy pandas matplotlib sqlalchemy tkinter pygame repr len bool str int dict tuple iter func params param async await init doc pycharm codex pyvis runtime git github macos windows ios android sdk ast builtin builtins eof byte bytes config configs const elif noqa pylint ruff ty venv pip jedis jedi parso dataclass enum eof fstring iterable'.split())
_TECH.update(keyword.kwlist)
_TECH.update(sys.stdlib_module_names)
_TECH.update(dir(builtins))
for _value in vars(builtins).values():
    if isinstance(_value, type): _TECH.update(dir(_value))
_TECH = {word.lower() for word in _TECH}
_PART = re.compile(r'[A-Z]+(?=[A-Z][a-z]|$)|[A-Z]?[a-z]+')
_SKIP = re.compile(r'https?://\S+|\b[\w.+-]+@[\w.-]+\b|\b(?:0x[0-9A-Fa-f]+|[A-Za-z]:[\\/][^\s]+)')


@lru_cache(1)
def dictionary():
    with gzip.open(_DATA, 'rt', encoding='utf-8') as stream:
        data = json.load(stream)
    return {word.lower(): frequency for word, frequency in data.items() if word.isascii()}


@lru_cache(2048)
def alternatives(word):
    words = dictionary()
    alphabet = 'abcdefghijklmnopqrstuvwxyz'
    splits = [(word[:i], word[i:]) for i in range(len(word) + 1)]
    edits = {a + b[1:] for a,b in splits if b}
    edits.update(a + b[1] + b[0] + b[2:] for a,b in splits if len(b)>1)
    edits.update(a + c + b[1:] for a,b in splits if b for c in alphabet)
    edits.update(a + c + b for a,b in splits for c in alphabet)
    return sorted((w for w in edits if w in words), key=lambda w: (-words[w], w))[:5]


def inspect_spelling(source, filename, accepted=()):
    words = dictionary()
    accepted = {w.lower() for w in accepted} | _TECH
    found = []
    # Match lexical words only. URLs, escape codes, numbers, and Chinese are not
    # misspelled English words. Tokenization retains real source coordinates.
    try:
        tokens = tokenize.generate_tokens(io.StringIO(source).readline)
        for token in tokens:
            if token.type not in (tokenize.NAME, tokenize.COMMENT, tokenize.STRING): continue
            if token.type == tokenize.NAME and (token.string in keyword.kwlist or token.string.lower() in accepted): continue
            text = token.string
            skip = [m.span() for m in _SKIP.finditer(text)]
            skip += [m.span() for m in re.finditer(r'\\(?:[a-zA-Z]|x[0-9a-fA-F]{2}|u[0-9a-fA-F]{4})', text)]
            for match in re.finditer(r'[A-Za-z]+', text):
                if any(a <= match.start() < b for a,b in skip): continue
                for part in _PART.finditer(match[0]):
                    word = part[0]
                    lower = word.lower()
                    if len(word)<3 or word.isupper() or lower in accepted or lower in words: continue
                    guesses = alternatives(lower)
                    # Unknown domain terms without a plausible nearby English
                    # spelling are left alone rather than inventing a correction.
                    if not guesses: continue
                    start = match.start()+part.start()
                    prefix = text[:start]
                    row = token.start[0]+prefix.count('\n')
                    column = (token.start[1] if '\n' not in prefix else 0) + len(prefix.rsplit('\n',1)[-1]) + 1
                    fixes=[]
                    if token.type != tokenize.NAME:
                        for replacement in guesses:
                            if word.istitle(): replacement=replacement.title()
                            fixes.append(dict(title=f'替换为 {replacement}', applicability='safe', edits=[dict(content=replacement,
                                location=dict(row=row,column=column),end_location=dict(row=row,column=column+len(word)))]))
                    fixes.append(dict(title=f'将 {word} 加入词典', applicability='safe', action='dictionary_add', word=lower))
                    found.append(dict(file=filename,line=row,column=column,end_line=row,end_column=column+len(word),
                        severity='typo', code='Typo', inspection='SpellCheckingInspection', presentation='typo',
                        message=f"Typo: In word '{word}'",hint='检查英文单词的拼写。专有名称可加入词典；这不会影响代码运行。',
                        engine='Spelling',blocking=False,fixes=fixes))
    except (tokenize.TokenError, IndentationError, SyntaxError):
        pass
    return found
