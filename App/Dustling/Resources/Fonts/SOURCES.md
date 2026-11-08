# Font sources

All four families are licensed under the SIL Open Font License 1.1. The licence texts ship next to the fonts:
`OFL-Geist.txt` (Geist, Geist Mono and Geist Pixel) and `OFL-PixelifySans.txt` (Pixelify Sans).
Downloaded on 8 Nov 2026. The app registers every `.ttf` in this folder at launch (`DustlingTheme.registerFonts`).

## Geist, Geist Mono, Geist Pixel

- Release: `vercel/geist-font` v1.9.2 (published 6 Nov 2026)
- URL: https://github.com/vercel/geist-font/releases/download/v1.9.2/geist-font-v1.9.2.zip
- SHA-256 of the zip: `15f066d58dcb99fb10014a49913009fdaf41e464cfb8851a44b44e593c95d3d8`

Files taken from the zip, unchanged:

| File in this folder | Path in the zip | SHA-256 |
|---|---|---|
| `Geist-Regular.ttf` | `geist-font/Geist/ttf/Geist-Regular.ttf` | `2c460a7a71063e53491f343d44b382267bc0cf496e31db64865f962af3152e68` |
| `Geist-Medium.ttf` | `geist-font/Geist/ttf/Geist-Medium.ttf` | `e9099e006d4934cae4a8c7d14a1ca2ea724ee2f69f9bdd5b2ffe715baf5524fc` |
| `Geist-SemiBold.ttf` | `geist-font/Geist/ttf/Geist-SemiBold.ttf` | `01923aa148e5202ae70a2e11b2ab4dc41b80bcc374aedccc913d47bb2f591c06` |
| `Geist-Bold.ttf` | `geist-font/Geist/ttf/Geist-Bold.ttf` | `1c24df313b8ddc9550e060cfe5321c6374997f2892880af303b5ded45fed2582` |
| `GeistMono-Regular.ttf` | `geist-font/GeistMono/ttf/GeistMono-Regular.ttf` | `686914333e77a620c85b35481064788deb33fc25f69901bdbf296c1bbc26a7fe` |
| `GeistMono-Medium.ttf` | `geist-font/GeistMono/ttf/GeistMono-Medium.ttf` | `34c0828460d47e697655bc9d730027a4b8baf6e6c9aa46f5f32b653b4797cf36` |
| `GeistMono-SemiBold.ttf` | `geist-font/GeistMono/ttf/GeistMono-SemiBold.ttf` | `70b2e3e4218e8bfeed9bf01049411316457936f965e49291863c16f0dafc59a6` |
| `GeistMono-Bold.ttf` | `geist-font/GeistMono/ttf/GeistMono-Bold.ttf` | `8e4dd6ba6c0d420537f400c64cdc130969ab7a4425bb799aa3e07b961dd3062f` |
| `GeistPixel-Square.ttf` | `geist-font/GeistPixel/ttf/GeistPixel-Square.ttf` | `c1fbf7316997c1749857708998958e8ca0343416b3f8d2c7156d634a9520e997` |
| `OFL-Geist.txt` | `geist-font/OFL.txt` | `021caa749f89fecd7c2e40a50499de29e84d2bc19251659b47d499c2fbfffc17` |

Geist Pixel ships in five shapes (Square, Circle, Grid, Triangle, Line). Square is bundled because it is the
default instance of the variable `GeistPixel[ELSH].ttf` (Element Shape 0), which is what the approved
mockups render when they ask for the family "Geist Pixel".

## Pixelify Sans

- Repository: `google/fonts`, folder `ofl/pixelifysans`, commit `8b0a1d0f5983c89bc2b93f1b5fb55f9e252744b5`
- google/fonts ships Pixelify Sans only as a variable font (weight 400 to 700). It is bundled as is.

| File in this folder | URL | SHA-256 |
|---|---|---|
| `PixelifySans-Variable.ttf` | https://raw.githubusercontent.com/google/fonts/8b0a1d0f5983c89bc2b93f1b5fb55f9e252744b5/ofl/pixelifysans/PixelifySans%5Bwght%5D.ttf | `9ba86cd010a4de309d263ceff8e8044092c9db7efda869620cb9ff1c4389e8a5` |
| `OFL-PixelifySans.txt` | https://raw.githubusercontent.com/google/fonts/8b0a1d0f5983c89bc2b93f1b5fb55f9e252744b5/ofl/pixelifysans/OFL.txt | `b66ba46f511a851ab09998b5a5a9fdbb102545a3864cb993095e1745996873a7` |

`PixelifySans-Variable.ttf` is renamed from `PixelifySans[wght].ttf` only to keep brackets out of the
bundle path. The bytes are unchanged.
