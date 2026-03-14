"""
Extract car/navigation assets from the full Google Maps APK.
Downloads from multiple mirrors, unzips, and extracts all drawable resources.
"""
import os, zipfile, shutil, glob, struct, re, subprocess, sys
from io import BytesIO
import requests

WORK_DIR = os.path.join(os.path.dirname(__file__), "_gmaps_extract")
OUTPUT_DIR = os.path.join(WORK_DIR, "extracted_assets")
APK_PATH = os.path.join(WORK_DIR, "google_maps.apk")
ALL_DRAWABLES = os.path.join(OUTPUT_DIR, "all_drawables")
MATCHED_DIR = os.path.join(OUTPUT_DIR, "matched_car_assets")
os.makedirs(OUTPUT_DIR, exist_ok=True)
os.makedirs(ALL_DRAWABLES, exist_ok=True)
os.makedirs(MATCHED_DIR, exist_ok=True)

KEYWORDS = [
    "car", "nav", "arrow", "vehicle", "chevron", "compass", "direction",
    "marker", "driving", "navigation", "puck", "cursor", "pointer",
    "my_location", "mylocation", "bearing", "heading", "turn", "route",
    "blue_dot", "location_dot", "ic_nav", "ic_car", "ic_direction",
    "trip", "driver", "ride", "uber", "lyft", "taxi"
]

HEADERS = {
    "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36",
    "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
    "Accept-Language": "en-US,en;q=0.5",
}

def _stream_download(url, dest, label=""):
    """Download a large file with progress."""
    try:
        r = requests.get(url, headers=HEADERS, timeout=120, allow_redirects=True, stream=True)
        ctype = r.headers.get('content-type', '')
        clen = int(r.headers.get('content-length', 0))
        # Must be a binary file > 1 MB
        if r.status_code != 200:
            print(f"    HTTP {r.status_code}")
            return False
        if clen > 0 and clen < 500_000:
            print(f"    Too small ({clen} bytes), skipping")
            return False
        # If it's HTML it's a webpage not an APK
        if 'text/html' in ctype and clen < 500_000:
            print(f"    Got HTML page, not APK")
            return False
        total = clen if clen > 0 else None
        print(f"    Downloading... {f'{total/1024/1024:.1f} MB' if total else 'unknown size'}")
        with open(dest, 'wb') as f:
            downloaded = 0
            for chunk in r.iter_content(chunk_size=256*1024):
                f.write(chunk)
                downloaded += len(chunk)
                if total:
                    print(f"\r    {downloaded/1024/1024:.1f} / {total/1024/1024:.1f} MB ({downloaded*100//total}%)", end="", flush=True)
                else:
                    print(f"\r    {downloaded/1024/1024:.1f} MB", end="", flush=True)
        print()
        fsize = os.path.getsize(dest)
        if fsize < 500_000:
            os.remove(dest)
            print(f"    File too small ({fsize} bytes), removed")
            return False
        # Quick check: is it a valid ZIP/APK?
        try:
            zipfile.ZipFile(dest)
            print(f"    Valid APK: {fsize/1024/1024:.1f} MB")
            return True
        except zipfile.BadZipFile:
            os.remove(dest)
            print(f"    Not a valid ZIP/APK, removed")
            return False
    except Exception as e:
        print(f"    Error: {e}")
        return False

def _try_apkcombo():
    """Try APKCombo download page scraping."""
    print("\n[Strategy 1] APKCombo...")
    try:
        page_url = "https://apkcombo.com/google-maps/com.google.android.apps.maps/download/apk"
        r = requests.get(page_url, headers=HEADERS, timeout=30)
        if r.status_code != 200:
            print(f"  Page HTTP {r.status_code}")
            return False
        # Find download links
        links = re.findall(r'href="(https?://[^"]*\.apk[^"]*)"', r.text)
        if not links:
            links = re.findall(r'href="(/download/[^"]*)"', r.text)
            links = [f"https://apkcombo.com{l}" for l in links]
        print(f"  Found {len(links)} download links")
        for link in links[:3]:
            print(f"  Trying: {link[:80]}...")
            if _stream_download(link, APK_PATH):
                return True
    except Exception as e:
        print(f"  Error: {e}")
    return False

