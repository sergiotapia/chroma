## Chroma - Chroma Key Background Removal CLI
## A fast, simple CLI utility for removing chroma key backgrounds from images

import std/[os, strutils, strformat, times, math, sets]

const
  Version = "0.1.0"
  DefaultThreshold = 38
  DefaultBlur = 2.0
  DefaultQuality = 90
  DefaultFormat = "webp"

type
  ExitCode = enum
    ecSuccess = 0
    ecGeneralError = 1
    ecBackgroundDetectionFailed = 2
    ecAllFilesSkipped = 3

  Config = object
    inputPath: string
    outputPath: string
    format: string
    threshold: int
    blur: float
    quality: int
    manualColor: string
    verbose: bool
    saveMask: bool

  RGB = tuple[r, g, b: uint8]

# ============================================================================
# libvips C bindings
# ============================================================================

{.passL: gorge("pkg-config --libs vips").}
{.passC: gorge("pkg-config --cflags vips").}

type
  VipsImage {.importc: "VipsImage", header: "<vips/vips.h>".} = object
  VipsImagePtr = ptr VipsImage

proc vips_init(argv0: cstring): cint {.importc, header: "<vips/vips.h>".}
proc vips_error_buffer(): cstring {.importc, header: "<vips/vips.h>".}
proc vips_error_clear() {.importc, header: "<vips/vips.h>".}
proc g_object_unref(obj: pointer) {.importc, header: "<glib.h>".}

proc vips_image_get_width(image: VipsImagePtr): cint {.importc, header: "<vips/vips.h>".}
proc vips_image_get_height(image: VipsImagePtr): cint {.importc, header: "<vips/vips.h>".}
proc vips_image_get_bands(image: VipsImagePtr): cint {.importc, header: "<vips/vips.h>".}

# Image I/O
proc vips_image_new_from_file(name: cstring): VipsImagePtr {.importc, header: "<vips/vips.h>", varargs.}
proc vips_webpsave(image: VipsImagePtr, filename: cstring): cint {.importc, header: "<vips/vips.h>", varargs.}
proc vips_pngsave(image: VipsImagePtr, filename: cstring): cint {.importc, header: "<vips/vips.h>", varargs.}

# Image operations
proc vips_extract_band(input: VipsImagePtr, output: ptr VipsImagePtr, band: cint): cint {.importc, header: "<vips/vips.h>", varargs.}
proc vips_bandjoin(images: ptr VipsImagePtr, output: ptr VipsImagePtr, n: cint): cint {.importc, header: "<vips/vips.h>", varargs.}
proc vips_bandjoin2(a: VipsImagePtr, b: VipsImagePtr, output: ptr VipsImagePtr): cint {.importc, header: "<vips/vips.h>", varargs.}
proc vips_flatten(input: VipsImagePtr, output: ptr VipsImagePtr): cint {.importc, header: "<vips/vips.h>", varargs.}
proc vips_cast(input: VipsImagePtr, output: ptr VipsImagePtr, format: cint): cint {.importc, header: "<vips/vips.h>", varargs.}
proc vips_linear(input: VipsImagePtr, output: ptr VipsImagePtr, a: ptr cdouble, b: ptr cdouble, n: cint): cint {.importc, header: "<vips/vips.h>", varargs.}
proc vips_gaussblur(input: VipsImagePtr, output: ptr VipsImagePtr, sigma: cdouble): cint {.importc, header: "<vips/vips.h>", varargs.}
proc vips_more(left: VipsImagePtr, right: VipsImagePtr, output: ptr VipsImagePtr): cint {.importc, header: "<vips/vips.h>", varargs.}
proc vips_less(left: VipsImagePtr, right: VipsImagePtr, output: ptr VipsImagePtr): cint {.importc, header: "<vips/vips.h>", varargs.}
proc vips_lesseq_const1(input: VipsImagePtr, output: ptr VipsImagePtr, c: cdouble): cint {.importc, header: "<vips/vips.h>", varargs.}
proc vips_more_const1(input: VipsImagePtr, output: ptr VipsImagePtr, c: cdouble): cint {.importc, header: "<vips/vips.h>", varargs.}
proc vips_subtract(left: VipsImagePtr, right: VipsImagePtr, output: ptr VipsImagePtr): cint {.importc, header: "<vips/vips.h>", varargs.}
proc vips_abs(input: VipsImagePtr, output: ptr VipsImagePtr): cint {.importc, header: "<vips/vips.h>", varargs.}
proc vips_bandmean(input: VipsImagePtr, output: ptr VipsImagePtr): cint {.importc, header: "<vips/vips.h>", varargs.}
proc vips_invert(input: VipsImagePtr, output: ptr VipsImagePtr): cint {.importc, header: "<vips/vips.h>", varargs.}
proc vips_ifthenelse(cond: VipsImagePtr, in1: VipsImagePtr, in2: VipsImagePtr, output: ptr VipsImagePtr): cint {.importc, header: "<vips/vips.h>", varargs.}
proc vips_black(output: ptr VipsImagePtr, width: cint, height: cint): cint {.importc, header: "<vips/vips.h>", varargs.}
proc vips_image_new_from_image(image: VipsImagePtr, c: ptr cdouble, n: cint): VipsImagePtr {.importc, header: "<vips/vips.h>".}
proc vips_image_write_to_memory(image: VipsImagePtr, size: ptr csize_t): pointer {.importc, header: "<vips/vips.h>".}
proc vips_crop(input: VipsImagePtr, output: ptr VipsImagePtr, left: cint, top: cint, width: cint, height: cint): cint {.importc, header: "<vips/vips.h>", varargs.}
proc vips_getpoint(image: VipsImagePtr, vector: ptr ptr cdouble, n: ptr cint, x: cint, y: cint): cint {.importc, header: "<vips/vips.h>", varargs.}
proc vips_multiply(left: VipsImagePtr, right: VipsImagePtr, output: ptr VipsImagePtr): cint {.importc, header: "<vips/vips.h>", varargs.}
proc vips_add(left: VipsImagePtr, right: VipsImagePtr, output: ptr VipsImagePtr): cint {.importc, header: "<vips/vips.h>", varargs.}
proc vips_divide(left: VipsImagePtr, right: VipsImagePtr, output: ptr VipsImagePtr): cint {.importc, header: "<vips/vips.h>", varargs.}

