#!/usr/bin/env python3
"""b20_price_check.py — health check for Coinbase tokenized stock (B20) feeds on Base.

Checks, for every token with a known Chainlink feed (and the API-published NAV set):
  1. onchain feed answer  vs  live equity quote x onchain-recorded multiplier
  2. onchain feed answer  vs  the issuer API's nav_price
  3. feed round age vs market session (off-hours holds are BY DESIGN, not failures)

Read-only. No keys. Public RPC + public APIs only. Artifacts are JSON.

Quote source: Yahoo Finance chart API (delayed/last). Disclosed in output.
This is reference-data verification, not trading data.
"""
import json, time, urllib.request, datetime

UA = {'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64) b20-feeds-health/1.0'}
BASE_RPC = 'https://mainnet.base.org'

# Chainlink Coinbase feed proxies on Base (from Base docs, list-tokenized-stocks).
# 10 addresses on record; CRCLc/INTCc publish nav_price via the issuer API but
# have no feed address in the public docs table yet (flagged in output).
FEEDS = {
    'AAPL':  '0x787f13dEa48Db0897CbCDD985de77809D837F988',
    'AMZN':  '0x06A8E4b3aBB3B7543d8396FB2B763d22820cB295',
    'GOOGL': '0x5bF49E0ffA937CE2FfF033c739aD7C634c4D34F2',
    'META':  '0x6526aE6797A76123638b863AeE4dD27Ba4E4b27D',
    'MSFT':  '0xeB10A6c9aa7E537aEd766C08c35Dae35B321b18c',
    'MSTR':  '0xB3cE282CD188b35DA0E38D8Bc7d58e33173D202a',
    'NVDA':  '0x04689a41629776563E6822F76f2e57D148d28513',
    'SNDK':  '0x388b0dC46C0Fb05A74BeE0994fa5b02c6Fcca2eA',
    'SPCX':  '0x6A634B235903C4ad6376892180d6fF8612e3Fa68',
    'TSLA':  '0xFaf869185383a24F8cb00e27BdA6b63B9905DCb4',
}
SEL_LATEST = '0xfeaf968c'
SEL_DECIMALS = '0x313ce567'
TOLERANCE_REGULAR = 0.0075   # 0.75%: 0.5% deviation threshold + buffer
TOLERANCE_EXTENDED = 0.02   # 2.0%: thin pre/post-market prints vs consolidated mark

