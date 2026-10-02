from pathlib import Path
from PIL import Image
import sys
folder = Path(sys.argv[1]) if len(sys.argv)>1 else Path(__file__).resolve().parents[1]/'runs'
for p in folder.rglob('*.ppm'):
    try:
        Image.open(p).save(p.with_suffix('.png'))
    except Exception as e:
        print(f'Incomplete frame preserved: {p}: {e}')