proc g_free(mem: pointer) {.importc, header: "<glib.h>".}

const
  VIPS_FORMAT_UCHAR = 0
  VIPS_FORMAT_DOUBLE = 9

# ============================================================================
# Helper functions
# ============================================================================

proc getVipsError(): string =
  result = $vips_error_buffer()
  vips_error_clear()

proc checkVips(ret: cint, msg: string) =
  if ret != 0:
    let err = getVipsError()
    quit(&"libvips error: {msg}: {err}", ord(ecGeneralError))

proc unref(img: VipsImagePtr) =
  if img != nil:
    g_object_unref(img)

proc parseHexColor(hex: string): RGB =
  var h = hex
  if h.startsWith("#"):
    h = h[1..^1]
  if h.len != 6:
    quit(&"Invalid hex color format: {hex}. Expected format: #RRGGBB", ord(ecGeneralError))
  try:
    result.r = uint8(parseHexInt(h[0..1]))
    result.g = uint8(parseHexInt(h[2..3]))
    result.b = uint8(parseHexInt(h[4..5]))
  except ValueError:
    quit(&"Invalid hex color: {hex}", ord(ecGeneralError))

proc colorDistance(c1, c2: RGB): float =
  let dr = float(c1.r) - float(c2.r)
  let dg = float(c1.g) - float(c2.g)
  let db = float(c1.b) - float(c2.b)
  sqrt(dr*dr + dg*dg + db*db)

proc getPixelColor(img: VipsImagePtr, x, y: int): RGB =
  var vector: ptr cdouble
  var n: cint
  if vips_getpoint(img, addr vector, addr n, cint(x), cint(y), nil) != 0:
    let err = getVipsError()
    quit(&"Failed to get pixel at ({x}, {y}): {err}", ord(ecGeneralError))
  
  let arr = cast[ptr UncheckedArray[cdouble]](vector)
  result.r = uint8(clamp(arr[0], 0, 255))
  result.g = if n > 1: uint8(clamp(arr[1], 0, 255)) else: result.r
  result.b = if n > 2: uint8(clamp(arr[2], 0, 255)) else: result.g
  g_free(vector)

# ============================================================================
# Background detection
# ============================================================================

proc detectBackgroundColor(img: VipsImagePtr, config: Config, stepStart: var float): RGB =
  ## Detect background color by sampling edges and clustering
  let width = vips_image_get_width(img)
  let height = vips_image_get_height(img)
  
  # Inset from edges to avoid artifacts
  let inset = max(2, min(width, height) div 100)
  
  # Sample points: corners and edge midpoints
  var samples: seq[RGB] = @[]
  
  # Corners
  samples.add(getPixelColor(img, inset, inset))                           # top-left
  samples.add(getPixelColor(img, width - inset - 1, inset))               # top-right
  samples.add(getPixelColor(img, inset, height - inset - 1))              # bottom-left
  samples.add(getPixelColor(img, width - inset - 1, height - inset - 1))  # bottom-right
  
  # Edge midpoints
  samples.add(getPixelColor(img, width div 2, inset))                     # top center
  samples.add(getPixelColor(img, width div 2, height - inset - 1))        # bottom center
  samples.add(getPixelColor(img, inset, height div 2))                    # left center
  samples.add(getPixelColor(img, width - inset - 1, height div 2))        # right center
  
  # Cluster similar colors using tolerance threshold
  let tolerance = float(config.threshold) * 1.5  # Slightly more lenient for clustering
  
  type Cluster = object
    colors: seq[RGB]
    center: RGB
  
  var clusters: seq[Cluster] = @[]
  
  for sample in samples:
    var foundCluster = false
    for i in 0..<clusters.len:
      if colorDistance(sample, clusters[i].center) < tolerance:
        clusters[i].colors.add(sample)
        # Update center as average
        var sumR, sumG, sumB: int
        for c in clusters[i].colors:
          sumR += int(c.r)
          sumG += int(c.g)
          sumB += int(c.b)
        let n = clusters[i].colors.len
        clusters[i].center = (uint8(sumR div n), uint8(sumG div n), uint8(sumB div n))
        foundCluster = true
        break
    
    if not foundCluster:
      clusters.add(Cluster(colors: @[sample], center: sample))
  
  # Find largest cluster
  var maxSize = 0
  var bestCluster = -1
  for i, c in clusters:
    if c.colors.len > maxSize:
      maxSize = c.colors.len
      bestCluster = i
  
  # Validate: need at least 3 samples (enough edge coverage)
  if bestCluster < 0 or maxSize < 3:
    quit("Could not detect background color. Try specifying manually with --color", ord(ecBackgroundDetectionFailed))
  
  result = clusters[bestCluster].center
  
  if config.verbose:
    let now = cpuTime()
    echo &"  detect background {(now - stepStart) * 1000:.2f}ms"
    stepStart = now

