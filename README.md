# dith

<p align="center">
  <img src="assets/pikachu.png" alt="dith demo" width="600">
</p>

Ever wanted to look at yourself... in Braille?

Plug in your webcam or throw any image at it: PNG, JPEG, BMP, whatever. 5 classic dithering algorithms render it live in your terminal.

Built in Zig with native macOS camera integration. No dependencies, just vibes.

## What You Can Do

**Dither anything:**

```bash
# Live camera feed
dith +source=cam +mode=atkinson

# Any image file
dith +source=file +mode=blue_noise +path=photo.png
```

**5 classic dithering algorithms:**

| Mode | Best For |
|------|----------|
| `edge` | Line art, sketches, outlines |
| `atkinson` | High contrast, classic Mac aesthetic |
| `floyd_steinberg` | Photos, smooth gradients |
| `blue_noise` | Organic, film-grain look |
| `bayer` | Retro 8-bit, crosshatch pattern |

**Fine-tune the output:**

```bash
# Adjust sensitivity
dith +source=cam +mode=edge +threshold=50

# Invert colors
dith +source=file +mode=bayer +path=image.jpg +invert
```

**Add brightness, color and depth:**

```bash
# Shade dots by brightness (0.55 lifts the dither's washed-out midtones)
dith +source=cam +mode=floyd_steinberg +gamma=0.55

# Color dots from the camera, with brightness shading
dith +source=cam +mode=atkinson +gamma=0.55 +color

# Depth: near things in the foreground color, far things fading into the background
dith +source=cam +mode=atkinson +depth

# Still images work the same way
dith +source=file +mode=blue_noise +path=photo.png +color +gamma=0.55
```

Shading uses only your terminal's own colors — `dith` asks the terminal for its foreground, background and 16-color palette (`dith +theme` shows the answer; `+fg`/`+bg` override the first two). Each cell is painted with the entry that best completes its dots and the difference is carried into the neighbouring cells, so tones between entries appear as mixtures. All channels are off unless asked for, so plain output stays as fast as before.

`+depth` runs [Depth Anything V2 (small)](https://huggingface.co/apple/coreml-depth-anything-v2-small) on the Neural Engine. The first use downloads the model (48 MB) into `~/.cache/dith` and compiles it there once; pass `+model=` to use your own.

## Install

**Requirements:** Zig 0.16.0+, macOS (for camera source)

```bash
git clone https://github.com/user/dith
cd dith
zig build -Doptimize=ReleaseFast
```

Binary is at `./zig-out/bin/dith`. Add it to your PATH or copy it somewhere convenient.

## Usage

```
dith +source=<SOURCE> +mode=<MODE> [options...]
```

### Sources

**Camera** - live feed from your webcam
```bash
dith +source=cam +mode=edge
dith +source=cam +mode=atkinson +warmup=5      # more warmup frames
dith +source=cam +mode=blue_noise +strategy=direct   # no background capture
```

**File** - PNG, JPEG, or BMP
```bash
dith +source=file +mode=floyd_steinberg +path=photo.png
dith +source=file +mode=bayer +path=~/Downloads/image.jpg +invert
```

### Options

| Option | Description | Default |
|--------|-------------|---------|
| `+threshold=N` | Sensitivity 0-255 | varies by mode |
| `+invert` | Flip black/white | off |
| `+gamma=G` | Shade dots by brightness with curve exponent G (lower = brighter shadows) | off |
| `+color` | Color dots from the source's chroma | off |
| `+depth` | Brightness follows distance: near = foreground color, far = background | off |
| `+model=PATH` | Depth model (`.mlpackage` or `.mlmodelc`) instead of the default | downloaded |
| `+fg=RRGGBB`, `+bg=RRGGBB` | Override the terminal's reported colors | queried |
| `+warmup=N` | Camera warmup frames | 3 |
| `+smooth=S` | Steadiness 0-1: holds the dots against noise and small motion (0 = off) | 0.7 |
| `+strategy=` | `pipelined` or `direct` | pipelined |

## Examples

```bash
# Sketch-like edge detection
dith +source=file +mode=edge +path=drawing.png +threshold=5

# Classic Macintosh dithering
dith +source=file +mode=atkinson +path=photo.jpg

# Smooth photo dithering
dith +source=cam +mode=floyd_steinberg +threshold=140

# Cinematic grain
dith +source=file +mode=blue_noise +path=portrait.png

# Retro game aesthetic
dith +source=cam +mode=bayer +invert
```

## Contributing

```bash
# Run tests
zig build test

# Debug build
zig build

# Release build
zig build -Doptimize=ReleaseFast

# Build and run
zig build run -- +source=cam +mode=edge
```

PRs welcome.
