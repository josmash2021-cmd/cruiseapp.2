import sys

with open('routers/auth.py', 'r', encoding='utf-8') as f:
    content = f.read()

marker = '_clear_login_failures(client_ip)'
idx = content.find(marker)
if idx == -1:
    print('MARKER NOT FOUND')
    sys.exit(1)

start = idx - 10
end = content.find('@router.post("', idx)
old_block = content[start:end]

new_block = '''lures
    _clear_login_failures(client_ip)

    # Apple App Store review bypass: skip OTP, return tokens directly
    if user.email and user.email.lower() in ("applereview@cruiseride.com", "applereviewdriver@cruiseride.com"):
        token = await _create_driver_aware_token_from_user(user, db)
        refresh = _create_refresh_token(user.id)
        return {
            "access_token": token,
            "refresh_token": refresh,
            "token_type": "bearer",
            "user": _user_dict(user),
        }

    login_token = _create_login_token(user.id)
    return {
        "login_token": login_token,
        "method": "email" if user.email == body.identifier else "phone",
        "email": user.email,
        "phone": user.phone,
    }

'''

if old_block in content:
    content = content.replace(old_block, new_block)
    with open('routers/auth.py', 'w', encoding='utf-8') as f:
        f.write(content)
    print('REPLACED')
else:
    print('NOT FOUND')
    print(repr(old_block))
    sys.exit(1)