# ============================================================================
# Mask generation
# ============================================================================

proc createChromaMask(img: VipsImagePtr, bgColor: RGB, config: Config): VipsImagePtr =
  ## Create alpha mask: white where background, black where foreground
  let width = vips_image_get_width(img)
  let height = vips_image_get_height(img)
  let bands = vips_image_get_bands(img)
  
  # Extract RGB channels (ignore alpha if present)
  var rgb: VipsImagePtr
  if bands > 3:
    var arr: array[3, VipsImagePtr]
    for i in 0..2:
      checkVips(vips_extract_band(img, addr arr[i], cint(i), nil), "extract band")
    var arrPtr = addr arr[0]
    checkVips(vips_bandjoin(arrPtr, addr rgb, 3, nil), "bandjoin RGB")
    for i in 0..2:
      unref(arr[i])
  else:
    rgb = img
  
  # Create background color image
  var bgValues: array[3, cdouble] = [cdouble(bgColor.r), cdouble(bgColor.g), cdouble(bgColor.b)]
  let bgImg = vips_image_new_from_image(rgb, addr bgValues[0], 3)
  if bgImg == nil:
    quit(&"Failed to create background color image: {getVipsError()}", ord(ecGeneralError))
  
  # Calculate |pixel - bgcolor| for each channel
  var diff: VipsImagePtr
  checkVips(vips_subtract(rgb, bgImg, addr diff, nil), "subtract")
  unref(bgImg)
  if bands > 3:
    unref(rgb)
  
  var absDiff: VipsImagePtr
  checkVips(vips_abs(diff, addr absDiff, nil), "abs")
  unref(diff)
  
  # Average the absolute differences across channels
  var meanDiff: VipsImagePtr
  checkVips(vips_bandmean(absDiff, addr meanDiff, nil), "bandmean")
  unref(absDiff)
  
  # Threshold: pixels within threshold are background (white=255), else foreground (black=0)
  # vips_lesseq_const1 returns 255 for true, 0 for false (already uchar)
  var mask: VipsImagePtr
  checkVips(vips_lesseq_const1(meanDiff, addr mask, cdouble(config.threshold), nil), "threshold")
  unref(meanDiff)
  
  result = mask

proc blurAndSoftenEdges(mask: VipsImagePtr, config: Config): VipsImagePtr =
  ## Apply blur to create soft edges with gradual alpha transitions
  
  # Apply Gaussian blur to smooth the hard mask edges
  var blurred: VipsImagePtr
  checkVips(vips_gaussblur(mask, addr blurred, cdouble(config.blur), nil), "gaussblur")
  
  # The blurred mask now has gradient values at edges (0-255)
  # Just cast to uchar to ensure proper format
  var resultUchar: VipsImagePtr
  checkVips(vips_cast(blurred, addr resultUchar, VIPS_FORMAT_UCHAR, nil), "cast to uchar")
  unref(blurred)
  
  result = resultUchar

