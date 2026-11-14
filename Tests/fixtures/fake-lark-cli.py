#!/usr/bin/python3
"""Local CLI stand-in. Never reads credentials or contacts Feishu."""
import json
import sys
import time

args = sys.argv[1:]
if args == ['test-large-output']:
    sys.stderr.write('x' * 262144)
    print(json.dumps({'ok': True, 'data': 'x' * 262144}))
elif args == ['test-wait']:
    time.sleep(30)
elif args[:2] == ['auth', 'status']:
    print(json.dumps({'identities': {'user': {'status': 'ready', 'available': True,
          'verified': True, 'openId': 'test-user', 'userName': '测试账号'}}}))
elif args[:2] == ['auth', 'login'] and '--no-wait' in args:
    assert args[args.index('--domain') + 1] == 'calendar'
    assert '--json' in args
    print(json.dumps({'device_code': 'success', 'verification_url':
          'https://example.com/verify?user_code=TEST&flow_id=EXAMPLE', 'expires_in': 600}))
elif args[:2] == ['auth', 'login'] and '--device-code' in args:
    code = args[args.index('--device-code') + 1]
    if code == 'success':
        print(json.dumps({'event': 'authorization_complete', 'user_open_id': 'test-user'}))
    else:
        print(json.dumps({'ok': False, 'error': {'type': 'authentication',
              'subtype': 'access_denied', 'message': 'authorization denied or expired'}}))
        sys.exit(3)
else:
    sys.exit(1)
