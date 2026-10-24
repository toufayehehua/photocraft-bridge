"""Build a headless renderer from pinned, unmodified upstream declarations."""
from pathlib import Path
import re
import subprocess
import tempfile
import sys

root = Path(__file__).resolve().parent
sources = list((root / 'vendor/Compositor').rglob('*.swift'))
pattern = re.compile(r'^(?:(?:private|fileprivate|public|final|nonisolated)\s+)*(struct|enum|class|actor|extension)\s+(\w+)', re.M)
parts = []
for path in sources:
    source = path.read_text()
    imports = '\n'.join(re.findall(r'^import .+$', source, re.M))
    if 'import Sparkle' in imports:
        continue
    matches = list(pattern.finditer(source))
    for i, match in enumerate(matches):
        start = source.rfind('\n', 0, match.start()) + 1
        # Keep declaration attributes but do not pull in the preceding declaration.
        while start > 0:
            prev = source.rfind('\n', 0, start - 1) + 1
            if not source[prev:start].strip().startswith('@'):
                break
            start = prev
        end = matches[i + 1].start() if i + 1 < len(matches) else len(source)
        text = source[start:end]
        # Attributes belonging to the next declaration are outside this declaration.
        text = re.sub(r'(?:\n@[^\n]+)+\s*$', '\n', text)
        parts.append((path, imports, match[1], match[2], text))
needed = {'ProjectStore', 'ImageExporter'}
selected = set()
while True:
    previous = len(selected)
    for i, (_, _, kind, name, text) in enumerate(parts):
        if name in needed and name != 'EditorSession':
            selected.add(i)
            code = re.sub(r'//[^\n]*|/\*.*?\*/', '', text, flags=re.S)
            needed.update(re.findall(r'\b[A-Z][A-Za-z0-9_]*\b', code))
    if previous == len(selected):
        break
with tempfile.TemporaryDirectory(prefix='xd-compositor-render-') as temp:
    generated = []
    for path in sorted({parts[i][0] for i in selected}):
        chunks = [parts[i] for i in sorted(selected) if parts[i][0] == path]
        out = Path(temp) / (path.parent.name + '-' + path.name)
        out.write_text(chunks[0][1] + '\n' + '\n'.join(chunk[4] for chunk in chunks))
        generated.append(str(out))
    objects = []
    for kernel in sorted((root / 'vendor/Compositor/Rendering').glob('*.c')):
        obj = Path(temp) / (kernel.stem + '.o')
        subprocess.run(['xcrun', 'clang', '-O3', '-arch', 'arm64', '-mmacosx-version-min=26.0',
                        '-c', str(kernel), '-o', str(obj)], check=True)
        objects.append(str(obj))
    output = sys.argv[1]
    subprocess.run(['xcrun', 'swiftc', '-O', '-parse-as-library', '-target', 'arm64-apple-macos26.0',
                    '-import-objc-header', str(root / 'vendor/Compositor/Compositor-Bridging-Header.h'),
                    *generated, *objects, str(root / 'main.swift'), '-o', output], check=True)
print('Renderer built from', len(selected), 'upstream declarations.')