proc despillGreen(img: VipsImagePtr, alphaMask: VipsImagePtr, bgColor: RGB, config: Config): VipsImagePtr =
  ## Remove green/blue color spill from edge pixels
  ## Uses two techniques:
  ## 1. Standard despill: new_green = min(green, max(red, blue)) 
  ## 2. Edge color correction: subtract background contribution from semi-transparent pixels
  
  # Extract RGB channels
  var rChan, gChan, bChan: VipsImagePtr
  checkVips(vips_extract_band(img, addr rChan, 0, nil), "extract R")
  checkVips(vips_extract_band(img, addr gChan, 1, nil), "extract G")
  checkVips(vips_extract_band(img, addr bChan, 2, nil), "extract B")
  
  # Determine which channel is dominant in background (green or blue usually)
  let isGreenScreen = bgColor.g > bgColor.r and bgColor.g > bgColor.b
  let isBlueScreen = bgColor.b > bgColor.r and bgColor.b > bgColor.g
  
  # Cast channels to double for math
  var rDouble, gDouble, bDouble: VipsImagePtr
  checkVips(vips_cast(rChan, addr rDouble, VIPS_FORMAT_DOUBLE, nil), "cast R")
  checkVips(vips_cast(gChan, addr gDouble, VIPS_FORMAT_DOUBLE, nil), "cast G")
  checkVips(vips_cast(bChan, addr bDouble, VIPS_FORMAT_DOUBLE, nil), "cast B")
  unref(rChan)
  unref(gChan)
  unref(bChan)
  
  var finalR, finalG, finalB: VipsImagePtr
  var zero: cdouble = 0.0
  
  if isGreenScreen:
    # For semi-transparent edge pixels, subtract the background green contribution
    # Edge pixels are a blend: pixel = foreground * alpha + background * (1-alpha)
    # To remove background: foreground = (pixel - background * (1-alpha)) / alpha
    # Simplified: just subtract background * (1-alpha) from the green channel
    
    # Get alpha normalized to 0-1
    var alphaDouble: VipsImagePtr
    checkVips(vips_cast(alphaMask, addr alphaDouble, VIPS_FORMAT_DOUBLE, nil), "cast alpha")
    var scale: cdouble = 1.0 / 255.0
    var alphaNorm: VipsImagePtr
    checkVips(vips_linear(alphaDouble, addr alphaNorm, addr scale, addr zero, 1, nil), "normalize alpha")
    unref(alphaDouble)
    
    # Calculate (1 - alpha) = transparency amount
    var one: cdouble = 1.0
    var oneImg: VipsImagePtr
    checkVips(vips_linear(alphaNorm, addr oneImg, addr zero, addr one, 1, nil), "create 1")
    var transparency: VipsImagePtr
    checkVips(vips_subtract(oneImg, alphaNorm, addr transparency, nil), "1 - alpha")
    unref(oneImg)
    unref(alphaNorm)
    
    # Subtract background green contribution: green - (bgGreen * transparency)
    var bgGreen: cdouble = cdouble(bgColor.g)
    var bgContrib: VipsImagePtr
    checkVips(vips_linear(transparency, addr bgContrib, addr bgGreen, addr zero, 1, nil), "bg * transparency")
    unref(transparency)
    
    var gCorrected: VipsImagePtr
    checkVips(vips_subtract(gDouble, bgContrib, addr gCorrected, nil), "subtract bg green")
    unref(bgContrib)
    
    # Also apply standard despill: new_green = min(green, max(red, blue))
    # This catches any remaining spill in opaque areas
    var rGreaterB: VipsImagePtr
    checkVips(vips_more(rDouble, bDouble, addr rGreaterB, nil), "r > b")
    
    var maxRB: VipsImagePtr
    checkVips(vips_ifthenelse(rGreaterB, rDouble, bDouble, addr maxRB, nil), "max(r,b)")
    unref(rGreaterB)
    
    var gGreater: VipsImagePtr
    checkVips(vips_more(gCorrected, maxRB, addr gGreater, nil), "g > max(r,b)")
    
    var despilledG: VipsImagePtr
    checkVips(vips_ifthenelse(gGreater, maxRB, gCorrected, addr despilledG, nil), "despill green")
    unref(gGreater)
    unref(maxRB)
    unref(gCorrected)
    
    finalR = rDouble
    finalB = bDouble
    finalG = despilledG
    unref(gDouble)
    
  elif isBlueScreen:
    # Same approach for blue screen
    var alphaDouble: VipsImagePtr
    checkVips(vips_cast(alphaMask, addr alphaDouble, VIPS_FORMAT_DOUBLE, nil), "cast alpha")
    var scale: cdouble = 1.0 / 255.0
    var alphaNorm: VipsImagePtr
    checkVips(vips_linear(alphaDouble, addr alphaNorm, addr scale, addr zero, 1, nil), "normalize alpha")
    unref(alphaDouble)
    
    var one: cdouble = 1.0
    var oneImg: VipsImagePtr
    checkVips(vips_linear(alphaNorm, addr oneImg, addr zero, addr one, 1, nil), "create 1")
    var transparency: VipsImagePtr
    checkVips(vips_subtract(oneImg, alphaNorm, addr transparency, nil), "1 - alpha")
    unref(oneImg)
    unref(alphaNorm)
    
    var bgBlue: cdouble = cdouble(bgColor.b)
    var bgContrib: VipsImagePtr
    checkVips(vips_linear(transparency, addr bgContrib, addr bgBlue, addr zero, 1, nil), "bg * transparency")
    unref(transparency)
    
    var bCorrected: VipsImagePtr
    checkVips(vips_subtract(bDouble, bgContrib, addr bCorrected, nil), "subtract bg blue")
    unref(bgContrib)
    
    # Standard despill
    var rGreaterG: VipsImagePtr
    checkVips(vips_more(rDouble, gDouble, addr rGreaterG, nil), "r > g")
    
    var maxRG: VipsImagePtr
    checkVips(vips_ifthenelse(rGreaterG, rDouble, gDouble, addr maxRG, nil), "max(r,g)")
    unref(rGreaterG)
    
    var bGreater: VipsImagePtr
    checkVips(vips_more(bCorrected, maxRG, addr bGreater, nil), "b > max(r,g)")
    
    var despilledB: VipsImagePtr
    checkVips(vips_ifthenelse(bGreater, maxRG, bCorrected, addr despilledB, nil), "despill blue")
    unref(bGreater)
    unref(maxRG)
    unref(bCorrected)
    
    finalR = rDouble
    finalG = gDouble
    finalB = despilledB
    unref(bDouble)
    
  else:
    # Not a standard green/blue screen - no despill
    finalR = rDouble
    finalG = gDouble
    finalB = bDouble
  
  # Recombine channels
  var finalRu, finalGu, finalBu: VipsImagePtr
  checkVips(vips_cast(finalR, addr finalRu, VIPS_FORMAT_UCHAR, nil), "cast R final")
  checkVips(vips_cast(finalG, addr finalGu, VIPS_FORMAT_UCHAR, nil), "cast G final")
  checkVips(vips_cast(finalB, addr finalBu, VIPS_FORMAT_UCHAR, nil), "cast B final")
  unref(finalR)
  unref(finalG)
  unref(finalB)
  
  var channels: array[3, VipsImagePtr] = [finalRu, finalGu, finalBu]
  var channelsPtr = addr channels[0]
  var rgbResult: VipsImagePtr
  checkVips(vips_bandjoin(channelsPtr, addr rgbResult, 3, nil), "join RGB")
  unref(finalRu)
  unref(finalGu)
  unref(finalBu)
  
  result = rgbResult

