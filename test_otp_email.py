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

print('Waiting 60s for Railway redeploy...')
time.sleep(60)

for i in range(8):
    time.sleep(15)
    try:
        start = time.time()
        data = json.dumps({'email': 'royalpurplecorp@gmail.com'}).encode()
        req = urllib.request.Request(BASE+'/auth/send-otp', data=data, headers=hdr(), method='POST')
        r = urllib.request.urlopen(req, timeout=15)
        elapsed = round(time.time()-start, 1)
        resp = json.loads(r.read().decode())
        method = resp.get('method', '?')
        ok = resp.get('ok')
        code = resp.get('code')
        print(f'[{(i+1)*15+60}s] ({elapsed}s) ok={ok} method={method}', end='')
        if code:
            print(f' code={code} (SMTP failed - still using fallback)')
        else:
            print(' -> EMAIL SENT VIA SMTP!')
        break
    except urllib.error.HTTPError as e:
        print(f'HTTP {e.code}: {e.read().decode()[:100]}')
    except Exception as e:
        print(f'[{(i+1)*15+60}s] {str(e)[:60]}')
