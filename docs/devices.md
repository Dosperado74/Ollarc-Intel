# Devices with the same GPU

Every device with an Arrow Lake-H CPU (Core Ultra 200H, Arc 140T / 130T) has the same iGPU
as the test machine (Core Ultra 9 285H, Arc 140T) and should behave the same with the
`latest-arl-h` image. Faster RAM helps: token generation on an iGPU is memory-bandwidth bound.

| Device | CPU / GPU | RAM | Status |
|---|---|---|---|
| UGREEN NASync iDX6011 Pro (AI NAS) | Core Ultra 7 255H, Arc 140T | 64 GB LPDDR5X-8533 (soldered) | expected to work, **not tested yet**: no unit available. Needs Docker on UGOS Pro with access to `/dev/dri` |

Do you own one of these? A [benchmark](https://github.com/Dosperado74/ollarc-intel/issues/new?template=benchmark.yml)
moves it into the tested table in the README.