proc applyAlphaMask(img: VipsImagePtr, mask: VipsImagePtr, bgColor: RGB, config: Config): VipsImagePtr =
  ## Apply inverted mask as alpha channel (foreground = opaque)
  ## Also applies despill to remove color fringing
  let bands = vips_image_get_bands(img)
  
  # Invert mask: background (white) becomes transparent (black), foreground becomes opaque
  var invertedMask: VipsImagePtr
  checkVips(vips_invert(mask, addr invertedMask, nil), "invert mask")
  
  # Extract RGB from input
  var rgb: VipsImagePtr
  if bands > 3:
    # Image already has alpha - extract RGB only
    var arr: array[3, VipsImagePtr]
    for i in 0..2:
      checkVips(vips_extract_band(img, addr arr[i], cint(i), nil), "extract band")
    var arrPtr = addr arr[0]
    checkVips(vips_bandjoin(arrPtr, addr rgb, 3, nil), "bandjoin RGB")
    for i in 0..2:
      unref(arr[i])
    
    # Get existing alpha and combine with new mask (multiply to keep both)
    var existingAlpha: VipsImagePtr
    checkVips(vips_extract_band(img, addr existingAlpha, cint(3), nil), "extract alpha")
    

    
    # Cast both to double for multiplication
    var maskDouble, alphaDouble: VipsImagePtr
    checkVips(vips_cast(invertedMask, addr maskDouble, VIPS_FORMAT_DOUBLE, nil), "cast mask")
    checkVips(vips_cast(existingAlpha, addr alphaDouble, VIPS_FORMAT_DOUBLE, nil), "cast alpha")
    unref(existingAlpha)
    
    # Normalize to 0-1, multiply, scale back
    var scale: cdouble = 1.0 / 255.0
    var zero: cdouble = 0.0
    var maskNorm, alphaNorm: VipsImagePtr
    checkVips(vips_linear(maskDouble, addr maskNorm, addr scale, addr zero, 1, nil), "normalize mask")
    checkVips(vips_linear(alphaDouble, addr alphaNorm, addr scale, addr zero, 1, nil), "normalize alpha")
    unref(maskDouble)
    unref(alphaDouble)
    
    var combined: VipsImagePtr
    checkVips(vips_multiply(maskNorm, alphaNorm, addr combined, nil), "multiply alpha")
    unref(maskNorm)
    unref(alphaNorm)
    
    var scale255: cdouble = 255.0
    var combinedScaled: VipsImagePtr
    checkVips(vips_linear(combined, addr combinedScaled, addr scale255, addr zero, 1, nil), "scale combined")
    unref(combined)
    
    checkVips(vips_cast(combinedScaled, addr invertedMask, VIPS_FORMAT_UCHAR, nil), "cast combined")
    unref(combinedScaled)
  elif bands == 3:
    rgb = img
  else:
    # Grayscale - expand to RGB
    var arr: array[3, VipsImagePtr] = [img, img, img]
    var arrPtr = addr arr[0]
    checkVips(vips_bandjoin(arrPtr, addr rgb, 3, nil), "expand grayscale to RGB")
  
  # Apply despill to remove color fringing on edges
  let despilledRgb = despillGreen(rgb, invertedMask, bgColor, config)
  if bands != 3:
    unref(rgb)
  
  # Join despilled RGB with alpha
  var rgba: VipsImagePtr
  checkVips(vips_bandjoin2(despilledRgb, invertedMask, addr rgba, nil), "bandjoin RGBA")
  
  unref(despilledRgb)
  unref(invertedMask)
  
  result = rgba

