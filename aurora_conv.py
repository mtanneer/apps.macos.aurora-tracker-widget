from PIL import Image, ImageEnhance

# ========= CONFIG =========
INPUT_IMAGE = "Aurora1.jpg"
OUTPUT_IMAGE = "aurora_processed.png"
OUTPUT_C_FILE = "aurora_bitmap.h"

WIDTH = 512
HEIGHT = 512
COLOR_COUNT = 16
BOOST_COLOR = 1.4
# ==========================


def rgb888_to_rgb565(r, g, b):
    return ((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3)


# Load and resize
img = Image.open(INPUT_IMAGE)
img = img.resize((WIDTH, HEIGHT), Image.LANCZOS)

# Enhance colors (aurora pop)
enhancer = ImageEnhance.Color(img)
img = enhancer.enhance(BOOST_COLOR)

# Reduce palette + dithering
img = img.convert(
    "P",
    palette=Image.ADAPTIVE,
    colors=COLOR_COUNT,
    dither=Image.FLOYDSTEINBERG
)
img = img.convert("RGB")

# Save preview image
img.save(OUTPUT_IMAGE)
print(f"[✓] Saved processed image → {OUTPUT_IMAGE}")

# Generate C header file
with open(OUTPUT_C_FILE, "w") as f:
    f.write(f"// {WIDTH}x{HEIGHT} RGB565 bitmap\n")
    f.write(f"const uint16_t aurora[{WIDTH * HEIGHT}] = {{\n")

    for y in range(HEIGHT):
        f.write("  ")
        for x in range(WIDTH):
            r, g, b = img.getpixel((x, y))
            val = rgb888_to_rgb565(r, g, b)
            f.write(f"0x{val:04X}, ")
        f.write("\n")

    f.write("};\n")

print(f"[✓] Saved bitmap array → {OUTPUT_C_FILE}")