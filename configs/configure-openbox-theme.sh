        configure_openbox_theme() {
          mkdir -p /usr/share/themes/ConstructorFabric/openbox-3 ${HOME}/.config/openbox ${HOME}/.config/gtk-3.0 ${HOME}/.config/gtk-2.0
          cat > /usr/share/themes/ConstructorFabric/openbox-3/themerc <<'OBTHEME'
        border.width: 2
        padding.width: 6
        padding.height: 5
        window.client.padding.width: 0
        window.handle.width: 4
        window.active.border.color: #2dd4bf
        window.inactive.border.color: #172944
        window.active.title.bg: flat gradient vertical
        window.active.title.bg.color: #132846
        window.active.title.bg.colorTo: #0a1628
        window.inactive.title.bg: flat gradient vertical
        window.inactive.title.bg.color: #0c1728
        window.inactive.title.bg.colorTo: #070d18
        window.active.label.text.color: #eef6ff
        window.inactive.label.text.color: #93a4b8
        window.label.text.justify: center
        window.active.handle.bg: flat solid
        window.active.handle.bg.color: #0b1b31
        window.inactive.handle.bg: flat solid
        window.inactive.handle.bg.color: #07111f
        window.active.grip.bg: flat solid
        window.active.grip.bg.color: #2dd4bf
        window.inactive.grip.bg: flat solid
        window.inactive.grip.bg.color: #1f3554
        window.active.button.unpressed.bg: flat solid
        window.active.button.unpressed.bg.color: #183454
        window.active.button.pressed.bg: flat solid
        window.active.button.pressed.bg.color: #2dd4bf
        window.active.button.hover.bg: flat solid
        window.active.button.hover.bg.color: #2563eb
        window.active.button.disabled.bg: flat solid
        window.active.button.disabled.bg.color: #102039
        window.active.button.unpressed.image.color: #e7f7ff
        window.active.button.pressed.image.color: #04111f
        window.active.button.hover.image.color: #ffffff
        window.active.button.disabled.image.color: #5d7089
        window.inactive.button.unpressed.bg: flat solid
        window.inactive.button.unpressed.bg.color: #101d31
        window.inactive.button.pressed.bg: flat solid
        window.inactive.button.pressed.bg.color: #223957
        window.inactive.button.hover.bg: flat solid
        window.inactive.button.hover.bg.color: #1d3556
        window.inactive.button.disabled.bg: flat solid
        window.inactive.button.disabled.bg.color: #0b1524
        window.inactive.button.unpressed.image.color: #93a4b8
        window.inactive.button.pressed.image.color: #d8e9ff
        window.inactive.button.hover.image.color: #d8e9ff
        window.inactive.button.disabled.image.color: #3d4d63
        menu.border.width: 1
        menu.border.color: #2dd4bf
        menu.title.bg: flat solid
        menu.title.bg.color: #132846
        menu.title.text.color: #eef6ff
        menu.items.bg: flat solid
        menu.items.bg.color: #07111f
        menu.items.text.color: #d8e9ff
        menu.items.active.bg: flat solid
        menu.items.active.bg.color: #1e3a5f
        menu.items.active.text.color: #ffffff
        osd.bg: flat solid
        osd.bg.color: #07111f
        osd.border.width: 1
        osd.border.color: #2dd4bf
        osd.label.text.color: #eef6ff
        OBTHEME
          cat > /usr/share/themes/ConstructorFabric/openbox-3/close.xbm <<'OBXBM'
        #define close_width 8
        #define close_height 8
        static unsigned char close_bits[] = { 0xc3,0xe7,0x7e,0x3c,0x3c,0x7e,0xe7,0xc3 };
        OBXBM
          cat > /usr/share/themes/ConstructorFabric/openbox-3/max.xbm <<'OBXBM'
        #define max_width 8
        #define max_height 8
        static unsigned char max_bits[] = { 0xff,0x81,0x81,0x81,0x81,0x81,0x81,0xff };
        OBXBM
          cat > /usr/share/themes/ConstructorFabric/openbox-3/iconify.xbm <<'OBXBM'
        #define iconify_width 8
        #define iconify_height 8
        static unsigned char iconify_bits[] = { 0x00,0x00,0x00,0x00,0x00,0x00,0xff,0xff };
        OBXBM
          cat > /usr/share/themes/ConstructorFabric/openbox-3/shade.xbm <<'OBXBM'
        #define shade_width 8
        #define shade_height 8
        static unsigned char shade_bits[] = { 0x18,0x3c,0x7e,0xff,0x00,0x00,0x00,0x00 };
        OBXBM
          cat > /usr/share/themes/ConstructorFabric/openbox-3/desk.xbm <<'OBXBM'
        #define desk_width 8
        #define desk_height 8
        static unsigned char desk_bits[] = { 0xff,0x81,0xbd,0xa5,0xa5,0xbd,0x81,0xff };
        OBXBM
          for n in close max iconify shade desk; do
            cp "/usr/share/themes/ConstructorFabric/openbox-3/$n.xbm" "/usr/share/themes/ConstructorFabric/openbox-3/${n}_pressed.xbm"
            cp "/usr/share/themes/ConstructorFabric/openbox-3/$n.xbm" "/usr/share/themes/ConstructorFabric/openbox-3/${n}_hover.xbm"
            cp "/usr/share/themes/ConstructorFabric/openbox-3/$n.xbm" "/usr/share/themes/ConstructorFabric/openbox-3/${n}_disabled.xbm"
          done
      python3 - <<'PYOB'
import os
from pathlib import Path
home=os.environ.get('HOME','/root')
candidates = [
  Path('/etc/xdg/openbox/LXDE/rc.xml'),
  Path('/etc/xdg/openbox/rc.xml'),
  Path('/usr/share/openbox/rc.xml'),
  Path('/usr/share/lxde/openbox/rc.xml'),
]
p=Path(f'{home}/.config/openbox/lxde-rc.xml')
for src in candidates:
  if src.exists():
    p.write_text(src.read_text())
    break
else:
  p.write_text('<?xml version="1.0" encoding="UTF-8"?>\n<openbox_config xmlns="http://openbox.org/3.4/rc"><theme><name>Onyx</name></theme><font><name>Sans</name><size>11</size></font></openbox_config>\n')
s=p.read_text().replace('<name>Onyx</name>', '<name>ConstructorFabric</name>').replace('<size>11</size>', '<size>12</size>')
p.write_text(s)
PYOB
          cat > ${HOME}/.config/gtk-3.0/settings.ini <<'GTK3'
        [Settings]
        gtk-theme-name=Adwaita-dark
        gtk-icon-theme-name=Adwaita
        gtk-font-name=Sans 11
        GTK3
          cat > ${HOME}/.gtkrc-2.0 <<'GTK2'
        gtk-theme-name="Adwaita-dark"
        gtk-icon-theme-name="Adwaita"
        gtk-font-name="Sans 11"
        GTK2
        }