# ============================================================================
# File processing
# ============================================================================

proc isImageFile(path: string): bool =
  let ext = path.splitFile.ext.toLowerAscii
  ext in [".jpg", ".jpeg", ".png", ".webp", ".tiff", ".tif", ".gif", ".heic", ".heif", ".avif", ".bmp"]

proc findImageFiles(dir: string): seq[string] =
  result = @[]
  for file in walkDirRec(dir):
    if file.isImageFile:
      result.add(file)

proc generateOutputPath(inputPath, outputPath, format: string, isDir: bool): string =
  let (_, name, _) = inputPath.splitFile
  let outExt = "." & format
  
  if outputPath == "":
    # Auto-generate next to input
    let (dir, _, _) = inputPath.splitFile
    result = dir / (name & "_nobg" & outExt)
  elif isDir:
    # Output to directory
    result = outputPath / (name & "_nobg" & outExt)
  else:
    # Explicit output path
    result = outputPath

proc resolveCollision(path: string): string =
  ## Handle filename collisions by appending numbers
  if not fileExists(path):
    return path
  
  let (dir, name, ext) = path.splitFile
  var counter = 1
  while true:
    result = dir / &"{name}_{counter}{ext}"
    if not fileExists(result):
      return result
    counter += 1

proc processImage(inputPath: string, outputPath: string, config: Config, fileIndex: int = 0, totalFiles: int = 1): bool =
  ## Process a single image, returns true if successful
  
  # Check output doesn't exist
  if fileExists(outputPath):
    if config.verbose:
      echo &"[{fileIndex}/{totalFiles}] Skipping (exists): {inputPath}"
    else:
      echo &"Output file exists, skipping: {outputPath}"
    return false
  
  let imageStart = cpuTime()
  var stepStart = imageStart
  if config.verbose:
    echo &"[{fileIndex}/{totalFiles}] Processing: {inputPath}"
  
  # Load image
  let img = vips_image_new_from_file(cstring(inputPath), nil)
  if img == nil:
    echo &"Failed to load image: {inputPath}: {getVipsError()}"
    return false
  
  if config.verbose:
    let now = cpuTime()
    echo &"  load image {(now - stepStart) * 1000:.2f}ms"
    stepStart = now
  
  # Detect or use manual background color
  var bgColor: RGB
  if config.manualColor != "":
    bgColor = parseHexColor(config.manualColor)
  else:
    bgColor = detectBackgroundColor(img, config, stepStart)
  
  # Create mask
  var mask = createChromaMask(img, bgColor, config)
  
  if config.verbose:
    let now = cpuTime()
    echo &"  create mask {(now - stepStart) * 1000:.2f}ms"
    stepStart = now
  
  # Save mask if requested
  if config.saveMask:
    let (dir, name, _) = outputPath.splitFile
    let maskPath = dir / (name & "_mask.png")
    discard vips_pngsave(mask, cstring(maskPath), nil)
    if config.verbose:
      let now = cpuTime()
      echo &"  save mask {(now - stepStart) * 1000:.2f}ms"
      stepStart = now
  
  # Blur and rethreshold
  let smoothMask = blurAndSoftenEdges(mask, config)
  unref(mask)
  
  if config.verbose:
    let now = cpuTime()
    echo &"  blur edges {(now - stepStart) * 1000:.2f}ms"
    stepStart = now
  
  # Apply as alpha channel
  let outputImg = applyAlphaMask(img, smoothMask, bgColor, config)
  unref(smoothMask)
  unref(img)
  
  if config.verbose:
    let now = cpuTime()
    echo &"  apply alpha {(now - stepStart) * 1000:.2f}ms"
    stepStart = now
  
  # Create output directory if needed
  let outDir = outputPath.parentDir
  if outDir != "" and not dirExists(outDir):
    createDir(outDir)
  
  # Save output
  var saveResult: cint
  if config.format == "png":
    saveResult = vips_pngsave(outputImg, cstring(outputPath), "compression", cint(9 - config.quality div 12), nil)
  else:
    saveResult = vips_webpsave(outputImg, cstring(outputPath), "Q", cint(config.quality), nil)
  
  unref(outputImg)
  
  if saveResult != 0:
    echo &"Failed to save output: {outputPath}: {getVipsError()}"
    return false
  
  if config.verbose:
    let now = cpuTime()
    echo &"  save output {(now - stepStart) * 1000:.2f}ms"
    echo &"  total {(now - imageStart) * 1000:.2f}ms"
  else:
    echo outputPath
  
  return true

