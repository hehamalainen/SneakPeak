"""Normalize supported local references without fetching or opening anything."""
from pathlib import Path
import re
from urllib.parse import unquote, urlsplit


def local_path(reference):
    if not isinstance(reference, str) or not reference or '\0' in reference:
        return None
    if reference.startswith('/'):
        return Path(reference)
    try:
        url = urlsplit(reference)
        if (url.scheme.lower() != 'file' or url.netloc.lower() not in {'', 'localhost'}
                or not url.path.startswith('/') or '?' in reference or '#' in reference
                or re.search(r'%(?![0-9a-fA-F]{2})', url.path)):
            return None
        path = unquote(url.path, encoding='utf-8', errors='strict')
        return Path(path) if path.startswith('/') and '\0' not in path else None
    except (ValueError, UnicodeError):
        return None


def normalize(reference):
    path = local_path(reference)
    return str(path) if path is not None else reference


def inspectable(reference):
    if local_path(reference) is not None:
        return True  # Availability and snapshot validity are checked separately.
    if not isinstance(reference, str) or not reference or '\0' in reference:
        return False
    try:
        url = urlsplit(reference)
        return (url.scheme.lower() == 'https' and bool(url.hostname)
                and url.username is None and url.password is None)
    except ValueError:
        return False
