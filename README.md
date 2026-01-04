# Chroma

A fast, simple CLI utility for removing chroma key backgrounds from images with clean, anti-aliased edges.

Chroma automatically detects the background color of an image and removes it, producing a transparent output. It uses a blur-and-rethreshold technique to achieve smooth, professional-looking edges without harsh stair-stepping artifacts.

```bash
./chroma -i ./example-images/ -v
```

## Performance

Benchmarks run on Arch Linux (AMD Ryzen 9 9950X, 92GB RAM) with 
libvips 8.17.3, averaged over 3 runs per size:

| Resolution | Megapixels | Total Time | Save Time | Processing Rate |
|------------|------------|------------|-----------|-----------------|
| 640x480 | 0.3 MP | ~10ms | ~1ms | ~30 images/sec |
| 1280x720 | 0.9 MP | ~11ms | ~2-3ms | ~90 images/sec |
| 1920x1080 | 2.1 MP | ~12ms | ~3-4ms | ~85 images/sec |
| 2560x1440 | 3.7 MP | ~13ms | ~5ms | ~75 images/sec |
| 3840x2160 (4K) | 8.3 MP | ~16ms | ~7-8ms | ~60 images/sec |
| 5120x2880 (5K) | 14.7 MP | ~19ms | ~11ms | ~50 images/sec |
| 6000x4000 | 24 MP | ~27ms | ~18ms | ~37 images/sec |
| 8000x6000 | 48 MP | ~39ms | ~30ms | ~26 images/sec |
| 10000x7500 | 75 MP | ~55ms | ~47ms | ~18 images/sec |

## Examples

| Before | After |
|--------|-------|
| ![](example-images/example-1.webp) | ![](example-images/example-1_nobg.webp) |
| ![](example-images/example-2.png) | ![](example-images/example-2_nobg.webp) |
| ![](example-images/example-3.jpg) | ![](example-images/example-3_nobg.webp) |
| ![](example-images/example-4.jpg) | ![](example-images/example-4_nobg.webp) |

## How It Works

Chroma uses libvips for fast, memory-efficient image processing.

## Memory Usage

libvips uses demand-driven processing with lazy evaluation. Memory usage depends on the operations performed:
- **Base overhead**: ~20-50MB for libvips initialization
- **Per-image**: The full decoded image is typically held in memory during processing
- **Peak**: Roughly 3-4x the decoded image size (e.g., a 24MP RGB image = ~72MB decoded, ~200-300MB peak)

Note: The background detection step requires random pixel access at 8 edge points, which may cause full image decoding. The subsequent operations (mask, blur, despill) benefit from libvips' lazy evaluation - they execute as a single fused pipeline during save.
