import port; port.FIXED = True
exec(open('/tmp/hunt/p48/test_p48.py').read().replace('import asyncio, sys, port','import asyncio, sys'))