def _try_apkpure_scrape():
    """Scrape APKPure download page for real download URL."""
    print("\n[Strategy 2] APKPure page scrape...")
    try:
        page_url = "https://apkpure.com/google-maps/com.google.android.apps.maps/download"
        r = requests.get(page_url, headers=HEADERS, timeout=30)
        if r.status_code != 200:
            print(f"  Page HTTP {r.status_code}")
            return False
        # Find download button URL
        links = re.findall(r'href="(https://d\.apkpure\.[^"]*)"', r.text)
        if not links:
            links = re.findall(r'"(https://download[^"]*\.apk[^"]*)"', r.text)
        print(f"  Found {len(links)} download links")
        for link in links[:3]:
            print(f"  Trying: {link[:80]}...")
            if _stream_download(link, APK_PATH):
                return True
    except Exception as e:
        print(f"  Error: {e}")
    return False

def _try_uptodown():
    """Try Uptodown APK download."""
    print("\n[Strategy 3] Uptodown...")
    try:
        # Get the download page
        page_url = "https://google-maps.en.uptodown.com/android/download"
        r = requests.get(page_url, headers=HEADERS, timeout=30, allow_redirects=True)
        if r.status_code != 200:
            print(f"  Page HTTP {r.status_code}")
            return False
        # Find the actual APK download link
        links = re.findall(r'data-url="([^"]+)"', r.text)
        if not links:
            links = re.findall(r'href="(https://[^"]*download[^"]*)"', r.text)
        print(f"  Found {len(links)} links")
        for link in links[:3]:
            if not link.startswith("http"):
                link = "https://google-maps.en.uptodown.com" + link
            print(f"  Trying: {link[:80]}...")
            if _stream_download(link, APK_PATH):
                return True
    except Exception as e:
        print(f"  Error: {e}")
    return False

def _try_apkmirror():
    """Try APKMirror."""
    print("\n[Strategy 4] APKMirror...")
    try:
        page_url = "https://www.apkmirror.com/apk/google-inc/maps/"
        r = requests.get(page_url, headers=HEADERS, timeout=30)
        if r.status_code != 200:
            print(f"  Page HTTP {r.status_code}")
            return False
        # Find latest version link
        versions = re.findall(r'href="(/apk/google-inc/maps/maps-[^"]*/)"\s', r.text)
        if versions:
            print(f"  Found {len(versions)} versions, checking latest...")
            ver_url = "https://www.apkmirror.com" + versions[0]
            r2 = requests.get(ver_url, headers=HEADERS, timeout=30)
            apk_links = re.findall(r'href="(/apk/google-inc/maps/[^"]*apk[^"]*download[^"]*)"', r2.text)
            if not apk_links:
                apk_links = re.findall(r'href="(/apk/[^"]*\.apk)"', r2.text)
            print(f"  Found {len(apk_links)} APK links")
            for link in apk_links[:3]:
                full = "https://www.apkmirror.com" + link
                print(f"  Trying: {full[:80]}...")
                if _stream_download(full, APK_PATH):
                    return True
        else:
            print("  No version links found")
    except Exception as e:
        print(f"  Error: {e}")
    return False

def _try_f_droid_osmand():
    """As alternative, try OsmAnd (open source nav app) from F-Droid for nav assets."""
    print("\n[Strategy 5] OsmAnd from F-Droid (open-source nav app with car icons)...")
    try:
        url = "https://f-droid.org/repo/net.osmand.plus_4900.apk"
        print(f"  Trying: {url[:80]}...")
        if _stream_download(url, APK_PATH):
            return True
        # Try older version
        url2 = "https://f-droid.org/repo/net.osmand.plus_4800.apk"
        print(f"  Trying: {url2[:80]}...")
        if _stream_download(url2, APK_PATH):
            return True
    except Exception as e:
        print(f"  Error: {e}")
    return False

def _try_waze():
    """Try Waze APK as alternative source for navigation car sprites."""
    print("\n[Strategy 6] Trying alternative navigation APKs...")
    alt_urls = [
        "https://d.apkpure.net/b/APK/com.waze?versionCode=1",
        "https://f-droid.org/repo/com.mapbox.mapboxsdk.testapp_1.apk",
    ]
    for url in alt_urls:
        print(f"  Trying: {url[:80]}...")
        if _stream_download(url, APK_PATH):
            return True
    return False

