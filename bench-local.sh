#!/bin/bash
# Local adaptation of p14s-setup/toolbox-raw/bench-host.sh — same prompt shape
# (1500x code line + nonce => ~18k tokens, cold prefill), same reported fields.
ARM="$1"; N="${2:-3}"
for i in $(seq 1 "$N"); do
  NONCE=$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')
  python3 - "$NONCE" > /tmp/bv.json <<'PY'
import json,sys
head=f"// session {sys.argv[1]}\n"
body="void f(int x){ return x+1; }\n"*1500
print(json.dumps({"messages":[{"role":"user","content":head+body+"\n\nSummarize the code above in three sentences."}],
                  "max_tokens":300,"stream":False,"temperature":0.7}))
PY
  curl -s -m 1800 "http://127.0.0.1:8080/v1/chat/completions" -H "Content-Type: application/json" --data @/tmp/bv.json \
  | python3 -c "
import json,sys
d=json.load(sys.stdin); t=d.get('timings',{})
dn,da=t.get('draft_n') or 0,t.get('draft_n_accepted') or 0
print('%s\t%s\t%s\t%s\t%.2f\t%.3f\t%.2f'%('$ARM','$i',t.get('prompt_n'),t.get('cache_n'),
  t.get('prompt_per_second') or 0,t.get('predicted_per_second') or 0,(100.0*da/dn) if dn else float('nan')))
"
done
