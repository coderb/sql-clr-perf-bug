"""Writes sql/repro.sql, sql/diag.sql, sql/diagconfig.sql and sql/cleanup.sql from sql/parts, embedding
the built ClrSpin.dll as hex.

repro.sql measures every function at a range of DOPs; diag.sql records what contends at DOP 4 and at
the machine's maximum; diagconfig.sql repeats one function under the scratch database's diagnostics
settings. All share the setup and teardown parts; cleanup.sql is the teardown alone.
"""
import hashlib
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
SQL = HERE / 'sql'
PARTS = SQL / 'parts'
DLL = HERE / 'clr' / 'bin' / 'Release' / 'net472' / 'ClrSpin.dll'

SCRIPTS = {
    'repro.sql': ['10-setup.sql', '20-measure.sql', '90-teardown.sql'],
    'diag.sql': ['10-setup.sql', '30-diag.sql', '90-teardown.sql'],
    'diagconfig.sql': ['10-setup.sql', '40-diag-config.sql', '90-teardown.sql'],
}


def fill(text: str, dll: bytes, source: str) -> str:
    text = text.replace('{{ASSEMBLY_SHA512}}', '0x' + hashlib.sha512(dll).hexdigest())
    text = text.replace('{{ASSEMBLY_HEX}}', '0x' + dll.hex())
    assert '{{' not in text, f'unfilled placeholder in {source}'
    return text


def main() -> int:
    dll = DLL.read_bytes()
    for out, parts in SCRIPTS.items():
        text = ''.join((PARTS / part).read_text() for part in parts)
        (SQL / out).write_text(fill(text, dll, out))
    # cleanup.sql is the teardown alone, under its own header
    cleanup = (SQL / 'cleanup.template.sql').read_text() + (PARTS / '90-teardown.sql').read_text()
    (SQL / 'cleanup.sql').write_text(fill(cleanup, dll, 'cleanup.sql'))
    print(f'{DLL.name}: {len(dll)} bytes, sha512 {hashlib.sha512(dll).hexdigest()[:16]}...; wrote {", ".join(SCRIPTS)}, cleanup.sql')
    return 0


if __name__ == '__main__':
    sys.exit(main())
