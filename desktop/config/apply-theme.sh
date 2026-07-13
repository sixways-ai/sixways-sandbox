#!/bin/bash
# Apply a familiar Windows/macOS-like layout to Xfce4 desktop.
# - Single bottom panel with app launcher, task list, system tray
# - Arc-Dark theme + Papirus icons + Ubuntu font
# - Desktop shortcuts for common apps
#
# This runs BEFORE startxfce4 so we write XML config files directly
# rather than using xfconf-query (which requires the settings daemon).

MARKER="$HOME/.config/sixways-theme-applied"
if [ -f "$MARKER" ]; then
    exit 0
fi

XFCONF="$HOME/.config/xfce4/xfconf/xfce-perchannel-xml"
mkdir -p "$XFCONF"
mkdir -p "$HOME/.config/xfce4/panel"
mkdir -p "$HOME/Desktop"

# --- Window manager: Arc-Dark theme, Ubuntu Bold font ---
cat > "$XFCONF/xfwm4.xml" << 'XMLEOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="theme" type="string" value="Arc-Dark"/>
    <property name="title_font" type="string" value="Ubuntu Bold 10"/>
    <property name="placement_ratio" type="int" value="20"/>
    <property name="button_layout" type="string" value="O|HMC"/>
  </property>
</channel>
XMLEOF

# --- GTK/appearance: Arc-Dark theme, Papirus icons, Ubuntu font ---
cat > "$XFCONF/xsettings.xml" << 'XMLEOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xsettings" version="1.0">
  <property name="Net" type="empty">
    <property name="ThemeName" type="string" value="Arc-Dark"/>
    <property name="IconThemeName" type="string" value="Papirus-Dark"/>
    <property name="CursorThemeName" type="string" value="Adwaita"/>
  </property>
  <property name="Gtk" type="empty">
    <property name="FontName" type="string" value="Ubuntu 10"/>
    <property name="MonospaceFontName" type="string" value="Ubuntu Mono 11"/>
    <property name="CursorThemeSize" type="int" value="24"/>
  </property>
</channel>
XMLEOF

# --- Panel layout: single bottom panel like Windows taskbar ---
# Plugins: whisker menu (1), task list (2), separator (3), systray (4), clock (5)
cat > "$XFCONF/xfce4-panel.xml" << 'XMLEOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-panel" version="1.0">
  <property name="configver" type="int" value="2"/>
  <property name="panels" type="array">
    <value type="int" value="1"/>
    <property name="dark-mode" type="bool" value="true"/>
    <property name="panel-1" type="empty">
      <property name="position" type="string" value="p=8;x=0;y=0"/>
      <property name="position-locked" type="bool" value="true"/>
      <property name="size" type="uint" value="40"/>
      <property name="length" type="uint" value="100"/>
      <property name="length-adjust" type="bool" value="false"/>
      <property name="mode" type="uint" value="0"/>
      <property name="plugin-ids" type="array">
        <value type="int" value="1"/>
        <value type="int" value="2"/>
        <value type="int" value="3"/>
        <value type="int" value="4"/>
        <value type="int" value="5"/>
        <value type="int" value="6"/>
      </property>
    </property>
  </property>
  <property name="plugins" type="empty">
    <property name="plugin-1" type="string" value="whiskermenu"/>
    <property name="plugin-2" type="string" value="separator">
      <property name="style" type="uint" value="0"/>
    </property>
    <property name="plugin-3" type="string" value="tasklist">
      <property name="flat-buttons" type="bool" value="true"/>
      <property name="show-labels" type="bool" value="true"/>
      <property name="grouping" type="uint" value="1"/>
    </property>
    <property name="plugin-4" type="string" value="separator">
      <property name="expand" type="bool" value="true"/>
      <property name="style" type="uint" value="0"/>
    </property>
    <property name="plugin-5" type="string" value="systray">
      <property name="square-icons" type="bool" value="true"/>
    </property>
    <property name="plugin-6" type="string" value="clock">
      <property name="digital-format" type="string" value="%H:%M"/>
    </property>
  </property>
</channel>
XMLEOF

# --- Desktop: solid dark background, no default icons ---
cat > "$XFCONF/xfce4-desktop.xml" << 'XMLEOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-desktop" version="1.0">
  <property name="backdrop" type="empty">
    <property name="screen0" type="empty">
      <property name="monitorVNC-0" type="empty">
        <property name="workspace0" type="empty">
          <property name="color-style" type="int" value="0"/>
          <property name="rgba1" type="array">
            <value type="double" value="0.180392"/>
            <value type="double" value="0.203922"/>
            <value type="double" value="0.250980"/>
            <value type="double" value="1.000000"/>
          </property>
          <property name="image-style" type="int" value="0"/>
        </property>
      </property>
    </property>
  </property>
  <property name="desktop-icons" type="empty">
    <property name="style" type="int" value="2"/>
    <property name="file-icons" type="empty">
      <property name="show-home" type="bool" value="false"/>
      <property name="show-filesystem" type="bool" value="false"/>
      <property name="show-trash" type="bool" value="false"/>
      <property name="show-removable" type="bool" value="false"/>
    </property>
  </property>
</channel>
XMLEOF

# --- Desktop shortcuts for common apps ---
cat > "$HOME/Desktop/firefox.desktop" << 'DEOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Firefox
Exec=firefox
Icon=firefox
Terminal=false
DEOF

cat > "$HOME/Desktop/terminal.desktop" << 'DEOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Terminal
Exec=xfce4-terminal
Icon=utilities-terminal
Terminal=false
DEOF

cat > "$HOME/Desktop/files.desktop" << 'DEOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Files
Exec=thunar
Icon=system-file-manager
Terminal=false
DEOF

cat > "$HOME/Desktop/editor.desktop" << 'DEOF'
[Desktop Entry]
Version=1.0
Type=Application
Name=Text Editor
Exec=mousepad
Icon=accessories-text-editor
Terminal=false
DEOF

chmod +x "$HOME/Desktop/"*.desktop

# Mark as applied so we don't overwrite user customizations
touch "$MARKER"
