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

# Reduced-resolution rendering. cmd game downscale accepts 0.3 - 0.9.
# 0.70 for games (GPU-bound), 0.75 for general apps (mostly CPU-bound).
DOWNSCALE="com.supercell.clashroyale:0.7 com.kotobagames.namelesscat:0.7 \
com.instagram.android:0.75 com.truecaller:0.75 com.whatsapp:0.75 com.brave.browser:0.75 \
com.google.android.apps.tachyon:0.75 com.grindrapp.android:0.75"

# Apps that must survive Doze and the standby demotion.
WHITELIST="com.whatsapp com.brave.browser com.supercell.clashroyale com.truecaller \
com.instagram.android com.google.android.gms"

# Shizuku's server binary, shipped inside the Shizuku APK.
SHIZUKU_BIN="/data/app/~~h6pqdtKdYlBZlljMu9wtPg==/moe.shizuku.privileged.api-oZ2_Sqv-Dr0x3xzA6t6GEA==/lib/arm64/libshizuku.so"
