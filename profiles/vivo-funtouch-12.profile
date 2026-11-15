# vivo Funtouch OS 12/13 (Android 12, SDK 31) - measured on vivo V2027
#
# Background-process supervisors. Each was verified to hold only background /
# management duties and to be non-critical (no IME, launcher, dialer, biometric).
DISABLE_SYSTEM="com.vivo.sps com.vivo.safecenter com.vivo.appfilter com.vivo.gamecube \
com.vivo.gamewatch com.vivo.doubletimezoneclock com.bbk.updater com.bbk.iqoo.logsystem \
com.vivo.smartmultiwindow com.vivo.fuelsummary com.vivo.epm com.vivo.aiengine \
com.iqoo.powersaving"

# Unused vendor packages. Must be removed with `--user 0`; a plain `pm uninstall`
# on a system package is reverted by the vendor package manager on next boot.
UNINSTALL_USER="com.vivo.easyshare com.vivo.browser com.vivo.unionpay com.yozo.vivo.office \
android.autoinstalls.config.vivo.devices"

# Reduced-resolution rendering via `cmd game downscale` (accepts 0.3 - 0.9).
#
# DISABLED BY DEFAULT. It does reduce GPU work and improves frame times, but
# upscaling to the panel renders text on a non-native pixel grid, making
# labels visibly larger and softer. On a 720p panel that reads as "the font
# size changed", which is a worse trade than the frame-rate gain.
# Enable deliberately by setting DOWNSCALE in a local copy of this profile.
DOWNSCALE=""

# Apps that must survive Doze and the standby demotion.
WHITELIST="com.whatsapp com.brave.browser com.supercell.clashroyale com.truecaller \
com.instagram.android com.google.android.gms"

# Shizuku's server binary, shipped inside the Shizuku APK.
SHIZUKU_BIN="/data/app/~~h6pqdtKdYlBZlljMu9wtPg==/moe.shizuku.privileged.api-oZ2_Sqv-Dr0x3xzA6t6GEA==/lib/arm64/libshizuku.so"
