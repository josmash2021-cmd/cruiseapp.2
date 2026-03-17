import urllib.request, json, time, hmac, hashlib, secrets

BASE = 'https://cruiseapp2-production.up.railway.app'
API_KEY = 'HWB88VurhLM-1GdVML2PT92iqNSbeJ52TU1VO37MBZS6RYlyWvfIpaTdD54GT_5u'
HMAC_SECRET = 'qUDmTNu1Dxxg_xo7kaUfRba4XiU_5H1ZhkUMDuVrD2dLQ2ImT8JXZ5FgUyXpSJ5h'

def hdr():
    ts = str(int(time.time()))
    n = secrets.token_hex(8)
    fp = 'test123'
    sig = hmac.new(HMAC_SECRET.encode(), (API_KEY+':'+ts+':'+n+':'+fp).encode(), hashlib.sha256).hexdigest()
    return {
        'Content-Type': 'application/json',
        'X-API-Key': API_KEY,
        'X-Timestamp': ts,
        'X-Nonce': n,
        'X-Signature': sig,
        'X-Device-FP': fp,
        'X-Client-Version': '1.0.0'
    }

# Poll every 20s for up to 5 minutes until method=email
for i in range(15):
    time.sleep(20)
    try:
        data = json.dumps({'email': 'royalpurplecorp@gmail.com'}).encode()
        req = urllib.request.Request(BASE+'/auth/send-otp', data=data, headers=hdr(), method='POST')
        start = time.time()
        r = urllib.request.urlopen(req, timeout=15)
        elapsed = round(time.time()-start, 1)
        resp = json.loads(r.read().decode())
        method = resp.get('method', '?')
        code = resp.get('code')
        print(f'[{(i+1)*20}s] ({elapsed}s) method={method}', end='')
        if method == 'email':
            print(' -> EMAIL SENT! Check royalpurplecorp@gmail.com inbox')
            break
        elif code:
            print(f' code={code} (still fallback)')
        else:
            print()
    except Exception as e:
        print(f'[{(i+1)*20}s] {str(e)[:60]}')
