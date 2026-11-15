# Test device

| Component | Specification |
|---|---|
| Model | vivo V2027 (iQOO / vivo "bengal" platform) |
| SoC | Qualcomm SM4250 (Snapdragon 460) - 4x A55 @ 1.8 GHz + 4x A55 @ 1.6 GHz |
| GPU | Adreno 610 |
| RAM | 2706 MB (2.7 GB) |
| Swap / zram | 1536 MB |
| Storage | 49 GB UFS, 19 GB free after tuning |
| Display | 720 x 1600 @ 60 Hz, 320 dpi (no high-refresh mode) |
| Android | 12 (SDK 31) |
| ROM | Funtouch OS 11.5, build SP1A.210812.003 |
| Bootloader | locked, verified boot green, no root |

This is a deliberately low-end device: 2.7 GB of RAM shared between the
system and 780+ processes, a 60 Hz panel, and a 2019-era GPU. The tuning in
this repo was developed against it specifically because the constraints are
tight enough that the problems are visible and measurable.