def download_apk():
    """Try multiple strategies to download a navigation APK."""
    if os.path.exists(APK_PATH) and os.path.getsize(APK_PATH) > 1_000_000:
        try:
            zipfile.ZipFile(APK_PATH)
            print(f"Using cached APK: {APK_PATH} ({os.path.getsize(APK_PATH)/1024/1024:.1f} MB)")
            return True
        except:
            os.remove(APK_PATH)

    strategies = [
        _try_apkcombo,
        _try_apkpure_scrape,
        _try_uptodown,
        _try_apkmirror,
        _try_f_droid_osmand,
        _try_waze,
    ]

    for strategy in strategies:
        if strategy():
            return True

    return False

def extract_all_images_from_apk():
    """Extract all image resources from the APK."""
    print(f"\nExtracting images from APK...")
    try:
        zf = zipfile.ZipFile(APK_PATH)
    except Exception as e:
        print(f"  Cannot open APK: {e}")
        return

    entries = zf.namelist()
    print(f"  Total entries in APK: {len(entries)}")

    img_exts = ('.png', '.webp', '.jpg', '.jpeg', '.svg')
    all_images = [e for e in entries if any(e.lower().endswith(ext) for ext in img_exts)]
    print(f"  Total image files: {len(all_images)}")

    # Extract ALL drawable images
    drawable_imgs = [e for e in all_images if 'res/' in e.lower()]
    print(f"  Resource images: {len(drawable_imgs)}")

    extracted = 0
    matched = 0
    for entry in drawable_imgs:
        basename = os.path.basename(entry)
        # Organize by density folder
        parts = entry.split("/")
        folder = parts[-2] if len(parts) >= 2 else "unknown"

        # Extract to all_drawables
        dest_dir = os.path.join(ALL_DRAWABLES, folder)
        os.makedirs(dest_dir, exist_ok=True)
        dest = os.path.join(dest_dir, basename)
        try:
            data = zf.read(entry)
            with open(dest, "wb") as f:
                f.write(data)
            extracted += 1

            # Check if matches keywords
            name_lower = basename.lower()
            if any(kw in name_lower for kw in KEYWORDS):
                match_dir = os.path.join(MATCHED_DIR, folder)
                os.makedirs(match_dir, exist_ok=True)
                shutil.copy2(dest, os.path.join(match_dir, basename))
                matched += 1
                if matched <= 50:
                    print(f"  MATCH: {folder}/{basename} ({len(data)} bytes)")
        except Exception:
            pass

    print(f"\n  Extracted {extracted} resource images total")
    print(f"  {matched} matched car/navigation keywords")

    # Save full image list
    list_path = os.path.join(OUTPUT_DIR, "ALL_IMAGE_LIST.txt")
    with open(list_path, "w") as f:
        for img in sorted(all_images):
            f.write(img + "\n")
    print(f"  Full list saved to {list_path}")

    # Summary of drawable folders
    print(f"\nDrawable folders extracted:")
    for d in sorted(os.listdir(ALL_DRAWABLES)):
        full = os.path.join(ALL_DRAWABLES, d)
        if os.path.isdir(full):
            count = len(os.listdir(full))
            print(f"  {d}: {count} files")

    zf.close()

def main():
    print("Google Maps APK Car Asset Extractor")
    print("=" * 60)

    ok = download_apk()
    if not ok:
        print("\nCould not download APK from mirrors.")
        print("Manual option: Download Google Maps APK from https://www.apkpure.com/google-maps/com.google.android.apps.maps")
        print(f"Save it as: {APK_PATH}")
        print("Then run this script again.")
        return

    extract_all_images_from_apk()

    print(f"\n{'='*60}")
    print(f"Output: {OUTPUT_DIR}")
    print(f"  all_drawables/   - ALL extracted images by density")
    print(f"  matched_car_assets/ - car/nav keyword matches")
    print(f"\nOpen matched folder to find the car icons!")

if __name__ == "__main__":
    main()
