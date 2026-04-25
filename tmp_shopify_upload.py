#!/usr/bin/env python3
"""Upload vip-ride-mod-steps.js to Shopify CDN via Admin GraphQL API.

Steps:
1. Extract Shopify CLI access token from local config
2. Find & delete existing vip-ride-mod-steps.js files
3. stagedUploadsCreate -> upload to GCS -> fileCreate
4. Poll for CDN URL and print with cache buster
"""
import json, urllib.request, urllib.parse, os, time, io

# 1) Extract token from Shopify CLI config
cfg = json.load(open(r'C:/Users/Puma/AppData/Roaming/shopify-cli-kit-nodejs/Config/config.json'))
store_data = json.loads(cfg['sessionStore'])
session = store_data['accounts.shopify.com']
sid = list(session.keys())[0]
apps = session[sid]['applications']
token = None
for k, v in apps.items():
    if 'cruise-8575' in k:
        token = v['accessToken']
        break
if not token:
    for k, v in apps.items():
        if v.get('scopes') == ['*']:
            token = v['accessToken']
            break

if not token:
    print('ERROR: No token found')
    exit(1)

print('Token found, length:', len(token))
SHOP = 'cruise-8575.myshopify.com'
API_VER = '2025-01'
GQL_URL = f'https://{SHOP}/admin/api/{API_VER}/graphql.json'

def gql(query, variables=None):
    payload = {'query': query}
    if variables:
        payload['variables'] = variables
    data = json.dumps(payload).encode('utf-8')
    req = urllib.request.Request(GQL_URL, data=data, headers={
        'Content-Type': 'application/json',
        'X-Shopify-Access-Token': token
    })
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read())

# 2) Find existing vip-ride-mod-steps.js files
print('\n--- Step 1: Finding existing files ---')
find_q = '''
query {
  files(first: 10, query: "filename:vip-ride-mod-steps") {
    edges {
      node {
        ... on GenericFile {
          id
          url
          originalFileSize
          createdAt
        }
      }
    }
  }
}
'''
result = gql(find_q)
print(json.dumps(result, indent=2))

files_found = result.get('data', {}).get('files', {}).get('edges', [])
file_ids = [e['node']['id'] for e in files_found if e['node'].get('id')]
print(f'Found {len(file_ids)} existing file(s)')

# 3) Delete old files
if file_ids:
    print('\n--- Step 2: Deleting old files ---')
    delete_mut = '''
    mutation fileDelete($input: [ID!]!) {
      fileDelete(fileIds: $input) {
        deletedFileIds
        userErrors {
          field
          message
        }
      }
    }
    '''
    del_result = gql(delete_mut, {'input': file_ids})
    print(json.dumps(del_result, indent=2))
    print('Waiting 3s for deletion to propagate...')
    time.sleep(3)
else:
    print('No old files to delete.')

# 4) Create staged upload
print('\n--- Step 3: Creating staged upload ---')
staged_mut = '''
mutation stagedUploadsCreate($input: [StagedUploadInput!]!) {
  stagedUploadsCreate(input: $input) {
    stagedTargets {
      url
      resourceUrl
      parameters {
        name
        value
      }
    }
    userErrors {
      field
      message
    }
  }
}
'''
staged_result = gql(staged_mut, {
    'input': [{
        'resource': 'FILE',
        'filename': 'vip-ride-mod-steps.js',
        'mimeType': 'application/javascript',
        'httpMethod': 'POST'
    }]
})
print(json.dumps(staged_result, indent=2))

targets = staged_result.get('data', {}).get('stagedUploadsCreate', {}).get('stagedTargets', [])
if not targets:
    print('ERROR: No staged target returned')
    exit(1)

target = targets[0]
upload_url = target['url']
resource_url = target['resourceUrl']
params = {p['name']: p['value'] for p in target['parameters']}

print(f'Upload URL: {upload_url}')
print(f'Resource URL: {resource_url}')

# 5) Upload the file using multipart/form-data
print('\n--- Step 4: Uploading file ---')
file_path = r'C:/Users/Puma/Desktop/website cruise/vip-ride-mod-steps.js'
file_content = open(file_path, 'rb').read()
print(f'File size: {len(file_content)} bytes')

boundary = '----WebKitFormBoundary7MA4YWxkTrZu0gW'
body = io.BytesIO()

for name, value in params.items():
    body.write(f'--{boundary}\r\n'.encode())
    body.write(f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode())
    body.write(f'{value}\r\n'.encode())

body.write(f'--{boundary}\r\n'.encode())
body.write(b'Content-Disposition: form-data; name="file"; filename="vip-ride-mod-steps.js"\r\n')
body.write(b'Content-Type: application/javascript\r\n\r\n')
body.write(file_content)
body.write(f'\r\n--{boundary}--\r\n'.encode())

upload_data = body.getvalue()
upload_req = urllib.request.Request(upload_url, data=upload_data, headers={
    'Content-Type': f'multipart/form-data; boundary={boundary}',
    'Content-Length': str(len(upload_data))
})
try:
    with urllib.request.urlopen(upload_req, timeout=60) as resp:
        upload_resp = resp.read().decode('utf-8')
        print(f'Upload status: {resp.status}')
        print(f'Upload response: {upload_resp[:500]}')
except urllib.error.HTTPError as e:
    print(f'Upload error: {e.code} {e.reason}')
    print(e.read().decode('utf-8')[:500])
    exit(1)

# 6) Create file entry
print('\n--- Step 5: Creating file entry ---')
file_create_mut = '''
mutation fileCreate($files: [FileCreateInput!]!) {
  fileCreate(files: $files) {
    files {
      ... on GenericFile {
        id
        url
        createdAt
      }
    }
    userErrors {
      field
      message
    }
  }
}
'''
file_result = gql(file_create_mut, {
    'files': [{
        'originalSource': resource_url,
        'contentType': 'FILE'
    }]
})
print(json.dumps(file_result, indent=2))

# 7) Wait and poll for the file to be ready
print('\n--- Step 6: Polling for CDN URL ---')
time.sleep(3)

poll_q = '''
query {
  files(first: 5, query: "filename:vip-ride-mod-steps", sortKey: CREATED_AT, reverse: true) {
    edges {
      node {
        ... on GenericFile {
          id
          url
          createdAt
        }
      }
    }
  }
}
'''
for attempt in range(5):
    poll_result = gql(poll_q)
    edges = poll_result.get('data', {}).get('files', {}).get('edges', [])
    if edges and edges[0]['node'].get('url'):
        cdn_url = edges[0]['node']['url']
        print('\n=== CDN URL ===')
        print(cdn_url)
        ts = int(time.time())
        if '?' in cdn_url:
            busted = cdn_url.split('?')[0] + '?v=' + str(ts)
        else:
            busted = cdn_url + '?v=' + str(ts)
        print('\n=== CDN URL with cache buster ===')
        print(busted)
        break
    print(f'Attempt {attempt+1}: file not ready yet, waiting 3s...')
    time.sleep(3)
else:
    print('File not ready after 15s. Check Shopify admin manually.')
    print(json.dumps(poll_result, indent=2))

print('\nDone!')
