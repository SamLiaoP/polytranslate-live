#!/bin/bash
# 建一張自簽的程式碼簽署憑證「PolyTranslate Live Dev」放進登入鑰匙圈。
# build.sh 偵測到它就改用它簽名；之後重新編譯，「螢幕與系統錄音」等授權都會保留，
# 不像 ad-hoc 簽名每次重建 cdhash 都變、授權就失效。
# 過程會跳一次系統密碼視窗（把憑證設為「程式碼簽署可信任」用）。
set -euo pipefail
NAME="PolyTranslate Live Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$NAME\""; then
  echo "✓ 憑證已存在：$NAME"
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
subjectKeyIdentifier = hash
CNF

echo "→ 產生憑證"
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" -extensions ext \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/cert.p12" \
  -passout pass:polytranslate -name "$NAME"

echo "→ 匯入登入鑰匙圈"
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P polytranslate -T /usr/bin/codesign -T /usr/bin/security >/dev/null

echo "→ 設為程式碼簽署可信任（會要系統密碼）"
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
  echo "✓ 建好了：$NAME"
  echo "  之後 ./build.sh install 會自動用它簽名。第一次簽名若跳出「codesign 想要使用鑰匙圈中的金鑰」，按「永遠允許」。"
  echo "  換了簽名身分後，macOS 會把 App 當成新的 App，「螢幕與系統錄音」要再授權最後一次。"
else
  echo "✗ 憑證沒有出現在可用的簽署身分裡，請打開「鑰匙圈存取」確認「$NAME」的信任設定是「程式碼簽署：永遠信任」。"
  exit 1
fi
