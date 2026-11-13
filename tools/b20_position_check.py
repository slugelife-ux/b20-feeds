#!/usr/bin/env python3
"""b20_position_check.py — verify a real holder's B20 position math on Base.

Finds a real holder from Transfer logs (no credentials, addresses only),
then cross-checks:
  shares  = balanceOf(h) * uiMultiplier / 1e18   (truncating)
          == balanceOfUI(h)                      (the token's own view — must match to the last digit)
  usd     = balanceOf(h) * feed answer / 1e8     (feed is already multiplier-adjusted)

Tail tokens without a feed are counted, never priced.
"""
import json, time, urllib.request

UA = {'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64) b20-feeds-position/1.0'}
BASE_RPC = "https://base-rpc.publicnode.com"  # log-friendly free endpoint
TRANSFER_TOPIC0 = '0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef'
SEL_BALANCE = '0x70a08231'       # balanceOf(address)
SEL_BALANCE_UI = '0x437a9958'    # balanceOfUI(address)
SEL_UI_MULT = '0xa60bf13d'       # uiMultiplier()
SEL_CANON_MULT = '0x1b3ed722'    # multiplier()
SEL_LATEST = '0xfeaf968c'
FEEDS = {  # Chainlink Coinbase feed proxies (multiplier-adjusted token NAV, 8 decimals)
    'AAPL': '0x787f13dEa48Db0897CbCDD985de77809D837F988',
    'AMZN': '0x06A8E4b3aBB3B7543d8396FB2B763d22820cB295',
    'GOOGL': '0x5bF49E0ffA937CE2FfF033c739aD7C634c4D34F2',
    'META': '0x6526aE6797A76123638b863AeE4dD27Ba4E4b27D',
    'MSFT': '0xeB10A6c9aa7E537aEd766C08c35Dae35B321b18c',
    'MSTR': '0xB3cE282CD188b35DA0E38D8Bc7d58e33173D202a',
    'NVDA': '0x04689a41629776563E6822F76f2e57D148d28513',
    'SNDK': '0x388b0dC46C0Fb05A74BeE0994fa5b02c6Fcca2eA',
    'SPCX': '0x6A634B235903C4ad6376892180d6fF8612e3Fa68',
    'TSLA': '0xFaf869185383a24F8cb00e27BdA6b63B9905DCb4',
}
TOKENS = {  # minted tokenized stocks (supply > 0) to scan for holders
    'AAPLc': '0xb200000000000000000000C2e324d24d7eEcd1fb',
    'NVDAc': '0xb20000000000000000000078ee7ce2fE4908108C',
    'GOOGLc': '0xb2000000000000000000002D0BA3164cc74f58B7',
}

def rpc(method, params, retries=4):
    import time as _t
    for attempt in range(retries):
        req = urllib.request.Request(BASE_RPC, json.dumps(
            {"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode(),
            {**UA, 'Content-Type': 'application/json'})
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                d = json.loads(r.read())
        except urllib.error.HTTPError as e:
            if e.code == 429 and attempt < retries - 1:
                _t.sleep(2 * (attempt + 1))
                continue
            raise
        if 'error' in d:
            raise RuntimeError(d['error'].get('message', 'rpc error'))
        return d['result']
    raise RuntimeError('rpc retries exhausted')

def call(addr, data):
    raw = rpc('eth_call', [{'to': addr, 'data': data}, 'latest'])
    return int(raw, 16) if raw != '0x' else None

def find_holder(token):
    head = int(rpc('eth_blockNumber', []), 16)
    for window_start in range(head, max(head - 40000, 0), -2000):
        lo, hi = max(window_start - 2000, 0), window_start
        try:
            logs = rpc('eth_getLogs', [{
                'fromBlock': hex(lo), 'toBlock': hex(hi),
                'address': token, 'topics': [TRANSFER_TOPIC0]}])
        except Exception as e:
            print(f"  (log window {lo}-{hi} failed: {e}; skipping)")
            time.sleep(1)
            continue
        seen = set()
        for lg in logs:
            to = '0x' + lg['topics'][2][-40:]
            if to in seen:
                continue
            seen.add(to)
            bal = call(token, SEL_BALANCE + to[2:].lower().zfill(64))
            if bal and bal > 10**8:  # > 1 whole token
                return to, bal, hex(lo), hex(hi), len(logs)
    return None, None, None, None, 0

def main():
    art = {'checked_at': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()), 'positions': []}
    for sym, token in TOKENS.items():
        holder, bal, lo, hi, nlogs = find_holder(token)
        if not holder:
            print(f"{sym}: no holder with balance > 1 token found in scanned window")
            continue
        # multiplier: alias first, canonical fallback (same WAD value)
        m = call(token, SEL_UI_MULT)
        if m is None:
            m = call(token, SEL_CANON_MULT)
        bal_ui = call(token, SEL_BALANCE_UI + holder[2:].lower().zfill(64))
        shares = (bal * m) // 10**18  # truncating, per issuer docs
        base_sym = sym.rstrip('c')
        entry = {'token': sym, 'token_address': token, 'holder': holder,
                 'raw_balance': bal, 'ui_multiplier_wad': m,
                 'computed_shares': shares, 'balanceOfUI': bal_ui,
                 'window': [lo, hi], 'logs_scanned': nlogs}
        if base_sym in FEEDS:
            raw = rpc('eth_call', [{'to': FEEDS[base_sym], 'data': SEL_LATEST}, 'latest'])[2:]
            w = [int(raw[i:i+64], 16) for i in range(0, len(raw), 64)]
            answer = (w[1] - 2**256 if w[1] >= 2**255 else w[1]) / 1e8
            usd = bal * answer / 1e8
            entry['feed_answer_usd'] = answer
            entry['usd_value'] = usd
            ok = (shares == bal_ui)
            print(f"{sym} holder {holder}")
            print(f"  raw={bal/1e8:.6f} tokens  multiplier={m/1e18:.6f}  shares computed={shares/1e8:.6f}")
            print(f"  balanceOfUI (token's own view) = {bal_ui/1e8:.6f}  -> {'MATCH' if ok else 'MISMATCH'}")
            print(f"  usd = raw x feed({answer:.4f}) = ${usd:,.2f}   (no double multiplier)")
            art['positions'].append(entry)
            if not ok:
                print("  !! POSITION MATH MISMATCH — do not ship")
                art['math_ok'] = False
        else:
            print(f"{sym} holder {holder}: {bal/1e8:.6f} tokens, {shares/1e8:.6f} shares "
                  f"(no feed — counted, not priced)")
            art['positions'].append(entry)

    if 'math_ok' not in art:
        art['math_ok'] = all(p.get('computed_shares') == p.get('balanceOfUI') for p in art['positions'])
    out = 'tools/position_check_result.json'
    with open(out, 'w') as f:
        json.dump(art, f, indent=1)
    print(f"\nmath_ok: {art['math_ok']}\nartifact: {out}")

if __name__ == '__main__':
    main()