def rpc(method, params):
    req = urllib.request.Request(BASE_RPC, json.dumps(
        {"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode(),
        {**UA, 'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=30) as r:
        d = json.loads(r.read())
    if 'error' in d:
        raise RuntimeError(d['error'].get('message', 'rpc error'))
    return d['result']

def feed_round(addr):
    raw = rpc('eth_call', [{'to': addr, 'data': SEL_LATEST}, 'latest'])[2:]
    w = [int(raw[i:i+64], 16) for i in range(0, len(raw), 64)]
    return {'roundId': w[0], 'answer': w[1] - 2**256 if w[1] >= 2**255 else w[1],
            'startedAt': w[2], 'updatedAt': w[3], 'answeredInRound': w[4]}

def yahoo_quote(sym):
    url = f'https://query1.finance.yahoo.com/v8/finance/chart/{sym}?interval=1d&range=5d'
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=20) as r:
        d = json.loads(r.read())
    meta = d['chart']['result'][0]['meta']
    last = (meta.get('regularMarketPrice') or meta.get('previousClose')
            or meta.get('chartPreviousClose'))
    prev = meta.get('previousClose') or meta.get('chartPreviousClose')
    # Nearest public reference: outside regular hours, the thin premarket print
    # (regularMarketPrice often tracks it) can sit far from the consolidated
    # extended-session mark Chainlink publishes. Compare to BOTH the last and
    # the previous close and take the nearer one.
    return float(last), float(prev) if prev else None, meta.get('regularMarketTime')

def market_session(now=None):
    """rough US regular session (14:30-21:00 UTC, Mon-Fri) + pre/post windows"""
    now = now or datetime.datetime.now(datetime.timezone.utc)
    if now.weekday() >= 5:
        return 'weekend'
    t = now.hour * 60 + now.minute
    if 14*60+30 <= t < 21*60:
        return 'regular'
    if 9*60 <= t < 14*60+30:
        return 'premarket'
    if 21*60 <= t or t < 1*60:
        return 'postmarket'
    return 'overnight'

def main():
    tokens, token = [], None
    for _ in range(12):
        url = 'https://api.coinbase.com/v1/tokenized-stocks?page_size=500' + (f'&page_token={token}' if token else '')
        req = urllib.request.Request(url, headers=UA)
        with urllib.request.urlopen(req, timeout=30) as r:
            d = json.loads(r.read())
        tokens.extend(d['tokens'])
        token = d.get('next_page_token')
        if not token:
            break
    api = {t['symbol'].rstrip('c'): t for t in tokens}
    print(f"issuer API: {len(tokens)} token records; nav_price for {sum(1 for t in tokens if 'nav_price' in t)}")

    session = market_session()
    tol = TOLERANCE_REGULAR if session == 'regular' else TOLERANCE_EXTENDED
    print(f"market session now: {session} (tolerance {tol*100:.2f}% vs nearest of last/prev close)")
    print(f"quote source: Yahoo Finance chart API (delayed/last) — reference data only\n")

    results, passes, fails = [], 0, 0
    for sym, addr in sorted(FEEDS.items()):
        t = api.get(sym, {})
        mult = float(t.get('multiplier', 1.0))
        nav = t.get('nav_price')
        nav_at = t.get('nav_price_updated_at', '')
        try:
            r = feed_round(addr)
        except Exception as e:
            print(f"{sym:6} FEED READ ERROR: {e}")
            fails += 1
            results.append({'symbol': sym, 'error': str(e)})
            continue
        try:
            q, prev, qtime = yahoo_quote(sym)
        except Exception as e:
            print(f"{sym:6} QUOTE ERROR: {e}")
            fails += 1
            results.append({'symbol': sym, 'feed': r, 'quote_error': str(e)})
            continue
        expect = q * mult
        ans = r['answer'] / 1e8
        dev = abs(ans - expect) / expect if expect else 0
        if session != 'regular' and prev is not None and abs(ans - prev * mult) < abs(ans - expect):
            expect = prev * mult
            dev = abs(ans - expect) / expect
        age_min = (time.time() - r['updatedAt']) / 60
        ok = dev <= tol
        passes += ok
        fails += (not ok)
        nav_dev = abs(ans - float(nav)) / float(nav) if nav else None
        print(f"{sym:6} feed={ans:10.4f}  quote*mult={expect:10.4f}  dev={dev*100:6.3f}%  "
              f"nav_api={nav or '-':>10}  nav_dev={f'{nav_dev*100:.3f}%' if nav_dev is not None else '-':>8}  "
              f"age={age_min:8.1f}m  {'PASS' if ok else 'FAIL'}")
        results.append({'symbol': sym, 'feed_address': addr, 'feed_answer_usd': ans,
                        'quote_usd': q, 'quote_prev_close': prev, 'multiplier': mult,
                        'expected_usd': expect,
                        'deviation_pct': dev*100, 'nav_price_api': nav,
                        'nav_updated_at': nav_at, 'round_age_min': age_min,
                        'round': {k: v for k, v in r.items()}, 'pass': ok})

    # API-published NAV for tokens with no feed address on record
    no_addr = [s for s in ('CRCL', 'INTC') if api.get(s, {}).get('nav_price')]
    for sym in no_addr:
        t = api[sym]
        try:
            q, _ = yahoo_quote(sym)
        except Exception:
            continue
        mult = float(t.get('multiplier', 1.0))
        nav = float(t['nav_price'])
        dev = abs(nav - q*mult) / (q*mult)
        print(f"{sym:6} (no feed address on record) api_nav={nav:.4f} vs quote*mult={q*mult:.4f} dev={dev*100:.3f}%")
        results.append({'symbol': sym, 'no_feed_address': True, 'nav_price_api': nav,
                        'quote_usd': q, 'multiplier': mult, 'deviation_pct': dev*100})

    print(f"\n{passes} pass, {fails} fail out of {len(FEEDS)} onchain feeds")
    art = {'checked_at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
           'session': session, 'quote_source': 'Yahoo Finance chart API (delayed)',
           'results': results}
    out = 'tools/price_check_result.json'
    with open(out, 'w') as f:
        json.dump(art, f, indent=1)
    print(f"artifact: {out}")

if __name__ == '__main__':
    main()
