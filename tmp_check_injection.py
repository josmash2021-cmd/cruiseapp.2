"""Check the injected CSS code in the local file."""
from pathlib import Path

c = Path(r"C:\Users\Puma\Desktop\shopify  code.txt").read_text(encoding="utf-8", errors="ignore")

idx = c.find("__vrCardCSSInjected")
if idx >= 0:
    # Show 200 chars of context around first occurrence
    print(f"Found at {idx}")
    print(c[max(0,idx-50):idx+500])
    print("...")
    
    # Check for Liquid-hostile chars in the injection
    inj_start = c.find("_s.textContent='")
    if inj_start >= 0:
        inj_end = c.find("';document.head", inj_start)
        css_in_js = c[inj_start+len("_s.textContent='"):inj_end]
        print(f"\nCSS in JS string length: {len(css_in_js)}")
        print(f"Contains backslash-quote: {'\\\"' in css_in_js}")
        print(f"Contains double quotes: {'\"' in css_in_js}")
        # Show first problematic spot
        for i, ch in enumerate(css_in_js):
            if ch == '"' or (ch == '\\' and i+1 < len(css_in_js) and css_in_js[i+1] == '"'):
                print(f"  Problematic at {i}: ...{css_in_js[max(0,i-20):i+20]}...")
                break
else:
    print("NOT FOUND!")
