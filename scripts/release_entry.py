"""Entry point for the self-contained release installer."""
import sys
from pathlib import Path
import tempfile
import zipfile
import install
import sign_iphone

if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == 'iphone':
        del sys.argv[1]
        sign_iphone.main()
    else:
        # Keep app binaries inside an archive so PyInstaller cannot rewrite their rpaths.
        with tempfile.TemporaryDirectory(prefix='relay-setup-') as directory:
            with zipfile.ZipFile(Path(sys._MEIPASS) / 'mac-payload.zip') as payload:
                payload.extractall(directory)
            install.ROOT = Path(directory)
            install.main()
