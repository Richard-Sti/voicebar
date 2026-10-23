# Maintainer: Will Handley <wh260@cantab.ac.uk>
pkgname=voicebar
pkgver=0.5.1
pkgrel=1
pkgdesc="Voice-to-text dictation tool for Linux (X11) using OpenAI Whisper"
arch=('any')
url="https://github.com/Richard-Sti/voicebar"
license=('MIT')
depends=(
    'python>=3.11'
    'python-numpy'
    'python-openai'
    'python-pynput'
    'python-sounddevice'
    'xdotool'
    'ffmpeg'
)
optdepends=(
    'sof-firmware: for internal microphone support on modern AMD laptops'
    'python-groq: for Groq backend (faster, alternative to OpenAI)'
)
source=(
    'voicebar.py'
    'platform_support.py'
    'voicebar.service'
    'README.md'
    'LICENSE'
)
sha256sums=('SKIP' 'SKIP' 'SKIP' 'SKIP' 'SKIP')

package() {

    # Install main script and platform support module
    install -Dm755 voicebar.py "$pkgdir/usr/lib/$pkgname/voicebar.py"
    install -Dm644 platform_support.py "$pkgdir/usr/lib/$pkgname/platform_support.py"

    # Create symlink in /usr/bin
    mkdir -p "$pkgdir/usr/bin"
    ln -s "/usr/lib/$pkgname/voicebar.py" "$pkgdir/usr/bin/voicebar"

    # Install systemd user service
    install -Dm644 voicebar.service "$pkgdir/usr/lib/systemd/user/voicebar.service"

    # Install documentation
    install -Dm644 README.md "$pkgdir/usr/share/doc/$pkgname/README.md"

    # Install license
    install -Dm644 LICENSE "$pkgdir/usr/share/licenses/$pkgname/LICENSE"
}
