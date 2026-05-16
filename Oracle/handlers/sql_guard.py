"""
Read-only SQL gate.

Every query the chatbot ships to an Ansible target passes through here.
Anything that isn't a pure SELECT (or WITH ... SELECT) is rejected before
it ever leaves this process.
"""

import re

import settings


class UnsafeSqlError(ValueError):
    pass


# Strip line and block comments so attackers can't hide DDL inside them.
_LINE_COMMENT  = re.compile(r"--[^\n]*")
_BLOCK_COMMENT = re.compile(r"/\*.*?\*/", re.DOTALL)


def sanitize(query: str) -> str:
    """Return a canonical, comment-free, single-statement SELECT or raise."""
    if not query or not query.strip():
        raise UnsafeSqlError("Empty query.")

    cleaned = _BLOCK_COMMENT.sub(" ", query)
    cleaned = _LINE_COMMENT.sub(" ", cleaned)
    cleaned = cleaned.strip().rstrip(";").strip()

    if not cleaned:
        raise UnsafeSqlError("Query is empty after stripping comments.")

    # Disallow multiple statements.
    if ";" in cleaned:
        raise UnsafeSqlError("Multiple SQL statements are not allowed.")

    lower = cleaned.lower()
    first_token = lower.split(None, 1)[0]
    if first_token not in {"select", "with"}:
        raise UnsafeSqlError(
            f"Only SELECT (or WITH ... SELECT) queries are permitted. Got: {first_token.upper()}"
        )

    # Whole-word keyword check against the denylist.
    for kw in settings.SQL_DENY_KEYWORDS:
        if re.search(rf"\b{re.escape(kw)}\b", lower):
            raise UnsafeSqlError(f"Disallowed keyword in query: {kw.upper()}")

    return cleaned


def looks_like_select(query: str) -> bool:
    try:
        sanitize(query)
        return True
    except UnsafeSqlError:
        return False
