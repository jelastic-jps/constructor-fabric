from pathlib import Path
p = Path('/etc/supervisor/conf.d/supervisord.conf')
if p.exists():
    s = p.read_text()
    s = s.replace(
        'command=x11vnc -display :1 -xkb -forever -shared -repeat -noxfixes -noxdamage -nowf -noscr -listen 0.0.0.0 -rfbport 5900 -rfbauth /.password2',
        'command=x11vnc -display :1 -xkb -forever -shared -repeat -noxfixes -noxdamage -nowf -noscr -listen 0.0.0.0 -rfbport 5900 -rfbauth /.password2'
    )
    s = s.replace(
        'command=x11vnc -display :1 -xkb -forever -shared -repeat -rfbauth /.password2',
        'command=x11vnc -display :1 -xkb -forever -shared -repeat -rfbauth /.password2'
    )
    p.write_text(s)
    print('x11vnc supervisor patched for native VNC')
