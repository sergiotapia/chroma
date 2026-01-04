# Chroma

A fast, simple CLI utility for removing chroma key backgrounds from images with clean, anti-aliased edges.

Chroma automatically detects the background color of an image and removes it, producing a transparent output. It uses a blur-and-rethreshold technique to achieve smooth, professional-looking edges without harsh stair-stepping artifacts.

## Examples

| Before | After |
|--------|-------|
| ![](example-images/example-1.webp) | ![](example-images/example-1_nobg.webp) |
| ![](example-images/example-2.png) | ![](example-images/example-2_nobg.webp) |
| ![](example-images/example-3.jpg) | ![](example-images/example-3_nobg.webp) |
| ![](example-images/example-4.jpg) | ![](example-images/example-4_nobg.webp) |

## How It Works

Chroma uses libvips for fast, memory-efficient image processing. The pipeline consists of several stages:

### 1. Background Color Detection

When no manual color is specified (`--color`), Chroma samples 8 strategic points around the image edges:
- 4 corners (with a small inset to avoid edge artifacts)
- 4 edge midpoints (top, bottom, left, right centers)

These samples are clustered by color similarity using the threshold value. The largest cluster (requiring at least 3 matching samples) determines the background color. This approach handles images where some edges may contain foreground content.

### 2. Mask Generation

A binary mask is created by calculating the color distance from each pixel to the detected background color:

1. **Color difference**: For each pixel, compute `|pixel - background|` per channel (RGB)
2. **Mean distance**: Average the absolute differences across all three channels
3. **Threshold**: Pixels within the threshold distance become white (background), others black (foreground)

The threshold parameter (`-t`) controls how aggressively colors are matched. Lower values are stricter (only very similar colors removed), higher values are more permissive.

### 3. Edge Softening

The raw binary mask would produce harsh, aliased edges. Chroma applies a Gaussian blur to the mask, creating smooth gradient transitions at foreground/background boundaries. The blur sigma (`-b`) controls how soft the edges become:
- Lower values (0.5-1.0): Sharp edges, minimal feathering
- Default (2.0): Balanced anti-aliasing
- Higher values (3.0+): Very soft, feathered edges

### 4. Color Spill Removal (Despill)

Green/blue screen backgrounds often reflect onto foreground subjects, causing a colored "fringe" at edges. Chroma applies two despill techniques:

1. **Standard despill**: For green screens, limits the green channel to `min(green, max(red, blue))`. This prevents green from exceeding what the other channels would naturally produce.

2. **Edge color correction**: For semi-transparent edge pixels, subtracts the background color contribution proportional to transparency: `corrected = pixel - background * (1 - alpha)`

### 5. Output

The final image combines the despilled RGB channels with the inverted, softened mask as an alpha channel. Output formats:
- **WebP** (default): Lossy compression with quality setting, smaller files
- **PNG**: Lossless compression, larger files but no quality loss

## Performance

Chroma uses libvips for image processing. libvips employs lazy evaluation - operations are chained into a pipeline that executes only when the output is written. This avoids redundant intermediate copies.

### Benchmark Results

Benchmarks run on Linux (AMD Ryzen / Intel equivalent) with libvips 8.17, averaged over 3 runs per size:

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

Key observations:
- **Fixed overhead**: ~7-8ms for loading and libvips initialization regardless of image size
- **Background detection**: ~0.5-0.6ms constant time (8 point samples)
- **Mask/blur/alpha operations**: ~1-2ms combined, nearly constant due to lazy evaluation
- **Save dominates at scale**: For large images, WebP encoding takes 60-85% of total time

### Verbose Timing Breakdown

Use `-v` to see per-stage timing:

```
$ chroma -i photo_3840x2160.jpg -v
[1/1] Processing: photo_3840x2160.jpg
  load image 7.18ms
  detect background 0.57ms
  create mask 0.25ms
  blur edges 0.32ms
  apply alpha 0.44ms
  save output 8.51ms
  total 17.26ms
```

Note: The mask, blur, and alpha operations appear fast because libvips uses lazy evaluation. The actual pixel processing happens during the save operation, which is why save time scales with image size.

### Output Format Comparison

At 3840x2160 (4K):
- **WebP**: ~16ms total (quality 90, ~200KB output)
- **PNG**: ~16ms total (compression 9, ~800KB output)

Both formats perform similarly. Choose based on output size requirements.

### Batch Processing

Processing is sequential. Measured throughput for 1920x1080 images:

| Image Count | Wall Clock Time | Throughput |
|-------------|-----------------|------------|
| 20 images | 4.3 seconds | ~5 images/sec |
| 100 images | 21 seconds | ~5 images/sec |

Note: Wall clock time includes process startup overhead per-image. For sustained batch processing, expect ~200ms per 2MP image including all overhead.

Projected batch times (1920x1080 images):
| Image Count | Estimated Time |
|-------------|----------------|
| 100 images | ~20 seconds |
| 1,000 images | ~3.5 minutes |
| 10,000 images | ~35 minutes |

### Scaling Characteristics

| Operation | Scaling | Notes |
|-----------|---------|-------|
| Load | O(n) | Linear with pixel count, I/O bound |
| Background detection | O(1) | Fixed 8 samples regardless of size |
| Mask/blur/alpha | O(n) | Lazy - computed during save |
| Save (WebP/PNG) | O(n) | Dominates for large images |

### Memory Usage

libvips uses demand-driven processing with lazy evaluation. Memory usage depends on the operations performed:
- **Base overhead**: ~20-50MB for libvips initialization
- **Per-image**: The full decoded image is typically held in memory during processing
- **Peak**: Roughly 3-4x the decoded image size (e.g., a 24MP RGB image = ~72MB decoded, ~200-300MB peak)

Note: The background detection step requires random pixel access at 8 edge points, which may cause full image decoding. The subsequent operations (mask, blur, despill) benefit from libvips' lazy evaluation - they execute as a single fused pipeline during save.
