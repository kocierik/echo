import json
from PIL import Image
src = Image.open("/work/docs/app-icon/icon-1024.png").convert("RGB")  # no alpha: iOS refuses it
def save(path, px):
    src.resize((px, px), Image.LANCZOS).save(path, optimize=True)
ios = "/work/mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset"
for image in json.load(open(f"{ios}/Contents.json"))["images"]:
    if "filename" in image:
        size = float(image["size"].split("x")[0]); scale = int(image["scale"][0])
        save(f"{ios}/{image['filename']}", round(size * scale))
for density, px in {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}.items():
    save(f"/work/mobile/android/app/src/main/res/mipmap-{density}/ic_launcher.png", px)
web = "/work/mobile/web"
for name, px in {"icons/Icon-192.png": 192, "icons/Icon-512.png": 512,
                 "icons/Icon-maskable-192.png": 192, "icons/Icon-maskable-512.png": 512,
                 "favicon.png": 64}.items():
    save(f"{web}/{name}", px)
print("ok")