# ============================================================================
# CLI
# ============================================================================

proc showHelp() =
  echo """
Chroma - Chroma Key Background Removal CLI

Usage:
  chroma -i <input> [-o <output>] [options]

Options:
  -i, --input <path>      Input file or directory (required)
  -o, --output <path>     Output file or directory (default: {input}_nobg.webp)
  -f, --format <fmt>      Output format: webp or png (default: webp)
  -t, --threshold <n>     Color matching threshold 0-255 (default: 38)
  -b, --blur <sigma>      Edge blur sigma for soft edges (default: 2.0)
  -q, --quality <n>       Output compression quality 1-100 (default: 90)
  -c, --color <hex>       Manual background color (e.g., #00FF00)
  -v, --verbose           Enable verbose output with timing info
      --save-mask         Save the alpha mask as a separate file
      --help              Show this help message
      --version           Show version

Examples:
  chroma -i photo.jpg
  chroma -i photo.jpg -o photo_transparent.png -f png
  chroma -i ./photos/ -o ./processed/ -v
  chroma -i photo.jpg -c "#00FF00" -t 50
"""

proc showVersion() =
  echo &"chroma {Version}"

proc parseArgs(): Config =
  result = Config(
    format: DefaultFormat,
    threshold: DefaultThreshold,
    blur: DefaultBlur,
    quality: DefaultQuality,
    verbose: false,
    saveMask: false
  )
  
  # Parse command line manually to support "-i value" syntax
  let args = commandLineParams()
  var i = 0
  while i < args.len:
    let arg = args[i]
    
    if arg.startsWith("--"):
      let opt = arg[2..^1]
      var key, val: string
      let eqPos = opt.find({'=', ':'})
      if eqPos >= 0:
        key = opt[0..<eqPos].toLowerAscii
        val = opt[eqPos+1..^1]
      else:
        key = opt.toLowerAscii
        val = ""
      
      case key
      of "input":
        if val == "":
          i += 1
          if i >= args.len:
            quit("--input requires a value", ord(ecGeneralError))
          result.inputPath = args[i]
        else:
          result.inputPath = val
      of "output":
        if val == "":
          i += 1
          if i >= args.len:
            quit("--output requires a value", ord(ecGeneralError))
          result.outputPath = args[i]
        else:
          result.outputPath = val
      of "format":
        if val == "":
          i += 1
          if i >= args.len:
            quit("--format requires a value", ord(ecGeneralError))
          result.format = args[i].toLowerAscii
        else:
          result.format = val.toLowerAscii
      of "threshold":
        if val == "":
          i += 1
          if i >= args.len:
            quit("--threshold requires a value", ord(ecGeneralError))
          val = args[i]
        try:
          result.threshold = parseInt(val)
        except ValueError:
          quit(&"Invalid threshold value: {val}", ord(ecGeneralError))
      of "blur":
        if val == "":
          i += 1
          if i >= args.len:
            quit("--blur requires a value", ord(ecGeneralError))
          val = args[i]
        try:
          result.blur = parseFloat(val)
        except ValueError:
          quit(&"Invalid blur value: {val}", ord(ecGeneralError))
      of "quality":
        if val == "":
          i += 1
          if i >= args.len:
            quit("--quality requires a value", ord(ecGeneralError))
          val = args[i]
        try:
          result.quality = parseInt(val)
        except ValueError:
          quit(&"Invalid quality value: {val}", ord(ecGeneralError))
      of "color":
        if val == "":
          i += 1
          if i >= args.len:
            quit("--color requires a value", ord(ecGeneralError))
          result.manualColor = args[i]
        else:
          result.manualColor = val
      of "verbose":
        result.verbose = true
      of "save-mask":
        result.saveMask = true
      of "help":
        showHelp()
        quit(0)
      of "version":
        showVersion()
        quit(0)
      else:
        quit(&"Unknown option: --{key}", ord(ecGeneralError))
    
    elif arg.startsWith("-"):
      var j = 1
      while j < arg.len:
        let c = arg[j]
        case c
        of 'i':
          if j + 1 < arg.len and arg[j+1] in {'=', ':'}:
            result.inputPath = arg[j+2..^1]
            break
          elif j + 1 < arg.len:
            result.inputPath = arg[j+1..^1]
            break
          else:
            i += 1
            if i >= args.len:
              quit("-i requires a value", ord(ecGeneralError))
            result.inputPath = args[i]
            break
        of 'o':
          if j + 1 < arg.len and arg[j+1] in {'=', ':'}:
            result.outputPath = arg[j+2..^1]
            break
          elif j + 1 < arg.len:
            result.outputPath = arg[j+1..^1]
            break
          else:
            i += 1
            if i >= args.len:
              quit("-o requires a value", ord(ecGeneralError))
            result.outputPath = args[i]
            break
        of 'f':
          var val: string
          if j + 1 < arg.len and arg[j+1] in {'=', ':'}:
            val = arg[j+2..^1]
          elif j + 1 < arg.len:
            val = arg[j+1..^1]
          else:
            i += 1
            if i >= args.len:
              quit("-f requires a value", ord(ecGeneralError))
            val = args[i]
          result.format = val.toLowerAscii
          break
        of 't':
          var val: string
          if j + 1 < arg.len and arg[j+1] in {'=', ':'}:
            val = arg[j+2..^1]
          elif j + 1 < arg.len:
            val = arg[j+1..^1]
          else:
            i += 1
            if i >= args.len:
              quit("-t requires a value", ord(ecGeneralError))
            val = args[i]
          try:
            result.threshold = parseInt(val)
          except ValueError:
            quit(&"Invalid threshold value: {val}", ord(ecGeneralError))
          break
        of 'b':
          var val: string
          if j + 1 < arg.len and arg[j+1] in {'=', ':'}:
            val = arg[j+2..^1]
          elif j + 1 < arg.len:
            val = arg[j+1..^1]
          else:
            i += 1
            if i >= args.len:
              quit("-b requires a value", ord(ecGeneralError))
            val = args[i]
          try:
            result.blur = parseFloat(val)
          except ValueError:
            quit(&"Invalid blur value: {val}", ord(ecGeneralError))
          break
        of 'q':
          var val: string
          if j + 1 < arg.len and arg[j+1] in {'=', ':'}:
            val = arg[j+2..^1]
          elif j + 1 < arg.len:
            val = arg[j+1..^1]
          else:
            i += 1
            if i >= args.len:
              quit("-q requires a value", ord(ecGeneralError))
            val = args[i]
          try:
            result.quality = parseInt(val)
          except ValueError:
            quit(&"Invalid quality value: {val}", ord(ecGeneralError))
          break
        of 'c':
          if j + 1 < arg.len and arg[j+1] in {'=', ':'}:
            result.manualColor = arg[j+2..^1]
            break
          elif j + 1 < arg.len:
            result.manualColor = arg[j+1..^1]
            break
          else:
            i += 1
            if i >= args.len:
              quit("-c requires a value", ord(ecGeneralError))
            result.manualColor = args[i]
            break
        of 'v':
          result.verbose = true
        of 'h':
          showHelp()
          quit(0)
        else:
          quit(&"Unknown option: -{c}", ord(ecGeneralError))
        j += 1
    
    else:
      quit(&"Unexpected argument: {arg}", ord(ecGeneralError))
    
    i += 1

proc validateConfig(config: var Config) =
  if config.inputPath == "":
    quit("Input path is required. Use -i or --input", ord(ecGeneralError))
  
  if not fileExists(config.inputPath) and not dirExists(config.inputPath):
    quit(&"Input path does not exist: {config.inputPath}", ord(ecGeneralError))
  
  if config.format notin ["webp", "png"]:
    quit(&"Unsupported output format: {config.format}. Use 'webp' or 'png'", ord(ecGeneralError))
  
  if config.threshold < 0 or config.threshold > 255:
    quit("Threshold must be between 0 and 255", ord(ecGeneralError))
  
  if config.quality < 1 or config.quality > 100:
    quit("Quality must be between 1 and 100", ord(ecGeneralError))
  
  if config.blur < 0:
    quit("Blur sigma must be non-negative", ord(ecGeneralError))

proc main() =
  # Initialize libvips
  if vips_init("chroma") != 0:
    quit(&"Failed to initialize libvips: {getVipsError()}", ord(ecGeneralError))
  
  var config = parseArgs()
  validateConfig(config)
  
  let isInputDir = dirExists(config.inputPath)
  let isOutputDir = config.outputPath != "" and (config.outputPath.endsWith("/") or dirExists(config.outputPath) or isInputDir)
  
  var files: seq[string]
  if isInputDir:
    files = findImageFiles(config.inputPath)
    if files.len == 0:
      quit(&"No image files found in: {config.inputPath}", ord(ecGeneralError))
    if config.verbose:
      echo &"Found {files.len} image files"
  else:
    files = @[config.inputPath]
  
  # Create output directory if needed
  if isOutputDir and config.outputPath != "" and not dirExists(config.outputPath):
    createDir(config.outputPath)
  
  var processed = 0
  var skipped = 0
  var usedNames: HashSet[string]
  
  let totalFiles = files.len
  for i, inputFile in files:
    var outPath = generateOutputPath(inputFile, config.outputPath, config.format, isOutputDir)
    
    # Handle collisions for directory output
    if isOutputDir:
      let baseName = outPath.extractFilename
      if baseName in usedNames:
        outPath = resolveCollision(outPath)
      usedNames.incl(outPath.extractFilename)
    
    if processImage(inputFile, outPath, config, i + 1, totalFiles):
      processed += 1
    else:
      skipped += 1
  
  if config.verbose:
    echo &"\nProcessed: {processed}, Skipped: {skipped}"
  
  if processed == 0:
    quit("All files skipped (nothing to process)", ord(ecAllFilesSkipped))

when isMainModule:
  main()
